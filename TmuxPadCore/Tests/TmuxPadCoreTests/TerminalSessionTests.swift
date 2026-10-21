import Foundation
import Testing
@testable import TmuxPadCore

struct TerminalSessionTests {
    static let listWithApi = "V\t1\nS\tapi\t0\tapi\t1700000000\nP\tapi\t/home/dev/projects/api\n"
    static let listEmpty = "V\t1\nP\tapi\t/home/dev/projects/api\n"

    /// Подключённый сервер на фейке и терминал `api` на нём.
    static func make(
        _ transport: FakeTransport = FakeTransport(),
        kickWindow: Duration = .seconds(60)
    ) async throws -> (ServerConnection, TerminalSession, RecordingSurface) {
        let server = try ServerConnectionTests.make(transport)
        try await server.connect()
        let surface = RecordingSurface(cols: 100, rows: 30)
        let session = TerminalSession(server: server, name: "api", surface: surface, kickWindow: kickWindow)
        return (server, session, surface)
    }

    /// Ждёт `count`-й открытый PTY последнего соединения.
    static func pty(_ transport: FakeTransport, _ count: Int = 1) async throws -> FakePTY {
        #expect(try await Bench.eventually(.seconds(3)) { (transport.lastConnection?.openedPTYs.count ?? 0) >= count })
        return try #require(transport.lastConnection?.openedPTYs[count - 1])
    }

    @Test func startFeedsOutput() async throws {
        let transport = FakeTransport()
        let (server, session, surface) = try await Self.make(transport)
        await session.start()
        let pty = try await Self.pty(transport)
        #expect(surface.states == [.connecting, .live])
        #expect(pty.command == (try await server.api.attachCommand(session: "api")))
        #expect(pty.command.contains("tmuxpad-host.sh attach 'api'"))
        #expect(pty.resizes.first! == (100, 30))
        #expect(pty.environment["LANG"] == "en_US.UTF-8")
        pty.emit(Data("hello".utf8))
        pty.emit(Data(" world".utf8))
        #expect(try await Bench.eventually { surface.text == "hello world" })
    }

    @Test func copyCancelBeforeInput() async throws {
        let transport = FakeTransport()
        let (_, session, _) = try await Self.make(transport)
        await session.start()
        let pty = try await Self.pty(transport)
        let connection = try #require(transport.lastConnection)
        connection.execDelay = .milliseconds(50)
        await session.noteScrolledUp()
        try await session.send(Data("x".utf8))
        try await session.send(Data("y".utf8))
        let journal = connection.journal.filter { !$0.hasPrefix("exec true") }
        #expect(journal.count == 3)
        #expect(journal[0].contains("tmuxpad-host.sh copy-cancel 'api'"))
        #expect(Array(journal.dropFirst()) == ["pty x", "pty y"])
        #expect(pty.sent == [Data("x".utf8), Data("y".utf8)])
    }

    @Test func inputOrderKeptWhileCopyCancelRuns() async throws {
        let transport = FakeTransport()
        let (_, session, _) = try await Self.make(transport)
        await session.start()
        let pty = try await Self.pty(transport)
        transport.lastConnection?.execDelay = .milliseconds(100)
        await session.noteScrolledUp()
        // второй send приходит, пока первый ждёт copy-cancel
        async let first: Void = session.send(Data("a".utf8))
        try await Task.sleep(for: .milliseconds(20))
        try await session.send(Data("b".utf8))
        try await first
        #expect(pty.sent == [Data("a".utf8), Data("b".utf8)])
    }

    static let wheelUp = Data("\u{1B}[<64;10;5M".utf8)
    static let wheelDown = Data("\u{1B}[<65;10;5M".utf8)

    static func copyCancels(_ transport: FakeTransport) -> Int {
        transport.lastConnection?.execCalls.filter { $0.command.contains("copy-cancel") }.count ?? 0
    }

    @Test func wheelGoesPastCopyCancel() async throws {
        let transport = FakeTransport()
        let (_, session, surface) = try await Self.make(transport)
        await session.start()
        let pty = try await Self.pty(transport)
        try await session.input(Self.wheelUp)
        try await session.input(Self.wheelUp)
        try await session.input(Self.wheelDown)
        #expect(Self.copyCancels(transport) == 0)
        #expect(surface.copyModeCalls == [true])
        try await session.input(Data("x".utf8))
        let journal = try #require(transport.lastConnection).journal.filter { !$0.hasPrefix("exec true") }
        #expect(journal.count == 5)
        #expect(journal[3].contains("tmuxpad-host.sh copy-cancel 'api'"))
        #expect(journal[4] == "pty x")
        #expect(Self.copyCancels(transport) == 1)
        #expect(surface.copyModeCalls == [true, false])
        #expect(pty.sent == [Self.wheelUp, Self.wheelUp, Self.wheelDown, Data("x".utf8)])
    }

