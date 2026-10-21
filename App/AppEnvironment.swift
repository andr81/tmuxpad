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
    /// Face ID для ключа не пройден (§8).
    case biometricsDenied
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
    let appearance: TerminalAppearance
    let security: SecurityPreferences
    let unlocker: any KeyUnlocking
    let navigation = AppNavigation()
    let lifecycle: LifecycleCoordinator
    /// Запускается только в `live()`: тесты сеть не слушают.
    let network = NetworkMonitor()

    init(
        deviceID: UUID,
        keyStore: any AppKeyStore,
        initialKeys: [SSHKeyInfo],
        secureEnclaveAvailable: Bool,
        hostKeys: any HostKeyStore,
        defaults: UserDefaults,
        serversFile: JSONFileStore<[ServerConfig]>,
        treeInterval: Duration = .seconds(10),
        biometricPrompt: any BiometricPrompt = DeviceOwnerPrompt()
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
        security = SecurityPreferences(defaults: defaults)
        let cache = KeyCache()
        // `UserDefaults` потокобезопасен, но не помечен `Sendable`
        nonisolated(unsafe) let settings = defaults
        let relay = UnlockRelay()
        let unlocker = KeyUnlocker(
            prompt: biometricPrompt,
            isRequired: { settings.bool(forKey: SecuritySettings.requireBiometricsKey) },
            onLock: { await cache.clear() },
            onUnlock: { await relay.keyUnlocked() }
        )
        self.unlocker = unlocker
        let auth: @Sendable (ServerConfig) async throws -> SSHAuth = { config in
            try await Self.auth(for: config, keyStore: keyStore, cache: cache, unlocker: unlocker)
        }
        authorize = auth
        servers = try ServerStore(file: serversFile, pool: pool, hostKeys: hostKeys)
        keys = KeyLibrary(store: keyStore, keys: initialKeys, servers: servers, secureEnclaveAvailable: secureEnclaveAvailable)
        refresher = TreeRefresher(
            pool: pool,
            bootstrap: bootstrap,
            auth: auth,
            interval: treeInterval
        )
        openSessions = OpenSessionsModel()
        tree = TreeModel(refresher: refresher, openSessions: openSessions, defaults: defaults)
        actions = SessionActions(
            servers: servers,
            pool: pool,
            auth: auth,
            openSessions: openSessions,
            tree: tree
        )
        appearance = TerminalAppearance(defaults: defaults)
        lifecycle = LifecycleCoordinator(targets: AppLifecycleTargets(pool: pool, tree: tree), log: log, unlocker: unlocker)
        relay.coordinator = lifecycle
        // слабые: задача `start` терминала может пережить окружение (так бывает в `AppTests`)
        let dependencies = OpenTerminal.Dependencies(
            connection: { [weak actions = self.actions] in
                guard let actions else {
                    throw AppError.serverMissing
                }
                return try await actions.terminalConnection(serverID: $0)
            },
            snapshot: { [weak tree = self.tree] in tree?.states[$0]?.snapshot },
            log: log,
            appearance: appearance,
            unlock: { [weak lifecycle = self.lifecycle] in await lifecycle?.unlock() ?? false }
        )
        openSessions.makeTerminal = { OpenTerminal(key: $0, dependencies: dependencies) }
        network.onChange = { [weak lifecycle] old, new in
            lifecycle?.networkChanged("\(old.summary) → \(new.summary)")
        }
    }

    /// Keychain, Secure Enclave и JSON в Application Support. Ошибка — экран `StartupErrorView`.
    static func live() throws -> AppEnvironment {
        let keyStore = KeychainKeyStore()
        let env = try AppEnvironment(
            deviceID: try DeviceIdentity.load(),
            keyStore: keyStore,
            initialKeys: try keyStore.list(),
            secureEnclaveAvailable: SecureEnclave.isAvailable,
            hostKeys: KeychainHostKeyStore(),
            defaults: .standard,
            serversFile: JSONFileStore(fileName: "servers.json")
        )
        env.network.start()
        let persistence = OpenSessionsPersistence(defaults: env.defaults)
        env.lifecycle.onLaunch = { [weak env] in
            guard let env else {
                return
            }
            persistence.restore(into: env.openSessions, knownServers: Set(env.servers.servers.map(\.id)))
            // до восстановления пустой ростер не затирает сохранённый; сохранение сразу
            // отбрасывает сессии удалённых серверов
            env.openSessions.onRosterChange = { persistence.save(roster: $0, selection: $1) }
            persistence.save(roster: env.openSessions.roster, selection: env.openSessions.selection)
        }
        return env
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

    /// Ключ сервера: сначала Face ID, если он включён (решение 6 плана 7), потом кеш или
    /// хранилище; нет ключа — `AppError.keyMissing`.
    private let authorize: @Sendable (ServerConfig) async throws -> SSHAuth

    func auth(for config: ServerConfig) async throws -> SSHAuth {
        try await authorize(config)
    }

    /// Без `self`: `TreeRefresher` создаётся в `init`, до готовности окружения.
    private nonisolated static func auth(
        for config: ServerConfig,
        keyStore: any AppKeyStore,
        cache: KeyCache,
        unlocker: any KeyUnlocking
    ) async throws -> SSHAuth {
        try await unlocker.authenticate()
        if let key = await cache.key(config.keyID) {
            return .privateKey(key, user: config.user)
        }
        guard let key = try await keyStore.privateKey(for: config.keyID) else {
            throw AppError.keyMissing(config.keyID)
        }
        await cache.store(key, for: config.keyID)
        return .privateKey(key, user: config.user)
    }
}

/// `KeyUnlocker` создаётся раньше координатора: пройденный Face ID доходит до него через ссылку.
@MainActor
private final class UnlockRelay {
    weak var coordinator: LifecycleCoordinator?

    func keyUnlocked() {
        coordinator?.keyUnlocked()
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
            .environment(env.appearance)
            .environment(env.security)
            .environment(env.navigation)
    }
}
