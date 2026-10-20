import Foundation
import Testing
@testable import TmuxPadCore

@Suite struct HostAPITests {
    let env = HostEnvironment(
        client: UUID(uuidString: "0F8E4C2A-1B3D-4E5F-9A7B-6C5D4E3F2A10")!,
        projectsRoot: "projects",
        startCommand: "claude"
    )

    private func api(_ connection: FakeConnection, log: DiagnosticsLog? = nil) -> HostAPI {
        HostAPI(runner: connection, environment: env, log: log, server: "fake")
    }

    @Test func listRendersAndParses() async throws {
        let connection = FakeConnection()
        connection.respond(containing: " list", stdout: "V\t1\nS\tapi\t1\tapi\t1700000000\nP\tapi\t/home/dev/projects/api\n")
        let snapshot = try await api(connection).list()
        #expect(connection.execCalls.map(\.command) == [
            #"env TMUXPAD_CLIENT='0f8e4c2a-1b3d-4e5f-9a7b-6c5d4e3f2a10' TMUXPAD_PROJECTS='projects' TMUXPAD_CMD='claude' "$HOME"/.local/bin/tmuxpad-host.sh list"#,
        ])
        #expect(snapshot.sessions == [RemoteSession(name: "api", project: "api", otherClients: 1, lastActivity: Date(timeIntervalSince1970: 1_700_000_000))])
        #expect(snapshot.projects == [RemoteProject(name: "api", path: "/home/dev/projects/api")])
    }

    @Test func newConflict() async throws {
        let connection = FakeConnection()
        connection.respond(containing: " new ", exitCode: 3, stderr: "session exists\n")
        await #expect(throws: HostError.sessionExists) {
            try await api(connection).new(session: "api", project: "api")
        }
    }

    @Test func scriptMissing() async throws {
        let connection = FakeConnection()
        connection.respond(containing: " version", exitCode: 127, stderr: "env: no such file\n")
        await #expect(throws: HostError.scriptMissing) {
            try await api(connection).version()
        }
    }

    @Test func versionParses() async throws {
        let connection = FakeConnection()
        connection.respond(containing: " version", stdout: "tmuxpad-host 7\n")
        #expect(try await api(connection).version() == 7)
        connection.respond(containing: " version", stdout: "something else\n")
        await #expect(throws: HostError.badOutput("bad version: something else")) {
            try await api(connection).version()
        }
    }

    @Test func badNamesNeverReachServer() async throws {
        let connection = FakeConnection()
        await #expect(throws: HostError.badRequest("invalid session name: a b")) {
            try await api(connection).new(session: "a b", project: "api")
        }
        #expect(connection.execCalls.isEmpty)
    }

    @Test func authValidatesLocallyAndUsesStdin() async throws {
        let connection = FakeConnection()
        await #expect(throws: HostError.badRequest("invalid token")) {
            try await api(connection).auth(token: "tok en")
        }
        await #expect(throws: HostError.badRequest("invalid token")) {
            try await api(connection).auth(token: "")
        }
        #expect(connection.execCalls.isEmpty)

        try await api(connection).auth(token: "tok_1-A")
        let call = try #require(connection.execCalls.first)
        #expect(call.command.hasSuffix("tmuxpad-host.sh auth"))
        #expect(!call.command.contains("tok_1-A"))
        #expect(call.stdin == Data("tok_1-A\n".utf8))
    }

    @Test func setupWithFailIsReportNotError() async throws {
        let connection = FakeConnection()
        connection.respond(containing: " setup", exitCode: 1, stdout: "ok\ttmux\ttmux 3.4\nfail\tclaude\tclaude not found\n")
        let report = try await api(connection).setup()
        #expect(!report.ok)
        #expect(report.lines.map(\.key) == ["tmux", "claude"])
    }

    @Test func doctorWithoutReportIsError() async throws {
        let connection = FakeConnection()
        connection.respond(containing: " doctor", exitCode: 1, stderr: "boom\n")
        await #expect(throws: HostError.failed(code: 1, stderr: "boom")) {
            try await api(connection).doctor()
        }
        connection.respond(containing: " doctor", exitCode: 2, stderr: "bad env\n")
        await #expect(throws: HostError.badRequest("bad env")) {
            try await api(connection).doctor()
        }
    }

    @Test func stderrIsTruncated() async throws {
        let connection = FakeConnection()
        connection.respond(containing: " kill", exitCode: 1, stderr: String(repeating: "x", count: 2000))
        await #expect(throws: HostError.failed(code: 1, stderr: String(repeating: "x", count: HostAPI.stderrLimit))) {
            try await api(connection).kill(session: "api")
        }
    }

    @Test func transportErrorPassesThrough() async throws {
        let connection = FakeConnection()
        connection.disconnect()
        await #expect(throws: SSHError.disconnected) {
            try await api(connection).list()
        }
    }

    @Test func journalHasNoEnvironmentValues() async throws {
        let connection = FakeConnection()
        let log = DiagnosticsLog()
        try await api(connection, log: log).copyCancel(session: "api")
        let events = await log.events()
        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(event.kind == .exec)
        #expect(event.server == "fake")
        #expect(event.message.hasPrefix("copy-cancel api exit 0"))
        #expect(!event.message.contains("0f8e4c2a"))
    }

    @Test func ptyCommands() throws {
        let api = api(FakeConnection())
        #expect(try api.attachCommand(session: "api").hasSuffix("tmuxpad-host.sh attach 'api'"))
        #expect(try api.takeCommand(session: "api").hasSuffix("tmuxpad-host.sh take 'api'"))
    }

    @Test func bootstrapStatus() async throws {
        let bootstrap = try HostBootstrap(script: Data("#!/bin/bash\nVERSION=2\n".utf8))
        let connection = FakeConnection()
        let api = api(connection)
        connection.respond(containing: " version", exitCode: 127)
        #expect(await bootstrap.status(api: api) == .missing)
        connection.respond(containing: " version", stdout: "tmuxpad-host 1\n")
        #expect(await bootstrap.status(api: api) == .outdated(installed: 1, bundled: 2))
        connection.respond(containing: " version", stdout: "tmuxpad-host 2\n")
        #expect(await bootstrap.status(api: api) == .ready(version: 2))
        connection.disconnect()
        #expect(await bootstrap.status(api: api) == .unreachable("\(SSHError.disconnected)"))
    }

    @Test func bootstrapInstallSendsScript() async throws {
        let script = Data("#!/bin/bash\nVERSION=2\n".utf8)
        let bootstrap = try HostBootstrap(script: script)
        let connection = FakeConnection()
        connection.respond(containing: " version", stdout: "tmuxpad-host 2\n")
        try await bootstrap.install(api: api(connection))
        let install = try #require(connection.execCalls.first)
        #expect(install.command == HostCommand.installCommand)
        #expect(install.stdin == script)
    }
}
