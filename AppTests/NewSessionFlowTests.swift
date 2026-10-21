import Foundation
import Testing
import TmuxPadCore
@testable import TmuxPad

@MainActor
struct NewSessionFlowTests {
    let first = ServerConfig(label: "a", host: "a", port: 22, user: "u", keyID: UUID())
    let second = ServerConfig(label: "b", host: "b", port: 22, user: "u", keyID: UUID())

    private func snapshot(sessions: [String]) -> ServerSnapshot {
        ServerSnapshot(
            projects: [RemoteProject(name: "api", path: "/p/api")],
            sessions: sessions.map { RemoteSession(name: $0, project: "api", otherClients: 0, lastActivity: Date()) },
            fetchedAt: Date()
        )
    }

    @Test func oneServerSkipsServerStep() {
        let flow = NewSessionFlow(servers: [first])
        #expect(flow.steps == [.project, .name])
        #expect(flow.serverID == first.id)
        #expect(flow.step(after: .project) == .name)
        #expect(flow.step(after: .name) == nil)
    }

    @Test func twoServersStartWithServer() {
        var flow = NewSessionFlow(servers: [first, second])
        #expect(flow.steps == [.server, .project, .name])
        #expect(flow.serverID == nil)
        flow.selectServer(second.id)
        flow.selectProject("api")
        // другой сервер — другие папки
        flow.selectServer(first.id)
        #expect(flow.project == nil)
        // тот же сервер ещё раз — проект остаётся
        flow.selectProject("web")
        flow.selectServer(first.id)
        #expect(flow.serverID == first.id)
        #expect(flow.project == "web")
    }

    /// «Создать» из пустого мастера «Подключиться»: сервер известен, проект — нет.
    @Test func serverOnlyPrefillAsksProject() {
        let flow = NewSessionFlow(servers: [first, second], serverID: second.id)
        #expect(flow.steps == [.project, .name])
        #expect(flow.serverID == second.id)
        #expect(flow.project == nil)
        #expect(flow.name.isEmpty)
    }

    @Test func contextMenuPrefillSkipsSteps() {
        let flow = NewSessionFlow(servers: [first, second], serverID: second.id, project: "my.app")
        #expect(flow.steps == [.name])
        #expect(flow.serverID == second.id)
        #expect(flow.project == "my.app")
        #expect(flow.name == "my-app")
        #expect(flow.key == OpenSessionKey(serverID: second.id, name: "my-app"))
    }

    @Test func suggestionFollowsProjectUntilEdited() {
        var flow = NewSessionFlow(servers: [first])
        flow.selectProject("my.app")
        #expect(flow.name == "my-app")
        flow.selectProject("web")
        #expect(flow.name == "web")
        flow.editName("web-2")
        flow.selectProject("api")
        #expect(flow.name == "web-2")
    }

    @Test func spaceBecomesDash() {
        var flow = NewSessionFlow(servers: [first])
        flow.editName("fix login bug")
        #expect(flow.name == "fix-login-bug")
    }

    @Test func nameIssues() {
        var flow = NewSessionFlow(servers: [first])
        flow.selectProject("api")
        let snapshot = snapshot(sessions: ["taken"])
        #expect(flow.nameIssue(snapshot: snapshot) == nil)
        #expect(flow.canCreate(snapshot: snapshot))
        flow.editName("")
        #expect(flow.nameIssue(snapshot: snapshot) == .empty)
        flow.editName("bad/name")
        #expect(flow.nameIssue(snapshot: snapshot) == .invalid)
        flow.editName(String(repeating: "a", count: 65))
        #expect(flow.nameIssue(snapshot: snapshot) == .invalid)
        flow.editName("taken")
        #expect(flow.nameIssue(snapshot: snapshot) == .exists)
        #expect(!flow.canCreate(snapshot: snapshot))
    }

    @Test func noProjectCannotCreate() {
        var flow = NewSessionFlow(servers: [first])
        flow.editName("ok")
        #expect(!flow.canCreate(snapshot: nil))
    }

    @Test func conflictOutcomeMarksNameTaken() {
        var flow = NewSessionFlow(servers: [first])
        flow.selectProject("api")
        flow.apply(.conflict)
        #expect(flow.nameIssue(snapshot: snapshot(sessions: [])) == .exists)
        flow.editName("api-2")
        #expect(flow.nameIssue(snapshot: snapshot(sessions: [])) == nil)
    }

    @Test func serverChangeForgetsNewOutcomes() {
        var flow = NewSessionFlow(servers: [first, second])
        flow.selectServer(first.id)
        flow.selectProject("api")
        flow.apply(.conflict)
        flow.apply(.invalid("bad project"))
        flow.selectServer(second.id)
        flow.selectProject("api")
        #expect(flow.nameIssue(snapshot: snapshot(sessions: [])) == nil)
        #expect(flow.serverIssue == nil)
        #expect(flow.canCreate(snapshot: snapshot(sessions: [])))
    }

    @Test func invalidOutcomeClearsOnEdit() {
        var flow = NewSessionFlow(servers: [first])
        flow.selectProject("api")
        flow.apply(.invalid("bad project"))
        #expect(flow.serverIssue == "bad project")
        #expect(!flow.canCreate(snapshot: nil))
        #expect(NameStep.footer(issue: nil, serverIssue: flow.serverIssue) == "bad project")
        flow.editName("api-2")
        #expect(flow.serverIssue == nil)
        #expect(NameStep.footer(issue: .invalid, serverIssue: nil)?.hasPrefix("Допустимы") == true)
    }

    /// Сервер удалили, пока мастер был открыт.
    @Test func createWithoutServerFails() async throws {
        let env = try AppEnvironment.inMemory()
        var flow = NewSessionFlow(servers: [first])
        flow.selectProject("api")
        #expect(await flow.create(using: env.actions) == .failed("Сервер удалён"))
    }

    @Test func unavailableReasons() {
        #expect(ServerPickStep.unavailableReason(server: first, state: nil) == "Подключение…")
        #expect(ServerPickStep.unavailableReason(server: first, state: ServerTreeState(reachability: .offline("x"))) == "Нет связи")
        let online = ServerTreeState(reachability: .online, snapshot: snapshot(sessions: []))
        #expect(ServerPickStep.unavailableReason(server: first, state: online) == nil)
    }
}
