import Foundation
import Testing
@testable import TmuxPadCore

struct TreeRefresherTests {
    static let bundled = try! HostScript.version
    static let listOutput = "V\t1\nP\tapi\t/home/dev/projects/api\nS\tapi\t0\tapi\t1700000000\n"

    /// Пул на фейке, сервер с подтверждённым отпечатком, интервал 50 мс.
    struct Rig {
        let transport = FakeTransport()
        let pool: ConnectionPool
        let refresher: TreeRefresher
        var config = ServerConfig(label: "fake", host: "fake.example", user: "dev", keyID: UUID(), hostKeyFingerprint: "SHA256:fake")

        init(
            backoff: [Duration] = [.milliseconds(20)],
            version: Int = TreeRefresherTests.bundled,
            list: String = TreeRefresherTests.listOutput,
            authDelay: Duration? = nil,
            authError: Error? = nil
        ) throws {
            let settings = PoolSettings(keepalive: .seconds(60), backoff: backoff, connectTimeout: .seconds(1), execTimeout: .seconds(2))
            pool = ConnectionPool(transport: transport, hostKeys: InMemoryHostKeyStore(), deviceID: UUID(), settings: { _ in settings })
            let key = SSHKeys.generateEd25519().privateKey
            let auth: @Sendable (ServerConfig) async throws -> SSHAuth = { _ in
                if let authDelay {
                    try await Task.sleep(for: authDelay)
                }
                if let authError {
                    throw authError
                }
                return .privateKey(key, user: "dev")
            }
            refresher = TreeRefresher(pool: pool, bootstrap: try HostBootstrap(), auth: auth, interval: .milliseconds(50))
            transport.onConnect { fake in
                fake.respondAlways(containing: " version", stdout: "tmuxpad-host \(version)\n")
                fake.respondAlways(containing: " list", stdout: list)
            }
        }

        var id: UUID { config.id }

        func state() async -> ServerTreeState? {
            await refresher.state(for: id)
        }

        func reachability() async -> ServerReachability? {
            await state()?.reachability
        }

        /// Exec `list` на всех соединениях фейка.
        var listCalls: Int {
            transport.connections.map { $0.execCount(containing: " list") }.reduce(0, +)
        }

        var versionCalls: Int {
            transport.connections.map { $0.execCount(containing: " version") }.reduce(0, +)
        }
    }

    @Test func successfulListGoesOnline() async throws {
        let rig = try Rig()
        await rig.refresher.setServers([rig.config])
        #expect(await rig.reachability() == .unknown)
        await rig.refresher.refresh(rig.id)
        let state = try #require(await rig.state())
        #expect(state.reachability == .online)
        #expect(state.snapshot?.sessions.map(\.name) == ["api"])
        #expect(state.bootstrap == .ready(version: TreeRefresherTests.bundled))
        #expect(state.refreshing == false)
        #expect(await rig.pool.log.events().contains { $0.kind == .exec && $0.message == "tree: online" })
        // в той же эпохе `version` не перечитывается
        await rig.refresher.refresh(rig.id)
        #expect(rig.versionCalls == 1)
        #expect(rig.listCalls == 2)
    }

    @Test func dropKeepsSnapshotOffline() async throws {
        let rig = try Rig()
        await rig.refresher.setServers([rig.config])
        await rig.refresher.refresh()
        let snapshot = try #require(await rig.state()?.snapshot)
        rig.transport.failNextConnects(100)
        rig.transport.dropConnection()
        let connection = try #require(await rig.pool.existing(id: rig.id))
        #expect(try await Bench.eventually(.seconds(3)) { await !connection.state.isConnected })
        await rig.refresher.refresh()
        let state = try #require(await rig.state())
        guard case .offline = state.reachability else {
            Issue.record("expected offline, got \(state.reachability)")
            return
        }
        #expect(state.snapshot == snapshot)
    }