    @Test func otherMouseKeepsFlagDown() async throws {
        let transport = FakeTransport()
        let (_, session, surface) = try await Self.make(transport)
        await session.start()
        _ = try await Self.pty(transport)
        try await session.input(Data("\u{1B}[<0;3;4M\u{1B}[<0;3;4m".utf8))
        try await session.input(Data("x".utf8))
        #expect(Self.copyCancels(transport) == 0)
        #expect(surface.copyModeCalls.isEmpty)
    }

    @Test func cancelCopyModeOnlyWhenSuspected() async throws {
        let transport = FakeTransport()
        let (_, session, surface) = try await Self.make(transport)
        await session.start()
        let pty = try await Self.pty(transport)
        await session.cancelCopyMode()
        #expect(Self.copyCancels(transport) == 0)
        try await session.input(Self.wheelUp)
        await session.cancelCopyMode()
        #expect(Self.copyCancels(transport) == 1)
        #expect(surface.copyModeCalls == [true, false])
        await session.cancelCopyMode()
        try await session.input(Data("x".utf8))
        #expect(Self.copyCancels(transport) == 1)
        #expect(pty.sent == [Self.wheelUp, Data("x".utf8)])
    }

    @Test func mixedInputKeepsOrder() async throws {
        let transport = FakeTransport()
        let (_, session, _) = try await Self.make(transport)
        await session.start()
        let pty = try await Self.pty(transport)
        try await session.input(Self.wheelUp)
        transport.lastConnection?.execDelay = .milliseconds(100)
        // колесо приходит, пока клавиатура ждёт copy-cancel
        async let first: Void = session.input(Data("a".utf8))
        try await Task.sleep(for: .milliseconds(20))
        try await session.input(Self.wheelDown)
        try await first
        #expect(pty.sent == [Self.wheelUp, Data("a".utf8), Self.wheelDown])
    }

    @Test func reconnectKeepsCopyModeFlag() async throws {
        let transport = FakeTransport()
        let (_, session, surface) = try await Self.make(transport)
        await session.start()
        _ = try await Self.pty(transport)
        try await session.input(Self.wheelUp)
        await session.reconnect()
        let second = try await Self.pty(transport, 2)
        try await session.input(Data("x".utf8))
        #expect(Self.copyCancels(transport) == 1)
        #expect(second.sent == [Data("x".utf8)])
        #expect(surface.copyModeCalls == [true, false])
    }

    @Test func takeKeepsCopyModeFlag() async throws {
        let transport = FakeTransport()
        let (_, session, surface) = try await Self.make(transport)
        await session.start()
        _ = try await Self.pty(transport)
        try await session.input(Self.wheelUp)
        await session.take()
        let second = try await Self.pty(transport, 2)
        try await session.input(Data("x".utf8))
        let journal = try #require(transport.lastConnection).journal.filter { !$0.hasPrefix("exec true") }
        #expect(journal.suffix(2).first?.contains("copy-cancel") == true)
        #expect(journal.last == "pty x")
        #expect(second.sent == [Data("x".utf8)])
        #expect(surface.copyModeCalls == [true, false])
    }

    @Test func failedCopyCancelKeepsFlag() async throws {
        let transport = FakeTransport()
        let (_, session, surface) = try await Self.make(transport)
        await session.start()
        _ = try await Self.pty(transport)
        try await session.input(Self.wheelUp)
        let connection = try #require(transport.lastConnection)
        connection.respond(when: { $0.contains("copy-cancel") }, with: .failure(SSHError.disconnected))
        await session.cancelCopyMode()
        #expect(Self.copyCancels(transport) == 1)
        #expect(surface.copyModeCalls == [true, false, true])
        await session.reconnect()
        let second = try await Self.pty(transport, 2)
        try await session.input(Data("x".utf8))
        #expect(Self.copyCancels(transport) == 2)
        #expect(second.sent == [Data("x".utf8)])
        #expect(surface.copyModeCalls == [true, false, true, false])
    }

