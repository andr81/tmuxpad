import Foundation
import Testing
@testable import TmuxPadCore

/// Копит все состояния соединения из `states`.
private final class StateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ConnectionState] = []
    private var task: Task<Void, Never>?

    init(_ connection: ServerConnection) {
        task = Task { [weak self] in
            for await state in connection.states {
                self?.lock.withLock { self?.recorded.append(state) }
            }
        }
    }

    deinit {
        task?.cancel()
    }

    var states: [ConnectionState] {
        lock.withLock { recorded }
    }

    /// Ждёт состояние, подходящее под `match`.
    func waitFor(_ timeout: Duration = .seconds(3), _ match: @escaping @Sendable (ConnectionState) -> Bool) async throws -> Bool {
        try await Bench.eventually(timeout) { self.states.contains(where: match) }
    }
}

struct ServerConnectionTests {
    static let config = ServerConfig(label: "fake", host: "fake.example", user: "dev", keyID: UUID())

    static func settings(
        keepalive: Duration = .seconds(60),
        pingTimeout: Duration = .milliseconds(50),
        backoff: [Duration] = [.milliseconds(20), .milliseconds(20), .milliseconds(20), .milliseconds(20)]
    ) -> PoolSettings {
        PoolSettings(keepalive: keepalive, pingTimeout: pingTimeout, backoff: backoff, connectTimeout: .seconds(1), execTimeout: .seconds(2))
    }

    static func make(_ transport: FakeTransport, settings: PoolSettings = settings(), log: DiagnosticsLog = DiagnosticsLog()) throws -> ServerConnection {
        let key = SSHKeys.generateEd25519().privateKey
        return ServerConnection(
            config: config,
            deviceID: UUID(),
            transport: transport,
            auth: .privateKey(key, user: "dev"),
            hostKeys: InMemoryHostKeyStore(),
            settings: settings,
            log: log
        )
    }

    @Test func connectPublishesStates() async throws {
        let transport = FakeTransport()
        let connection = try Self.make(transport)
        let recorder = StateRecorder(connection)
        try await connection.connect()
        #expect(await connection.state.isConnected)
        #expect(try await recorder.waitFor { $0.isConnected })
        #expect(recorder.states.first == .connecting)
        #expect(await connection.hostKeyFingerprint == "SHA256:fake")
        // повторный connect при живом соединении ничего не делает
        try await connection.connect()
        #expect(transport.connectAttempts == 1)
    }

