import Foundation

/// UUID устройства (§5): по нему скрипт отличает своих tmux-клиентов от чужих (§6.1).
enum DeviceIdentity {
    static let account = "device-id"

    /// Читает UUID из Keychain, при первом запуске создаёт и записывает.
    static func load(keychain: Keychain = .device) throws -> UUID {
        if let data = try keychain.read(account: account) {
            guard let text = String(data: data, encoding: .utf8), let id = UUID(uuidString: text) else {
                throw KeychainError.unexpectedData
            }
            return id
        }
        let id = UUID()
        try keychain.write(Data(id.uuidString.utf8), account: account)
        return id
    }
}
