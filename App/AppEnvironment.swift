import CryptoKit
import Foundation
import SwiftUI
import TmuxPadCore

enum AppError: Error, Equatable {
    /// У сервера `keyID`, которого нет в хранилище ключей.
    case keyMissing(UUID)
    /// Сервер удалили, пока шло действие.
    case serverMissing
    /// Отпечаток хост-ключа не подтверждён: подключение сохранило бы его без «Доверять» (§8).
    case hostKeyUnconfirmed
    /// «Создать заново»: проекта сессии нет в последнем снимке сервера.
    case projectNotFound(String)
    /// «Создать заново»: проект сессии неизвестен — её не было в снимке, когда её открыли.
    case projectUnknown
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
    let diagnostics: DiagnosticsModel
    let refresher: TreeRefresher
    let openSessions: OpenSessionsModel
    let tree: TreeModel
    let actions: SessionActions

    init(
        deviceID: UUID,
        keyStore: any AppKeyStore,
        initialKeys: [SSHKeyInfo],
        secureEnclaveAvailable: Bool,
        hostKeys: any HostKeyStore,
        defaults: UserDefaults,
        serversFile: JSONFileStore<[ServerConfig]>,
        treeInterval: Duration = .seconds(10)
    ) throws {
        self.deviceID = deviceID
        self.keyStore = keyStore
        self.hostKeys = hostKeys
        self.defaults = defaults
        let log = DiagnosticsLog()
        self.log = log
        diagnostics = DiagnosticsModel(log: log)
        pool = ConnectionPool(transport: CitadelTransport(log: log), hostKeys: hostKeys, deviceID: deviceID, log: log)
        bootstrap = try HostBootstrap()
        servers = try ServerStore(file: serversFile, pool: pool, hostKeys: hostKeys)
        keys = KeyLibrary(store: keyStore, keys: initialKeys, servers: servers, secureEnclaveAvailable: secureEnclaveAvailable)
        refresher = TreeRefresher(
            pool: pool,
            bootstrap: bootstrap,
            auth: { config in try await Self.auth(for: config, keyStore: keyStore) },
            interval: treeInterval
        )
        openSessions = OpenSessionsModel()
        tree = TreeModel(refresher: refresher, openSessions: openSessions, defaults: defaults)
        actions = SessionActions(
            servers: servers,
            pool: pool,
            auth: { config in try await Self.auth(for: config, keyStore: keyStore) },
            openSessions: openSessions,
            tree: tree
        )
        let dependencies = OpenTerminal.Dependencies(
            connection: { [unowned actions = self.actions] in try await actions.terminalConnection(serverID: $0) },
            snapshot: { [unowned tree = self.tree] in tree.states[$0]?.snapshot },
            log: log,
            defaults: defaults
        )
        openSessions.makeTerminal = { OpenTerminal(key: $0, dependencies: dependencies) }
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
    static func inMemory(directory: URL? = nil, treeInterval: Duration = .seconds(10)) throws -> AppEnvironment {
        let directory = directory ?? FileManager.default.temporaryDirectory
            .appending(path: "tmuxpad-\(UUID().uuidString)", directoryHint: .isDirectory)
        return try AppEnvironment(
            deviceID: UUID(),
            keyStore: InMemoryKeyStore(),
            initialKeys: [],
            secureEnclaveAvailable: false,
            hostKeys: InMemoryHostKeyStore(),
            defaults: UserDefaults(suiteName: "dev.tmuxpad.test.\(UUID().uuidString)")!,
            serversFile: JSONFileStore(fileName: "servers.json", directory: directory),
            treeInterval: treeInterval
        )
    }

    /// Ключ сервера из хранилища; нет ключа — `AppError.keyMissing`.
    func auth(for config: ServerConfig) async throws -> SSHAuth {
        try await Self.auth(for: config, keyStore: keyStore)
    }

    /// Без `self`: `TreeRefresher` создаётся в `init`, до готовности окружения.
    private nonisolated static func auth(for config: ServerConfig, keyStore: any AppKeyStore) async throws -> SSHAuth {
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
            .environment(env.diagnostics)
            .environment(env.tree)
            .environment(env.openSessions)
    }
}
