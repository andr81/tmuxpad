import Foundation
import Testing
import TmuxPadCore
@testable import TmuxPad

@MainActor
struct OpenSessionsModelTests {
    let server = UUID()

    private func key(_ name: String, server: UUID? = nil) -> OpenSessionKey {
        OpenSessionKey(serverID: server ?? self.server, name: name)
    }

    @Test func openSelectsAndMarksOpen() {
        let model = OpenSessionsModel()
        model.open(key("api"))
        #expect(model.selection == key("api"))
        #expect(model.isOpen(key("api")))
        #expect(!model.isOpen(key("web")))
    }

    @Test func ninthEvictsLeastRecentlyActive() {
        let model = OpenSessionsModel()
        for index in 1...8 {
            model.open(key("s\(index)"))
        }
        // `s1` активирована заново — вытесняется следующая по давности
        model.open(key("s1"))
        model.open(key("s9"))
        #expect(model.roster.tabs.count == 8)
        #expect(!model.isOpen(key("s2")))
        #expect(model.isOpen(key("s1")))
        #expect(model.selection == key("s9"))
    }

    @Test func openNamesPerServer() {
        let other = UUID()
        let model = OpenSessionsModel()
        model.open(key("api"))
        model.open(key("web"))
        model.open(key("api", server: other))
        #expect(model.openNames(serverID: server) == ["api", "web"])
        #expect(model.openNames(serverID: other) == ["api"])
        #expect(model.openNames(serverID: UUID()).isEmpty)
    }

    @Test func closeMovesSelectionToMostRecent() {
        let model = OpenSessionsModel()
        model.open(key("api"))
        model.open(key("web"))
        model.open(key("cli"))
        model.open(key("web"))
        model.close(key("web"))
        #expect(model.selection == key("cli"))
        model.close(key("api"))
        #expect(model.selection == key("cli"))
        model.close(key("cli"))
        #expect(model.selection == nil)
    }

    @Test func closeServerDropsItsSessions() {
        let other = UUID()
        let model = OpenSessionsModel()
        model.open(key("api", server: other))
        model.open(key("api"))
        model.close(serverID: server)
        #expect(model.roster.tabs == [key("api", server: other)])
        #expect(model.selection == key("api", server: other))
    }

    /// Терминалы без сети: соединения нет, сессия так и не создаётся.
    private func modelWithTerminals() -> OpenSessionsModel {
        let model = OpenSessionsModel()
        let defaults = UserDefaults(suiteName: "dev.tmuxpad.test.\(UUID().uuidString)")!
        let dependencies = OpenTerminal.Dependencies(
            connection: { _ in throw AppError.serverMissing },
            snapshot: { _ in nil },
            log: nil,
            appearance: TerminalAppearance(defaults: defaults)
        )
        model.makeTerminal = { OpenTerminal(key: $0, dependencies: dependencies) }
        return model
    }

    @Test func ninthClosesEvictedTerminal() throws {
        let model = modelWithTerminals()
        for index in 1...8 {
            model.open(key("s\(index)"))
        }
        let evicted = try #require(model.terminals[key("s1")])
        let kept = try #require(model.terminals[key("s2")])
        model.open(key("s9"))
        #expect(evicted.isClosed)
        #expect(!kept.isClosed)
        #expect(model.terminals[key("s1")] == nil)
        #expect(model.terminals.count == 8)
        #expect(model.selectedTerminal?.key == key("s9"))
    }

