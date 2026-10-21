import Foundation
import Observation
import SwiftTerm
import TmuxPadCore

/// Терминал открытой сессии (§5): `TerminalView` создаётся один раз и живёт, пока терминал
/// открыт, — так переключение мгновенное. Соединение пула и `TerminalSession` появляются в
/// `start()`: `open` модели синхронный, а пул — актор.
@MainActor
@Observable
final class OpenTerminal {
    /// Откуда терминал берёт соединение и снимок сервера; в тестах — заглушки.
    struct Dependencies {
        /// Соединение пула; ошибка (`AppError`) — `.offline` с её текстом.
        var connection: @MainActor (UUID) async throws -> ServerConnection
        /// Последний снимок сервера из дерева: проект сессии для «Создать заново».
        var snapshot: @MainActor (UUID) -> ServerSnapshot?
        var log: DiagnosticsLog?
        var defaults: UserDefaults
        /// Шрифт всех открытых терминалов и pinch.
        var appearance: TerminalAppearance
    }

    let key: OpenSessionKey
    let view: TmuxTerminalView
    /// Проект сессии из снимка на момент открытия.
    private(set) var project: String?
    private(set) var session: TerminalSession?
    private(set) var state: TerminalState = .connecting
    /// Чип «Прокрутка ✕»: pane, вероятно, в copy-mode.
    private(set) var showsScrollChip = false
    private(set) var lastActive = Date()
    private(set) var isClosed = false

    @ObservationIgnored private let dependencies: Dependencies
    @ObservationIgnored private var pump: InputPump?
    /// `terminalDelegate` у `TerminalView` слабый — держим здесь.
    @ObservationIgnored private var delegate: TerminalDelegate?
    @ObservationIgnored private var setup: Task<TerminalSession?, Never>?
    @ObservationIgnored private var events: Task<Void, Never>?
    /// Конец потока `events`: сам он не кончится, пока жива задача, которая его читает.
    @ObservationIgnored private var eventsEnd: AsyncStream<Event>.Continuation?

    /// Начальный кадр до вёрстки: размер PTY при `attach`, потом его поправит `sizeChanged`.
    static let initialFrame = CGRect(x: 0, y: 0, width: 1024, height: 768)
    /// Плашка офлайна без фатальной ошибки пула.
    static let offlineText = "Подробности — в журнале диагностики"

    init(key: OpenSessionKey, dependencies: Dependencies) {
        self.key = key
        self.dependencies = dependencies
        view = TmuxTerminalView(frame: Self.initialFrame, defaults: dependencies.defaults)
        dependencies.appearance.attach(view)
        project = dependencies.snapshot(key.serverID)?.sessions.first { $0.name == key.name }?.project
    }

    /// Сессия, а с `take` — «Забрать» (§6.1). `after` — `detach` вытесненных: их PTY-слоты
    /// освобождаются после ответа сервера, а ростер и пул ограничены одним числом.
    func start(take: Bool = false, after evictions: [Task<Void, Never>] = []) {
        guard setup == nil, !isClosed else {
            return
        }
        state = .connecting
        setup = Task { [weak self] in
            for eviction in evictions {
                await eviction.value
            }
            guard let self else {
                return nil
            }
            guard let session = await makeSession() else {
                setup = nil
                return nil
            }
            if take {
                await session.take()
            } else {
                await session.start()
            }
            return session
        }
    }

    func activate() {
        lastActive = Date()
    }

    /// `detach()` и конец ввода; tmux-сессия на сервере остаётся. Задача кончается, когда
    /// PTY закрыт и его слот в пуле свободен; поток состояний — после `.ended` от `detach`.
    @discardableResult
    func close() -> Task<Void, Never> {
        guard !isClosed else {
            return Task {}
        }
        isClosed = true
        pump?.finish()
        let setup = setup
        let session = session
        return Task {
            await (setup?.value ?? session)?.detach()
            self.eventsEnd?.finish()
            self.eventsEnd = nil
        }
    }

    /// «Переподключить», «Повторить».
    func reconnect() async {
        guard let session = await ready() else {
            return
        }
        await session.reconnect()
    }

    /// «Повторить» в офлайне: немедленная попытка пула и новый `attach`.
    func retry() async {
        guard let session = await ready() else {
            return
        }
        await session.server.reconnectNow()
        // закрыли, пока пул переподключался: `detach` уже освободил слот
        guard !isClosed else {
            return
        }
        await session.reconnect()
    }

    /// «Забрать».
    func take() async {
        guard let session = await ready() else {
            return
        }
        await session.take()
    }

