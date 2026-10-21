import Foundation
import TmuxPadCore

/// `KeyStore` ядра плюс то, что нужно экрану ключей: создание и импорт. Живая реализация —
/// `KeychainKeyStore`, в тестах и `-uitest-inmemory` — `InMemoryKeyStore` без Secure Enclave.
protocol AppKeyStore: KeyStore {
    func createEd25519(name: String) async throws -> SSHKeyInfo
    func createSecureEnclave(name: String) async throws -> SSHKeyInfo
    func importEd25519(name: String, text: String, passphrase: String?) async throws -> SSHKeyInfo
}

extension InMemoryKeyStore: AppKeyStore {
    func createEd25519(name: String) -> SSHKeyInfo {
        let (info, text) = KeychainKeyStore.newEd25519(name: name)
        save(info, privateKeyOpenSSH: text)
        return info
    }

    func createSecureEnclave(name: String) throws -> SSHKeyInfo {
        throw KeyStoreError.secureEnclaveUnavailable
    }

    func importEd25519(name: String, text: String, passphrase: String?) throws -> SSHKeyInfo {
        let (info, plain) = try KeychainKeyStore.decryptEd25519(name: name, text: text, passphrase: passphrase)
        save(info, privateKeyOpenSSH: plain)
        return info
    }
}