    @Test func detachClearsCopyModeFlag() async throws {
        let transport = FakeTransport()
        let (_, session, surface) = try await Self.make(transport)
        await session.start()
        _ = try await Self.pty(transport)
        try await session.input(Self.wheelUp)
        await session.detach()
        #expect(surface.copyModeCalls == [true, false])
    }

    @Test func resizeForwards() async throws {
        let transport = FakeTransport()
        let (_, session, _) = try await Self.make(transport)
        await session.start()
        let pty = try await Self.pty(transport)
        try await session.resize(cols: 132, rows: 43)
        #expect(pty.resizes.last! == (132, 43))
    }

    @Test func detachEnds() async throws {
        let transport = FakeTransport()
        let (_, session, surface) = try await Self.make(transport)
        await session.start()
        let pty = try await Self.pty(transport)
        await session.detach()
        #expect(pty.isClosed)
        #expect(surface.states == [.connecting, .live, .ended])
        try await Task.sleep(for: .milliseconds(100))
        #expect(!(transport.lastConnection?.execCalls.contains { $0.command.contains(" list") } ?? true))
        #expect(surface.states.last == .ended)
        await #expect(throws: SSHError.disconnected) { try await session.send(Data("x".utf8)) }
    }

    @Test func endedWhenSessionGone() async throws {
        let transport = FakeTransport()
        let (_, session, surface) = try await Self.make(transport)
        await session.start()
        let pty = try await Self.pty(transport)
        transport.lastConnection?.respond(containing: " list", stdout: Self.listEmpty)
        pty.close(exitCode: 0)
        #expect(try await surface.waitFor(.ended))
        #expect(transport.lastConnection?.openedPTYs.count == 1)
    }

    @Test func noSessionExitEnds() async throws {
        let transport = FakeTransport()
        let (_, session, surface) = try await Self.make(transport)
        await session.start()
        try await Self.pty(transport).close(exitCode: 4)
        #expect(try await surface.waitFor(.ended))
    }

    @Test func failedAttachOfLiveSessionIsOffline() async throws {
        let transport = FakeTransport()
        let (_, session, surface) = try await Self.make(transport)
        await session.start()
        transport.lastConnection?.respond(containing: " list", stdout: Self.listWithApi)
        try await Self.pty(transport).close(exitCode: 1)
        #expect(try await Bench.eventually { if case .offline = surface.states.last { true } else { false } })
        #expect(transport.lastConnection?.openedPTYs.count == 1)
    }

    @Test func failedAttachOfKilledSessionEnds() async throws {
        let transport = FakeTransport()
        let (_, session, surface) = try await Self.make(transport)
        await session.start()
        transport.lastConnection?.respond(containing: " list", stdout: Self.listEmpty)
        try await Self.pty(transport).close(exitCode: 1)
        #expect(try await surface.waitFor(.ended))
    }

    @Test func kickedOnceReconnectsSilently() async throws {
        let transport = FakeTransport()
        let (_, session, surface) = try await Self.make(transport)
        await session.start()
        let first = try await Self.pty(transport)
        transport.lastConnection?.respond(containing: " list", stdout: Self.listWithApi)
        first.close(exitCode: 0)
        let second = try await Self.pty(transport, 2)
        #expect(second.command.contains("tmuxpad-host.sh attach 'api'"))
        #expect(try await surface.waitFor(.live))
        #expect(surface.states == [.connecting, .live, .reconnecting, .live])
        #expect(await session.state == .live)
    }

    @Test func kickedTwiceWithinMinute() async throws {
        let transport = FakeTransport()
        let (_, session, surface) = try await Self.make(transport, kickWindow: .milliseconds(500))
        await session.start()
        transport.lastConnection?.respond(containing: " list", stdout: Self.listWithApi)
        transport.lastConnection?.respond(containing: " list", stdout: Self.listWithApi)
        try await Self.pty(transport).close(exitCode: 0)
        let second = try await Self.pty(transport, 2)
        #expect(try await surface.waitFor(.live))
        second.close(exitCode: 0)
        #expect(try await surface.waitFor(.disconnectedByOther))
        #expect(transport.lastConnection?.openedPTYs.count == 2)
        #expect(!surface.states.contains(.ended))
    }

