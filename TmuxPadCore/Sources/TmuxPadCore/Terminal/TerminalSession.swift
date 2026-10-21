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
    /// Ожидание `.connected` от пула после обрыва.
    private var waitTask: Task<Void, Never>?
    /// Хвост очереди ввода: `send`, `input` и `cancelCopyMode` идут в порядке вызова, даже если
    /// ждут `copy-cancel`.
    private var sendTail: Task<Void, Never>?
    /// `openPTY` и `close` канала в полёте и `detach`, которые ждут их конца: слот PTY пула
    /// занят, пока канал не открылся и не закрылся.
    private var channelOps = 0
    private var channelOpsWaiters: [CheckedContinuation<Void, Never>] = []

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
        guard pty == nil, !userDetached else {
            return
        }
        let current = await begin()
        guard isCurrent(current) else {
            return
        }
        setState(.connecting)
        await open(take: false, current)
    }

    /// Ввод с клавиатуры. После скролла вверх сначала `copy-cancel` через exec (ошибка — в журнал
    /// и флаг обратно, байты всё равно идут), иначе tmux в copy-mode проглотит ввод.
    public func send(_ data: Data) async throws {
        let cancelFirst = needsCopyCancel
        setCopyModeSuspected(false)
        try await enqueue(data, cancelFirst: cancelFirst)
    }

    /// Байты от экрана (§3.5): мышиные отчёты идут в PTY мимо `copy-cancel`, колесо вверх
    /// поднимает чип, всё прочее — ввод, как `send`. Вызывать по порядку прихода байтов.
    public func input(_ bytes: Data) async throws {
        switch MouseReport.classify(bytes) {
        case .wheelUp:
            setCopyModeSuspected(true)
            try await enqueue(bytes, cancelFirst: false)
        case .otherMouse:
            try await enqueue(bytes, cancelFirst: false)
        case .keyboard:
            try await send(bytes)
        }
    }

    /// Тап по чипу «Прокрутка ✕»: `copy-cancel` в очереди ввода; без подозрения ничего не делает.
    public func cancelCopyMode() async {
        guard needsCopyCancel else {
            return
        }
        setCopyModeSuspected(false)
        try? await enqueue(Data(), cancelFirst: true)
    }

    /// UI прокрутил вверх (чип «Прокрутка»): следующий ввод сначала выведет pane из copy-mode.
    public func noteScrolledUp() {
        setCopyModeSuspected(true)
    }

    public func resize(cols: Int, rows: Int) async throws {
        try await pty?.resize(cols: cols, rows: rows)
    }

    /// Закрыть терминал; tmux-сессия на сервере остаётся. Окончательно: `start`, `reconnect` и
    /// `take` после него ничего не делают, иначе запоздавший «Повторить» занял бы PTY-слот.
    /// Возвращается, когда открывавшиеся и закрывавшиеся каналы закрыты и их слоты в пуле свободны.
    public func detach() async {
        userDetached = true
        setCopyModeSuspected(false)
        _ = await begin()
        setState(.ended)
        if channelOps > 0 {
            await withCheckedContinuation { channelOpsWaiters.append($0) }
        }
        await record("detached by app")
    }

    /// «Забрать»: `take` выкидывает всех прочих клиентов (§6.1).
    public func take() async {
        guard !userDetached else {
            return
        }
        let current = await begin()
        guard isCurrent(current) else {
            return
        }
        setState(.reconnecting)
        await record("take")
        await open(take: true, current)
    }

    /// Новый канал `attach`: возврат из фона, «Переподключить», «Повторить».
    public func reconnect() async {
        guard !userDetached else {
            return
        }
        let current = await begin()
        guard isCurrent(current) else {
            return
        }
        setState(.reconnecting)
        await open(take: false, current)
    }

    // MARK: - Ввод

    /// В очередь `sendTail`: байты в PTY в порядке вызовов, перед ними при `cancelFirst` —
    /// `copy-cancel`, его неудача снова поднимает флаг; пустые байты в PTY не пишутся.
    private func enqueue(_ data: Data, cancelFirst: Bool) async throws {
        let previous = sendTail
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
                    self.copyCancelFailed()
                }
            }
            guard !data.isEmpty else {
                return
            }
            guard let channel else {
                throw SSHError.disconnected
            }
            try await channel.send(data)
        }
        sendTail = Task { _ = await task.result }
        try await task.value
    }

    /// pane, возможно, остался в copy-mode: следующий ввод (и после переподключения) повторит
    /// `copy-cancel`; после `detach` флаг не нужен.
    private func copyCancelFailed() {
        guard !userDetached else {
            return
        }
        setCopyModeSuspected(true)
    }

    /// Флаг «pane, вероятно, в copy-mode»; экран узнаёт только о смене значения.
    private func setCopyModeSuspected(_ value: Bool) {
        guard value != needsCopyCancel else {
            return
        }
        needsCopyCancel = value
        surface.copyModeSuspected(value)
    }

    // MARK: - Канал

    /// Новая операция: гасит ожидание и закрывает текущий канал; `detach`, пришедший во время
    /// закрытия, ждёт его конца.
    private func begin() async -> Int {
        generation += 1
        let current = generation
        waitTask?.cancel()
        waitTask = nil
        if let old = pty {
            pty = nil
            channelOps += 1
            await old.close()
            channelOpEnded()
        }
        return current
    }

    /// Открывает канал и запускает чтение; неудача — `.offline`, при мёртвом соединении —
    /// ожидание пула.
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
        let api = await server.api
        let command = take ? try api.takeCommand(session: name) : try api.attachCommand(session: name)
        let size = surface.size
        // операцию сменили, пока закрывался старый канал: новый не открывать
        guard current == generation, !userDetached else {
            return
        }
        channelOps += 1
        let channel: any PTYChannel
        do {
            channel = try await server.openPTY(command: command, cols: size.cols, rows: size.rows)
        } catch {
            channelOpEnded()
            throw error
        }
        guard current == generation, !userDetached else {
            await channel.close()
            channelOpEnded()
            return
        }
        channelOpEnded()
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

    /// Открытие или закрытие канала кончилось; последнее отпускает ждущих `detach`.
    private func channelOpEnded() {
        channelOps -= 1
        guard channelOps == 0 else {
            return
        }
        let waiters = channelOpsWaiters
        channelOpsWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Вывод канала кончился без нашего `detach`.
    private func channelEnded(_ current: Int, exitCode: Int?, error: Error?) async {
        guard current == generation, !userDetached else {
            return
        }
        pty = nil
        if let error {
            await transportLost("\(error)", current)
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
            await transportLost("list failed: \(error)", current)
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
            setState(.offline("\(error)"))
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

    /// Ошибка открытия: транспортная — ждать пул (`.reconnecting`), прочая — `.offline` без повторов.
    private func failed(_ error: Error, _ current: Int) async {
        if Self.isTransport(error) {
            await transportLost("\(error)", current)
        } else {
            setState(.offline("\(error)"))
            await record("attach failed: \(error)")
        }
    }

    /// Соединение мертво: новый `attach` на каждое `.connected` пула, пока не выйдет. Пока пул
    /// переподключается — `.reconnecting` (§3.5), пул в `.failed` — `.offline` до явного запроса.
    /// `.disconnected` — тоже `.offline`: само оно не переподключится (пул мог заменить соединение).
    private func transportLost(_ reason: String, _ current: Int) async {
        setState(.reconnecting)
        await record("connection lost: \(reason)")
        let updates = await server.stateUpdates()
        // устаревший вызов не трогает ожидание новой операции
        guard current == generation else {
            return
        }
        waitTask?.cancel()
        waitTask = Task { [weak self] in
            for await connectionState in updates {
                guard let self else {
                    return
                }
                switch connectionState {
                case .connected:
                    guard await self.retryAfterOffline(current) else {
                        return
                    }
                case .failed, .disconnected:
                    await self.poolChanged(.offline(reason), current)
                case .connecting, .reconnecting:
                    await self.poolChanged(.reconnecting, current)
                }
            }
        }
    }

    /// Плашка ожидания пула; устаревшее ожидание молчит.
    private func poolChanged(_ new: TerminalState, _ current: Int) {
        guard current == generation else {
            return
        }
        setState(new)
    }

    /// Попытка после обрыва (`.reconnecting` или `.offline`); `true` — ждать следующего `.connected`.
    private func retryAfterOffline(_ current: Int) async -> Bool {
        guard current == generation, state == .reconnecting || isOffline else {
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
                await record("reattach failed: \(error)")
                // пул жив (канал не открылся по таймауту): следующего `.connected` может не быть,
                // поэтому «Повторить», а не вечное «Переподключение…»
                if await server.state.isConnected, current == generation {
                    setState(.offline("\(error)"))
                }
                return true
            }
            setState(.offline("\(error)"))
            return false
        }
    }

    /// Операцию не сменили, пока `begin` закрывал старый канал.
    private func isCurrent(_ current: Int) -> Bool {
        current == generation && !userDetached
    }

    private var isOffline: Bool {
        if case .offline = state { true } else { false }
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
}
