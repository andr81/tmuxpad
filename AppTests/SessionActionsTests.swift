import Foundation
import Testing
import TmuxPadCore
@testable import TmuxPad

@MainActor
struct SessionActionsTests {
    let env: AppEnvironment
    let key = OpenSessionKey(serverID: UUID(), name: "api-1")

    init() throws {
        env = try AppEnvironment.inMemory()
    }

    @Test func attachCommandWithoutDetach() {
        #expect(env.actions.attachCommand(key) == "tmux attach -t '=api-1'")
    }

    /// Имя пришло из `list` сервера: кавычка в нём не выходит из строки.
    @Test func attachCommandEscapesQuote() {
        let hostile = OpenSessionKey(serverID: key.serverID, name: "x'; rm -rf ~; '")
        #expect(env.actions.attachCommand(hostile) == #"tmux attach -t '=x'\''; rm -rf ~; '\'''"#)
    }

    @Test func openTakeDetach() {
        env.actions.open(key)
        #expect(env.openSessions.selection == key)
        let other = OpenSessionKey(serverID: key.serverID, name: "web")
        env.actions.take(other)
        #expect(env.openSessions.selection == other)
        env.actions.detach(other)
        #expect(!env.openSessions.isOpen(other))
        #expect(env.openSessions.selection == key)
    }

    /// Сервера уже нет: идти некуда, сессия просто закрывается.
    @Test func killWithoutServerCloses() async throws {
        env.actions.open(key)
        try await env.actions.kill(key)
        #expect(!env.openSessions.isOpen(key))
        #expect(env.openSessions.selection == nil)
    }

    /// Сервер без подтверждённого отпечатка: подключение запомнило бы ключ без «Доверять» (§8).
    @Test func actionsRefuseUnconfirmedServer() async throws {
        let server = ServerConfig(label: "s", host: "127.0.0.1", port: 1, user: "u", keyID: UUID())
        try env.servers.add(server)
        let key = OpenSessionKey(serverID: server.id, name: "api")
        env.actions.open(key)
        await #expect(throws: AppError.hostKeyUnconfirmed) { try await env.actions.kill(key) }
        // `kill` не дошёл до сервера — сессия остаётся открытой
        #expect(env.openSessions.isOpen(key))

        var flow = NewSessionFlow(servers: env.servers.servers)
        flow.selectProject("api")
        flow.editName("fresh")
        #expect(await flow.create(using: env.actions) == .failed(userText(AppError.hostKeyUnconfirmed)))
    }

    @Test func showEmptyProjectsPersists() {
        env.tree.showEmptyProjects = true
        let reopened = TreeModel(refresher: env.refresher, openSessions: env.openSessions, defaults: env.defaults)
        #expect(reopened.showEmptyProjects)
    }

    /// Опрос удалённого сервера, закончившийся после удаления, не возвращает его в дерево.
    @Test func removedServerStaysRemoved() async throws {
        let env = try AppEnvironment.inMemory(treeInterval: .milliseconds(50))
        var server = ServerConfig(label: "s", host: "127.0.0.1", port: 1, user: "u", keyID: UUID())
        server.hostKeyFingerprint = "SHA256:x"
        env.tree.setServers([server])
        env.tree.start()
        await env.tree.setServers([]).value
        try await Task.sleep(for: .milliseconds(300))
        #expect(env.tree.states[server.id] == nil)
        await env.tree.stop().value
    }

    @Test func activityText() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(SessionRow.activityText(now.addingTimeInterval(-300), now: now) == "5 мин. назад")
        // часы сервера впереди — не «через N»
        #expect(SessionRow.activityText(now.addingTimeInterval(60), now: now) == "сейчас")
    }

    @Test func serverStatus() {
        var server = ServerConfig(label: "s", host: "h", port: 22, user: "u", keyID: UUID())
        #expect(ServerRow.status(server: server, state: nil) == nil)
        #expect(ServerRow.status(server: server, state: ServerTreeState(reachability: .online)) == nil)
        #expect(ServerRow.status(server: server, state: ServerTreeState(reachability: .offline("x")))?.action == .retry)
        #expect(ServerRow.status(server: server, state: ServerTreeState(reachability: .needsSetup("x")))
            == ServerRow.Status(text: "Подключение не проверено", action: .check))
        server.hostKeyFingerprint = "SHA256:x"
        #expect(ServerRow.status(server: server, state: ServerTreeState(reachability: .needsSetup("x")))?.text
            == "Требуется подготовка")
        let attention = ServerTreeState(reachability: .offline("x"), attention: .authFailed)
        #expect(ServerRow.status(server: server, state: attention) == ServerRow.Status(text: "Сервер не принял ключ", action: .check))
        let changed = ServerTreeState(
            reachability: .offline("x"), attention: .hostKeyChanged(expected: "SHA256:a", actual: "SHA256:b")
        )
        #expect(ServerRow.status(server: server, state: changed) == ServerRow.Status(text: "Ключ сервера изменился", action: .check))
        #expect(ServerRow.status(server: server, state: ServerTreeState(reachability: .unknown)) == nil)
    }

    @Test func staleOnlyOfflineWithSnapshot() {
        let snapshot = ServerSnapshot(projects: [], sessions: [], fetchedAt: Date())
        #expect(ServerRow.isStale(ServerTreeState(reachability: .offline("x"), snapshot: snapshot)))
        #expect(!ServerRow.isStale(ServerTreeState(reachability: .offline("x"))))
        #expect(!ServerRow.isStale(ServerTreeState(reachability: .online, snapshot: snapshot)))
        #expect(ServerRow.staleCaption(ServerTreeState(reachability: .offline("x"), snapshot: snapshot))?
            .hasPrefix("по состоянию на ") == true)
    }
}
