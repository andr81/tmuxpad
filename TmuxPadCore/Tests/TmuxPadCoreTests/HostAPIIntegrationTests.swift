import Foundation
import Testing
@testable import TmuxPadCore

@Suite(.serialized, .enabled(if: Bench.isAvailable))
struct HostAPIIntegrationTests {
    /// Сброс стенда, скрипт из ресурса через `HostBootstrap`.
    private func withAPI(_ body: @escaping @Sendable (any SSHConnection, HostAPI) async throws -> Void) async throws {
        try await Bench.withReset { connection in
            let api = Bench.api(connection)
            _ = try await HostBootstrap().prepare(api: api)
            try await body(connection, api)
        }
    }

    @Test func listEmpty() async throws {
        try await withAPI { _, api in
            let snapshot = try await api.list()
            #expect(snapshot.sessions.isEmpty)
            #expect(Set(snapshot.projects.map(\.name)) == ["api", "web", "my.app"])
            #expect(snapshot.projects.allSatisfy { $0.path.hasSuffix("/projects/\($0.name)") })
        }
    }

    @Test func newListKill() async throws {
        try await withAPI { _, api in
            try await api.new(session: "api", project: "api")
            let snapshot = try await api.list()
            let session = try #require(snapshot.sessions.first { $0.name == "api" })
            #expect(snapshot.sessions.count == 1)
            #expect(session.project == "api")
            #expect(session.otherClients == 0)
            #expect(abs(session.lastActivity.timeIntervalSinceNow) < 60)

            try await api.kill(session: "api")
            #expect(try await api.list().sessions.isEmpty)
        }
    }

    @Test func newConflict() async throws {
        try await withAPI { _, api in
            try await api.new(session: "api", project: "api")
            await #expect(throws: HostError.sessionExists) {
                try await api.new(session: "api", project: "web")
            }
        }
    }

    @Test func badNames() async throws {
        try await withAPI { _, api in
            await #expect(throws: HostError.self) {
                try await api.new(session: "a b", project: "api")
            }
            await #expect(throws: HostError.self) {
                try await api.new(session: "ok", project: "../etc")
            }
        }
    }

    @Test func othersCountsForeignClient() async throws {
        try await withAPI { _, api in
            try await api.new(session: "api", project: "api")
            let client = try Bench.foreignClient("tmux attach -t =api")
            defer { client.terminate() }
            let seen = try await Bench.eventually {
                try await api.list().sessions.first { $0.name == "api" }?.otherClients == 1
            }
            #expect(seen)
        }
    }

    @Test func projectsRootMissing() async throws {
        try await withAPI { connection, _ in
            let api = Bench.api(connection, projectsRoot: "nope")
            await #expect(throws: HostError.projectsRootMissing) {
                try await api.list()
            }
        }
    }

    @Test func copyCancelIdempotent() async throws {
        try await withAPI { _, api in
            try await api.copyCancel(session: "ghost")
            try await api.new(session: "api", project: "api")
            try await api.copyCancel(session: "api")
            try await api.copyCancel(session: "api")
        }
    }

    @Test func authStoresToken() async throws {
        try await withAPI { connection, api in
            try await api.auth(token: "tok_1")
            let env = try await connection.exec("cat ~/.tmuxpad/env").stdoutText
            #expect(env.contains("tok_1"))
            let mode = try await connection.exec("stat -c %a ~/.tmuxpad/env").stdoutText
            #expect(mode == "600\n")
        }
    }
}
