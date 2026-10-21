import Foundation
import TmuxPadCore

/// Доверенные отпечатки хост-ключей в Keychain; account — `host:port`, данные — UTF-8 отпечатка.
actor KeychainHostKeyStore: HostKeyStore {
    private let keychain: Keychain

    init(keychain: Keychain = .hostKeys) {
        self.keychain = keychain
    }

    func fingerprint(for host: String, port: Int) throws -> String? {
        guard let data = try keychain.read(account: InMemoryHostKeyStore.key(host: host, port: port)) else {
            return nil
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw KeychainError.unexpectedData
        }
        return text
    }

    func save(_ fingerprint: String, for host: String, port: Int) throws {
        try keychain.write(Data(fingerprint.utf8), account: InMemoryHostKeyStore.key(host: host, port: port))
    }

    func reset(host: String, port: Int) throws {
        try keychain.delete(account: InMemoryHostKeyStore.key(host: host, port: port))
    }
}
