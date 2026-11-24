import CommonCrypto
import Foundation
import LocalAuthentication
import Security

/// PIN или пароль безопасного режима (§3.8): хранится не код, а PBKDF2-HMAC-SHA256 от него.
/// Формат записи: версия (1 байт) · число итераций (4 байта, big-endian) · соль (16) · хеш (32).
struct LockCodeHasher: Sendable {
    static let saltLength = 16
    static let hashLength = 32
    private static let version: UInt8 = 1

    /// В тестах меньше: 200 000 итераций на каждый вызов замедлили бы их на секунды.
    var rounds: UInt32 = 200_000

    /// Хеш считается не на main: 200 000 итераций — это сотни миллисекунд.
    func make(_ code: String) async -> Data {
        let rounds = rounds
        return await Task.detached {
            var salt = Data(count: Self.saltLength)
            let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, Self.saltLength, $0.baseAddress!) }
            precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
            var blob = Data([Self.version])
            withUnsafeBytes(of: rounds.bigEndian) { blob.append(contentsOf: $0) }
            blob.append(salt)
            blob.append(Self.derive(code, salt: salt, rounds: rounds))
            return blob
        }.value
    }

    /// Запись другой версии или длины — несовпадение, а не ошибка.
    func verify(_ code: String, against blob: Data) async -> Bool {
        await Task.detached {
            let bytes = [UInt8](blob)
            guard bytes.count == 1 + 4 + Self.saltLength + Self.hashLength, bytes[0] == Self.version else {
                return false
            }
            let rounds = bytes[1...4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            guard rounds > 0 else {
                return false
            }
            let salt = Data(bytes[5..<(5 + Self.saltLength)])
            let expected = bytes[(5 + Self.saltLength)...]
            let actual = [UInt8](Self.derive(code, salt: salt, rounds: rounds))
            // за постоянное время: без раннего выхода на первом отличии
            var difference: UInt8 = 0
            for (left, right) in zip(actual, expected) {
                difference |= left ^ right
            }
            return difference == 0
        }.value
    }

    private static func derive(_ code: String, salt: Data, rounds: UInt32) -> Data {
        var key = Data(count: hashLength)
        let password = Array(code.utf8)
        let status = key.withUnsafeMutableBytes { keyBytes in
            salt.withUnsafeBytes { saltBytes in
                password.withUnsafeBufferPointer { passwordBytes in
                    passwordBytes.withMemoryRebound(to: CChar.self) { passwordChars in
                        CCKeyDerivationPBKDF(
                            CCPBKDFAlgorithm(kCCPBKDF2),
                            passwordChars.baseAddress, passwordChars.count,
                            saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                            rounds,
                            keyBytes.bindMemory(to: UInt8.self).baseAddress, hashLength
                        )
                    }
                }
            }
        }
        precondition(Int(status) == kCCSuccess, "CCKeyDerivationPBKDF failed: \(status)")
        return key
    }
}

/// Где лежит хеш кода: Keychain в приложении, память в тестах.
protocol LockSecretStore: Sendable {
    /// `nil` — записи нет.
    func read() throws -> Data?
    func write(_ data: Data) throws
    /// Отсутствующая запись — не ошибка.
    func delete() throws
}

struct KeychainLockSecretStore: LockSecretStore {
    private static let account = "code"

    func read() throws -> Data? {
        try Keychain.lock.read(account: Self.account)
    }

    func write(_ data: Data) throws {
        try Keychain.lock.write(data, account: Self.account)
    }

    func delete() throws {
        try Keychain.lock.delete(account: Self.account)
    }
}

final class InMemoryLockSecretStore: LockSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?

    func read() throws -> Data? {
        lock.withLock { data }
    }

    func write(_ data: Data) throws {
        lock.withLock { self.data = data }
    }

    func delete() throws {
        lock.withLock { data = nil }
    }
}

/// Что умеет устройство для способа «Face ID» и «Забыли код?».
protocol DeviceAuthInfo: Sendable {
    /// Есть код-пароль iPad: политика `deviceOwnerAuthentication` доступна.
    var canUseDeviceOwnerAuth: Bool { get }
    /// «Face ID», «Touch ID», «Optic ID»; `nil` — биометрии нет, остаётся код-пароль.
    var biometryName: String? { get }
}

struct SystemDeviceAuthInfo: DeviceAuthInfo {
    var canUseDeviceOwnerAuth: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    var biometryName: String? {
        let context = LAContext()
        // `biometryType` заполняется только после `canEvaluatePolicy`
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return nil
        }
    }
}