    /// Тап по чипу «Прокрутка ✕».
    func cancelCopyMode() async {
        await session?.cancelCopyMode()
    }

    /// Проект для «Создать заново» (`SessionActions.recreate`). Проекта нет в снимке —
    /// `AppError.projectNotFound`.
    func recreateProject() throws -> String {
        guard let project else {
            throw AppError.projectUnknown
        }
        if let snapshot = dependencies.snapshot(key.serverID), !snapshot.projects.contains(where: { $0.name == project }) {
            throw AppError.projectNotFound(project)
        }
        return project
    }

    // MARK: - Сессия

    /// Сессия есть и её соединение всё ещё в пуле — она; нет — новая попытка, одна на все
    /// одновременные вызовы (двойной тап «Повторить» не создаёт две сессии на один view).
    /// Неудачная попытка сама очищает `setup`. Закрыли за время ожидания — `nil`.
    private func ready() async -> TerminalSession? {
        guard !isClosed else {
            return nil
        }
        let fresh = setup == nil
        if fresh {
            setup = Task { [weak self] in
                guard let self else {
                    return nil
                }
                let session = await makeSession()
                if session == nil {
                    setup = nil
                }
                return session
            }
        }
        guard let existing = await setup?.value, !isClosed else {
            return nil
        }
        if fresh {
            return existing
        }
        // пул сменил соединение (адрес, ключ) или отпечаток сбросили: старое не переподключать
        let connection: ServerConnection
        do {
            connection = try await dependencies.connection(key.serverID)
        } catch {
            if !isClosed {
                state = .offline(userText(error))
            }
            return nil
        }
        guard !isClosed else {
            return nil
        }
        if connection === existing.server {
            return existing
        }
        if session === existing {
            drop(existing)
        }
        return await ready()
    }

    /// Сессия на соединении, которого больше нет в пуле: её состояние на экран уже не идёт.
    private func drop(_ old: TerminalSession) {
        events?.cancel()
        events = nil
        eventsEnd?.finish()
        eventsEnd = nil
        pump?.finish()
        pump = nil
        delegate = nil
        view.terminalDelegate = nil
        session = nil
        setup = nil
        showsScrollChip = false
        Task {
            await old.detach()
        }
    }

    private func makeSession() async -> TerminalSession? {
        let connection: ServerConnection
        do {
            connection = try await dependencies.connection(key.serverID)
        } catch {
            if !isClosed {
                state = .offline(userText(error))
            }
            return nil
        }
        guard !isClosed else {
            return nil
        }
        // состояние и чип приходят не с main; один поток держит их порядок
        let (stream, continuation) = AsyncStream<Event>.makeStream(bufferingPolicy: .unbounded)
        let surface = SwiftTermSurface(
            view: view,
            stateChanged: { continuation.yield(.state($0)) },
            copyModeSuspected: { continuation.yield(.scrollChip($0)) })
        let session = TerminalSession(server: connection, name: key.name, surface: surface, log: dependencies.log)
        let pump = InputPump(session: session, log: dependencies.log ?? connection.log, server: await connection.config.label)
        let delegate = TerminalDelegate(pump: pump) { cols, rows in
            try await session.resize(cols: cols, rows: rows)
        }
        guard !isClosed else {
            pump.finish()
            continuation.finish()
            return nil
        }
        self.session = session
        self.pump = pump
        self.delegate = delegate
        view.terminalDelegate = delegate
        eventsEnd = continuation
        // кончается вместе с потоком: `finish` в `close` и `drop`
        events = Task { [weak self] in
            for await event in stream {
                await self?.apply(event)
            }
        }
        return session
    }

    private enum Event {
        case state(TerminalState)
        case scrollChip(Bool)
    }

    private func apply(_ event: Event) async {
        switch event {
        case .state(.live):
            state = .live
            // `sizeChanged` во время `attach` ушёл в `resize` без PTY и потерялся
            let size = view.terminalDimensions
            delegate?.requestResize(cols: size.cols, rows: size.rows)
        case .state(.offline):
            // соединение пула в `.failed` (ключ, отпечаток): причина — его ошибка, а не `disconnected` канала;
            // прочие причины ядра — английский текст, он уже в журнале диагностики
            if let fatal = await session?.server.lastFatalError {
                state = .offline(userText(fatal))
            } else {
                state = .offline(Self.offlineText)
            }
        case let .state(new):
            state = new
        case let .scrollChip(shown):
            showsScrollChip = shown
        }
    }
}
