import Foundation
import Testing
@testable import TmuxPadCore

@Suite(.serialized, .enabled(if: Bench.isAvailable))
struct HostBootstrapIntegrationTests {
    /// Сброс стенда и чистый сервер без скрипта.
    private func withoutScript(_ body: @escaping @Sendable (any SSHConnection, HostAPI) async throws -> Void) async throws {
        try await Bench.withReset { connection in
            let removed = try await connection.exec("rm -f ~/.local/bin/tmuxpad-host.sh")
            #expect(removed.exitCode == 0)
            try await body(connection, Bench.api(connection))
        }
    }

    @Test func missingThenInstalled() async throws {
        try await withoutScript { connection, api in
            let bootstrap = try HostBootstrap()
            #expect(await bootstrap.status(api: api) == .missing)
            try await bootstrap.install(api: api)
            let check = try await connection.exec("test -x ~/.local/bin/tmuxpad-host.sh")
            #expect(check.exitCode == 0)
            #expect(await bootstrap.status(api: api) == .ready(version: 1))
        }
    }

    @Test func outdatedVersion() async throws {
        try await withoutScript { connection, api in
            let bootstrap = try HostBootstrap()
            try await bootstrap.install(api: api)
            let sed = try await connection.exec("sed -i 's/^VERSION=1/VERSION=0/' ~/.local/bin/tmuxpad-host.sh")
            #expect(sed.exitCode == 0)
            #expect(await bootstrap.status(api: api) == .outdated(installed: 0, bundled: 1))
        }
    }

    @Test func prepareReinstallsAndRunsSetup() async throws {
        try await withoutScript { connection, api in
            let bootstrap = try HostBootstrap()
            try await bootstrap.install(api: api)
            _ = try await connection.exec("sed -i 's/^VERSION=1/VERSION=0/' ~/.local/bin/tmuxpad-host.sh")
            let report = try await bootstrap.prepare(api: api)
            #expect(await bootstrap.status(api: api) == .ready(version: 1))
            #expect(report.ok)
            for key in ["tmux", "projects", "script"] {
                #expect(report.lines.first { $0.key == key }?.level == .ok, "\(key): \(report.lines)")
            }
            let conf = try await connection.exec("cat ~/.tmux.conf").stdoutText
            #expect(conf.contains("# tmuxpad: begin"))
        }
    }
}
