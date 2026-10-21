import Foundation
import Testing
import TmuxPadCore
@testable import TmuxPad

@MainActor
struct AttachFlowTests {
    let first = ServerConfig(label: "a", host: "a", port: 22, user: "u", keyID: UUID())
    let second = ServerConfig(label: "b", host: "b", port: 22, user: "u", keyID: UUID())

    @Test func oneServerSkipsServerStep() {
        let flow = AttachFlow(servers: [first])
        #expect(flow.steps == [.sessions])
        #expect(flow.serverID == first.id)
        #expect(flow.step(after: .sessions) == nil)
        #expect(flow.key(for: "api") == OpenSessionKey(serverID: first.id, name: "api"))
    }

    @Test func twoServersStartWithServer() {
        var flow = AttachFlow(servers: [first, second])
        #expect(flow.steps == [.server, .sessions])
        #expect(flow.serverID == nil)
        #expect(flow.key(for: "api") == nil)
        #expect(flow.step(after: .server) == .sessions)
        flow.selectServer(second.id)
        #expect(flow.key(for: "api") == OpenSessionKey(serverID: second.id, name: "api"))
    }

    @Test func groupsByActivity() {
        let now = Date()
        let snapshot = ServerSnapshot(
            projects: [RemoteProject(name: "api", path: "/p/api"), RemoteProject(name: "web", path: "/p/web")],
            sessions: [
                RemoteSession(name: "api-old", project: "api", otherClients: 0, lastActivity: now.addingTimeInterval(-600)),
                RemoteSession(name: "web", project: "web", otherClients: 1, lastActivity: now.addingTimeInterval(-60)),
                RemoteSession(name: "api", project: "api", otherClients: 0, lastActivity: now),
            ],
            fetchedAt: now
        )
        let flow = AttachFlow(servers: [first])
        let groups = flow.groups(snapshot: snapshot)
        #expect(groups.map(\.project) == ["api", "web"])
        #expect(groups[0].sessions.map(\.name) == ["api", "api-old"])
        #expect(groups[1].sessions[0].otherClients == 1)
    }

    @Test func noSnapshotNoGroups() {
        let flow = AttachFlow(servers: [first])
        #expect(flow.groups(snapshot: nil).isEmpty)
        let empty = ServerSnapshot(projects: [RemoteProject(name: "api", path: "/p/api")], sessions: [], fetchedAt: Date())
        #expect(flow.groups(snapshot: empty).isEmpty)
    }
}