    @Test func execUsesTwoSlots() async throws {
        let transport = FakeTransport()
        transport.onConnect { $0.execDelay = .milliseconds(80) }
        let connection = try Self.make(transport)
        try await connection.connect()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<3 {
                group.addTask { _ = try await connection.exec("echo \(index)") }
            }
            try await group.waitForAll()
        }
        let fake = try #require(transport.lastConnection)
        #expect(fake.maxConcurrentExecs == 2)
        #expect(fake.execCalls.count == 3)
    }

    @Test func execWhileDisconnectedFails() async throws {
        let connection = try Self.make(FakeTransport())
        await #expect(throws: SSHError.disconnected) { try await connection.exec("true") }
    }

    @Test func ptyLimit() async throws {
        let transport = FakeTransport()
        let connection = try Self.make(transport)
        try await connection.connect()
        var channels: [any PTYChannel] = []
        for _ in 0..<8 {
            channels.append(try await connection.openPTY(command: "cat", cols: 80, rows: 24))
        }
        await #expect(throws: SSHError.channelRefused) { _ = try await connection.openPTY(command: "cat", cols: 80, rows: 24) }
        // девятый не дошёл до сервера
        #expect(transport.lastConnection?.openedPTYs.count == 8)

        await channels[0].close()
        #expect(await connection.openPTYCount == 7)
        channels[0] = try await connection.openPTY(command: "cat", cols: 80, rows: 24)

        // канал, закрытый сервером, тоже освобождает слот
        let fake = try #require(transport.lastConnection?.openedPTYs.last)
        fake.close(exitCode: 0)
        #expect(try await Bench.eventually(.seconds(2)) { await connection.openPTYCount == 7 })
    }

    @Test func ptyForwardsOutputAndInput() async throws {
        let transport = FakeTransport()
        let connection = try Self.make(transport)
        try await connection.connect()
        let channel = try await connection.openPTY(command: "attach", cols: 100, rows: 30)
        let fake = try #require(transport.lastConnection?.openedPTYs.first)
        #expect(fake.environment == ["LANG": "en_US.UTF-8"])
        #expect(fake.resizes.first! == (100, 30))
        fake.emit(Data("hello".utf8))
        fake.close(exitCode: 0)
        var received = Data()
        for try await chunk in channel.output {
            received.append(chunk)
        }
        #expect(received == Data("hello".utf8))
        #expect(channel.exitCode == 0)
    }

    @Test func pingSkippedAfterRecentExec() async throws {
        let transport = FakeTransport()
        let connection = try Self.make(transport, settings: Self.settings(keepalive: .milliseconds(300)))
        try await connection.connect()
        try await Task.sleep(for: .milliseconds(150))
        _ = try await connection.exec("echo hi")
        // такт на 300 мс пропущен: exec был 150 мс назад
        try await Task.sleep(for: .milliseconds(300))
        let fake = try #require(transport.lastConnection)
        #expect(!fake.execCalls.contains { $0.command == "true" })
        // на такте 600 мс exec старше интервала — пинг
        #expect(try await Bench.eventually(.seconds(2)) { fake.execCalls.contains { $0.command == "true" } })
    }

    @Test func twoMissedPingsReconnect() async throws {
        let transport = FakeTransport()
        let log = DiagnosticsLog()
        let connection = try Self.make(transport, settings: Self.settings(keepalive: .milliseconds(50)), log: log)
        let recorder = StateRecorder(connection)
        try await connection.connect()
        let first = try #require(transport.lastConnection)
        first.hangExec = true
        #expect(try await recorder.waitFor { $0 == .reconnecting(attempt: 1) })
        #expect(try await Bench.eventually { await connection.state.isConnected && transport.connections.count == 2 })
        #expect(!first.isConnected)
        #expect(await log.events().contains { $0.message == "ping timeout x2" })
        #expect(await log.events().filter { $0.kind == .ping }.count == 2)
    }

    @Test func disconnectEventReconnects() async throws {
        let transport = FakeTransport()
        let connection = try Self.make(transport)
        let recorder = StateRecorder(connection)
        try await connection.connect()
        transport.dropConnection()
        #expect(try await recorder.waitFor { $0 == .reconnecting(attempt: 1) })
        #expect(try await Bench.eventually { await connection.state.isConnected && transport.connectAttempts == 2 })
        _ = try await connection.exec("true")
    }

    @Test func backoffThenFailed() async throws {
        let transport = FakeTransport()
        transport.failNextConnects(10)
        let backoff: [Duration] = [.milliseconds(20), .milliseconds(40), .milliseconds(60), .milliseconds(80)]
        let connection = try Self.make(transport, settings: Self.settings(backoff: backoff))
        let recorder = StateRecorder(connection)
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: SSHError.connectFailed("fake refused")) { try await connection.connect() }
        #expect(try await recorder.waitFor { if case .failed = $0 { true } else { false } })
        #expect(clock.now - start >= .milliseconds(200))
        #expect(transport.connectAttempts == 5)
        #expect(recorder.states == [
            .connecting,
            .reconnecting(attempt: 1),
            .reconnecting(attempt: 2),
            .reconnecting(attempt: 3),
            .reconnecting(attempt: 4),
            .failed(SSHError.connectFailed("fake refused").description),
        ])
        // в .failed без явного запроса попыток больше нет
        try await Task.sleep(for: .milliseconds(150))
        #expect(transport.connectAttempts == 5)

        await connection.reconnectNow()
        #expect(transport.connectAttempts == 6)
        await connection.disconnect()
    }

    @Test func reconnectNowAfterFailureConnects() async throws {
        let transport = FakeTransport()
        transport.failNextConnects(5)
        let connection = try Self.make(transport)
        let recorder = StateRecorder(connection)
        _ = try? await connection.connect()
        #expect(try await recorder.waitFor { if case .failed = $0 { true } else { false } })
        await connection.reconnectNow()
        #expect(await connection.state.isConnected)
    }

    @Test func explicitDisconnectDoesNotReconnect() async throws {
        let transport = FakeTransport()
        let connection = try Self.make(transport)
        try await connection.connect()
        await connection.disconnect()
        #expect(await connection.state == .disconnected)
        #expect(transport.lastConnection?.isConnected == false)
        try await Task.sleep(for: .milliseconds(150))
        #expect(transport.connectAttempts == 1)
        #expect(await connection.state == .disconnected)
    }

    @Test func hostKeyChangedIsFatal() async throws {
        let transport = FakeTransport()
        let changed = SSHError.hostKeyChanged(expected: "SHA256:a", actual: "SHA256:b")
        transport.failNextConnects(10, with: changed)
        let connection = try Self.make(transport)
        await #expect(throws: changed) { try await connection.connect() }
        #expect(await connection.state == .failed(changed.description))
        try await Task.sleep(for: .milliseconds(150))
        #expect(transport.connectAttempts == 1)
    }

    @Test func hostKeyChangedDuringReconnectStops() async throws {
        let transport = FakeTransport()
        let connection = try Self.make(transport)
        try await connection.connect()
        let changed = SSHError.hostKeyChanged(expected: "SHA256:a", actual: "SHA256:b")
        transport.failNextConnects(10, with: changed)
        transport.dropConnection()
        #expect(try await Bench.eventually { await connection.state == .failed(changed.description) })
        #expect(transport.connectAttempts == 2)
    }

    @Test func apiRunsThroughPool() async throws {
        let transport = FakeTransport()
        transport.onConnect { $0.respond(containing: "tmuxpad-host.sh version", stdout: "tmuxpad-host 1\n") }
        let connection = try Self.make(transport)
        try await connection.connect()
        #expect(try await connection.api.version() == 1)
    }
}

