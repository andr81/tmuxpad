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

    @Test func activityText() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(SessionRow.activityText(now.addingTimeInterval(-300), now: now).contains("5"))
        // часы сервера впереди — не «через N»
        #expect(!SessionRow.activityText(now.addingTimeInterval(60), now: now).contains("через"))
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
