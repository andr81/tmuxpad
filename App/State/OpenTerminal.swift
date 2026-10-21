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

    /// Начальный кадр до вёрстки: размер PTY при `attach`, потом его поправит `sizeChanged`.
    static let initialFrame = CGRect(x: 0, y: 0, width: 1024, height: 768)

    init(key: OpenSessionKey, dependencies: Dependencies) {
        self.key = key
        self.dependencies = dependencies
        view = TmuxTerminalView(frame: Self.initialFrame, defaults: dependencies.defaults)
        project = dependencies.snapshot(key.serverID)?.sessions.first { $0.name == key.name }?.project
    }

    /// Сессия, а с `take` — «Забрать» (§6.1).
    func start(take: Bool = false) {
        guard setup == nil, !isClosed else {
            return
        }
        state = .connecting
        setup = Task { [weak self] in
            guard let session = await self?.makeSession() else {
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

    /// `detach()` и конец ввода; tmux-сессия на сервере остаётся.
    func close() {
        guard !isClosed else {
            return
        }
        isClosed = true
        pump?.finish()
        let setup = setup
        let session = session
        Task {
            await (setup?.value ?? session)?.detach()
        }
    }

    /// «Переподключить», «Повторить».
    func reconnect() async {
        guard let session = await ready() else {
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

    /// «Создать заново»: `new` с тем же именем и проектом, затем новый `attach`. Проекта нет в
    /// снимке — `AppError.projectNotFound`; сессию уже создали заново — не ошибка.
    func recreate() async throws {
        guard let project else {
            throw AppError.projectUnknown
        }
        if let snapshot = dependencies.snapshot(key.serverID), !snapshot.projects.contains(where: { $0.name == project }) {
            throw AppError.projectNotFound(project)
        }
        let connection: ServerConnection
        if let session {
            connection = session.server
        } else {
            connection = try await dependencies.connection(key.serverID)
        }
        do {
            try await connection.api.new(session: key.name, project: project)
        } catch HostError.sessionExists {
        }
        await reconnect()
    }

    // MARK: - Сессия

    /// Сессия есть — она; создание упало — новая попытка.
    private func ready() async -> TerminalSession? {
        guard !isClosed else {
            return nil
        }
        if let session = await setup?.value {
            return session
        }
        setup = nil
        guard let session = await makeSession() else {
            return nil
        }
        setup = Task { session }
        return session
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
            return nil
        }
        self.session = session
        self.pump = pump
        self.delegate = delegate
        view.terminalDelegate = delegate
        // кончается вместе с потоком: продолжение держит поверхность, её — сессия
        events = Task { [weak self] in
            for await event in stream {
                self?.apply(event)
            }
        }
        return session
    }

    private enum Event {
        case state(TerminalState)
        case scrollChip(Bool)
    }

    private func apply(_ event: Event) {
        switch event {
        case let .state(new):
            state = new
        case let .scrollChip(shown):
            showsScrollChip = shown
        }
    }
}
