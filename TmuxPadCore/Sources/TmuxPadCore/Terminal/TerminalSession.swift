import Foundation

/// Терминал одной tmux-сессии без view (§5, §6, §6.1): PTY-канал `attach NAME` через пул,
/// вывод в `TerminalSurface`, `copy-cancel` перед первым вводом после скролла (§3.5),
/// правило выбивания «один раз молча, второй раз за `kickWindow` — плашка».
public actor TerminalSession {
    public nonisolated let server: ServerConnection
    public nonisolated let name: String
    public nonisolated let kickWindow: Duration
    public private(set) var state: TerminalState = .connecting

    private let surface: any TerminalSurface
    private let log: DiagnosticsLog
    private var pty: (any PTYChannel)?
    /// Растёт при каждой операции, которая меняет канал (`detach`, `take`, `reconnect`):
    /// конец вывода старого канала и устаревшие ожидания сравнивают номер и молча выходят.
    private var generation = 0
    private var userDetached = false
    private var needsCopyCancel = false
    /// Когда нас в прошлый раз выбил чужой `attach -d`.
    private var lastKick: ContinuousClock.Instant?
    /// Ожидание `.connected` от пула в состоянии `.offline`.
    private var waitTask: Task<Void, Never>?
    /// Хвост очереди ввода: `send` идут в порядке вызова, даже если ждут `copy-cancel`.
    private var sendTail: Task<Void, Never>?

    public init(
        server: ServerConnection,
        name: String,
        surface: any TerminalSurface,
        log: DiagnosticsLog? = nil,
        kickWindow: Duration = .seconds(60)
    ) {
        self.server = server
        self.name = name
        self.surface = surface
        self.log = log ?? server.log
        self.kickWindow = kickWindow
    }

    deinit {
        waitTask?.cancel()
        if let pty {
            Task { await pty.close() }
        }
    }

    // MARK: - Действия UI

    /// Открывает канал `attach`. Ошибки не бросает: они видны в `state`.
    public func start() async {
        guard pty == nil else {
            return
        }
        let current = await begin()
        setState(.connecting)
        await open(take: false, current)
    }

    /// Ввод с клавиатуры. После скролла вверх сначала `copy-cancel` через exec (ошибки — только
    /// в журнал), иначе tmux в copy-mode проглотит ввод.
    public func send(_ data: Data) async throws {
        let previous = sendTail
        let cancelFirst = needsCopyCancel
        needsCopyCancel = false
        let channel = pty
        let server = server
        let name = name
        let log = log
        let task = Task<Void, Error> {
            await previous?.value
            if cancelFirst {
                do {
                    try await server.api.copyCancel(session: name)
                } catch {
                    await log.record(server: await server.config.label, kind: .terminal, "\(name): copy-cancel failed: \(error)")
                }
            }
            guard let channel else {
                throw SSHError.disconnected
            }
            try await channel.send(data)
        }
        sendTail = Task { _ = await task.result }
        try await task.value
    }

    /// UI прокрутил вверх (чип «Прокрутка»): следующий ввод сначала выведет pane из copy-mode.
    public func noteScrolledUp() {
        needsCopyCancel = true
    }

    public func resize(cols: Int, rows: Int) async throws {
        try await pty?.resize(cols: cols, rows: rows)
    }

    /// Закрыть терминал; tmux-сессия на сервере остаётся.
    public func detach() async {
        userDetached = true
        _ = await begin()
        setState(.ended)
        await record("detached by app")
    }

    /// «Забрать»: `take` выкидывает всех прочих клиентов (§6.1).
    public func take() async {
        let current = await begin()
        setState(.reconnecting)
        await record("take")
        await open(take: true, current)
    }

    /// Новый канал `attach`: возврат из фона, «Переподключить», «Повторить».
    public func reconnect() async {
        let current = await begin()
        setState(.reconnecting)
        await open(take: false, current)
    }

    // MARK: - Канал

    /// Новая операция: гасит ожидание и закрывает текущий канал.
    private func begin() async -> Int {
        generation += 1
        let current = generation
        waitTask?.cancel()
        waitTask = nil
        let old = pty
        pty = nil
        await old?.close()
        return current
    }

    /// Открывает канал и запускает чтение; неудача — `.offline`, при мёртвом соединении с
    /// ожиданием пула.
    private func open(take: Bool, _ current: Int) async {
        do {
            try await openChannel(take: take, current)
        } catch {
            guard current == generation else {
                return
            }
            await failed(error, current)
        }
    }

    private func openChannel(take: Bool, _ current: Int) async throws {
        userDetached = false
        let api = await server.api
        let command = take ? try api.takeCommand(session: name) : try api.attachCommand(session: name)
        let size = surface.size
        let channel = try await server.openPTY(command: command, cols: size.cols, rows: size.rows)
        guard current == generation, !userDetached else {
            await channel.close()
            return
        }
        pty = channel
        setState(.live)
        let surface = surface
        Task.detached { [weak self] in
            var failure: Error?
            do {
                for try await chunk in channel.output {
                    surface.feed(chunk)
                }
            } catch {
                failure = error
            }
            await self?.channelEnded(current, exitCode: channel.exitCode, error: failure)
        }
    }

    /// Вывод канала кончился без нашего `detach`.
    private func channelEnded(_ current: Int, exitCode: Int?, error: Error?) async {
        guard current == generation, !userDetached else {
            return
        }
        pty = nil
        if let error {
            await transportLost(Self.describe(error), current)
            return
        }
        await record("channel closed, exit \(exitCode.map(String.init) ?? "none")")
        if exitCode == 4 {
            setState(.ended)
            return
        }
        // nil — канал закрылся без exit-status: так бывает и при обрыве соединения
        guard await server.state.isConnected else {
            await transportLost("connection lost", current)
            return
        }
        guard current == generation, !userDetached else {
            return
        }
        await checkSession(current, exitCode: exitCode)
    }

    /// Канал кончился без `detach`: сессии нет — `.ended` при любом коде (её могли убить, пока
    /// скрипт готовил `attach`); есть и код 0 — нас выбил чужой `attach -d`; есть и прочий код —
    /// `.offline` без повторов (имя, окружение, скрипт повтором не лечатся).
    private func checkSession(_ current: Int, exitCode: Int?) async {
        let snapshot: ServerSnapshot
        do {
            snapshot = try await server.api.list()
        } catch {
            guard current == generation, !userDetached else {
                return
            }
            await transportLost("list failed: \(Self.describe(error))", current)
            return
        }
        guard current == generation, !userDetached else {
            return
        }
        guard snapshot.sessions.contains(where: { $0.name == name }) else {
            setState(.ended)
            await record("session gone")
            return
        }
        if let exitCode, exitCode != 0 {
            let error = HostError.from(command: .attach(session: name), exitCode: exitCode, stderr: "")
            setState(.offline(Self.describe(error)))
            return
        }
        let now = ContinuousClock.now
        if let lastKick, now - lastKick < kickWindow {
            self.lastKick = now
            setState(.disconnectedByOther)
            await record("disconnected by other client again")
            return
        }
        lastKick = now
        setState(.reconnecting)
        await record("disconnected by other client, reattaching")
        await open(take: false, current)
    }

    /// Ошибка открытия: транспортная — ждать пул, прочая — `.offline` без повторов.
    private func failed(_ error: Error, _ current: Int) async {
        if Self.isTransport(error) {
            await transportLost(Self.describe(error), current)
        } else {
            setState(.offline(Self.describe(error)))
            await record("attach failed: \(Self.describe(error))")
        }
    }

    /// Соединение мертво: `.offline` и новый `attach` на каждое `.connected` пула, пока не выйдет.
    private func transportLost(_ reason: String, _ current: Int) async {
        setState(.offline(reason))
        await record("offline: \(reason)")
        waitTask?.cancel()
        let updates = await server.stateUpdates()
        guard current == generation else {
            return
        }
        waitTask = Task { [weak self] in
            for await connectionState in updates where connectionState.isConnected {
                guard let self, await self.retryAfterOffline(current) else {
                    return
                }
            }
        }
    }

    /// Попытка из `.offline`; `true` — ждать следующего `.connected`.
    private func retryAfterOffline(_ current: Int) async -> Bool {
        guard current == generation, case .offline = state else {
            return false
        }
        do {
            try await openChannel(take: false, current)
            return false
        } catch {
            guard current == generation else {
                return false
            }
            if Self.isTransport(error) {
                await record("reattach failed: \(Self.describe(error))")
                return true
            }
            setState(.offline(Self.describe(error)))
            return false
        }
    }

    private func setState(_ new: TerminalState) {
        guard new != state || new == .connecting else {
            return
        }
        state = new
        surface.stateChanged(new)
    }

    private func record(_ message: String) async {
        await log.record(server: await server.config.label, kind: .terminal, "\(name): \(message)")
    }

    /// Ошибки, которые лечит переподключение пула; `channelRefused` — предел каналов, не обрыв.
    static func isTransport(_ error: Error) -> Bool {
        guard let error = error as? SSHError else {
            return false
        }
        return error != .channelRefused
    }

    static func describe(_ error: Error) -> String {
        String(describing: error)
    }
}
