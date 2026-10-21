import CryptoKit
import Foundation
import SwiftUI
import TmuxPadCore

enum AppError: Error, Equatable {
    /// У сервера `keyID`, которого нет в хранилище ключей.
    case keyMissing(UUID)
}

/// Composition root: неизменяемые зависимости и модели State. Создаётся один раз при запуске.
@MainActor
final class AppEnvironment {
    let deviceID: UUID
    let keyStore: any AppKeyStore
    let hostKeys: any HostKeyStore
    /// Все настройки приложения читаются только отсюда.
    let defaults: UserDefaults
    let log: DiagnosticsLog
    let pool: ConnectionPool
    let bootstrap: HostBootstrap
    let servers: ServerStore
    let keys: KeyLibrary

    init(
        deviceID: UUID,
        keyStore: any AppKeyStore,
        initialKeys: [SSHKeyInfo],
        secureEnclaveAvailable: Bool,
        hostKeys: any HostKeyStore,
        defaults: UserDefaults,
        serversFile: JSONFileStore<[ServerConfig]>
    ) throws {
        self.deviceID = deviceID
        self.keyStore = keyStore
        self.hostKeys = hostKeys
        self.defaults = defaults
        let log = DiagnosticsLog()
        self.log = log
        pool = ConnectionPool(transport: CitadelTransport(log: log), hostKeys: hostKeys, deviceID: deviceID, log: log)
        bootstrap = try HostBootstrap()
        servers = try ServerStore(file: serversFile, pool: pool, hostKeys: hostKeys)
        keys = KeyLibrary(store: keyStore, keys: initialKeys, servers: servers, secureEnclaveAvailable: secureEnclaveAvailable)
    }

    /// Keychain, Secure Enclave и JSON в Application Support. Ошибка — экран `StartupErrorView`.
    static func live() throws -> AppEnvironment {
        let keyStore = KeychainKeyStore()
        return try AppEnvironment(
            deviceID: try DeviceIdentity.load(),
            keyStore: keyStore,
            initialKeys: try keyStore.list(),
            secureEnclaveAvailable: SecureEnclave.isAvailable,
            hostKeys: KeychainHostKeyStore(),
            defaults: .standard,
            serversFile: JSONFileStore(fileName: "servers.json")
        )
    }

    /// Хранилища в памяти, JSON во временном каталоге (или в `directory`), свежий `UserDefaults`.
    /// Для `AppTests` и `-uitest-inmemory`; сеть настоящая.
    static func inMemory(directory: URL? = nil) throws -> AppEnvironment {
        let directory = directory ?? FileManager.default.temporaryDirectory
            .appending(path: "tmuxpad-\(UUID().uuidString)", directoryHint: .isDirectory)
        return try AppEnvironment(
            deviceID: UUID(),
            keyStore: InMemoryKeyStore(),
            initialKeys: [],
            secureEnclaveAvailable: false,
            hostKeys: InMemoryHostKeyStore(),
            defaults: UserDefaults(suiteName: "dev.tmuxpad.test.\(UUID().uuidString)")!,
            serversFile: JSONFileStore(fileName: "servers.json", directory: directory)
        )
    }

    /// Ключ сервера из хранилища; нет ключа — `AppError.keyMissing`.
    func auth(for config: ServerConfig) async throws -> SSHAuth {
        guard let key = try await keyStore.privateKey(for: config.keyID) else {
            throw AppError.keyMissing(config.keyID)
        }
        return .privateKey(key, user: config.user)
    }
}

extension EnvironmentValues {
    @Entry var appEnvironment: AppEnvironment?
}

extension View {
    /// Окружение и его `@Observable`-модели.
    func appEnvironment(_ env: AppEnvironment) -> some View {
        environment(\.appEnvironment, env)
            .environment(env.servers)
            .environment(env.keys)
    }
}
