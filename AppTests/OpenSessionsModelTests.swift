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
}
