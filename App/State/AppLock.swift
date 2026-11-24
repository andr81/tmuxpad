import Foundation
import Observation
import SwiftUI

/// Способ разблокировки безопасного режима (§3.8).
enum LockMethod: String, CaseIterable, Sendable {
    /// Face ID, Touch ID или Optic ID с запасным кодом-паролем устройства.
    case biometrics
    case pin
    case password
}

/// «Блокировать через»: сколько приложение может пробыть в фоне без блокировки.
enum LockDelay: Int, CaseIterable, Sendable {
    case immediately = 0
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900

    var title: String {
        switch self {
        case .immediately: "Сразу"
        case .oneMinute: "1 минута"
        case .fiveMinutes: "5 минут"
        case .fifteenMinutes: "15 минут"
        }
    }
}

enum LockSettings {
    static let enabledKey = "lock.enabled"
    static let methodKey = "lock.method"
    static let delayKey = "lock.delay"
    static let failuresKey = "lock.failures"
    static let pausedUntilKey = "lock.pausedUntil"
}

/// Проверка PIN или пароля.
enum CodeCheck: Equatable {
    case accepted
    case rejected
    /// Слишком много ошибок: до этого момента код не проверяется.
    case paused(until: Date)
    /// Хеша нет в Keychain (бэкап на новом устройстве): помогает только «Забыли код?».
    case missing
}

enum LockSetupError: Error, Equatable {
    /// Режим включён, а текущий способ не проверен (`authorizeChange`).
    case notAuthorized
    case invalidCode
    /// Нет кода-пароля на устройстве.
    case biometricsUnavailable
    case biometricsDenied
    case storeFailed
}

/// Безопасный режим (§3.8): блокировка всего приложения при запуске и возврате из фона.
/// Решает только, заблокировано ли приложение; пул и дерево по-прежнему ведёт
/// `LifecycleCoordinator`, `RootView` передаёт ему `.active` лишь после разблокировки.
@MainActor
@Observable
final class AppLock {
    static let pinLengths = 4...8
    static let passwordLengths = 4...128
    /// Столько ошибок подряд проходят без паузы.
    static let freeFailures = 5
    static let firstPause: TimeInterval = 30
    static let maxPause: TimeInterval = 900

    static let unlockReason = "Разблокировать TmuxPad"
    static let resetReason = "Сбросить код TmuxPad"
    static let enableReason = "Включить блокировку TmuxPad"
    static let changeReason = "Изменить блокировку TmuxPad"

    private(set) var enabled: Bool
    private(set) var method: LockMethod
    private(set) var delay: LockDelay
    private(set) var isLocked: Bool
    private(set) var failures: Int
    private(set) var pausedUntil: Date?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let secrets: any LockSecretStore
    @ObservationIgnored private let hasher: LockCodeHasher
    @ObservationIgnored private let prompt: any BiometricPrompt
    @ObservationIgnored let device: any DeviceAuthInfo
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let clock: @MainActor () -> ContinuousClock.Instant
    @ObservationIgnored private var backgroundedAt: ContinuousClock.Instant?
    /// Текущий способ проверен: можно выключить режим или сменить способ и код. Сбрасывается
    /// первым же изменением.
    @ObservationIgnored private(set) var changeAuthorized = false

    init(
        defaults: UserDefaults,
        secrets: any LockSecretStore,
        hasher: LockCodeHasher = LockCodeHasher(),
        prompt: any BiometricPrompt = DeviceOwnerPrompt(),
        device: any DeviceAuthInfo = SystemDeviceAuthInfo(),
        now: @escaping @MainActor () -> Date = { Date() },
        clock: @escaping @MainActor () -> ContinuousClock.Instant = { .now }
    ) {
        self.defaults = defaults
        self.secrets = secrets
        self.hasher = hasher
        self.prompt = prompt
        self.device = device
        self.now = now
        self.clock = clock
        let enabled = defaults.bool(forKey: LockSettings.enabledKey)
        self.enabled = enabled
        method = defaults.string(forKey: LockSettings.methodKey).flatMap(LockMethod.init(rawValue:)) ?? .biometrics
        delay = LockDelay(rawValue: defaults.integer(forKey: LockSettings.delayKey)) ?? .immediately
        failures = defaults.integer(forKey: LockSettings.failuresKey)
        pausedUntil = defaults.object(forKey: LockSettings.pausedUntilKey) as? Date
        // запуск всегда начинается с блокировки
        isLocked = enabled
    }

    /// Название способа для UI: у биометрии — имя по устройству.
    func title(of method: LockMethod) -> String {
        switch method {
        case .biometrics: device.biometryName ?? "Код-пароль \(device.deviceName)"
        case .pin: "PIN"
        case .password: "Пароль"
        }
    }

    // MARK: - Фаза сцены