struct ConnectionPoolTests {
    @Test func oneConnectionPerServer() async throws {
        let pool = ConnectionPool(transport: FakeTransport(), hostKeys: InMemoryHostKeyStore(), deviceID: UUID())
        let key = SSHKeys.generateEd25519().privateKey
        var config = ServerConnectionTests.config
        let first = await pool.connection(for: config, auth: .privateKey(key, user: "dev"))
        config.projectsRoot = "work"
        let same = await pool.connection(for: config, auth: .privateKey(key, user: "dev"))
        #expect(first === same)
        #expect(await same.config.projectsRoot == "work")
        config.host = "other.example"
        let recreated = await pool.connection(for: config, auth: .privateKey(key, user: "dev"))
        #expect(first !== recreated)
        await pool.remove(id: config.id)
        #expect(await pool.existing(id: config.id) == nil)
    }

    @Test func disconnectAllAndReconnectAll() async throws {
        let transport = FakeTransport()
        let pool = ConnectionPool(transport: transport, hostKeys: InMemoryHostKeyStore(), deviceID: UUID()) { _ in
            ServerConnectionTests.settings()
        }
        let key = SSHKeys.generateEd25519().privateKey
        let connection = await pool.connection(for: ServerConnectionTests.config, auth: .privateKey(key, user: "dev"))
        try await connection.connect()
        await pool.disconnectAll()
        #expect(await connection.state == .disconnected)
        await pool.reconnectAll()
        #expect(await connection.state.isConnected)
        #expect(transport.connectAttempts == 2)
    }
}
