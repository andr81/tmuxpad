import Foundation
import Testing
@testable import TmuxPadCore

@Suite struct SessionTreeTests {
    private func session(_ name: String, _ project: String, at seconds: TimeInterval = 0, others: Int = 0) -> RemoteSession {
        RemoteSession(name: name, project: project, otherClients: others, lastActivity: Date(timeIntervalSince1970: seconds))
    }

    private func snapshot(projects: [String], sessions: [RemoteSession]) -> ServerSnapshot {
        ServerSnapshot(
            projects: projects.map { RemoteProject(name: $0, path: "/p/\($0)") },
            sessions: sessions,
            fetchedAt: Date(timeIntervalSince1970: 0)
        )
    }

    @Test func sortsProjectsAndSessionsCaseInsensitively() {
        let tree = SessionTree.build(
            snapshot: snapshot(
                projects: ["beta", "Alpha", "api", "API"],
                sessions: [session("zed", "beta"), session("Bob", "beta"), session("alice", "beta"),
                           session("s", "Alpha"), session("a", "api"), session("b", "API")]
            ),
            openSessions: [], showEmptyProjects: false
        )
        #expect(tree.map(\.name) == ["Alpha", "API", "api", "beta"])
        #expect(tree[3].sessions.map(\.id) == ["alice", "Bob", "zed"])
        #expect(tree[0].path == "/p/Alpha")
        #expect(tree[0].id == "Alpha")
    }

    @Test func sessionOfMissingProjectGetsNodeWithoutPath() {
        let tree = SessionTree.build(
            snapshot: snapshot(projects: ["app"], sessions: [session("s1", "app"), session("ghost", "gone")]),
            openSessions: [], showEmptyProjects: false
        )
        #expect(tree.map(\.name) == ["app", "gone"])
        #expect(tree[0].path == "/p/app")
        #expect(tree[1].path == nil)
        #expect(tree[1].sessions.map(\.session) == [session("ghost", "gone")])
    }

    @Test func showEmptyProjectsTogglesEmptyNodes() {
        let snap = snapshot(projects: ["empty", "full"], sessions: [session("s", "full")])
        let hidden = SessionTree.build(snapshot: snap, openSessions: [], showEmptyProjects: false)
        #expect(hidden.map(\.name) == ["full"])
        let shown = SessionTree.build(snapshot: snap, openSessions: [], showEmptyProjects: true)
        #expect(shown.map(\.name) == ["empty", "full"])
        #expect(shown[0].sessions.isEmpty)
    }

    @Test func isOpenFollowsOpenSessionNames() {
        let tree = SessionTree.build(
            snapshot: snapshot(projects: ["app"], sessions: [session("a", "app", others: 2), session("b", "app")]),
            openSessions: ["b", "unrelated"], showEmptyProjects: false
        )
        #expect(tree[0].sessions.map(\.isOpen) == [false, true])
        #expect(tree[0].sessions[0].session.otherClients == 2)
    }

    @Test func emptySnapshotGivesEmptyTree() {
        let tree = SessionTree.build(snapshot: snapshot(projects: [], sessions: []), openSessions: [], showEmptyProjects: true)
        #expect(tree.isEmpty)
    }

    @Test func byActivityOrdersGroupsAndSessions() {
        let groups = SessionTree.byActivity(snapshot: snapshot(
            projects: ["old", "new", "empty"],
            sessions: [session("o1", "old", at: 50), session("n1", "new", at: 10), session("n2", "new", at: 100),
                       session("o2", "old", at: 90), session("x", "gone", at: 70)]
        ))
        #expect(groups.map(\.project) == ["new", "old", "gone"])
        #expect(groups[0].sessions.map(\.name) == ["n2", "n1"])
        #expect(groups[1].sessions.map(\.name) == ["o2", "o1"])
        #expect(groups[2] == ActivityGroup(project: "gone", sessions: [session("x", "gone", at: 70)]))
    }

    @Test func byActivityBreaksTiesByName() {
        let groups = SessionTree.byActivity(snapshot: snapshot(
            projects: [],
            sessions: [session("b", "p2", at: 5), session("B", "p1", at: 5), session("a", "p1", at: 5)]
        ))
        #expect(groups.map(\.project) == ["p1", "p2"])
        #expect(groups[0].sessions.map(\.name) == ["a", "B"])
    }
}
