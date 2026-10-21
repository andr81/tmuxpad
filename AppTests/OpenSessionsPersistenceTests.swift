import Foundation
import Testing
import TmuxPadCore
@testable import TmuxPad

@MainActor
struct OpenSessionsPersistenceTests {
    let defaults = UserDefaults(suiteName: "dev.tmuxpad.test.\(UUID().uuidString)")!
    let server = UUID()
    let other = UUID()

    private var persistence: OpenSessionsPersistence {
        OpenSessionsPersistence(defaults: defaults)
    }

    private func key(_ name: String, server: UUID? = nil) -> OpenSessionKey {
        OpenSessionKey(serverID: server ?? self.server, name: name)
    }

    /// Модель, которая пишет каждое изменение, как в приложении.
    private func savingModel() -> OpenSessionsModel {
        let model = OpenSessionsModel()
        let persistence = persistence
        model.onRosterChange = { persistence.save(roster: $0, selection: $1) }
        return model
    }

    @Test func emptyDefaultsLoadNothing() {
        let loaded = persistence.load(knownServers: [server])
        #expect(loaded.tabs.isEmpty)
        #expect(loaded.selection == nil)
    }

    @Test func everyChangeIsSaved() {
        let model = savingModel()
        model.open(key("api"))
        model.open(key("web"))
        #expect(persistence.load(knownServers: [server]).tabs == [key("api"), key("web")])
        #expect(persistence.load(knownServers: [server]).selection == key("web"))

        model.select(index: 1)
        #expect(persistence.load(knownServers: [server]).selection == key("api"))

        model.close(key("api"))
        let loaded = persistence.load(knownServers: [server])
        #expect(loaded.tabs == [key("web")])
        #expect(loaded.selection == key("web"))

        model.close(key("web"))
        #expect(persistence.load(knownServers: [server]).tabs.isEmpty)
        #expect(persistence.load(knownServers: [server]).selection == nil)
    }

    @Test func unknownServersAreDropped() {
        let model = savingModel()
        model.open(key("api"))
        model.open(key("db", server: other))
        let loaded = persistence.load(knownServers: [server])
        #expect(loaded.tabs == [key("api")])
        // выделение было на удалённом сервере
        #expect(loaded.selection == nil)
    }

    @Test func restoreKeepsTabOrderAndSelection() {
        let saved = savingModel()
        saved.open(key("api"))
        saved.open(key("web"))
        saved.open(key("db", server: other))
        saved.select(index: 2)

        let restored = OpenSessionsModel()
        persistence.restore(into: restored, knownServers: [server, other])
        #expect(restored.roster.tabs == [key("api"), key("web"), key("db", server: other)])
        #expect(restored.selection == key("web"))
    }

    @Test func restoreKeepsRecency() {
        let saved = savingModel()
        saved.open(key("api"))
        saved.open(key("web"))
        saved.open(key("db"))
        saved.select(index: 1)
        saved.select(index: 2)

        let restored = OpenSessionsModel()
        persistence.restore(into: restored, knownServers: [server])
        #expect(restored.roster == saved.roster)
        // закрытие выделенной отдаёт выделение последней активированной до неё, а не последней вкладке
        restored.close(key("web"))
        #expect(restored.selection == key("api"))
    }

    @Test func restoreWithoutSelectionKeepsLastOpened() {
        let saved = savingModel()
        saved.open(key("api"))
        saved.open(key("db", server: other))

        let restored = OpenSessionsModel()
        persistence.restore(into: restored, knownServers: [server])
        #expect(restored.roster.tabs == [key("api")])
        #expect(restored.selection == key("api"))
    }

    @Test func corruptDataLoadsNothing() {
        defaults.set(Data("not json".utf8), forKey: OpenSessionsPersistence.rosterKey)
        defaults.set(Data("{}".utf8), forKey: OpenSessionsPersistence.selectionKey)
        let restored = OpenSessionsModel()
        persistence.restore(into: restored, knownServers: [server])
        #expect(restored.roster.tabs.isEmpty)
        #expect(restored.selection == nil)
    }
}
