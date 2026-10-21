import Foundation
import Testing
import TmuxPadCore
@testable import TmuxPad

/// Уход в фон и возврат против стенда: координатор с короткой задержкой над настоящими пулом
/// и деревом окружения.
@MainActor
@Suite(.serialized, .enabled(if: Bench.isAvailable), .timeLimit(.minutes(2)))
final class LifecycleBenchTests {
    let directory = temporaryDirectory()
    let env: AppEnvironment
    let coordinator: LifecycleCoordinator

    init() async throws {
        env = try AppEnvironment.inMemory(directory: directory)
        coordinator = LifecycleCoordinator(
            targets: AppLifecycleTargets(pool: env.pool, tree: env.tree, openSessions: env.openSessions),
            log: env.log,
            backgroundTasks: FakeBackgroundTasks(),
            closeDelay: .milliseconds(50)
        )
        try await Bench.reset()
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
        let env = env
        Task { @MainActor in
            await env.pool.disconnectAll()
        }
    }

    private func openLive(_ name: String) async throws -> OpenTerminal {
        let server = try await Bench.preparedServer(in: env)
        let created = try await Bench.exec("~/.local/bin/tmuxpad-host.sh new \(name) api")
        #expect(created.exitCode == 0, "\(created.stderrText)")
        env.tree.setServers(env.servers.servers)
        await env.tree.refresh(serverID: server.id)
        await coordinator.scenePhaseChanged(.active)?.value
        let key = OpenSessionKey(serverID: server.id, name: name)
        env.openSessions.open(key)
        let terminal = try #require(env.openSessions.terminals[key])
        try await waitUntil(timeout: .seconds(15)) { terminal.state == .live }
        return terminal
    }

    /// Фон дольше задержки: соединения закрыты.
    private func goToBackground(_ terminal: OpenTerminal) async throws {
        coordinator.scenePhaseChanged(.background)
        try await waitUntil(timeout: .seconds(10)) { coordinator.closed && terminal.state != .live }
    }

    private func finish() async {
        for key in env.openSessions.roster.tabs {
            env.openSessions.close(key)
        }
        await env.pool.disconnectAll()
    }

    @Test func returnReattachesWithoutZombies() async throws {
        let terminal = try await openLive("revive")
        try await waitForExec { try await self.clients("revive") == 1 }
        try await goToBackground(terminal)
        #expect(terminal.state != .live)
        await coordinator.scenePhaseChanged(.active)?.value
        try await waitUntil(timeout: .seconds(15)) { terminal.state == .live }
        #expect(terminal.state == .live)
        // старый клиент ушёл вместе с соединением или выкинут `attach` по файлу клиента
        try await waitForExec { try await self.clients("revive") == 1 }
        #expect(try await clients("revive") == 1)
        await finish()
    }

    @Test func sessionKilledInBackgroundEndsAfterReturn() async throws {
        let terminal = try await openLive("gone")
        try await goToBackground(terminal)
        let killed = try await Bench.exec("tmux kill-session -t '=gone'")
        #expect(killed.exitCode == 0, "\(killed.stderrText)")
        await coordinator.scenePhaseChanged(.active)?.value
        try await waitUntil(timeout: .seconds(15)) { terminal.state == .ended }
        #expect(terminal.state == .ended)
        await finish()
    }

    /// Клиенты tmux, подключённые к сессии `name`.
    private func clients(_ name: String) async throws -> Int {
        let result = try await Bench.exec("tmux list-clients -t '=\(name)' -F '#{client_pid}'")
        return result.stdoutText.split(separator: "\n").count
    }

    private func waitForExec(timeout: Duration = .seconds(15), _ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !(try await condition()) {
            guard ContinuousClock.now < deadline else {
                Issue.record("условие на стенде не выполнилось за \(timeout)")
                return
            }
            try await Task.sleep(for: .milliseconds(200))
        }
    }
}