    @Test func evictionOnOtherServerDoesNotDelayStart() async throws {
        let other = UUID()
        let hung = server
        // соединения первого сервера висят: `close()` его вытесненного терминала не кончается
        let (released, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        let model = OpenSessionsModel()
        let defaults = UserDefaults(suiteName: "dev.tmuxpad.test.\(UUID().uuidString)")!
        let dependencies = OpenTerminal.Dependencies(
            connection: { id in
                if id == hung {
                    for await _ in released {}
                }
                throw AppError.serverMissing
            },
            snapshot: { _ in nil },
            log: nil,
            appearance: TerminalAppearance(defaults: defaults)
        )
        model.makeTerminal = { OpenTerminal(key: $0, dependencies: dependencies) }
        for index in 1...8 {
            model.open(key("s\(index)"))
        }
        model.open(key("api", server: other))
        #expect(model.terminals[key("s1")] == nil)
        let terminal = try #require(model.terminals[key("api", server: other)])
        try await waitUntil { terminal.state != .connecting }
        #expect(terminal.state == .offline(userText(AppError.serverMissing)))
    }

    /// Закрытый терминал ещё не освободил PTY-слот: новый на том же сервере ждёт его `detach`.
    @Test func openWaitsForPendingCloseOnSameServer() async throws {
        let (released, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        let calls = Counter()
        let model = OpenSessionsModel()
        let defaults = UserDefaults(suiteName: "dev.tmuxpad.test.\(UUID().uuidString)")!
        let dependencies = OpenTerminal.Dependencies(
            connection: { _ in
                // первое подключение (терминал `api`) висит: его `close()` не кончается
                if calls.next() == 1 {
                    for await _ in released {}
                }
                throw AppError.serverMissing
            },
            snapshot: { _ in nil },
            log: nil,
            appearance: TerminalAppearance(defaults: defaults)
        )
        model.makeTerminal = { OpenTerminal(key: $0, dependencies: dependencies) }
        model.open(key("api"))
        model.close(key("api"))
        model.open(key("web"))
        let web = try #require(model.terminals[key("web")])
        try await Task.sleep(for: .milliseconds(200))
        #expect(web.state == .connecting)
        release.finish()
        try await waitUntil { web.state != .connecting }
        #expect(web.state == .offline(userText(AppError.serverMissing)))
    }

    @Test func reopenKeepsTerminal() {
        let model = modelWithTerminals()
        model.open(key("api"))
        let terminal = model.terminals[key("api")]
        model.open(key("web"))
        model.open(key("api"))
        #expect(model.terminals[key("api")] === terminal)
        #expect(model.terminals.count == 2)
    }

    @Test func closeClosesTerminal() {
        let other = UUID()
        let model = modelWithTerminals()
        model.open(key("api"))
        model.open(key("web"))
        model.open(key("api", server: other))
        let api = model.terminals[key("api")]
        let web = model.terminals[key("web")]
        model.close(key("api"))
        #expect(api?.isClosed == true)
        model.close(serverID: server)
        #expect(web?.isClosed == true)
        #expect(Array(model.terminals.keys) == [key("api", server: other)])
    }

    @Test func noConnectionIsOffline() async throws {
        let model = modelWithTerminals()
        model.open(key("api"))
        let terminal = try #require(model.terminals[key("api")])
        try await waitUntil { terminal.state != .connecting }
        #expect(terminal.state == .offline(userText(AppError.serverMissing)))
    }

    @Test func selectByIndexAndCycle() {
        let model = OpenSessionsModel()
        model.open(key("a"))
        model.open(key("b"))
        model.open(key("c"))
        model.select(index: 1)
        #expect(model.selection == key("a"))
        model.select(index: 9)
        #expect(model.selection == key("a"))
        model.selectPrevious()
        #expect(model.selection == key("c"))
        model.selectNext()
        #expect(model.selection == key("a"))
        model.selectNext()
        model.selectNext()
        #expect(model.selection == key("c"))
        // выбор — активация: вытесняется не она
        for index in 1...5 {
            model.open(key("n\(index)"))
        }
        model.select(index: 1)
        model.open(key("n6"))
        #expect(model.isOpen(key("a")))
        #expect(!model.isOpen(key("b")))
    }
}

/// Номер вызова, с 1.
@MainActor
private final class Counter {
    private var value = 0

    func next() -> Int {
        value += 1
        return value
    }
}
