import Foundation
import Testing
import TmuxPadCore
@testable import TmuxPad

@MainActor
struct NewProjectFlowTests {
    let serverID = UUID()

    private func snapshot(projects: [String]) -> ServerSnapshot {
        ServerSnapshot(
            projects: projects.map { RemoteProject(name: $0, path: "/p/\($0)") },
            sessions: [],
            fetchedAt: Date()
        )
    }

    @Test func cloneIsDefaultAndNeedsURL() {
        var flow = NewProjectFlow(serverID: serverID)
        #expect(flow.mode == .clone)
        #expect(flow.urlIssue == .empty)
        #expect(flow.nameIssue(snapshot: nil) == .empty)
        flow.editURL("https://github.com/andr81/tmuxpad.git")
        #expect(flow.urlIssue == nil)
        #expect(flow.name == "tmuxpad")
        #expect(flow.canCreate(snapshot: snapshot(projects: ["api"])))
    }

    @Test func emptyFolderNeedsNoURL() {
        var flow = NewProjectFlow(serverID: serverID)
        flow.selectMode(.empty)
        flow.editName("scratch")
        #expect(flow.urlIssue == nil)
        #expect(flow.canCreate(snapshot: nil))
    }

    @Test func nameFollowsURLUntilEdited() {
        var flow = NewProjectFlow(serverID: serverID)
        flow.editURL("git@github.com:a/first.git")
        #expect(flow.name == "first")
        flow.editName("mine")
        flow.editURL("git@github.com:a/second.git")
        #expect(flow.name == "mine")
        // стёртое имя снова берётся из адреса
        flow.editName("")
        flow.editURL("git@github.com:a/third.git")
        #expect(flow.name == "third")
    }

    @Test func pastedURLIsTrimmed() {
        var flow = NewProjectFlow(serverID: serverID)
        flow.editURL("  https://example.com/a/b.git\n")
        #expect(flow.url == "https://example.com/a/b.git")
        #expect(flow.urlIssue == nil)
    }

    @Test func badURLsAreFlagged() {
        var flow = NewProjectFlow(serverID: serverID)
        for url in ["file:///srv/a.git", "/srv/a.git", "https://u:secret@example.com/a.git", "https://ghp_token@github.com/a/b.git", "ext::sh"] {
            flow.editURL(url)
            #expect(flow.urlIssue == .invalid, "\(url)")
        }
    }

    @Test func nameIssues() {
        var flow = NewProjectFlow(serverID: serverID)
        flow.selectMode(.empty)
        flow.editName(".hidden")
        #expect(flow.nameIssue(snapshot: nil) == .invalid)
        flow.editName("my app")
        #expect(flow.name == "my-app")
        #expect(flow.nameIssue(snapshot: nil) == nil)
        flow.editName("api")
        #expect(flow.nameIssue(snapshot: snapshot(projects: ["api"])) == .exists)
        #expect(!flow.canCreate(snapshot: snapshot(projects: ["api"])))
    }

    /// Сервер сказал «уже есть» про имя, которого нет в снимке (файл, папка с точкой).
    @Test func existsOutcomeMarksNameTaken() {
        var flow = NewProjectFlow(serverID: serverID)
        flow.selectMode(.empty)
        flow.editName("README.md")
        flow.apply(.exists, of: flow)
        #expect(flow.nameIssue(snapshot: snapshot(projects: [])) == .exists)
        flow.editName("other")
        #expect(flow.nameIssue(snapshot: snapshot(projects: [])) == nil)
    }

    @Test func invalidOutcomeClearsOnEdit() {
        var flow = NewProjectFlow(serverID: serverID)
        flow.editURL("https://example.com/a/b.git")
        flow.apply(.invalid("git not found"), of: flow)
        #expect(flow.serverIssue == "git not found")
        #expect(!flow.canCreate(snapshot: nil))
        flow.editURL("https://example.com/a/c.git")
        #expect(flow.serverIssue == nil)
    }

    @Test func staleOutcomeIgnored() {
        var flow = NewProjectFlow(serverID: serverID)
        flow.selectMode(.empty)
        flow.editName("one")
        let request = flow
        flow.editName("two")
        flow.apply(.exists, of: request)
        flow.editName("one")
        #expect(flow.nameIssue(snapshot: nil) == nil)
    }

    /// Сервер удалили, пока мастер был открыт.
    @Test func createWithoutServerFails() async throws {
        let env = try AppEnvironment.inMemory()
        var flow = NewProjectFlow(serverID: serverID)
        flow.selectMode(.empty)
        flow.editName("scratch")
        #expect(await flow.create(using: env.actions) == .failed("Сервер удалён"))
    }

    /// Без подтверждённого отпечатка ни `mkproject`, ни `clone` к серверу не идут (§8).
    @Test func createRefusesUnconfirmedServer() async throws {
        let env = try AppEnvironment.inMemory()
        let server = ServerConfig(label: "s", host: "127.0.0.1", port: 1, user: "u", keyID: UUID())
        try env.servers.add(server)
        var flow = NewProjectFlow(serverID: server.id)
        flow.editURL("https://example.com/a/b.git")
        #expect(await flow.create(using: env.actions) == .failed(userText(AppError.hostKeyUnconfirmed)))
    }

    @Test func nameFooter() {
        #expect(NewProjectStep.footer(issue: .exists, name: "api", serverIssue: nil) == "Проект api уже есть")
        #expect(NewProjectStep.footer(issue: nil, name: "x", serverIssue: "git not found") == "git not found")
        #expect(NewProjectStep.footer(issue: .empty, name: "", serverIssue: nil) == nil)
        #expect(NewProjectStep.footer(issue: .invalid, name: ".x", serverIssue: nil)?.contains("128") == true)
    }
}
