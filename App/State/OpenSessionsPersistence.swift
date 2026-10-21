import Foundation
import TmuxPadCore

/// Открытые сессии между запусками (§11 фаза 5): ростер и выделение в `UserDefaults`,
/// переписываются при каждом изменении ростера.
@MainActor
struct OpenSessionsPersistence {
    static let rosterKey = "openSessions.roster"
    static let selectionKey = "openSessions.selection"

    let defaults: UserDefaults

    func save(roster: OpenSessionsRoster, selection: OpenSessionKey?) {
        let encoder = JSONEncoder()
        defaults.set(try? encoder.encode(roster), forKey: Self.rosterKey)
        defaults.set(selection.flatMap { try? encoder.encode($0) }, forKey: Self.selectionKey)
    }

    /// Сохранённые вкладки серверов из `knownServers` в порядке `tabs` и выделение среди них.
    /// Нечитаемые данные — как пустые: открытые сессии не стоят ошибки запуска.
    func load(knownServers: Set<UUID>) -> (tabs: [OpenSessionKey], selection: OpenSessionKey?) {
        let decoder = JSONDecoder()
        guard let data = defaults.data(forKey: Self.rosterKey),
              let roster = try? decoder.decode(OpenSessionsRoster.self, from: data) else {
            return ([], nil)
        }
        let tabs = roster.tabs.filter { knownServers.contains($0.serverID) }
        let selection = defaults.data(forKey: Self.selectionKey)
            .flatMap { try? decoder.decode(OpenSessionKey.self, from: $0) }
            .flatMap { tabs.contains($0) ? $0 : nil }
        return (tabs, selection)
    }

    /// Открывает сохранённые через `model.open` без `take` (§6.1: молча, независимо от
    /// `others`); исчезнувшие на сервере ядро переведёт в `.ended`. Выделение — последним.
    func restore(into model: OpenSessionsModel, knownServers: Set<UUID>) {
        let (tabs, selection) = load(knownServers: knownServers)
        for key in tabs {
            model.open(key)
        }
        if let selection {
            model.open(selection)
        }
    }
}
