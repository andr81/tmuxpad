import Foundation
import SwiftUI
import TmuxPadCore
import UIKit

/// То, что координатор жизненного цикла делает с пулом и деревом. В приложении —
/// `AppLifecycleTargets`, в тестах — запись вызовов.
@MainActor
protocol LifecycleTargets: AnyObject {
    func disconnectAll() async
    func reconnectAll(force: Bool) async
    func startTree()
    func stopTree()
    func refreshTree() async
}

/// Фоновая задача iPadOS: время на закрытие соединений после ухода в фон.
@MainActor
protocol BackgroundTasks {
    func begin(expiration: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier
    func end(_ id: UIBackgroundTaskIdentifier)
}

struct SystemBackgroundTasks: BackgroundTasks {
    func begin(expiration: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier {
        UIApplication.shared.beginBackgroundTask(withName: "tmuxpad.close") {
            MainActor.assumeIsolated { expiration() }
        }
    }

    func end(_ id: UIBackgroundTaskIdentifier) {
        UIApplication.shared.endBackgroundTask(id)
    }
}

/// Единственное место, которое реагирует на `scenePhase` и смену сети (§6). Уход в фон —
/// соединения закрываются через `closeDelay`, возврат раньше ничего не рвёт; возврат после
/// разрыва — `reconnectAll`, терминалы переоткрывают `attach` сами (ядро).
@MainActor
final class LifecycleCoordinator {
    static let logServer = "app"

    private let targets: any LifecycleTargets
    private let backgroundTasks: any BackgroundTasks
    private let log: DiagnosticsLog
    private let closeDelay: Duration
    /// Соединения закрыты уходом в фон; сбрасывается возвратом в `.active`.
    private(set) var closed = false
    /// Первый `.active` после запуска — восстановление открытых сессий; ставит `AppEnvironment.live()`.
    var onLaunch: (@MainActor () -> Void)?
    private var launched = false
    private var closeTimer: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// Действия над пулом и деревом идут по порядку вызова: закрытие и переподключение,
    /// начатые отдельными `Task`, могли бы переставиться.
    private var queue: Task<Void, Never>?

    init(
        targets: any LifecycleTargets,
        log: DiagnosticsLog,
        backgroundTasks: any BackgroundTasks = SystemBackgroundTasks(),
        closeDelay: Duration = .seconds(25)
    ) {
        self.targets = targets
        self.log = log
        self.backgroundTasks = backgroundTasks
        self.closeDelay = closeDelay
    }

    /// Новая `scenePhase` от `RootView`. Возвращает задачу действий для тестов.
    @discardableResult
    func scenePhaseChanged(_ phase: ScenePhase) -> Task<Void, Never>? {
        switch phase {
        case .inactive:
            return nil
        case .background:
            enterBackground()
            return nil
        case .active:
            return becomeActive()
        @unknown default:
            return nil
        }
    }

    /// Сеть сменилась (`NetworkMonitor`): рвутся и живые соединения. Пока соединения закрыты
    /// фоном, событие игнорируется — возврат и так переподключит.
    @discardableResult
    func networkChanged(_ description: String) -> Task<Void, Never>? {
        guard !closed else {
            record("network changed: \(description), ignored in background")
            return nil
        }
        record("network changed: \(description)")
        return enqueue { targets in
            await targets.reconnectAll(force: true)
            await targets.refreshTree()
        }
    }

    private func enterBackground() {
        guard !closed, closeTimer == nil else {
            return
        }
        // по истечении задачу нужно закончить сразу, не дожидаясь `disconnectAll`
        backgroundTask = backgroundTasks.begin { [weak self] in
            self?.closeConnections()
            self?.endBackgroundTask()
        }
        let delay = closeDelay
        closeTimer = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else {
                return
            }
            self?.closeConnections()
        }
    }

    private func becomeActive() -> Task<Void, Never> {
        if !launched {
            launched = true
            onLaunch?()
        }
        if let closeTimer {
            closeTimer.cancel()
            self.closeTimer = nil
            endBackgroundTask()
        }
        guard closed else {
            return enqueue { $0.startTree() }
        }
        closed = false
        record("foreground reconnect")
        return enqueue { targets in
            await targets.reconnectAll(force: false)
            targets.startTree()
            await targets.refreshTree()
        }
    }

    private func closeConnections() {
        closeTimer?.cancel()
        closeTimer = nil
        guard !closed else {
            return
        }
        closed = true
        record("background close")
        enqueue { [weak self] targets in
            targets.stopTree()
            await targets.disconnectAll()
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else {
            return
        }
        backgroundTasks.end(backgroundTask)
        backgroundTask = .invalid
    }

    @discardableResult
    private func enqueue(_ operation: @escaping @MainActor (any LifecycleTargets) async -> Void) -> Task<Void, Never> {
        let previous = queue
        let targets = targets
        let task = Task {
            await previous?.value
            await operation(targets)
        }
        queue = task
        return task
    }

    private func record(_ message: String) {
        let log = log
        Task { await log.record(server: Self.logServer, kind: .reconnect, message) }
    }
}

/// Адаптер координатора над пулом и деревом приложения.
@MainActor
final class AppLifecycleTargets: LifecycleTargets {
    private let pool: ConnectionPool
    private let tree: TreeModel

    init(pool: ConnectionPool, tree: TreeModel) {
        self.pool = pool
        self.tree = tree
    }

    func disconnectAll() async {
        await pool.disconnectAll()
    }

    func reconnectAll(force: Bool) async {
        await pool.reconnectAll(force: force)
    }

    func startTree() {
        tree.start()
    }

    func stopTree() {
        tree.stop()
    }

    func refreshTree() async {
        await tree.refresh()
    }
}
