import Foundation
import Testing
@testable import TmuxPadCore

@Suite(.serialized, .enabled(if: Bench.isAvailable))
struct TerminalIntegrationTests {
    /// `ServerConnection` к стенду; в pane `api` — интерактивный `bash`.
    static func server(deviceID: UUID = Bench.deviceID) throws -> ServerConnection {
        let config = ServerConfig(label: "bench", host: Bench.endpoint.host, port: Bench.endpoint.port, user: Bench.user, keyID: UUID(), startCommand: "bash")
        return ServerConnection(
            config: config,
            deviceID: deviceID,
            transport: CitadelTransport(),
            auth: try Bench.auth(),
            hostKeys: InMemoryHostKeyStore(),
            settings: PoolSettings(keepalive: .seconds(30), connectTimeout: .seconds(10))
        )
    }

    /// Сброс стенда, скрипт из ресурса, сессия `api`; `raw` — отдельное соединение для `tmux`.
    private func withSession(_ body: @escaping @Sendable (_ raw: any SSHConnection, _ server: ServerConnection) async throws -> Void) async throws {
        try await Bench.withReset { raw in
            let server = try Self.server()
            try await server.connect()
            do {
                _ = try await HostBootstrap().prepare(api: server.api)
                try await server.api.new(session: "api", project: "api")
                try await body(raw, server)
            } catch {
                await server.disconnect()
                throw error
            }
            await server.disconnect()
        }
    }

    static func clients(_ raw: any SSHConnection) async throws -> [String] {
        try await Bench.tmux(raw, "list-clients -t =api -F '#{client_pid}'").split(separator: "\n").map(String.init)
    }

    static func capture(_ raw: any SSHConnection) async throws -> String {
        try await Bench.tmux(raw, "capture-pane -p -t =api:")
    }

    @Test func attachShowsTmux() async throws {
        try await withSession { raw, server in
            let surface = RecordingSurface()
            let session = TerminalSession(server: server, name: "api", surface: surface)
            await session.start()
            #expect(await session.state == .live)
            #expect(try await Bench.eventually { !surface.output.isEmpty })
            #expect(try await Bench.eventually { try await Self.clients(raw).count == 1 })
            let files = try await raw.exec("cat ~/.tmuxpad/clients/*").stdoutText
            #expect(files.contains(Bench.deviceID.uuidString.lowercased()))
            await session.detach()
        }
    }

    @Test func typingReachesPane() async throws {
        try await withSession { raw, server in
            let surface = RecordingSurface()
            let session = TerminalSession(server: server, name: "api", surface: surface)
            await session.start()
            try await session.send(Data("echo hello-from-pty\n".utf8))
            #expect(try await Bench.eventually { try await Self.capture(raw).contains("hello-from-pty") })
            #expect(try await Bench.eventually { surface.text.contains("hello-from-pty") })
            await session.detach()
        }
    }

    @Test func resizeChangesWindow() async throws {
        try await withSession { raw, server in
            let session = TerminalSession(server: server, name: "api", surface: RecordingSurface())
            await session.start()
            #expect(try await Bench.eventually { try await Self.clients(raw).count == 1 })
            try await session.resize(cols: 132, rows: 43)
            #expect(try await Bench.eventually {
                try await Bench.tmux(raw, "list-clients -t =api -F '#{client_width}x#{client_height}'") == "132x43\n"
            })
            await session.detach()
        }
    }

    @Test func copyCancelLeavesCopyMode() async throws {
        try await withSession { raw, server in
            let session = TerminalSession(server: server, name: "api", surface: RecordingSurface())
            await session.start()
            #expect(try await Bench.eventually { try await Self.clients(raw).count == 1 })
            try await Bench.tmux(raw, "copy-mode -t =api:")
            #expect(try await Bench.tmux(raw, "display -p -t =api: '#{pane_in_mode}'") == "1\n")
            await session.noteScrolledUp()
            try await session.send(Data("echo after\n".utf8))
            #expect(try await Bench.tmux(raw, "display -p -t =api: '#{pane_in_mode}'") == "0\n")
            #expect(try await Bench.eventually { try await Self.capture(raw).contains("after") })
            await session.detach()
        }
    }

    @Test func takeKicksOther() async throws {
        try await withSession { raw, server in
            let other = try Self.server(deviceID: UUID())
            try await other.connect()
            do {
                let mine = TerminalSession(server: server, name: "api", surface: RecordingSurface())
                let theirsSurface = RecordingSurface()
                let theirs = TerminalSession(server: other, name: "api", surface: theirsSurface)
                await mine.start()
                await theirs.start()
                #expect(try await Bench.eventually { try await Self.clients(raw).count == 2 })

                await mine.take()
                #expect(await mine.state == .live)
                // нас выбили впервые: молча обратно
                #expect(try await Bench.eventually(.seconds(10)) { theirsSurface.states.contains(.reconnecting) })
                #expect(try await theirsSurface.waitFor(.live, .seconds(10)))
                #expect(try await Bench.eventually { try await Self.clients(raw).count == 2 })

                await mine.take()
                #expect(try await theirsSurface.waitFor(.disconnectedByOther, .seconds(10)))
                #expect(try await Self.clients(raw).count == 1)
                #expect(theirsSurface.states == [.connecting, .live, .reconnecting, .live, .disconnectedByOther])
                await mine.detach()
                await theirs.detach()
            } catch {
                await other.disconnect()
                throw error
            }
            await other.disconnect()
        }
    }

    @Test func detachLeavesSessionAlive() async throws {
        try await withSession { raw, server in
            let surface = RecordingSurface()
            let session = TerminalSession(server: server, name: "api", surface: surface)
            await session.start()
            #expect(try await Bench.eventually { try await Self.clients(raw).count == 1 })
            await session.detach()
            #expect(try await Bench.eventually { try await Self.clients(raw).isEmpty })
            #expect(try await server.api.list().sessions.map(\.name) == ["api"])
            try await Task.sleep(for: .milliseconds(300))
            #expect(surface.states == [.connecting, .live, .ended])
        }
    }

    @Test func killedSessionEnds() async throws {
        try await withSession { _, server in
            let surface = RecordingSurface()
            let session = TerminalSession(server: server, name: "api", surface: surface)
            await session.start()
            try await server.api.kill(session: "api")
            let ended = try await surface.waitFor(.ended, .seconds(10))
            let journal = await server.log.export()
            #expect(ended, "\(surface.states) \(journal)")
        }
    }
}
