import Foundation
import NIOConcurrencyHelpers

/// Одно SSH-соединение с сервером (§5): exec через очередь на `execSlots`, не больше `ptySlots`
/// PTY, exec-пинг `true`, реконнект с бэкоффом, автомат `ConnectionState`.
public actor ServerConnection: ExecRunner {
    public private(set) var config: ServerConfig
    public nonisolated let deviceID: UUID
    public private(set) var settings: PoolSettings
    public nonisolated let log: DiagnosticsLog

    public private(set) var state: ConnectionState = .disconnected
    /// Отпечаток хост-ключа последнего подключения и был ли он увиден впервые (UI «Доверять»).
    public private(set) var hostKeyFingerprint: String?
    public private(set) var hostKeyFirstSeen = false
    /// Фатальная ошибка (`authFailed`, `hostKeyChanged`), с которой соединение ушло в `.failed`;
    /// сбрасывается при подключении.
    public private(set) var lastFatalError: SSHError?

    private let transport: any SSHTransport
    private let auth: SSHAuth
    private let hostKeys: any HostKeyStore
    /// Ждёт перед каждой попыткой реконнекта (`authenticate` она не заменяет); ошибка — цикл выходит.
    private let reconnectGate: (@Sendable () async throws -> Void)?
    private let execSlots: AsyncSemaphore

    private var connection: (any SSHConnection)?
    /// Растёт при каждой смене соединения: задачи старого соединения и устаревшие попытки
    /// сравнивают свой номер с текущим и молча выходят.
    private var epoch = 0
    private var keepaliveTask: Task<Void, Never>?
    private var watcherTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    /// Последний успешный exec, кроме пингов: свежий exec заменяет пинг.
    private var lastExecAt: ContinuousClock.Instant?
    private var missedPings = 0
    private var openPTYs: Set<UUID> = []
    private var observers: [UUID: AsyncStream<ConnectionState>.Continuation] = [:]

    public init(
        config: ServerConfig,
        deviceID: UUID,
        transport: any SSHTransport,
        auth: SSHAuth,
        hostKeys: any HostKeyStore,
        settings: PoolSettings? = nil,
        log: DiagnosticsLog = DiagnosticsLog(),
        reconnectGate: (@Sendable () async throws -> Void)? = nil
    ) {
        self.config = config
        self.deviceID = deviceID
        self.transport = transport
        self.auth = auth
        self.hostKeys = hostKeys
        self.reconnectGate = reconnectGate
        let settings = settings ?? PoolSettings(config: config)
        self.settings = settings
        self.log = log
        execSlots = AsyncSemaphore(slots: settings.execSlots)
    }

    deinit {
        keepaliveTask?.cancel()
        watcherTask?.cancel()
        reconnectTask?.cancel()
        for observer in observers.values {
            observer.finish()
        }
    }

    /// `HostAPI` поверх этого соединения: exec идут через очередь пула.
    public var api: HostAPI {
        HostAPI(runner: self, config: config, deviceID: deviceID, log: log)
    }

    /// Новые поля конфига без переподключения (адрес, пользователь и ключ меняет пул пересозданием).
    public func update(config: ServerConfig, settings: PoolSettings) {
        self.config = config
        self.settings = settings
    }

    // MARK: - Жизненный цикл

    /// Подключается, если ещё не подключён. Ошибка первой попытки пробрасывается, а пул
    /// продолжает попытки по `backoff`; `hostKeyChanged` и `authFailed` — сразу `.failed`.
    public func connect() async throws {
        if state.isConnected, connection?.isConnected == true {
            return
        }
        let current = await beginEpoch()
        setState(.connecting)
        do {
            try await attempt(current)
        } catch {
            guard current == epoch else {
                throw error
            }
            if Self.isFatal(error) {
                lastFatalError = error as? SSHError
                setState(.failed("\(error)"))
            } else {
                startReconnectLoop(current, reason: "\(error)")
            }
            throw error
        }
    }

    /// Немедленная попытка со сбросом бэкоффа: возврат из фона, «Повторить». Живое соединение
    /// не трогает, а с `force` рвёт и его: после смены сети старый сокет выглядит активным,
    /// пока его не похоронит keepalive (§6).
    public func reconnectNow(force: Bool = false) async {
        if force, state.isConnected {
            await log.record(server: config.label, kind: .reconnect, "forced reconnect")
            _ = await beginEpoch()
        }
        _ = try? await connect()
    }

    /// Явное отключение без реконнекта.
    public func disconnect() async {
        let wasActive = state != .disconnected
        _ = await beginEpoch()
        setState(.disconnected)
        if wasActive {
            await log.record(server: config.label, kind: .disconnect, "disconnected by app")
        }
    }

    /// Новая эпоха: гасит задачи и закрывает текущее соединение.
    private func beginEpoch() async -> Int {
        epoch += 1
        let current = epoch
        // фатальная ошибка относится к прошлой эпохе: иначе сетевой сбой новой попытки
        // покажется в дереве как `hostKeyChanged`/`authFailed`
        lastFatalError = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        keepaliveTask?.cancel()
        keepaliveTask = nil
        watcherTask?.cancel()
        watcherTask = nil
        openPTYs.removeAll()
        let old = connection
        connection = nil
        await old?.close()
        return current
    }

    /// Одна попытка подключения в эпохе `current`.
    private func attempt(_ current: Int) async throws {
        let endpoint = SSHEndpoint(host: config.host, port: config.port, connectTimeout: settings.connectTimeout)
        let outcome: ConnectOutcome
        do {
            outcome = try await transport.connect(endpoint, auth: auth, hostKeys: hostKeys)
        } catch {
            await log.record(server: config.label, kind: .error, "connect failed: \(error)")
            throw error
        }
        guard current == epoch else {
            // пока шла попытка, соединение отключили или начали заново
            await outcome.connection.close()
            throw CancellationError()
        }
        let established = outcome.connection
        connection = established
        hostKeyFingerprint = outcome.hostKeyFingerprint
        hostKeyFirstSeen = outcome.firstSeen
        lastExecAt = nil
        missedPings = 0
        setState(.connected(since: Date()))
        await log.record(server: config.label, kind: .connect, "connected, host key \(outcome.hostKeyFingerprint)")

        let disconnects = established.onDisconnect
        watcherTask = Task { [weak self] in
            for await _ in disconnects {
                break
            }
            guard !Task.isCancelled else {
                return
            }
            await self?.markDead("transport disconnected", epoch: current)
        }
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = await self?.settings.keepalive else {
                    return
                }
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard let self, await self.keepaliveTick(epoch: current) else {
                    return
                }
            }
        }
    }

    /// Соединение умерло: закрыть, уйти в реконнект.
    private func markDead(_ reason: String, epoch dead: Int) async {
        guard dead == epoch, state.isConnected else {
            return
        }
        // новая эпоха — до первого `await`: иначе второй `markDead` той же эпохи (обрыв и
        // пропущенный пинг разом) пройдёт проверку и своим циклом отменит цикл первого
        let current = await beginEpoch()
        await log.record(server: config.label, kind: .disconnect, reason)
        startReconnectLoop(current, reason: reason)
    }

    private func startReconnectLoop(_ current: Int, reason: String) {
        guard current == epoch else {
            return
        }
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            await self?.reconnectLoop(current, reason: reason)
        }
    }

    private func reconnectLoop(_ current: Int, reason: String) async {
        var lastError = reason
        for (index, delay) in settings.backoff.enumerated() {
            guard current == epoch, !Task.isCancelled else {
                return
            }
            setState(.reconnecting(attempt: index + 1))
            await log.record(server: config.label, kind: .reconnect, "attempt \(index + 1) in \(delay): \(lastError)")
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            do {
                // попытка идёт с сохранённым `auth`: приложение держит её, пока ключ закрыт (Face ID, §8)
                try await reconnectGate?()
            } catch {
                // отказ приложения — `.failed`: ждать дальше нечего, повтор — `reconnectNow`
                guard current == epoch, !(error is CancellationError) else {
                    return
                }
                lastError = "\(error)"
                break
            }
            guard current == epoch else {
                return
            }
            do {
                try await attempt(current)
                return
            } catch {
                guard current == epoch, !(error is CancellationError) else {
                    return
                }
                lastError = "\(error)"
                if Self.isFatal(error) {
                    lastFatalError = error as? SSHError
                    break
                }
            }
        }
        guard current == epoch else {
            return
        }
        setState(.failed(lastError))
        await log.record(server: config.label, kind: .error, "gave up: \(lastError)")
    }

    /// Один такт keepalive; `false` — задачу пора завершить.
    private func keepaliveTick(epoch current: Int) async -> Bool {
        guard current == epoch, state.isConnected else {
            return false
        }
        if let lastExecAt, ContinuousClock.now - lastExecAt < settings.keepalive {
            return true
        }
        do {
            // ожидание слота — не пропуск: занятые слоты значат, что exec идут; `pingTimeout`
            // ограничивает сам exec вместе с открытием канала
            _ = try await slotted("true", stdin: nil, timeout: settings.pingTimeout, markActivity: false)
            guard current == epoch else {
                return false
            }
            missedPings = 0
            return true
        } catch {
            guard current == epoch, state.isConnected else {
                return false
            }
            missedPings += 1
            await log.record(server: config.label, kind: .ping, "ping missed (\(missedPings)): \(error)")
            if missedPings >= 2 {
                await markDead("ping timeout x2", epoch: current)
                return false
            }
            return true
        }
    }

    private func setState(_ new: ConnectionState) {
        guard new != state else {
            return
        }
        state = new
        if new.isConnected {
            lastFatalError = nil
        }
        for observer in observers.values {
            observer.yield(new)
        }
    }

    /// Текущее состояние и все следующие; подписчиков сколько угодно (по одному на
    /// `TerminalSession`). Подписка снимается отменой итерации.
    public func stateUpdates() -> AsyncStream<ConnectionState> {
        let (stream, continuation) = AsyncStream.makeStream(of: ConnectionState.self, bufferingPolicy: .bufferingNewest(16))
        let id = UUID()
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        continuation.yield(state)
        return stream
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    static func isFatal(_ error: Error) -> Bool {
        switch error as? SSHError {
        case .hostKeyChanged, .authFailed: true
        default: false
        }
    }

    // MARK: - Каналы

    public func exec(_ command: String, stdin: Data?, timeout: Duration) async throws -> ExecResult {
        try await slotted(command, stdin: stdin, timeout: timeout, markActivity: true)
    }

    /// Exec с таймаутом `settings.execTimeout`.
    public func exec(_ command: String, stdin: Data? = nil) async throws -> ExecResult {
        try await exec(command, stdin: stdin, timeout: settings.execTimeout)
    }

    private func slotted(_ command: String, stdin: Data?, timeout: Duration, markActivity: Bool) async throws -> ExecResult {
        try await execSlots.acquire()
        do {
            guard let connection, state.isConnected else {
                throw SSHError.disconnected
            }
            let result = try await connection.exec(command, stdin: stdin, environment: [:], timeout: timeout)
            if markActivity {
                lastExecAt = ContinuousClock.now
            }
            await execSlots.release()
            return result
        } catch {
            await execSlots.release()
            throw error
        }
    }

    /// PTY + exec `command`. Больше `ptySlots` открытых → `SSHError.channelRefused` без похода на
    /// сервер; слот освобождают `close()` канала, конец его вывода или смерть соединения.
    public func openPTY(
        command: String,
        cols: Int,
        rows: Int,
        term: String = "xterm-256color",
        environment: [String: String] = ["LANG": "en_US.UTF-8"]
    ) async throws -> any PTYChannel {
        guard let connection, state.isConnected else {
            throw SSHError.disconnected
        }
        guard openPTYs.count < settings.ptySlots else {
            throw SSHError.channelRefused
        }
        let id = UUID()
        openPTYs.insert(id)
        do {
            let channel = try await connection.openPTY(command: command, term: term, cols: cols, rows: rows, environment: environment)
            return PooledPTY(base: channel) { [weak self] in
                await self?.ptyClosed(id)
            }
        } catch {
            openPTYs.remove(id)
            throw error
        }
    }

    /// Открытых PTY-каналов.
    public var openPTYCount: Int {
        openPTYs.count
    }

    private func ptyClosed(_ id: UUID) {
        openPTYs.remove(id)
    }
}

