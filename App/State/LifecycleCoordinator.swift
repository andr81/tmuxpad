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

/// Face ID выключен или тесты без него: всегда открыто.
struct NoKeyUnlock: KeyUnlocking {
    func authenticate() async throws {}
    func lock() async {}
}

/// Единственное место, которое реагирует на `scenePhase` и смену сети (§6). Уход в фон —
/// соединения закрываются через `closeDelay`, возврат раньше ничего не рвёт; возврат после
/// разрыва — `reconnectAll`, терминалы переоткрывают `attach` сами (ядро). С Face ID (§8)
/// запуск и возврат из фона сначала ждут `authenticate()`; отказ оставляет соединения и опрос
/// дерева выключенными до `unlock()` («Повторить» у терминала) или `keyUnlocked()`. Опрос дерева в фоне
/// останавливается сразу: его тик после `lock()` спрашивал бы Face ID.
@MainActor
final class LifecycleCoordinator {
    static let logServer = "app"

    private let targets: any LifecycleTargets
    private let unlocker: any KeyUnlocking
    private let backgroundTasks: any BackgroundTasks
    private let log: DiagnosticsLog
    private let closeDelay: Duration
    /// Соединения закрыты уходом в фон; сбрасывается возвратом в `.active`.
    private(set) var closed = false
    /// Между `.background` и следующим `.active`.
    private var inBackground = false
    /// Face ID отклонён: отложенное действие возврата ждёт `unlock()`; `true` — с переподключением.
    private(set) var locked: Bool?
    /// До первого `.active` и после ухода в фон ключ снова закрыт.
    private var needsUnlock = true
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
        unlocker: any KeyUnlocking = NoKeyUnlock(),
        backgroundTasks: any BackgroundTasks = SystemBackgroundTasks(),
        closeDelay: Duration = .seconds(25)
    ) {
        self.targets = targets
        self.log = log
        self.unlocker = unlocker
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

    /// Сеть сменилась (`NetworkMonitor`): рвутся и живые соединения. В фоне соединения
    /// закрываются сразу, не дожидаясь `closeDelay`, — возврат переподключит; после отказа
    /// Face ID событие игнорируется — переподключит `unlock()`.
    @discardableResult
    func networkChanged(_ description: String) -> Task<Void, Never>? {
        if inBackground {
            record("network changed: \(description), in background")
            closeConnections()
            return nil
        }
        guard locked == nil else {
            record("network changed: \(description), ignored until key unlock")
            return nil
        }
        record("network changed: \(description)")
        // `locked` читается и в очереди: шаг `becomeActive` впереди мог ждать Face ID и получить отказ
        return enqueue { [weak self] targets in
            guard let self, locked == nil else {
                return
            }
            await targets.reconnectAll(force: true)
            await targets.refreshTree()
        }
    }

    /// Face ID пройден вне `unlock()` (открытие сессии, обновление дерева, мастер): отложенное
    /// действие возврата выполняется так же. Очередь не ждёт: вызов может прийти из её шага.
    @discardableResult
    func keyUnlocked() -> Task<Void, Never>? {
        guard locked != nil else {
            return nil
        }
        return enqueue { [weak self] targets in
            guard let self, let reconnect = locked else {
                return
            }
            locked = nil
            await Self.resume(targets, reconnect: reconnect)
        }
    }

    /// Face ID и отложенное действие возврата, если его отклонили раньше. `false` — снова отказ.
    func unlock() async -> Bool {
        do {
            try await unlocker.authenticate()
        } catch {
            record("key unlock denied")
            return false
        }
        // `locked` читается в очереди: шаг `becomeActive`, ждавший тот же запрос, мог уже
        // всё поднять — второй `resume` переподключил бы дважды
        await enqueue { [weak self] targets in
            guard let self, let reconnect = locked else {
                return
            }
            locked = nil
            await Self.resume(targets, reconnect: reconnect)
        }.value
        return true
    }

    private func enterBackground() {
        needsUnlock = true
        inBackground = true
        let unlocker = unlocker
        enqueue { targets in
            targets.stopTree()
            await unlocker.lock()
        }
        guard !closed, closeTimer == nil else {
            return
        }
        // по истечении задачу нужно закончить сразу, не дожидаясь `disconnectAll`; живая задача
        // всегда текущая: `becomeActive` заканчивает её, новая начинается только без неё
        backgroundTask = backgroundTasks.begin { [weak self] in
            self?.closeConnections()
            self?.endBackgroundTask(self?.backgroundTask ?? .invalid)
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
        closeTimer?.cancel()
        closeTimer = nil
        // в `.active` фоновая задача не нужна, даже если `disconnectAll` ещё в очереди: иначе
        // следующий уход в фон начал бы свою поверх незаконченной
        endBackgroundTask(backgroundTask)
        inBackground = false
        let reconnect = closed || locked == true
        if closed {
            closed = false
            record("foreground reconnect")
        }
        let unlock = needsUnlock
        needsUnlock = false
        let unlocker = unlocker
        return enqueue { [weak self] targets in
            // отказ раньше: дерево без ключа спрашивало бы Face ID на каждом тике
            guard let self, locked == nil || unlock else {
                return
            }
            if unlock {
                do {
                    try await unlocker.authenticate()
                } catch {
                    locked = reconnect
                    record("key unlock denied")
                    return
                }
                locked = nil
            }
            await Self.resume(targets, reconnect: reconnect)
        }
    }

    private static func resume(_ targets: any LifecycleTargets, reconnect: Bool) async {
        guard reconnect else {
            targets.startTree()
            return
        }
        await targets.reconnectAll(force: false)
        targets.startTree()
        await targets.refreshTree()
    }

    private func closeConnections() {
        closeTimer?.cancel()
        closeTimer = nil
        guard !closed else {
            return
        }
        closed = true
        record("background close")
        // новый уход в фон до конца `disconnectAll` начинает свою задачу: её не заканчиваем
        let task = backgroundTask
        // опрос дерева уже остановил `enterBackground`
        enqueue { [weak self] targets in
            await targets.disconnectAll()
            self?.endBackgroundTask(task)
        }
    }

    /// Заканчивает `id`, только если это всё ещё текущая задача.
    private func endBackgroundTask(_ id: UIBackgroundTaskIdentifier) {
        guard id != .invalid, id == backgroundTask else {
            return
        }
        backgroundTasks.end(id)
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
