import Foundation
import Testing
import TmuxPadCore
@testable import TmuxPad

/// Дерево сайдбара против стенда: настоящие `TreeRefresher` и `ConnectionPool`, опрос 200 мс.
@MainActor
@Suite(.serialized, .enabled(if: Bench.isAvailable), .timeLimit(.minutes(2)))
final class SidebarBenchTests {
    let directory = temporaryDirectory()
    let env: AppEnvironment

    init() async throws {
        env = try AppEnvironment.inMemory(directory: directory, treeInterval: .milliseconds(200))
        try await Bench.reset()
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
        // тест упал до `finish()`: опрос не должен пережить его и мешать `Bench.reset()` следующего
        let env = env
        Task { @MainActor in
            await env.tree.stop().value
            await env.pool.disconnectAll()
        }
    }

    private func finish() async {
        await env.tree.stop().value
        await env.pool.disconnectAll()
    }

    /// Сервер стенда с подтверждённым отпечатком и установленным скриптом.
    private func preparedServer() async throws -> ServerConfig {
        let server = try await Bench.addServer(to: env)
        let model = ServerCheckModel(serverID: server.id, environment: env)
        await model.check().value
        await model.trust().value
        await model.prepare().value
        guard case .done(.ready, _) = model.state else {
            Issue.record("expected done(.ready), got \(model.state)")
            throw CancellationError()
        }
        return try #require(env.servers.server(id: server.id))
    }

    @Test func benchOnlineWithProjects() async throws {
        let server = try await preparedServer()
        env.tree.setServers(env.servers.servers)
        env.tree.start()

        try await waitUntil(timeout: .seconds(10)) { env.tree.states[server.id]?.reachability == .online }
        let names = env.tree.states[server.id]?.snapshot?.projects.map(\.name).sorted()
        #expect(names == ["api", "my.app", "web"])
        // сессий нет — проекты без сессий скрыты, пока не включён «Показывать все проекты»
        #expect(env.tree.nodes(for: server.id).isEmpty)
        env.tree.showEmptyProjects = true
        #expect(env.tree.nodes(for: server.id).map(\.name) == ["api", "my.app", "web"])
        await finish()
    }

    @Test func wrongPortOfflineBenchOnline() async throws {
        let server = try await preparedServer()
        var broken = Bench.config(keyID: server.keyID, label: "broken")
        broken.port = 1
        broken.hostKeyFingerprint = server.hostKeyFingerprint
        try env.servers.add(broken)
        env.tree.setServers(env.servers.servers)
        env.tree.start()

        try await waitUntil(timeout: .seconds(10)) {
            env.tree.states[server.id]?.reachability == .online
                && env.tree.states[broken.id].map { if case .offline = $0.reachability { true } else { false } } == true
        }
        #expect(env.tree.states[server.id]?.reachability == .online)
        guard case .offline = env.tree.states[broken.id]?.reachability else {
            Issue.record("expected offline, got \(String(describing: env.tree.states[broken.id]))")
            return
        }
        await finish()
    }

    @Test func removedServerLeavesTree() async throws {
        let server = try await preparedServer()
        env.tree.setServers(env.servers.servers)
        await env.tree.refresh(serverID: server.id)
        #expect(env.tree.states[server.id]?.reachability == .online)
        env.openSessions.open(OpenSessionKey(serverID: server.id, name: "api"))

        try await env.servers.delete(id: server.id)
        await env.tree.setServers(env.servers.servers).value
        #expect(env.tree.states[server.id] == nil)
        #expect(env.openSessions.roster.tabs.isEmpty)
        await finish()
    }

    @Test func killRemovesSession() async throws {
        let server = try await preparedServer()
        let created = try await Bench.exec("~/.local/bin/tmuxpad-host.sh new doomed api")
        #expect(created.exitCode == 0, "\(created.stderrText)")
        env.tree.setServers(env.servers.servers)
        await env.tree.refresh(serverID: server.id)
        let key = OpenSessionKey(serverID: server.id, name: "doomed")
        #expect(env.tree.nodes(for: server.id).flatMap(\.sessions).map(\.session.name) == ["doomed"])
        env.actions.open(key)

        try await env.actions.kill(key)
        #expect(env.tree.nodes(for: server.id).isEmpty)
        #expect(!env.openSessions.isOpen(key))
        // второй раз сессии уже нет — не ошибка
        try await env.actions.kill(key)
        await finish()
    }

    @Test func createdSessionVisibleInTree() async throws {
        let server = try await preparedServer()
        env.tree.setServers(env.servers.servers)
        await env.tree.refresh(serverID: server.id)
        var flow = NewSessionFlow(servers: env.servers.servers)
        flow.selectProject("my.app")
        flow.editName("fresh")
        #expect(flow.canCreate(snapshot: env.tree.states[server.id]?.snapshot))

        let key = OpenSessionKey(serverID: server.id, name: "fresh")
        #expect(await flow.create(using: env.actions) == .created(key))
        let sessions = env.tree.nodes(for: server.id).flatMap(\.sessions)
        #expect(sessions.map(\.session.name) == ["fresh"])
        #expect(sessions.first?.session.project == "my.app")
        #expect(sessions.first?.isOpen == true)
        #expect(env.openSessions.selection == key)
        await finish()
    }

    /// Снимок устарел: имя занято на сервере, но дерево его ещё не знает.
    @Test func repeatedNameConflicts() async throws {
        let server = try await preparedServer()
        env.tree.setServers(env.servers.servers)
        await env.tree.refresh(serverID: server.id)
        let created = try await Bench.exec("~/.local/bin/tmuxpad-host.sh new taken api")
        #expect(created.exitCode == 0, "\(created.stderrText)")
        var flow = NewSessionFlow(servers: env.servers.servers, serverID: server.id, project: "api")
        flow.editName("taken")
        let snapshot = env.tree.states[server.id]?.snapshot
        #expect(flow.nameIssue(snapshot: snapshot) == nil)

        let outcome = await flow.create(using: env.actions)
        #expect(outcome == .conflict)
        flow.apply(outcome)
        #expect(flow.nameIssue(snapshot: snapshot) == .exists)
        #expect(env.openSessions.selection == nil)
        await finish()
    }
}
