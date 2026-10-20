import Foundation
import Testing
@testable import TmuxPadCore

@Suite(.serialized, .enabled(if: Bench.isAvailable))
struct TreeRefresherIntegrationTests {
    /// Сброс стенда, скрипт и `setup`; пул на стенде, конфиг с отпечатком из первого
    /// `connect()` того же пула — так приложение делает «Доверять».
    private func withRefresher(
        _ body: @escaping @Sendable (any SSHConnection, TreeRefresher, ServerConfig, ConnectionPool) async throws -> Void
    ) async throws {
        try await Bench.withReset(timeout: .seconds(90)) { connection in
            _ = try await HostBootstrap().prepare(api: Bench.api(connection))
            let pool = ConnectionPool(transport: CitadelTransport(), hostKeys: InMemoryHostKeyStore(), deviceID: Bench.deviceID)
            let auth = try Bench.auth()
            var config = PoolIntegrationTests.config()
            let pooled = await pool.connection(for: config, auth: auth)
            try await pooled.connect()
            config.hostKeyFingerprint = await pooled.hostKeyFingerprint
            #expect(config.hostKeyFingerprint != nil)
            let refresher = TreeRefresher(pool: pool, bootstrap: try HostBootstrap(), auth: { _ in auth })
            await refresher.setServers([config])
            do {
                try await body(connection, refresher, config, pool)
            } catch {
                await pool.remove(id: config.id)
                throw error
            }
            await pool.remove(id: config.id)
        }
    }

    @Test func onlineWithBenchProjects() async throws {
        try await withRefresher { _, refresher, config, _ in
            await refresher.refresh(config.id)
            let state = try #require(await refresher.state(for: config.id))
            #expect(state.reachability == .online)
            #expect(Set(state.snapshot?.projects.map(\.name) ?? []) == ["api", "web", "my.app"])
            #expect(state.snapshot?.sessions.isEmpty == true)
        }
    }

    @Test func refreshSeesNewSession() async throws {
        try await withRefresher { _, refresher, config, pool in
            await refresher.refresh(config.id)
            let connection = try #require(await pool.existing(id: config.id))
            try await connection.api.new(session: "tree", project: "api")
            await refresher.refresh(config.id)
            let sessions = await refresher.state(for: config.id)?.snapshot?.sessions ?? []
            #expect(sessions.map(\.name) == ["tree"])
            #expect(sessions.first?.project == "api")
        }
    }

    @Test func removedScriptNeedsSetupThenPrepared() async throws {
        try await withRefresher { connection, refresher, config, pool in
            do {
                await refresher.refresh(config.id)
                #expect(await refresher.state(for: config.id)?.reachability == .online)
                let removed = try await connection.exec("rm ~/.local/bin/tmuxpad-host.sh")
                #expect(removed.exitCode == 0)
                // эпоха та же: `version` не перечитывается, `list` даёт 127
                await refresher.refresh(config.id)
                #expect(await refresher.state(for: config.id)?.reachability == .needsSetup(TreeRefresher.scriptMissing))

                let pooled = try #require(await pool.existing(id: config.id))
                _ = try await HostBootstrap().prepare(api: pooled.api)
                await refresher.markPrepared(config.id)
                let state = try #require(await refresher.state(for: config.id))
                #expect(state.reachability == .online)
                #expect(state.bootstrap == .ready(version: try HostScript.version))
            } catch {
                try? await HostBootstrap().install(api: Bench.api(connection))
                throw error
            }
            try await HostBootstrap().install(api: Bench.api(connection))
        }
    }
}