    /// Уход в фон запоминает время; возврат блокирует, если в фоне пробыли не меньше `delay`.
    /// При «Сразу» блокировка ставится уже при уходе: возврат не покажет интерфейс ни на кадр.
    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            if backgroundedAt == nil {
                backgroundedAt = clock()
            }
            if enabled, delay == .immediately {
                isLocked = true
            }
        case .active:
            if enabled, let since = backgroundedAt, clock() - since >= .seconds(delay.rawValue) {
                isLocked = true
            }
            backgroundedAt = nil
        default:
            break
        }
    }

    /// Шторка поверх интерфейса для снимка переключателя приложений.
    func shieldVisible(in phase: ScenePhase) -> Bool {
        enabled && phase != .active
    }

    // MARK: - Разблокировка

    /// Способ «Face ID»: системный запрос с запасным кодом-паролем устройства.
    @discardableResult
    func unlockWithBiometrics() async -> Bool {
        guard isLocked else {
            return true
        }
        guard method == .biometrics, await evaluate(Self.unlockReason) else {
            return false
        }
        isLocked = false
        return true
    }

    func unlock(code: String) async -> CodeCheck {
        guard isLocked else {
            return .accepted
        }
        let result = await check(code)
        if result == .accepted {
            isLocked = false
        }
        return result
    }

    /// «Забыли код?»: код-пароль устройства разрешает задать новый код или выключить режим
    /// (`configure`, `disable`); блокировка снимается только ими.
    func authorizeWithDevicePasscode() async -> Bool {
        guard device.canUseDeviceOwnerAuth, await evaluate(Self.resetReason) else {
            return false
        }
        changeAuthorized = true
        return true
    }

    /// Проверка текущим способом перед выключением или сменой способа и кода. `code` — для PIN и пароля.
    func authorizeChange(code: String?) async -> CodeCheck {
        guard enabled else {
            changeAuthorized = true
            return .accepted
        }
        let result: CodeCheck
        switch method {
        case .biometrics:
            result = await evaluate(Self.changeReason) ? .accepted : .rejected
        case .pin, .password:
            result = await check(code ?? "")
        }
        if result == .accepted {
            changeAuthorized = true
        }
        return result
    }

    // MARK: - Настройка

    static func isValid(_ code: String, for method: LockMethod) -> Bool {
        switch method {
        case .biometrics:
            true
        case .pin:
            pinLengths.contains(code.count) && code.allSatisfy { $0.isASCII && $0.isNumber }
        case .password:
            passwordLengths.contains(code.count)
        }
    }

    /// Включение или смена способа и кода. Включённый режим сначала проверяется `authorizeChange`
    /// или «Забыли код?». Для «Face ID» — системный запрос, чтобы не включить способ, который не
    /// пройти. Успех снимает блокировку: так «Забыли код?» возвращает в приложение.
    func configure(method: LockMethod, code: String?) async throws(LockSetupError) {
        if enabled, !changeAuthorized {
            throw .notAuthorized
        }
        switch method {
        case .biometrics:
            guard device.canUseDeviceOwnerAuth else {
                throw .biometricsUnavailable
            }
            guard await evaluate(Self.enableReason) else {
                throw .biometricsDenied
            }
            try? secrets.delete()
        case .pin, .password:
            guard let code, Self.isValid(code, for: method) else {
                throw .invalidCode
            }
            let blob = await hasher.make(code)
            do {
                try secrets.write(blob)
            } catch {
                throw .storeFailed
            }
        }
        self.method = method
        enabled = true
        isLocked = false
        changeAuthorized = false
        setFailures(0, pausedUntil: nil)
        defaults.set(true, forKey: LockSettings.enabledKey)
        defaults.set(method.rawValue, forKey: LockSettings.methodKey)
    }

    func disable() throws(LockSetupError) {
        guard !enabled || changeAuthorized else {
            throw .notAuthorized
        }
        try? secrets.delete()
        enabled = false
        isLocked = false
        changeAuthorized = false
        setFailures(0, pausedUntil: nil)
        defaults.set(false, forKey: LockSettings.enabledKey)
    }

    /// Задержка не ослабляет защиту до разблокировки: её меняют только в настройках.
    func setDelay(_ delay: LockDelay) {
        self.delay = delay
        defaults.set(delay.rawValue, forKey: LockSettings.delayKey)
    }

    /// Проверка закончена без изменений (лист закрыли): разрешение не висит до следующего раза.
    func cancelChange() {
        changeAuthorized = false
    }

    // MARK: - Внутреннее

    /// Пауза после `failures` ошибок подряд: первые `freeFailures - 1` без паузы, дальше 30 с и
    /// удвоение до 15 минут.
    static func pause(afterFailures failures: Int) -> TimeInterval? {
        guard failures >= freeFailures else {
            return nil
        }
        return min(maxPause, firstPause * pow(2, Double(failures - freeFailures)))
    }

    private func check(_ code: String) async -> CodeCheck {
        if let pausedUntil, pausedUntil > now() {
            return .paused(until: pausedUntil)
        }
        guard let stored = try? secrets.read() else {
            return .missing
        }
        if await hasher.verify(code, against: stored) {
            setFailures(0, pausedUntil: nil)
            return .accepted
        }
        let count = failures + 1
        let until = Self.pause(afterFailures: count).map { now().addingTimeInterval($0) }
        setFailures(count, pausedUntil: until)
        return until.map { .paused(until: $0) } ?? .rejected
    }

    private func setFailures(_ count: Int, pausedUntil: Date?) {
        failures = count
        self.pausedUntil = pausedUntil
        defaults.set(count, forKey: LockSettings.failuresKey)
        defaults.set(pausedUntil, forKey: LockSettings.pausedUntilKey)
    }

    private func evaluate(_ reason: String) async -> Bool {
        (try? await prompt.evaluate(reason: reason)) == true
    }
}
