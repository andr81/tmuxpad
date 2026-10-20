import Foundation
import Testing
@testable import TmuxPadCore

@Suite(.serialized, .enabled(if: Bench.isAvailable))
struct PoolIntegrationTests {
    static func config() -> ServerConfig {
        ServerConfig(label: "bench", host: Bench.endpoint.host, port: Bench.endpoint.port, user: Bench.user, keyID: UUID(), startCommand: "sleep 1000")
    }

    static func connection() throws -> ServerConnection {
        ServerConnection(
            config: config(),
            deviceID: Bench.deviceID,
            transport: CitadelTransport(),
            auth: try Bench.auth(),
            hostKeys: InMemoryHostKeyStore(),
            settings: PoolSettings(keepalive: .seconds(2), connectTimeout: .seconds(10))
        )
    }

    @Test func connectExecPing() async throws {
        let connection = try Self.connection()
        try await withTimeout(.seconds(30)) {
            try await connection.connect()
            #expect(await connection.state.isConnected)
            #expect(try await connection.exec("true").exitCode == 0)
            // keepalive на 2 с: пинг проходит, соединение живо
            try await Task.sleep(for: .seconds(5))
            #expect(await connection.state.isConnected)
            #expect(try await connection.exec("echo ok").stdoutText == "ok\n")
            #expect(await !connection.log.events().contains { $0.kind == .ping })
        }
        await connection.disconnect()
    }

    @Test func killSessionReconnects() async throws {
        try await Bench.exclusive {
            let connection = try Self.connection()
            try await withTimeout(.seconds(40)) {
                try await connection.connect()
                _ = try await HostBootstrap().prepare(api: connection.api)
                // $PPID — sshd-процесс сеанса: его смерть рвёт TCP
                _ = try? await connection.exec("kill -9 $PPID")
                #expect(try await Bench.eventually(.seconds(5)) {
                    if case .reconnecting = await connection.state { true } else { await !connection.state.isConnected }
                })
                #expect(try await Bench.eventually(.seconds(10)) { await connection.state.isConnected })
                #expect(try await connection.api.version() == HostScript.version)
                #expect(await connection.log.events().contains { $0.message == "transport disconnected" })
            }
            await connection.disconnect()
        }
    }

    @Test func disconnectAllAndReconnectAll() async throws {
        let pool = ConnectionPool(transport: CitadelTransport(), hostKeys: InMemoryHostKeyStore(), deviceID: Bench.deviceID)
        let connection = await pool.connection(for: Self.config(), auth: try Bench.auth())
        try await withTimeout(.seconds(30)) {
            try await connection.connect()
            await pool.disconnectAll()
            #expect(await connection.state == .disconnected)
            await #expect(throws: SSHError.disconnected) { try await connection.exec("true") }
            await pool.reconnectAll()
            #expect(await connection.state.isConnected)
            #expect(try await connection.exec("true").exitCode == 0)
        }
        await pool.remove(id: connection.config.id)
    }
}
