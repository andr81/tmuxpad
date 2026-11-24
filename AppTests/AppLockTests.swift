import Foundation
import SwiftUI
import Testing
@testable import TmuxPad

struct FakeDeviceAuth: DeviceAuthInfo {
    var deviceName = "iPad"
    var canUseDeviceOwnerAuth = true
    var biometryName: String? = "Face ID"
}

/// Часы, которые двигает тест.
@MainActor
final class TestClocks {
    var date = Date(timeIntervalSince1970: 1_000_000)
    var instant = ContinuousClock.now

    func advance(seconds: Int) {
        date = date.addingTimeInterval(TimeInterval(seconds))
        instant = instant.advanced(by: .seconds(seconds))
    }
}

@MainActor
struct AppLockTests {
    let defaults = UserDefaults(suiteName: "dev.tmuxpad.test.\(UUID().uuidString)")!
    let secrets = InMemoryLockSecretStore()
    let prompt = FakePrompt()
    let clocks = TestClocks()

    private func makeLock(device: FakeDeviceAuth = FakeDeviceAuth()) -> AppLock {
        let clocks = clocks
        return AppLock(
            defaults: defaults,
            secrets: secrets,
            hasher: LockCodeHasher(rounds: 1000),
            prompt: prompt,
            device: device,
            now: { clocks.date },
            clock: { clocks.instant }
        )
    }

    @Test func offByDefault() {
        let lock = makeLock()
        #expect(!lock.enabled)
        #expect(!lock.isLocked)
        #expect(!lock.shieldVisible(in: .background))
    }

    @Test func pinSetupLocksNextLaunch() async throws {
        let lock = makeLock()
        try await lock.configure(method: .pin, code: "1234")
        #expect(lock.enabled)
        #expect(!lock.isLocked)
        #expect(try secrets.read() != nil)
        let relaunched = makeLock()
        #expect(relaunched.isLocked)
        #expect(relaunched.method == .pin)
        #expect(await relaunched.unlock(code: "0000") == .rejected)
        #expect(relaunched.isLocked)
        #expect(await relaunched.unlock(code: "1234") == .accepted)
        #expect(!relaunched.isLocked)
    }

