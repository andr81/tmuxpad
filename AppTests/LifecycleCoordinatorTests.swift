import Foundation
import SwiftUI
import Testing
import TmuxPadCore
import UIKit
@testable import TmuxPad

@MainActor
final class RecordingTargets: LifecycleTargets {
    enum Call: Equatable {
        case disconnectAll
        case reconnectAll(force: Bool)
        case startTree
        case stopTree
        case refreshTree
        case authenticate
        case lock
    }

    var calls: [Call] = []

    func disconnectAll() async { calls.append(.disconnectAll) }
    func reconnectAll(force: Bool) async { calls.append(.reconnectAll(force: force)) }
    func startTree() { calls.append(.startTree) }
    func stopTree() { calls.append(.stopTree) }
    func refreshTree() async { calls.append(.refreshTree) }
}

/// Face ID для координатора: вызовы пишутся в общий журнал целей.
@MainActor
final class FakeUnlocker: KeyUnlocking {
    let targets: RecordingTargets
    var granted = true

    init(targets: RecordingTargets) {
        self.targets = targets
    }

    func authenticate() async throws {
        targets.calls.append(.authenticate)
        guard granted else {
            throw AppError.biometricsDenied
        }
    }

    func lock() async {
        targets.calls.append(.lock)
    }
}

@MainActor
final class FakeBackgroundTasks: BackgroundTasks {
    var expiration: (@MainActor () -> Void)?
    var begun = 0
    var ended: [UIBackgroundTaskIdentifier] = []

    func begin(expiration: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier {
        begun += 1
        self.expiration = expiration
        return UIBackgroundTaskIdentifier(rawValue: begun)
    }

    func end(_ id: UIBackgroundTaskIdentifier) {
        ended.append(id)
    }
}

@MainActor
struct LifecycleCoordinatorTests {
    let targets = RecordingTargets()
    let tasks = FakeBackgroundTasks()
    let log = DiagnosticsLog()
    let coordinator: LifecycleCoordinator

    init() {
        coordinator = LifecycleCoordinator(targets: targets, log: log, backgroundTasks: tasks, closeDelay: .milliseconds(50))
    }

    private func messages() async throws -> [String] {
        try await Task.sleep(for: .milliseconds(20))
        return await log.events().filter { $0.kind == .reconnect }.map(\.message)
    }

    @Test func firstActiveStartsTreeOnly() async {
        await coordinator.scenePhaseChanged(.active)?.value
        #expect(targets.calls == [.startTree])
    }

    @Test func launchRunsOnceOnFirstActive() async throws {
        var launches = 0
        coordinator.onLaunch = { launches += 1 }
        coordinator.scenePhaseChanged(.inactive)
        #expect(launches == 0)
        await coordinator.scenePhaseChanged(.active)?.value
        #expect(launches == 1)
        coordinator.scenePhaseChanged(.background)
        try await waitUntil { coordinator.closed }
        await coordinator.scenePhaseChanged(.active)?.value
        #expect(launches == 1)
    }

    @Test func backgroundClosesAfterDelay() async throws {
        await coordinator.scenePhaseChanged(.active)?.value
        coordinator.scenePhaseChanged(.background)
        #expect(tasks.begun == 1)
        try await waitUntil { targets.calls.count == 3 }
        #expect(targets.calls == [.startTree, .stopTree, .disconnectAll])
        try await waitUntil { tasks.ended.count == 1 }
        #expect(coordinator.closed)
        #expect(try await messages() == ["background close"])
    }

    @Test func returnBeforeDelayTouchesNothing() async throws {
        coordinator.scenePhaseChanged(.background)
        coordinator.scenePhaseChanged(.inactive)
        await coordinator.scenePhaseChanged(.active)?.value
        try await Task.sleep(for: .milliseconds(150))
        #expect(targets.calls == [.stopTree, .startTree])
        #expect(tasks.ended.count == 1)
        #expect(!coordinator.closed)
        #expect(try await messages().isEmpty)
    }

