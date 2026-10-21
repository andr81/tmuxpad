import Foundation
import Observation
import TmuxPadCore

/// Дерево сайдбара: состояния серверов из `TreeRefresher` ядра и узлы проектов для `List`.
@MainActor
@Observable
final class TreeModel {
    static let showEmptyProjectsKey = "sidebar.showEmptyProjects"

    /// Только серверы из последнего `setServers`.
    private(set) var states: [UUID: ServerTreeState] = [:]
    /// «Показывать все проекты» (§3.1), хранится в `defaults`.
    var showEmptyProjects: Bool {
        didSet { defaults.set(showEmptyProjects, forKey: Self.showEmptyProjectsKey) }
    }

    @ObservationIgnored let refresher: TreeRefresher
    @ObservationIgnored private let openSessions: OpenSessionsModel
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var serverIDs: Set<UUID> = []
    @ObservationIgnored private var subscription: Task<Void, Never>?
    /// `setServers`, `start` и `stop` уходят в актор по порядку вызова: отдельные `Task`
    /// могли бы переставить их местами.
    @ObservationIgnored private var queue: Task<Void, Never>?

    init(refresher: TreeRefresher, openSessions: OpenSessionsModel, defaults: UserDefaults) {
        self.refresher = refresher
        self.openSessions = openSessions
        self.defaults = defaults
        showEmptyProjects = defaults.bool(forKey: Self.showEmptyProjectsKey)
        subscription = Task { [weak self, refresher] in
            for await (id, state) in await refresher.updates() {
                guard let self else { return }
                self.receive(id, state)
            }
        }
    }

    deinit {
        subscription?.cancel()
    }

    /// Новый список серверов из `ServerStore`. Удалённые пропадают из `states` сразу, их
    /// открытые сессии закрываются.
    @discardableResult
    func setServers(_ configs: [ServerConfig]) -> Task<Void, Never> {
        let ids = Set(configs.map(\.id))
        for id in serverIDs.subtracting(ids) {
            states[id] = nil
            openSessions.close(serverID: id)
        }
        serverIDs = ids
        return enqueue { await $0.setServers(configs) }
    }

    /// Опрос раз в интервал, пока сцена активна.
    @discardableResult
    func start() -> Task<Void, Never> {
        enqueue { await $0.start() }
    }

    @discardableResult
    func stop() -> Task<Void, Never> {
        enqueue { await $0.stop() }
    }

    /// Один сервер или все (`nil`). `force` — pull-to-refresh и «Повторить»: переподключение
    /// без бэкоффа; после действий (new, kill) — без него.
    func refresh(serverID: UUID? = nil, force: Bool = false) async {
        await queue?.value
        await refresher.refresh(serverID, force: force)
    }

    /// После «Подготовить» в проверке сервера: перечитать версию скрипта и список.
    func markPrepared(_ serverID: UUID) async {
        await queue?.value
        await refresher.markPrepared(serverID)
    }

    /// Проекты сервера из последнего снимка; без снимка — пусто.
    func nodes(for serverID: UUID) -> [ProjectNode] {
        guard let snapshot = states[serverID]?.snapshot else {
            return []
        }
        return SessionTree.build(
            snapshot: snapshot,
            openSessions: openSessions.openNames(serverID: serverID),
            showEmptyProjects: showEmptyProjects
        )
    }

    /// Обновление удалённого сервера, пришедшее после `setServers`, не возвращает его.
    private func receive(_ id: UUID, _ state: ServerTreeState) {
        guard serverIDs.contains(id) else {
            return
        }
        states[id] = state
    }

    private func enqueue(_ operation: @escaping @Sendable (TreeRefresher) async -> Void) -> Task<Void, Never> {
        let previous = queue
        let refresher = refresher
        let task = Task {
            await previous?.value
            await operation(refresher)
        }
        queue = task
        return task
    }
}