    @Test func ticksDoNotConnectWhileReconnecting() async throws {
        let rig = try Rig(backoff: [.seconds(30)])
        await rig.refresher.setServers([rig.config])
        await rig.refresher.refresh()
        #expect(rig.transport.connectAttempts == 1)
        rig.transport.dropConnection()
        let connection = try #require(await rig.pool.existing(id: rig.id))
        #expect(try await Bench.eventually(.seconds(3)) {
            if case .reconnecting = await connection.state { true } else { false }
        })
        await rig.refresher.start()
        #expect(try await Bench.eventually(.seconds(3)) { await rig.reachability() == .offline(TreeRefresher.reconnecting) })
        try await Task.sleep(for: .milliseconds(300))
        await rig.refresher.stop()
        #expect(rig.transport.connectAttempts == 1)
        #expect(rig.listCalls == 1)
    }

    @Test func authFailedNeedsAttentionAndForceRetriesOnce() async throws {
        let rig = try Rig()
        rig.transport.failNextConnects(100, with: SSHError.authFailed)
        await rig.refresher.setServers([rig.config])
        await rig.refresher.refresh()
        let state = try #require(await rig.state())
        #expect(state.attention == .authFailed)
        #expect(state.reachability == .offline("\(SSHError.authFailed)"))
        #expect(rig.transport.connectAttempts == 1)
        // пул в `.failed`: тики попыток не делают
        await rig.refresher.start()
        try await Task.sleep(for: .milliseconds(250))
        await rig.refresher.stop()
        #expect(rig.transport.connectAttempts == 1)
        #expect(await rig.state()?.attention == .authFailed)
        // «Повторить» — ровно одна попытка
        await rig.refresher.refresh(rig.id, force: true)
        #expect(rig.transport.connectAttempts == 2)
        // успешное подключение сбрасывает `attention`
        rig.transport.failNextConnects(0)
        await rig.refresher.refresh(rig.id, force: true)
        #expect(rig.transport.connectAttempts == 3)
        #expect(await rig.state()?.attention == nil)
        #expect(await rig.reachability() == .online)
    }

    @Test func missingScriptNeedsSetupWithoutList() async throws {
        let rig = try Rig()
        rig.transport.onConnect { fake in
            fake.respondAlways(containing: " version", exitCode: 127, stderr: "not found")
        }
        await rig.refresher.setServers([rig.config])
        await rig.refresher.refresh()
        #expect(await rig.reachability() == .needsSetup(TreeRefresher.scriptMissing))
        #expect(await rig.state()?.bootstrap == .missing)
        #expect(rig.listCalls == 0)
    }

    @Test func outdatedScriptNeedsSetup() async throws {
        let rig = try Rig(version: TreeRefresherTests.bundled - 1)
        await rig.refresher.setServers([rig.config])
        await rig.refresher.refresh()
        #expect(await rig.reachability() == .needsSetup("Host script v\(TreeRefresherTests.bundled - 1) is older than v\(TreeRefresherTests.bundled)"))
        #expect(rig.listCalls == 0)
    }

    @Test func missingProjectsRootNeedsSetup() async throws {
        let rig = try Rig()
        rig.transport.onConnect { fake in
            fake.respondAlways(containing: " version", stdout: "tmuxpad-host \(TreeRefresherTests.bundled)\n")
            fake.respondAlways(containing: " list", exitCode: 2, stderr: "no projects")
        }
        await rig.refresher.setServers([rig.config])
        await rig.refresher.refresh()
        #expect(await rig.reachability() == .needsSetup("Projects folder projects does not exist"))
        #expect(await rig.state()?.snapshot == nil)
    }

    @Test func concurrentRefreshesShareOneList() async throws {
        let rig = try Rig()
        rig.transport.onConnect { fake in
            fake.execDelay = .milliseconds(100)
            fake.respondAlways(containing: " version", stdout: "tmuxpad-host \(TreeRefresherTests.bundled)\n")
            fake.respondAlways(containing: " list", stdout: TreeRefresherTests.listOutput)
        }
        await rig.refresher.setServers([rig.config])
        async let first: Void = rig.refresher.refresh(rig.id)
        async let second: Void = rig.refresher.refresh()
        _ = await (first, second)
        #expect(rig.listCalls == 1)
        #expect(rig.versionCalls == 1)
        #expect(await rig.reachability() == .online)
    }

    @Test func markPreparedWaitsAndRereadsVersion() async throws {
        let rig = try Rig()
        rig.transport.onConnect { fake in
            fake.execDelay = .milliseconds(150)
            // первый `version` — до подготовки, следующие — после
            fake.respond(containing: " version", exitCode: 127)
            fake.respondAlways(containing: " version", stdout: "tmuxpad-host \(TreeRefresherTests.bundled)\n")
            fake.respondAlways(containing: " list", stdout: TreeRefresherTests.listOutput)
        }
        await rig.refresher.setServers([rig.config])
        let updates = await rig.refresher.updates()
        let seen = Task {
            var seen: [ServerReachability] = []
            for await (_, state) in updates {
                seen.append(state.reachability)
                if state.reachability == .online {
                    break
                }
            }
            return seen
        }
        let running = Task { await rig.refresher.refresh() }
        #expect(try await Bench.eventually(.seconds(3)) { rig.versionCalls == 1 })
        await rig.refresher.markPrepared(rig.id)
        await running.value
        #expect(await seen.value.contains(.needsSetup(TreeRefresher.scriptMissing)))
        #expect(rig.versionCalls == 2)
        #expect(await rig.reachability() == .online)
        #expect(await rig.state()?.bootstrap == .ready(version: TreeRefresherTests.bundled))
    }

    @Test func unconfirmedHostKeyNeverConnects() async throws {
        var rig = try Rig()
        rig.config.hostKeyFingerprint = nil
        await rig.refresher.setServers([rig.config])
        await rig.refresher.refresh(force: true)
        #expect(await rig.reachability() == .needsSetup(TreeRefresher.notChecked))
        #expect(rig.transport.connectAttempts == 0)
        #expect(await rig.pool.existing(id: rig.id) == nil)
    }

    @Test func stopStopsTicks() async throws {
        let rig = try Rig()
        await rig.refresher.setServers([rig.config])
        await rig.refresher.start()
        #expect(try await Bench.eventually(.seconds(3)) { rig.listCalls >= 3 })
        await rig.refresher.stop()
        try await Task.sleep(for: .milliseconds(100))
        let calls = rig.listCalls
        try await Task.sleep(for: .milliseconds(250))
        #expect(rig.listCalls == calls)
    }

    @Test func slowServerDoesNotHoldTicks() async throws {
        let rig = try Rig()
        let slow = ServerConfig(label: "slow", host: "slow.example", user: "dev", keyID: UUID(), hostKeyFingerprint: "SHA256:fake")
        let key = SSHKeys.generateEd25519().privateKey
        let refresher = TreeRefresher(pool: rig.pool, bootstrap: try HostBootstrap(), auth: { config in
            if config.id == slow.id {
                try await Task.sleep(for: .seconds(30))
            }
            return .privateKey(key, user: "dev")
        }, interval: .milliseconds(50))
        await refresher.setServers([rig.config, slow])
        await refresher.start()
        #expect(try await Bench.eventually(.seconds(3)) { rig.listCalls >= 3 })
        #expect(await refresher.state(for: slow.id)?.refreshing == true)
        await refresher.stop()
    }

    @Test func removedServerLeavesPoolAndOutput() async throws {
        let rig = try Rig()
        let other = ServerConfig(label: "other", host: "other.example", user: "dev", keyID: UUID(), hostKeyFingerprint: "SHA256:fake")
        await rig.refresher.setServers([rig.config, other])
        await rig.refresher.refresh()
        let connection = try #require(await rig.pool.existing(id: rig.id))
        await rig.refresher.setServers([other])
        #expect(await rig.state() == nil)
        #expect(await rig.pool.existing(id: rig.id) == nil)
        #expect(await connection.state == .disconnected)
        var iterator = await rig.refresher.updates().makeAsyncIterator()
        let first = try #require(await iterator.next())
        #expect(first.0 == other.id)
        #expect(first.1.reachability == .online)
    }

    @Test(.timeLimit(.minutes(1))) func updatesReplayAndFollow() async throws {
        let rig = try Rig()
        await rig.refresher.setServers([rig.config])
        let updates = await rig.refresher.updates()
        await rig.refresher.refresh()
        var seen: [ServerTreeState] = []
        for await (id, state) in updates {
            #expect(id == rig.id)
            seen.append(state)
            if state.reachability == .online, !state.refreshing {
                break
            }
        }
        #expect(seen.first == ServerTreeState())
        #expect(seen.contains { $0.refreshing })
    }

    @Test func serverRemovedDuringRefreshStaysOutOfPool() async throws {
        let rig = try Rig(authDelay: .milliseconds(200))
        await rig.refresher.setServers([rig.config])
        let running = Task { await rig.refresher.refresh() }
        #expect(try await Bench.eventually(.seconds(3)) { await rig.state()?.refreshing == true })
        await rig.refresher.setServers([])
        await running.value
        #expect(await rig.pool.existing(id: rig.id) == nil)
        #expect(rig.transport.connectAttempts == 0)
        #expect(await rig.state() == nil)
    }

    @Test func authErrorGoesOffline() async throws {
        let rig = try Rig(authError: SSHError.authFailed)
        await rig.refresher.setServers([rig.config])
        await rig.refresher.refresh()
        #expect(await rig.reachability() == .offline("\(SSHError.authFailed)"))
        #expect(rig.transport.connectAttempts == 0)
    }

    @Test func forceDuringPollRunsAfterIt() async throws {
        let rig = try Rig()
        rig.transport.onConnect { fake in
            fake.execDelay = .milliseconds(150)
            fake.respondAlways(containing: " version", stdout: "tmuxpad-host \(TreeRefresherTests.bundled)\n")
            fake.respondAlways(containing: " list", stdout: TreeRefresherTests.listOutput)
        }
        await rig.refresher.setServers([rig.config])
        let poll = Task { await rig.refresher.refresh() }
        #expect(try await Bench.eventually(.seconds(3)) { rig.versionCalls == 1 })
        await rig.refresher.refresh(rig.id, force: true)
        await poll.value
        // `force` не схлопнулся с опросом: `version` прочитан заново
        #expect(rig.versionCalls == 2)
        #expect(rig.listCalls == 2)
    }

    @Test func reconnectRereadsVersion() async throws {
        let rig = try Rig()
        await rig.refresher.setServers([rig.config])
        await rig.refresher.refresh()
        let connection = try #require(await rig.pool.existing(id: rig.id))
        let first = await connection.state
        rig.transport.dropConnection()
        #expect(try await Bench.eventually(.seconds(3)) {
            let state = await connection.state
            return state.isConnected && state != first
        })
        await rig.refresher.refresh()
        #expect(rig.versionCalls == 2)
        #expect(await rig.reachability() == .online)
    }

    @Test func fatalReconnectFailureNeedsAttention() async throws {
        let rig = try Rig()
        await rig.refresher.setServers([rig.config])
        await rig.refresher.refresh()
        rig.transport.failNextConnects(100, with: SSHError.authFailed)
        rig.transport.dropConnection()
        let connection = try #require(await rig.pool.existing(id: rig.id))
        #expect(try await Bench.eventually(.seconds(3)) {
            if case .failed = await connection.state { true } else { false }
        })
        await rig.refresher.refresh()
        #expect(await rig.state()?.attention == .authFailed)
        guard case .offline = await rig.reachability() else {
            Issue.record("expected offline")
            return
        }
    }

    @Test func networkFailureAfterFatalClearsAttention() async throws {
        let rig = try Rig()
        rig.transport.failNextConnects(100, with: SSHError.authFailed)
        await rig.refresher.setServers([rig.config])
        await rig.refresher.refresh()
        #expect(await rig.state()?.attention == .authFailed)
        // ключ поставили, но «Повторить» упёрся в сеть: это не повод снова проверять сервер
        rig.transport.failNextConnects(100)
        await rig.refresher.refresh(rig.id, force: true)
        #expect(await rig.state()?.attention == nil)
        let connection = try #require(await rig.pool.existing(id: rig.id))
        #expect(try await Bench.eventually(.seconds(3)) {
            if case .failed = await connection.state { true } else { false }
        })
        #expect(await connection.lastFatalError == nil)
        await rig.refresher.refresh()
        #expect(await rig.state()?.attention == nil)
    }

    @Test func listScriptMissingNeedsSetup() async throws {
        let rig = try Rig()
        await rig.refresher.setServers([rig.config])
        await rig.refresher.refresh()
        let fake = try #require(rig.transport.lastConnection)
        fake.respondAlways(containing: " list", exitCode: 127, stderr: "not found")
        await rig.refresher.refresh()
        #expect(await rig.reachability() == .needsSetup(TreeRefresher.scriptMissing))
        #expect(await rig.state()?.bootstrap == .missing)
    }
}
