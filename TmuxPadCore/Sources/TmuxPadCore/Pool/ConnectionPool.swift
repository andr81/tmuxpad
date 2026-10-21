import Foundation

/// Одно `ServerConnection` на сервер (§5) и общие действия жизненного цикла (§6).
public actor ConnectionPool {
    public nonisolated let log: DiagnosticsLog
    public nonisolated let deviceID: UUID

    private let transport: any SSHTransport
    private let hostKeys: any HostKeyStore
    private let settings: @Sendable (ServerConfig) -> PoolSettings
    /// Передаётся каждому `ServerConnection`: приложение держит им реконнект с закрытым ключом.
    private let reconnectGate: (@Sendable () async throws -> Void)?
    private var entries: [UUID: (config: ServerConfig, connection: ServerConnection)] = [:]

    public init(
        transport: any SSHTransport,
        hostKeys: any HostKeyStore,
        deviceID: UUID,
        log: DiagnosticsLog = DiagnosticsLog(),
        settings: @escaping @Sendable (ServerConfig) -> PoolSettings = { PoolSettings(config: $0) },
        reconnectGate: (@Sendable () async throws -> Void)? = nil
    ) {
        self.transport = transport
        self.hostKeys = hostKeys
        self.deviceID = deviceID
        self.log = log
        self.settings = settings
        self.reconnectGate = reconnectGate
    }

    /// Соединение сервера, без подключения. Сменились адрес, порт, пользователь или ключ —
    /// старое отключается и создаётся новое; прочие поля конфига обновляются на месте.
    public func connection(for config: ServerConfig, auth: SSHAuth) async -> ServerConnection {
        if let entry = entries[config.id] {
            if !Self.needsNewConnection(entry.config, config) {
                if entry.config != config {
                    entries[config.id] = (config, entry.connection)
                    await entry.connection.update(config: config, settings: settings(config))
                }
                return entry.connection
            }
        }
        let old = entries[config.id]?.connection
        let connection = ServerConnection(
            config: config,
            deviceID: deviceID,
            transport: transport,
            auth: auth,
            hostKeys: hostKeys,
            settings: settings(config),
            log: log,
            reconnectGate: reconnectGate
        )
        entries[config.id] = (config, connection)
        await old?.disconnect()
        return connection
    }

    /// Уже созданное соединение сервера.
    public func existing(id: UUID) -> ServerConnection? {
        entries[id]?.connection
    }

    /// Сервер удалён из списка.
    public func remove(id: UUID) async {
        guard let entry = entries.removeValue(forKey: id) else {
            return
        }
        await entry.connection.disconnect()
    }

    /// Уход в фон: iPadOS всё равно порвёт сокеты.
    public func disconnectAll() async {
        let connections = entries.values.map(\.connection)
        await withTaskGroup(of: Void.self) { group in
            for connection in connections {
                group.addTask { await connection.disconnect() }
            }
        }
    }

    /// Немедленная попытка со сбросом бэкоффа: возврат из фона (`force == false`, живые
    /// соединения не трогаются) или смена сети (`force == true`, рвутся и живые).
    public func reconnectAll(force: Bool = false) async {
        let connections = entries.values.map(\.connection)
        await withTaskGroup(of: Void.self) { group in
            for connection in connections {
                group.addTask { await connection.reconnectNow(force: force) }
            }
        }
    }

    static func needsNewConnection(_ old: ServerConfig, _ new: ServerConfig) -> Bool {
        old.host != new.host || old.port != new.port || old.user != new.user || old.keyID != new.keyID
    }
}
