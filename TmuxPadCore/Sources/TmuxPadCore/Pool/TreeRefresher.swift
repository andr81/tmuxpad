import Foundation

/// Состояние сервера в дереве сайдбара (§3.1, §9).
public struct ServerTreeState: Sendable, Equatable {
    public var reachability: ServerReachability
    /// Последний удачный `list`; при ошибках остаётся прежним («последний снимок серым»).
    public var snapshot: ServerSnapshot?
    /// Версия скрипта в текущей эпохе соединения; `nil` — ещё не проверяли.
    public var bootstrap: BootstrapStatus?
    /// Идёт `refresh`.
    public var refreshing: Bool
    /// Последняя фатальная ошибка подключения (`authFailed`, `hostKeyChanged`): UI открывает
    /// проверку сервера вместо «Повторить». Сбрасывается при успешном подключении.
    public var attention: SSHError?

    public init(
        reachability: ServerReachability = .unknown,
        snapshot: ServerSnapshot? = nil,
        bootstrap: BootstrapStatus? = nil,
        refreshing: Bool = false,
        attention: SSHError? = nil
    ) {
        self.reachability = reachability
        self.snapshot = snapshot
        self.bootstrap = bootstrap
        self.refreshing = refreshing
        self.attention = attention
    }
}

/// Опрос серверов для дерева: раз в `interval` `list` каждого сервера, пока приложение активно
/// (§3.1). Сам соединения не держит и не переподключает: `connect()` — только из
/// `.disconnected`, иначе тики гасили бы бэкофф пула и повторяли бы `authFailed` (§9).
public actor TreeRefresher {
    static let notChecked = "Connection not checked"
    static let reconnecting = "Reconnecting…"
    static let scriptMissing = "Host script is not installed"

    private let pool: ConnectionPool
    private let bootstrapper: HostBootstrap
    private let auth: @Sendable (ServerConfig) async throws -> SSHAuth
    private let interval: Duration

    /// Серверы в порядке `setServers`.
    private var order: [UUID] = []
    private var configs: [UUID: ServerConfig] = [:]
    private var states: [UUID: ServerTreeState] = [:]
    /// `since` последнего увиденного `.connected`: новое значение — новая эпоха, `version` заново.
    private var epochs: [UUID: Date] = [:]
    /// Идущий `refresh` сервера; `token` отличает его от следующего после удаления и возврата.
    private var inFlight: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]
    private var ticker: Task<Void, Never>?
    private var observers: [UUID: AsyncStream<(UUID, ServerTreeState)>.Continuation] = [:]

    public init(
        pool: ConnectionPool,
        bootstrap: HostBootstrap,
        auth: @escaping @Sendable (ServerConfig) async throws -> SSHAuth,
        interval: Duration = .seconds(10)
    ) {
        self.pool = pool
        self.bootstrapper = bootstrap
        self.auth = auth
        self.interval = interval
    }

    deinit {
        ticker?.cancel()
        for observer in observers.values {
            observer.finish()
        }
    }

    // MARK: - Серверы и подписка

    /// Новый список серверов: добавленные — `.unknown`, удалённые уходят из пула и из выхода.
    public func setServers(_ newConfigs: [ServerConfig]) async {
        let ids = Set(newConfigs.map(\.id))
        let removed = order.filter { !ids.contains($0) }
        order = []
        for config in newConfigs where !order.contains(config.id) {
            order.append(config.id)
            configs[config.id] = config
        }
        for id in removed {
            configs[id] = nil
            states[id] = nil
            epochs[id] = nil
            inFlight[id] = nil
        }
        for id in order where states[id] == nil {
            publish(id, ServerTreeState())
        }
        for id in removed {
            await pool.remove(id: id)
        }
    }

    public func state(for id: UUID) -> ServerTreeState? {
        states[id]
    }

    /// Текущее состояние всех известных серверов и все следующие изменения; подписчиков сколько
    /// угодно. Подписка снимается отменой итерации.
    public func updates() -> AsyncStream<(UUID, ServerTreeState)> {
        let (stream, continuation) = AsyncStream.makeStream(of: (UUID, ServerTreeState).self, bufferingPolicy: .bufferingNewest(64))
        let id = UUID()
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        for server in order {
            if let state = states[server] {
                continuation.yield((server, state))
            }
        }
        return stream
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    // MARK: - Тики

    /// Периодический опрос; первый тик — сразу.
    public func start() {
        guard ticker == nil else {
            return
        }
        let interval = interval
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else {
                    return
                }
                await self.refresh()
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
            }
        }
    }

    /// Уход в фон: дерево не опрашивается.
    public func stop() {
        ticker?.cancel()
        ticker = nil
    }

    /// Обновить один сервер или все и дождаться. `force` — pull-to-refresh и «Повторить»:
    /// неподключённый сервер подключается заново со сбросом бэкоффа, `version` читается заново.
    public func refresh(_ id: UUID? = nil, force: Bool = false) async {
        let ids = id.map { [$0] } ?? order
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { await self.refreshOne(id, force: force) }
            }
        }
    }

    /// После `HostBootstrap.prepare`: дождаться идущего `refresh` (он начат до подготовки) и
    /// запустить новый с чтением `version`.
    public func markPrepared(_ id: UUID) async {
        while let running = inFlight[id] {
            await running.task.value
        }
        guard var state = states[id] else {
            return
        }
        state.bootstrap = nil
        publish(id, state)
        await refreshOne(id, force: false)
    }

    /// Один `refresh` на сервер: второй вызов ждёт идущего, а с `force` после него запускает свой.
    private func refreshOne(_ id: UUID, force: Bool) async {
        while let running = inFlight[id] {
            await running.task.value
            if !force {
                return
            }
        }
        guard configs[id] != nil else {
            return
        }
        // задача не начнётся раньше записи в `inFlight`: актор занят до `await`
        let token = UUID()
        let task = Task { await self.perform(id, force: force, token: token) }
        inFlight[id] = (token, task)
        await task.value
    }

    // MARK: - Один refresh

    private func perform(_ id: UUID, force: Bool, token: UUID) async {
        defer {
            if inFlight[id]?.token == token {
                inFlight[id] = nil
                update(id) { $0.refreshing = false }
            }
        }
        guard let config = configs[id] else {
            return
        }
        update(id) { $0.refreshing = true }
        // без подтверждённого отпечатка опрос сохранил бы его молча, без «Доверять» (§8)
        guard config.hostKeyFingerprint != nil else {
            await setReachability(id, .needsSetup(Self.notChecked))
            return
        }
        let credentials: SSHAuth
        do {
            credentials = try await auth(config)
        } catch {
            await setReachability(id, .offline("\(error)"))
            return
        }
        // пока ждали ключ, сервер могли удалить или изменить: старый конфиг вернул бы его в пул
        guard isCurrent(id, token: token, config: config) else {
            return
        }
        let connection = await pool.connection(for: config, auth: credentials)

        var state = await connection.state
        // `connect()` из любого состояния, кроме `.disconnected`, начал бы новую эпоху; с `force`
        // это и нужно — как `reconnectNow()`, но с ошибкой на руках для `attention`
        var connectError: Error?
        if state == .disconnected || (force && !state.isConnected) {
            do {
                try await connection.connect()
            } catch {
                connectError = error
            }
            state = await connection.state
        }
        guard isCurrent(id, token: token, config: config) else {
            // сервер удалили, пока шли `pool.connection` и `connect()`: убрать возвращённое соединение
            if configs[id] == nil {
                await pool.remove(id: id)
            }
            return
        }
        if let connectError {
            if ServerConnection.isFatal(connectError) {
                update(id) { $0.attention = connectError as? SSHError }
            }
            await setReachability(id, .offline("\(connectError)"))
            return
        }
        let since: Date
        switch state {
        case let .connected(date):
            since = date
        case .connecting, .reconnecting:
            await setReachability(id, .offline(Self.reconnecting))
            return
        case let .failed(reason):
            // пул сам бросил попытки на фатальной ошибке после обрыва
            if let fatal = await connection.lastFatalError {
                update(id) { $0.attention = fatal }
            }
            await setReachability(id, .offline(reason))
            return
        case .disconnected:
            await setReachability(id, .offline("\(SSHError.disconnected)"))
            return
        }
        update(id) { $0.attention = nil }
        if epochs[id] != since {
            epochs[id] = since
            update(id) { $0.bootstrap = nil }
        }

        let api = await connection.api
        var status = states[id]?.bootstrap
        if force || status == nil || status.map(Self.isUnreachable) == true {
            let fresh = await bootstrapper.status(api: api)
            status = fresh
            update(id) { $0.bootstrap = fresh }
        }
        switch status {
        case .missing:
            await setReachability(id, .needsSetup(Self.scriptMissing))
            return
        case let .outdated(installed, bundled):
            await setReachability(id, .needsSetup("Host script v\(installed) is older than v\(bundled)"))
            return
        case let .unreachable(reason):
            await setReachability(id, .offline(reason))
            return
        case .ready, nil:
            break
        }

        do {
            let snapshot = try await api.list()
            update(id) { $0.snapshot = snapshot }
            await setReachability(id, .online)
        } catch HostError.projectsRootMissing {
            await setReachability(id, .needsSetup("Projects folder \(config.projectsRoot) does not exist"))
        } catch HostError.scriptMissing {
            // скрипт удалили между подключениями
            update(id) { $0.bootstrap = .missing }
            await setReachability(id, .needsSetup(Self.scriptMissing))
        } catch {
            await setReachability(id, .offline("\(error)"))
        }
    }

    /// Этот `refresh` всё ещё актуален: сервер в списке с тем же конфигом, а его не сменил новый.
    private func isCurrent(_ id: UUID, token: UUID, config: ServerConfig) -> Bool {
        inFlight[id]?.token == token && configs[id] == config
    }

    private static func isUnreachable(_ status: BootstrapStatus) -> Bool {
        if case .unreachable = status { true } else { false }
    }

    // MARK: - Публикация

    /// Каждая смена `reachability` — строка в журнал пула.
    private func setReachability(_ id: UUID, _ reachability: ServerReachability) async {
        guard let state = states[id], let label = configs[id]?.label, state.reachability != reachability else {
            return
        }
        update(id) { $0.reachability = reachability }
        await pool.log.record(server: label, kind: .exec, "tree: \(Self.describe(reachability))")
    }

    private static func describe(_ reachability: ServerReachability) -> String {
        switch reachability {
        case .unknown: "unknown"
        case .online: "online"
        case let .offline(reason): "offline: \(reason)"
        case let .needsSetup(reason): "needs setup: \(reason)"
        }
    }

    private func update(_ id: UUID, _ change: (inout ServerTreeState) -> Void) {
        guard var state = states[id] else {
            return
        }
        change(&state)
        publish(id, state)
    }

    /// Пишет и рассылает, если сервер ещё в списке и состояние изменилось.
    private func publish(_ id: UUID, _ state: ServerTreeState) {
        guard configs[id] != nil, states[id] != state else {
            return
        }
        states[id] = state
        for observer in observers.values {
            observer.yield((id, state))
        }
    }
}