/// PTY-канал пула: пересылает вывод и один раз освобождает слот.
final class PooledPTY: PTYChannel {
    let output: AsyncThrowingStream<Data, Error>
    private let base: any PTYChannel
    private let release: ReleaseOnce

    init(base: any PTYChannel, release: @escaping @Sendable () async -> Void) {
        self.base = base
        let release = ReleaseOnce(release)
        self.release = release
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
        output = stream
        let forward = Task {
            do {
                for try await chunk in base.output {
                    continuation.yield(chunk)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
            await release.run()
        }
        continuation.onTermination = { _ in forward.cancel() }
    }

    var exitCode: Int? {
        base.exitCode
    }

    func send(_ data: Data) async throws {
        try await base.send(data)
    }

    func resize(cols: Int, rows: Int) async throws {
        try await base.resize(cols: cols, rows: rows)
    }

    func close() async {
        await base.close()
        await release.run()
    }
}

/// Действие, которое выполняется не больше одного раза.
final class ReleaseOnce: Sendable {
    private let done = NIOLockedValueBox(false)
    private let action: @Sendable () async -> Void

    init(_ action: @escaping @Sendable () async -> Void) {
        self.action = action
    }

    func run() async {
        let first = done.withLockedValue { done in
            defer { done = true }
            return !done
        }
        if first {
            await action()
        }
    }
}
