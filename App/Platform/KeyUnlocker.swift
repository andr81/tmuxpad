import Foundation
import LocalAuthentication
import Observation
import TmuxPadCore

/// Face ID перед первым использованием ключа в сессии приложения (§8). Успех действует до
/// ухода в фон (`lock`). В тестах координатора — фейк.
protocol KeyUnlocking: Sendable {
    /// Ничего не спрашивает, если проверка выключена или уже пройдена; отказ — `AppError.biometricsDenied`.
    func authenticate() async throws
    /// Уход в фон: следующее использование ключа снова спросит.
    func lock() async
}

/// Сам запрос к системе; в тестах — фейк со счётчиком.
protocol BiometricPrompt: Sendable {
    /// `false` или ошибка — отказ.
    func evaluate(reason: String) async throws -> Bool
}

struct DeviceOwnerPrompt: BiometricPrompt {
    func evaluate(reason: String) async throws -> Bool {
        try await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
    }
}

/// Настройка «Требовать Face ID для ключей», по умолчанию выключена.
enum SecuritySettings {
    static let requireBiometricsKey = "security.requireBiometrics"
}

/// Один запрос на все одновременные вызовы: параллельные `authenticate` ждут его, а не
/// показывают несколько.
actor KeyUnlocker: KeyUnlocking {
    static let reason = "Доступ к SSH-ключу"

    private let prompt: any BiometricPrompt
    private let isRequired: @Sendable () -> Bool
    private let onLock: @Sendable () async -> Void
    private let onUnlock: @Sendable () async -> Void
    private var unlocked = false
    /// Последний запрос отклонён: ждущий реконнект пула сдаётся, а не висит до `lock`.
    private var denied = false
    private var pending: Task<Bool, Error>?
    /// Растёт на каждый `lock`: запрос, начатый до ухода в фон, не открывает доступ после него.
    private var generation = 0

    /// `onLock` — при уходе в фон с включённой проверкой (очистка кеша ключей); `onUnlock` —
    /// после пройденного запроса (координатор снимает блокировку после отказа).
    init(
        prompt: any BiometricPrompt = DeviceOwnerPrompt(),
        isRequired: @escaping @Sendable () -> Bool,
        onLock: @escaping @Sendable () async -> Void = {},
        onUnlock: @escaping @Sendable () async -> Void = {}
    ) {
        self.prompt = prompt
        self.isRequired = isRequired
        self.onLock = onLock
        self.onUnlock = onUnlock
    }

    func authenticate() async throws {
        guard !unlocked else {
            return
        }
        // выключенная проверка тоже открывает сессию: включённая посреди неё спросит после
        // фона или перезапуска, а не тиком опроса дерева каждые 10 с
        guard isRequired() else {
            unlocked = true
            await onUnlock()
            return
        }
        let task: Task<Bool, Error>
        if let pending {
            task = pending
        } else {
            let prompt = prompt
            task = Task { try await prompt.evaluate(reason: Self.reason) }
            pending = task
        }
        let started = generation
        let granted = (try? await task.value) ?? false
        if pending == task {
            pending = nil
        }
        // ответ на запрос, начатый до ухода в фон, — отказ: ключ уже закрыт `lock`
        guard generation == started else {
            throw AppError.biometricsDenied
        }
        guard granted else {
            if !unlocked {
                denied = true
            }
            throw AppError.biometricsDenied
        }
        if !unlocked {
            unlocked = true
            denied = false
            await onUnlock()
        }
    }

    /// Реконнект пула (`reconnectGate`) идёт с сохранённым `SSHAuth`, мимо `authenticate`: он
    /// ждёт здесь, пока ключ закрыт, и не показывает запрос сам — его покажет координатор,
    /// «Повторить» или действие с ключом. Отмена задачи — `CancellationError`; отказ в запросе
    /// (уже прошедшем или во время ожидания) — `AppError.biometricsDenied`: соединение уходит в
    /// `.failed`, у терминала «Повторить», а не вечное «Переподключение…».
    func waitUntilUnlocked() async throws {
        while isRequired(), !unlocked {
            if denied {
                throw AppError.biometricsDenied
            }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    func lock() async {
        generation += 1
        unlocked = false
        denied = false
        pending = nil
        if isRequired() {
            await onLock()
        }
    }
}

/// Приватные ключи по `keyID`: `TreeRefresher` не читает Keychain и Secure Enclave на каждом
/// тике. Очищается при уходе в фон, если включён Face ID.
actor KeyCache {
    private var keys: [UUID: SSHPrivateKey] = [:]

    func key(_ id: UUID) -> SSHPrivateKey? {
        keys[id]
    }

    func store(_ key: SSHPrivateKey, for id: UUID) {
        keys[id] = key
    }

    func clear() {
        keys = [:]
    }
}

/// Переключатель Face ID в разделе «Ключи».
@MainActor
@Observable
final class SecurityPreferences {
    var requireBiometrics: Bool {
        didSet { defaults.set(requireBiometrics, forKey: SecuritySettings.requireBiometricsKey) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        requireBiometrics = defaults.bool(forKey: SecuritySettings.requireBiometricsKey)
    }
}
