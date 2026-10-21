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
    /// Открытые терминалы без сессии (восстановленные до Face ID, упавшие на отказе) пробуют снова.
    func startTerminals()
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
/// соединения закрываются через `closeDelay`, возврат раньше ничего не рвёт, но повторяет
/// сдавшиеся (`reconnectAll(force: false)`); возврат после разрыва — `reconnectAll`, терминалы переоткрывают `attach` сами (ядро). С Face ID (§8)
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
    /// Face ID отклонён: отложенное действие возврата ждёт `unlock()` или `keyUnlocked()`.
    private(set) var locked = false
    /// Соединения закрыты уходом в фон или упали на отказе Face ID (реконнект пула ждёт ключ в
    /// `reconnectGate` и после отказа уходит в `.failed`): следующий подъём зовёт `reconnectAll`.
    private var needsReconnect = false
    /// Возврат из фона без разрыва: соединения, которые пул бросил в `.failed` (сдался за время
    /// фона или раньше), пробуют снова (§6); живые `reconnectAll(force: false)` не трогает.
    private var needsRetry = false
    /// До первого `.active` и после ухода в фон ключ снова закрыт.
    private var needsUnlock = true
    /// Растёт на каждый уход в фон: шаг очереди, поставленный до него, ничего не поднимает.
    private var generation = 0
    /// Первый `.active` после запуска — восстановление открытых сессий; ставит `AppEnvironment.live()`.
    var onLaunch: (@MainActor () -> Void)?
    private var launched = false
    private var closeTimer: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// Подъём соединений и дерева идёт по порядку вызова: переподключения, начатые отдельными
    /// `Task`, могли бы переставиться. Закрытие в фоне идёт мимо очереди — медленный реконнект
    /// впереди не должен его задерживать.
    private var queue: Task<Void, Never>?
    /// `lock()` ухода в фон: запрос Face ID после возврата ждёт его.
    private var lockTask: Task<Void, Never>?
    /// `disconnectAll` ухода в фон: переподключение ждёт его.
    private var disconnectTask: Task<Void, Never>?

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
        guard !locked else {
            record("network changed: \(description), ignored until key unlock")
            return nil
        }
        record("network changed: \(description)")
        // `locked` читается и в очереди: шаг `becomeActive` впереди мог ждать Face ID и получить отказ
        return enqueue { [weak self] targets, current in
            guard let self, isCurrent(current), !locked else {
                return
            }
            await disconnectTask?.value
            // ушли в фон, пока ждали закрытия: переподключит возврат
            guard isCurrent(current) else {
                needsReconnect = true
                return
            }
            await targets.reconnectAll(force: true)
            guard await settled(current) else {
                return
            }
            await targets.refreshTree()
        }
    }

    /// Face ID пройден вне `unlock()` (открытие сессии, обновление дерева, мастер): отложенное
    /// действие возврата выполняется так же. Очередь не ждёт: вызов может прийти из её шага.
    @discardableResult
    func keyUnlocked() -> Task<Void, Never>? {
        guard locked, !inBackground else {
            return nil
        }
        return enqueueResume()
    }

    /// Face ID и отложенное действие возврата, если его отклонили раньше. `false` — снова отказ.
    func unlock() async -> Bool {
        await lockTask?.value
        do {
            try await unlocker.authenticate()
        } catch {
            record("key unlock denied")
            return false
        }
        guard !inBackground else {
            return true
        }
        // `locked` читается в очереди: шаг `becomeActive`, ждавший тот же запрос, мог уже
        // всё поднять — второй `resume` переподключил бы дважды
        await enqueueResume().value
        return true
    }

    private func enqueueResume() -> Task<Void, Never> {
        enqueue { [weak self] targets, current in
            guard let self, isCurrent(current), locked else {
                return
            }
            locked = false
            await resume(targets, current)
        }
    }

    private func enterBackground() {
        needsUnlock = true
        needsRetry = true
        inBackground = true
        generation += 1
        // мимо очереди: шаг впереди может ждать сеть, а ключ и опрос дерева закрываются сразу
        targets.stopTree()
        let unlocker = unlocker
        let previousLock = lockTask
        lockTask = Task {
            await previousLock?.value
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
        // в `.active` фоновая задача не нужна, даже если `disconnectAll` ещё идёт: иначе
        // следующий уход в фон начал бы свою поверх незаконченной
        endBackgroundTask(backgroundTask)
        inBackground = false
        if closed {
            closed = false
            record("foreground reconnect")
        }
        let unlock = needsUnlock
        needsUnlock = false
        let unlocker = unlocker
        return enqueue { [weak self] targets, current in
            // отказ раньше: дерево без ключа спрашивало бы Face ID на каждом тике
            guard let self, isCurrent(current), !locked || unlock else {
                return
            }
            if unlock {
                await lockTask?.value
                do {
                    try await unlocker.authenticate()
                } catch {
                    // запрос прервал новый уход в фон: возврат спросит снова
                    guard isCurrent(current) else {
                        return
                    }
                    locked = true
                    needsReconnect = true
                    record("key unlock denied")
                    return
                }
                guard isCurrent(current) else {
                    return
                }
                locked = false
            }
            await resume(targets, current)
        }
    }

    private func resume(_ targets: any LifecycleTargets, _ current: Int) async {
        let reconnect = needsReconnect
        if reconnect || needsRetry {
            // сбрасывается до вызова: закрытие в фоне во время реконнекта ставит его снова
            needsReconnect = false
            needsRetry = false
            await disconnectTask?.value
            // ушли в фон, пока ждали закрытия: ключ уже закрыт, переподключит следующий возврат
            guard isCurrent(current) else {
                needsReconnect = true
                return
            }
            await targets.reconnectAll(force: false)
            guard await settled(current) else {
                return
            }
        }
        targets.startTerminals()
        targets.startTree()
        if reconnect {
            await targets.refreshTree()
        }
    }

    /// Шаг очереди поставлен в текущем `.active`, ухода в фон после него не было.
    private func isCurrent(_ current: Int) -> Bool {
        current == generation && !inBackground
    }

    /// После реконнекта: если тем временем ушли в фон и соединения уже закрыли, `disconnectAll`
    /// мог пройти раньше реконнекта — закрываем снова. `false` — шаг дальше не идёт.
    private func settled(_ current: Int) async -> Bool {
        if isCurrent(current) {
            return true
        }
        if closed {
            await targets.disconnectAll()
        }
        return false
    }

    private func closeConnections() {
        closeTimer?.cancel()
        closeTimer = nil
        guard !closed else {
            return
        }
        closed = true
        needsReconnect = true
        record("background close")
        // новый уход в фон до конца `disconnectAll` начинает свою задачу: её не заканчиваем
        let task = backgroundTask
        let targets = targets
        let previous = disconnectTask
        // опрос дерева уже остановил `enterBackground`; мимо очереди — см. `queue`
        disconnectTask = Task { [weak self] in
            await previous?.value
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
    private func enqueue(_ operation: @escaping @MainActor (any LifecycleTargets, Int) async -> Void) -> Task<Void, Never> {
        let previous = queue
        let targets = targets
        let current = generation
        let task = Task {
            await previous?.value
            await operation(targets, current)
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
    private let openSessions: OpenSessionsModel

    init(pool: ConnectionPool, tree: TreeModel, openSessions: OpenSessionsModel) {
        self.pool = pool
        self.tree = tree
        self.openSessions = openSessions
    }

    func startTerminals() {
        openSessions.startIdle()
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
