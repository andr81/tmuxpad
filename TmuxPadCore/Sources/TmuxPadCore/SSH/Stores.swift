import Foundation
@preconcurrency import NIOSSH

/// Хранилище ключей пользователя; в приложении — Keychain и Secure Enclave.
public protocol KeyStore: Sendable {
    func list() async throws -> [SSHKeyInfo]
    func save(_ info: SSHKeyInfo, privateKeyOpenSSH: String) async throws
    func privateKey(for id: UUID) async throws -> SSHPrivateKey?
    func delete(_ id: UUID) async throws
}

/// Доверенные отпечатки хост-ключей (TOFU, §8).
public protocol HostKeyStore: Sendable {
    func fingerprint(for host: String, port: Int) async throws -> String?
    func save(_ fingerprint: String, for host: String, port: Int) async throws
    func reset(host: String, port: Int) async throws
}

/// Ключи в памяти: Ed25519 из OpenSSH-текста. Для тестов и как заглушка до Keychain.
public actor InMemoryKeyStore: KeyStore {
    private var keys: [UUID: (info: SSHKeyInfo, privateKeyOpenSSH: String)] = [:]

    public init() {}

    public func list() -> [SSHKeyInfo] {
        keys.values.map(\.info).sorted { $0.createdAt < $1.createdAt }
    }

    public func save(_ info: SSHKeyInfo, privateKeyOpenSSH: String) {
        keys[info.id] = (info, privateKeyOpenSSH)
    }

    public func privateKey(for id: UUID) throws -> SSHPrivateKey? {
        guard let entry = keys[id] else {
            return nil
        }
        return SSHPrivateKey(try SSHKeys.importOpenSSHEd25519(entry.privateKeyOpenSSH))
    }

    public func delete(_ id: UUID) {
        keys[id] = nil
    }
}

public actor InMemoryHostKeyStore: HostKeyStore {
    private var fingerprints: [String: String] = [:]

    public init(_ initial: [String: String] = [:]) {
        fingerprints = initial
    }

    /// Ключ словаря: `host:port`.
    public static func key(host: String, port: Int) -> String {
        "\(host):\(port)"
    }

    public func fingerprint(for host: String, port: Int) -> String? {
        fingerprints[Self.key(host: host, port: port)]
    }

    public func save(_ fingerprint: String, for host: String, port: Int) {
        fingerprints[Self.key(host: host, port: port)] = fingerprint
    }

    public func reset(host: String, port: Int) {
        fingerprints[Self.key(host: host, port: port)] = nil
    }
}