    @Test func returnAfterDelayReconnects() async throws {
        coordinator.scenePhaseChanged(.background)
        try await waitUntil { coordinator.closed && tasks.ended.count == 1 }
        targets.calls = []
        await coordinator.scenePhaseChanged(.active)?.value
        #expect(targets.calls == [.reconnectAll(force: false), .startTree, .refreshTree])
        #expect(!coordinator.closed)
        #expect(try await messages() == ["background close", "foreground reconnect"])
    }

    @Test func expirationClosesAtOnce() async throws {
        coordinator.scenePhaseChanged(.background)
        tasks.expiration?()
        #expect(coordinator.closed)
        #expect(tasks.ended.count == 1)
        try await waitUntil { targets.calls.count == 2 }
        #expect(targets.calls == [.stopTree, .disconnectAll])
        // таймер отменён, задача не закрывается дважды
        try await Task.sleep(for: .milliseconds(150))
        #expect(targets.calls.count == 2)
        #expect(tasks.ended.count == 1)
    }

    @Test func networkChangeForcesReconnect() async throws {
        await coordinator.networkChanged("wifi → cellular")?.value
        #expect(targets.calls == [.reconnectAll(force: true), .refreshTree])
        #expect(try await messages() == ["network changed: wifi → cellular"])
    }

    @Test func networkChangeInBackgroundClosesAtOnce() async throws {
        coordinator.scenePhaseChanged(.background)
        #expect(coordinator.networkChanged("wifi → cellular") == nil)
        #expect(coordinator.closed)
        try await waitUntil { targets.calls.count == 2 && tasks.ended.count == 1 }
        #expect(targets.calls == [.stopTree, .disconnectAll])
        // таймер отменён: второго закрытия нет
        try await Task.sleep(for: .milliseconds(150))
        #expect(targets.calls.count == 2)
    }

    @Test func networkChangeIgnoredWhileClosed() async throws {
        coordinator.scenePhaseChanged(.background)
        try await waitUntil { coordinator.closed && targets.calls.count == 2 }
        #expect(coordinator.networkChanged("wifi → cellular") == nil)
        try await Task.sleep(for: .milliseconds(20))
        #expect(targets.calls == [.stopTree, .disconnectAll])
    }
}

/// Face ID в координаторе (решение 6): перед переподключением, отказ ничего не поднимает.
@MainActor
struct LifecycleUnlockTests {
    let targets = RecordingTargets()
    let unlocker: FakeUnlocker
    let tasks = FakeBackgroundTasks()
    let coordinator: LifecycleCoordinator

    init() {
        unlocker = FakeUnlocker(targets: targets)
        coordinator = LifecycleCoordinator(
            targets: targets,
            log: DiagnosticsLog(),
            unlocker: unlocker,
            backgroundTasks: tasks,
            closeDelay: .milliseconds(50)
        )
    }

    @Test func launchAsksBeforeTree() async {
        await coordinator.scenePhaseChanged(.active)?.value
        #expect(targets.calls == [.authenticate, .startTree])
        // шторка и сам запрос Face ID: `.inactive` → `.active` не спрашивает снова
        coordinator.scenePhaseChanged(.inactive)
        await coordinator.scenePhaseChanged(.active)?.value
        #expect(targets.calls == [.authenticate, .startTree, .startTree])
    }

    @Test func returnAfterCloseAsksBeforeReconnect() async throws {
        await coordinator.scenePhaseChanged(.active)?.value
        coordinator.scenePhaseChanged(.background)
        try await waitUntil { coordinator.closed && tasks.ended.count == 1 }
        targets.calls = []
        await coordinator.scenePhaseChanged(.active)?.value
        #expect(targets.calls == [.authenticate, .reconnectAll(force: false), .startTree, .refreshTree])
    }