    @Test func badCodesAreRefused() async {
        let lock = makeLock()
        for code in ["123", "123456789", "12a4", "١٢٣٤"] {
            await #expect(throws: LockSetupError.invalidCode) {
                try await lock.configure(method: .pin, code: code)
            }
        }
        await #expect(throws: LockSetupError.invalidCode) {
            try await lock.configure(method: .password, code: "abc")
        }
        #expect(!lock.enabled)
    }

    @Test func biometricsSetupNeedsPromptAndPasscode() async throws {
        prompt.granted = false
        let lock = makeLock()
        await #expect(throws: LockSetupError.biometricsDenied) {
            try await lock.configure(method: .biometrics, code: nil)
        }
        #expect(!lock.enabled)
        let noPasscode = makeLock(device: FakeDeviceAuth(canUseDeviceOwnerAuth: false, biometryName: nil))
        await #expect(throws: LockSetupError.biometricsUnavailable) {
            try await noPasscode.configure(method: .biometrics, code: nil)
        }
        #expect(LockSetupForm.methods(device: FakeDeviceAuth(canUseDeviceOwnerAuth: false)) == [.pin, .password])
        prompt.granted = true
        try await lock.configure(method: .biometrics, code: nil)
        #expect(lock.enabled)
        #expect(lock.method == .biometrics)
    }

    @Test func biometricsUnlock() async throws {
        let lock = makeLock()
        try await lock.configure(method: .biometrics, code: nil)
        let relaunched = makeLock()
        prompt.granted = false
        #expect(!(await relaunched.unlockWithBiometrics()))
        #expect(relaunched.isLocked)
        prompt.granted = true
        #expect(await relaunched.unlockWithBiometrics())
        #expect(!relaunched.isLocked)
    }

    @Test func backgroundLocksAfterDelay() async throws {
        let lock = makeLock()
        try await lock.configure(method: .pin, code: "1234")
        lock.setDelay(.fiveMinutes)
        lock.scenePhaseChanged(.background)
        #expect(lock.shieldVisible(in: .background))
        #expect(!lock.isLocked)
        clocks.advance(seconds: 299)
        lock.scenePhaseChanged(.active)
        #expect(!lock.isLocked)
        lock.scenePhaseChanged(.background)
        clocks.advance(seconds: 300)
        lock.scenePhaseChanged(.active)
        #expect(lock.isLocked)
    }

    /// «Сразу» блокирует уже при уходе в фон: возврат не покажет интерфейс ни на кадр.
    @Test func immediateLocksOnBackground() async throws {
        let lock = makeLock()
        try await lock.configure(method: .pin, code: "1234")
        lock.scenePhaseChanged(.inactive)
        #expect(!lock.isLocked)
        lock.scenePhaseChanged(.background)
        #expect(lock.isLocked)
    }

    /// Face ID переводит сцену в `.inactive` и обратно: это не уход в фон.
    @Test func inactiveIsNotBackground() async throws {
        let lock = makeLock()
        try await lock.configure(method: .pin, code: "1234")
        lock.setDelay(.oneMinute)
        lock.scenePhaseChanged(.inactive)
        clocks.advance(seconds: 600)
        lock.scenePhaseChanged(.active)
        #expect(!lock.isLocked)
    }

    @Test func failuresPauseAndSurviveRelaunch() async throws {
        let lock = makeLock()
        try await lock.configure(method: .pin, code: "1234")
        let relaunched = makeLock()
        for _ in 1..<AppLock.freeFailures {
            #expect(await relaunched.unlock(code: "0000") == .rejected)
        }
        let paused = await relaunched.unlock(code: "0000")
        #expect(paused == .paused(until: clocks.date.addingTimeInterval(30)))
        // даже верный код ждёт конца паузы
        #expect(await relaunched.unlock(code: "1234") == paused)
        let again = makeLock()
        #expect(again.failures == AppLock.freeFailures)
        #expect(await again.unlock(code: "1234") == paused)
        clocks.advance(seconds: 30)
        #expect(await again.unlock(code: "1234") == .accepted)
        #expect(again.failures == 0)
    }

    @Test func pauseGrowsAndCaps() {
        #expect(AppLock.pause(afterFailures: 4) == nil)
        #expect(AppLock.pause(afterFailures: 5) == 30)
        #expect(AppLock.pause(afterFailures: 6) == 60)
        #expect(AppLock.pause(afterFailures: 9) == 480)
        #expect(AppLock.pause(afterFailures: 10) == 900)
        #expect(AppLock.pause(afterFailures: 40) == 900)
    }

    @Test func changesNeedAuthorization() async throws {
        let lock = makeLock()
        try await lock.configure(method: .pin, code: "1234")
        #expect(throws: LockSetupError.notAuthorized) { try lock.disable() }
        await #expect(throws: LockSetupError.notAuthorized) {
            try await lock.configure(method: .password, code: "secret")
        }
        #expect(await lock.authorizeChange(code: "9999") == .rejected)
        #expect(throws: LockSetupError.notAuthorized) { try lock.disable() }
        #expect(await lock.authorizeChange(code: "1234") == .accepted)
        try await lock.configure(method: .password, code: "secret")
        #expect(lock.method == .password)
        // разрешение одноразовое
        #expect(throws: LockSetupError.notAuthorized) { try lock.disable() }
        #expect(await lock.authorizeChange(code: "secret") == .accepted)
        lock.cancelChange()
        #expect(throws: LockSetupError.notAuthorized) { try lock.disable() }
        #expect(await lock.authorizeChange(code: "secret") == .accepted)
        try lock.disable()
        #expect(!lock.enabled)
        #expect(try secrets.read() == nil)
        #expect(!makeLock().isLocked)
    }

    /// «Забыли код?»: код-пароль устройства, затем новый код снимает блокировку.
    @Test func forgotCodeWithDevicePasscode() async throws {
        let lock = makeLock()
        try await lock.configure(method: .pin, code: "1234")
        let relaunched = makeLock()
        prompt.granted = false
        #expect(!(await relaunched.authorizeWithDevicePasscode()))
        prompt.granted = true
        #expect(await relaunched.authorizeWithDevicePasscode())
        try await relaunched.configure(method: .pin, code: "5678")
        #expect(!relaunched.isLocked)
        #expect(await makeLock().unlock(code: "5678") == .accepted)
    }

    @Test func forgotCodeNeedsPasscode() async throws {
        let lock = makeLock(device: FakeDeviceAuth(canUseDeviceOwnerAuth: false, biometryName: nil))
        try await lock.configure(method: .pin, code: "1234")
        #expect(!(await lock.authorizeWithDevicePasscode()))
        #expect(prompt.calls == 0)
    }

    /// Бэкап на новом устройстве: настройки приехали, хеша в Keychain нет.
    @Test func missingSecretAsksForReset() async throws {
        let lock = makeLock()
        try await lock.configure(method: .pin, code: "1234")
        try secrets.delete()
        let relaunched = makeLock()
        #expect(await relaunched.unlock(code: "1234") == .missing)
        #expect(relaunched.isLocked)
    }

    @Test func hasherRoundTrip() async {
        let hasher = LockCodeHasher(rounds: 1000)
        let blob = await hasher.make("p@ss wörd")
        let expectedLength = 1 + 4 + LockCodeHasher.saltLength + LockCodeHasher.hashLength
        #expect(blob.count == expectedLength)
        #expect(await hasher.verify("p@ss wörd", against: blob))
        #expect(!(await hasher.verify("p@ss word", against: blob)))
        // соль случайная
        #expect(await hasher.make("p@ss wörd") != blob)
        #expect(!(await hasher.verify("x", against: Data([1, 2, 3]))))
    }

    @Test func titlesAndMessages() {
        let lock = makeLock(device: FakeDeviceAuth(biometryName: "Touch ID"))
        #expect(lock.title(of: .biometrics) == "Touch ID")
        #expect(makeLock(device: FakeDeviceAuth(biometryName: nil)).title(of: .biometrics) == "Код-пароль iPad")
        let phone = FakeDeviceAuth(deviceName: "iPhone", biometryName: nil)
        #expect(makeLock(device: phone).title(of: .biometrics) == "Код-пароль iPhone")
        #expect(LockSetupForm.footer(method: .pin, device: phone) == "Забытый код можно сбросить кодом-паролем iPhone.")
        #expect(LockSetupForm.footer(method: .biometrics, device: FakeDeviceAuth(deviceName: "iPhone")) == "Если Face ID не пройдёт, iPhone спросит свой код-пароль.")
        #expect(AppLockView.message(for: .rejected, method: .pin) == "Неверный PIN")
        #expect(AppLockView.message(for: .rejected, method: .password) == "Неверный пароль")
        #expect(AppLockView.message(for: .accepted, method: .pin) == nil)
        #expect(LockSetupForm.codeIssue(code: "12", repeated: "", method: .pin) == "PIN — от 4 до 8 цифр")
        #expect(LockSetupForm.codeIssue(code: "1234", repeated: "1235", method: .pin) == "PIN не совпадает")
        #expect(LockSetupForm.codeIssue(code: "1234", repeated: "1234", method: .pin) == nil)
    }
}
