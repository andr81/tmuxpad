import Foundation
import Observation
import TmuxPadCore

enum KeyLibraryError: Error, Equatable {
    /// Метки серверов, которые используют ключ.
    case inUse([String])
}

/// Ключи пользователя для экранов настроек; источник правды — `AppKeyStore`.
@MainActor
@Observable
final class KeyLibrary {
    private(set) var keys: [SSHKeyInfo]
    let secureEnclaveAvailable: Bool

    @ObservationIgnored private let store: any AppKeyStore
    @ObservationIgnored private let servers: ServerStore

    init(store: any AppKeyStore, keys: [SSHKeyInfo], servers: ServerStore, secureEnclaveAvailable: Bool) {
        self.store = store
        self.keys = keys
        self.servers = servers
        self.secureEnclaveAvailable = secureEnclaveAvailable
    }

    func key(id: UUID) -> SSHKeyInfo? {
        keys.first { $0.id == id }
    }

    @discardableResult
    func create(kind: SSHKeyInfo.Kind, name: String) async throws -> SSHKeyInfo {
        let info = switch kind {
        case .ed25519: try await store.createEd25519(name: name)
        case .secureEnclaveP256: try await store.createSecureEnclave(name: name)
        }
        try await reload()
        return info
    }

    @discardableResult
    func importKey(name: String, text: String, passphrase: String?) async throws -> SSHKeyInfo {
        let info = try await store.importEd25519(name: name, text: text, passphrase: passphrase)
        try await reload()
        return info
    }

    /// Ключ, на который ссылается сервер, не удаляется: сервер остался бы без входа.
    func delete(_ id: UUID) async throws {
        let users = servers.servers.filter { $0.keyID == id }.map(\.label)
        guard users.isEmpty else {
            throw KeyLibraryError.inUse(users)
        }
        try await store.delete(id)
        try await reload()
    }

    func reload() async throws {
        keys = try await store.list()
    }
}