    @Test func backgroundLocksKeys() async throws {
        await coordinator.scenePhaseChanged(.active)?.value
        targets.calls = []
        coordinator.scenePhaseChanged(.background)
        try await waitUntil { targets.calls.count == 3 }
        #expect(targets.calls == [.stopTree, .lock, .disconnectAll])
    }

    @Test func returnBeforeCloseAsksToo() async throws {
        await coordinator.scenePhaseChanged(.active)?.value
        coordinator.scenePhaseChanged(.background)
        targets.calls = []
        await coordinator.scenePhaseChanged(.active)?.value
        #expect(targets.calls == [.stopTree, .lock, .authenticate, .startTree])
    }

    @Test func denialOnQuickReturnKeepsTreeStopped() async throws {
        await coordinator.scenePhaseChanged(.active)?.value
        coordinator.scenePhaseChanged(.background)
        targets.calls = []
        unlocker.granted = false
        await coordinator.scenePhaseChanged(.active)?.value
        // опрос дерева остановлен уходом в фон и без ключа не запускается
        #expect(targets.calls == [.stopTree, .lock, .authenticate])
        #expect(coordinator.locked == false)
        unlocker.granted = true
        #expect(await coordinator.unlock())
        #expect(targets.calls == [.stopTree, .lock, .authenticate, .authenticate, .startTree])
    }

    @Test func denialKeepsEverythingDownUntilUnlock() async throws {
        coordinator.scenePhaseChanged(.background)
        try await waitUntil { coordinator.closed && tasks.ended.count == 1 }
        targets.calls = []
        unlocker.granted = false
        await coordinator.scenePhaseChanged(.active)?.value
        #expect(targets.calls == [.authenticate])
        #expect(coordinator.locked == true)
        // без ключа ни дерево, ни смена сети ничего не поднимают
        coordinator.scenePhaseChanged(.inactive)
        await coordinator.scenePhaseChanged(.active)?.value
        #expect(coordinator.networkChanged("wifi → cellular") == nil)
        #expect(targets.calls == [.authenticate])
        // «Повторить» у терминала: снова отказ, потом успех
        #expect(await coordinator.unlock() == false)
        unlocker.granted = true
        #expect(await coordinator.unlock())
        #expect(coordinator.locked == nil)
        #expect(targets.calls == [
            .authenticate, .authenticate, .authenticate,
            .reconnectAll(force: false), .startTree, .refreshTree,
        ])
    }

    @Test func networkChangeBehindDeniedPromptDoesNothing() async throws {
        coordinator.scenePhaseChanged(.background)
        try await waitUntil { coordinator.closed && tasks.ended.count == 1 }
        targets.calls = []
        unlocker.granted = false
        // смена сети приходит, пока шаг возврата ещё ждёт Face ID
        let active = coordinator.scenePhaseChanged(.active)
        await coordinator.networkChanged("wifi → cellular")?.value
        await active?.value
        #expect(targets.calls == [.authenticate])
        #expect(coordinator.locked == true)
    }

    @Test func keyUnlockedElsewhereResumes() async throws {
        coordinator.scenePhaseChanged(.background)
        try await waitUntil { coordinator.closed && tasks.ended.count == 1 }
        targets.calls = []
        unlocker.granted = false
        await coordinator.scenePhaseChanged(.active)?.value
        // Face ID пройден в `auth(for:)`, например при обновлении дерева
        await coordinator.keyUnlocked()?.value
        #expect(coordinator.locked == nil)
        #expect(targets.calls == [.authenticate, .reconnectAll(force: false), .startTree, .refreshTree])
        #expect(coordinator.keyUnlocked() == nil)
    }

    @Test func unlockWithoutDenialOnlyAsks() async {
        await coordinator.scenePhaseChanged(.active)?.value
        targets.calls = []
        #expect(await coordinator.unlock())
        #expect(targets.calls == [.authenticate])
    }
}