    @Test func kickAfterWindowIsSilentAgain() async throws {
        let transport = FakeTransport()
        let (_, session, surface) = try await Self.make(transport, kickWindow: .milliseconds(100))
        await session.start()
        for _ in 0..<2 {
            transport.lastConnection?.respond(containing: " list", stdout: Self.listWithApi)
        }
        try await Self.pty(transport).close(exitCode: 0)
        let second = try await Self.pty(transport, 2)
        try await Task.sleep(for: .milliseconds(200))
        second.close(exitCode: 0)
        _ = try await Self.pty(transport, 3)
        #expect(try await surface.waitFor(.live))
        #expect(!surface.states.contains(.disconnectedByOther))
    }

    @Test func takeUsesTakeCommand() async throws {
        let transport = FakeTransport()
        let (_, session, surface) = try await Self.make(transport)
        await session.start()
        let first = try await Self.pty(transport)
        await session.take()
        let second = try await Self.pty(transport, 2)
        #expect(first.isClosed)
        #expect(second.command.contains("tmuxpad-host.sh take 'api'"))
        #expect(surface.states == [.connecting, .live, .reconnecting, .live])
        // закрытие старого канала не считается выбиванием
        try await Task.sleep(for: .milliseconds(100))
        #expect(!(transport.lastConnection?.execCalls.contains { $0.command.contains(" list") } ?? true))
    }

    @Test func offlineThenReconnect() async throws {
        let transport = FakeTransport()
        let (server, session, surface) = try await Self.make(transport)
        await session.start()
        _ = try await Self.pty(transport)
        let dropped = try #require(transport.lastConnection)
        transport.failNextConnects(1)
        transport.dropConnection()
        // пока пул в бэкоффе — «Переподключение…», а не офлайн (§3.5)
        #expect(try await Bench.eventually { surface.states.contains(.reconnecting) })
        #expect(try await Bench.eventually { transport.connections.count == 2 })
        #expect(transport.connectAttempts == 3)
        let fresh = try #require(transport.lastConnection)
        #expect(fresh !== dropped)
        #expect(try await Bench.eventually { fresh.openedPTYs.count == 1 })
        #expect(try await surface.waitFor(.live))
        #expect(await server.state.isConnected)
        #expect(fresh.openedPTYs[0].command.contains("attach 'api'"))
    }

    @Test func failedPoolAfterDropIsOfflineUntilReconnect() async throws {
        let transport = FakeTransport()
        let (server, session, surface) = try await Self.make(transport)
        await session.start()
        _ = try await Self.pty(transport)
        transport.failNextConnects(10)
        transport.dropConnection()
        #expect(try await Bench.eventually { if case .offline = surface.states.last { true } else { false } })
        // офлайн — только когда пул сдался, до того «Переподключение…»
        #expect(surface.states.dropLast() == [.connecting, .live, .reconnecting])
        guard case .failed = await server.state else {
            Issue.record("expected failed pool")
            return
        }
        transport.failNextConnects(0)
        await server.reconnectNow()
        #expect(try await surface.waitFor(.live))
        #expect(transport.lastConnection?.openedPTYs.count == 1)
    }

    @Test func disconnectedPoolAfterDropIsOffline() async throws {
        let transport = FakeTransport()
        let (server, session, surface) = try await Self.make(transport)
        await session.start()
        _ = try await Self.pty(transport)
        // так заканчивается соединение, которое пул заменил: само оно не переподключится
        await server.disconnect()
        #expect(try await Bench.eventually { if case .offline = surface.states.last { true } else { false } })
        try await server.connect()
        #expect(try await surface.waitFor(.live))
    }

    @Test func refusedChannelIsOfflineWithoutRetry() async throws {
        let transport = FakeTransport()
        let server = try ServerConnectionTests.make(transport, settings: PoolSettings(keepalive: .seconds(60), ptySlots: 0))
        try await server.connect()
        let surface = RecordingSurface()
        let session = TerminalSession(server: server, name: "api", surface: surface)
        await session.start()
        #expect(surface.states == [.connecting, .offline(String(describing: SSHError.channelRefused))])
    }

    @Test func detachDuringKickCheckWins() async throws {
        let transport = FakeTransport()
        let (_, session, surface) = try await Self.make(transport)
        await session.start()
        let pty = try await Self.pty(transport)
        let connection = try #require(transport.lastConnection)
        connection.execDelay = .milliseconds(150)
        connection.respond(containing: " list", stdout: Self.listWithApi)
        pty.close(exitCode: 0)
        #expect(try await Bench.eventually { connection.execCalls.contains { $0.command.contains(" list") } })
        await session.detach()
        try await Task.sleep(for: .milliseconds(300))
        #expect(surface.states.last == .ended)
        #expect(connection.openedPTYs.count == 1)
    }
}
