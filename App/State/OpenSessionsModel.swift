import Foundation
import Observation
import TmuxPadCore

/// Открытые в приложении сессии и выделенная (§5). До плана 6 терминала нет: открытие только
/// записывает сессию в ростер и выделяет её; план 6 меняет внутренности `open`/`close`.
@MainActor
@Observable
final class OpenSessionsModel {
    private(set) var roster: OpenSessionsRoster
    /// Сессия в детали.
    private(set) var selection: OpenSessionKey?

    init(limit: Int = OpenSessionsRoster.defaultLimit) {
        roster = OpenSessionsRoster(limit: limit)
    }

    /// Открывает (или активирует открытую) и выделяет. Сверх лимита самые давно неактивные
    /// выпадают из ростера. `take` — «Забрать» (§6.1); пока терминала нет, это обычное открытие.
    func open(_ key: OpenSessionKey, take: Bool = false) {
        _ = roster.open(key)
        selection = key
    }

    /// Выделение переходит к последней активированной из оставшихся.
    func close(_ key: OpenSessionKey) {
        roster.close(key)
        if selection == key {
            selection = roster.active
        }
    }

    /// Сервер удалили — закрываются все его сессии.
    func close(serverID: UUID) {
        roster.close(serverID: serverID)
        if selection?.serverID == serverID {
            selection = roster.active
        }
    }

    func isOpen(_ key: OpenSessionKey) -> Bool {
        roster.tabs.contains(key)
    }

    /// Имена открытых сессий сервера — `●` в дереве.
    func openNames(serverID: UUID) -> Set<String> {
        Set(roster.tabs.filter { $0.serverID == serverID }.map(\.name))
    }
}
