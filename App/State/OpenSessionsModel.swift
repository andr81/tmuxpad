import Foundation
import Observation
import TmuxPadCore

/// Открытые в приложении сессии, их терминалы и выделенная (§5). Вытесненные ростером сверх
/// лимита закрываются (`detach`).
@MainActor
@Observable
final class OpenSessionsModel {
    private(set) var roster: OpenSessionsRoster
    /// Сессия в детали.
    private(set) var selection: OpenSessionKey?
    private(set) var terminals: [OpenSessionKey: OpenTerminal] = [:]
    /// Терминал новой открытой сессии; ставит `AppEnvironment`. Без фабрики — только ростер.
    @ObservationIgnored var makeTerminal: ((OpenSessionKey) -> OpenTerminal)?

    init(limit: Int = OpenSessionsRoster.defaultLimit) {
        roster = OpenSessionsRoster(limit: limit)
    }

    /// Открывает (или активирует открытую) и выделяет. Сверх лимита самые давно неактивные
    /// закрываются. `take` — «Забрать» (§6.1): у открытой — `take()`, у новой — открытие через `take`.
    func open(_ key: OpenSessionKey, take: Bool = false) {
        for evicted in roster.open(key) {
            terminals.removeValue(forKey: evicted)?.close()
        }
        selection = key
        if let terminal = terminals[key] {
            terminal.activate()
            if take {
                Task { await terminal.take() }
            }
        } else if let terminal = makeTerminal?(key) {
            terminals[key] = terminal
            terminal.start(take: take)
        }
    }

    /// Выделение переходит к последней активированной из оставшихся.
    func close(_ key: OpenSessionKey) {
        roster.close(key)
        terminals.removeValue(forKey: key)?.close()
        if selection == key {
            selection = roster.active
        }
    }

    /// Сервер удалили — закрываются все его сессии.
    func close(serverID: UUID) {
        roster.close(serverID: serverID)
        for key in terminals.keys where key.serverID == serverID {
            terminals.removeValue(forKey: key)?.close()
        }
        if selection?.serverID == serverID {
            selection = roster.active
        }
    }

    /// `⌘1…⌘9`; `index` 1-based.
    func select(index: Int) {
        if let key = roster.tab(at: index) {
            activate(key)
        }
    }

    /// `⌘]`, по кругу.
    func selectNext() {
        if let key = selection.flatMap(roster.next(after:)) ?? roster.tabs.first {
            activate(key)
        }
    }

    /// `⌘[`, по кругу.
    func selectPrevious() {
        if let key = selection.flatMap(roster.previous(before:)) ?? roster.tabs.last {
            activate(key)
        }
    }

    var selectedTerminal: OpenTerminal? {
        selection.flatMap { terminals[$0] }
    }

    private func activate(_ key: OpenSessionKey) {
        roster.activate(key)
        selection = key
        terminals[key]?.activate()
    }

    func isOpen(_ key: OpenSessionKey) -> Bool {
        roster.tabs.contains(key)
    }

    /// Имена открытых сессий сервера — `●` в дереве.
    func openNames(serverID: UUID) -> Set<String> {
        Set(roster.tabs.filter { $0.serverID == serverID }.map(\.name))
    }
}
