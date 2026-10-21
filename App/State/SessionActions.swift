import Foundation
import TmuxPadCore
import UIKit

/// Действия над сессией (§3.2): контекст-меню и свайп сайдбара, а в плане 6 — меню `[⋯]` над
/// терминалом вызывают одно и то же. Подтверждения — в UI.
@MainActor
final class SessionActions {
    private let servers: ServerStore
    private let pool: ConnectionPool
    private let auth: @Sendable (ServerConfig) async throws -> SSHAuth
    private let openSessions: OpenSessionsModel
    private let tree: TreeModel

    init(
        servers: ServerStore,
        pool: ConnectionPool,
        auth: @escaping @Sendable (ServerConfig) async throws -> SSHAuth,
        openSessions: OpenSessionsModel,
        tree: TreeModel
    ) {
        self.servers = servers
        self.pool = pool
        self.auth = auth
        self.openSessions = openSessions
        self.tree = tree
    }

    /// Обычный `attach` (§6.1).
    func open(_ key: OpenSessionKey) {
        openSessions.open(key)
    }

    /// «Забрать» — единственный путь к `take` (§6.1).
    func take(_ key: OpenSessionKey) {
        openSessions.open(key, take: true)
    }

    /// «Отключиться»: сессия на сервере остаётся.
    func detach(_ key: OpenSessionKey) {
        openSessions.close(key)
    }

    /// `kill` на сервере; сессии, которой уже нет, — не ошибка. Затем закрытие и перечитывание
    /// дерева. Сервер удалили — только закрытие.
    func kill(_ key: OpenSessionKey) async throws {
        if let config = servers.server(id: key.serverID) {
            do {
                try await api(for: config).kill(session: key.name)
            } catch HostError.noSession {
            } catch AppError.serverMissing {
            }
        }
        openSessions.close(key)
        await tree.refreshAfterAction(serverID: key.serverID)
    }

    /// `new` на сервере, затем перечитывание дерева и открытие (§3.3). Имя занято —
    /// `HostError.sessionExists`; сервер удалили — `AppError.serverMissing`.
    func create(_ key: OpenSessionKey, project: String) async throws {
        guard let config = servers.server(id: key.serverID) else {
            throw AppError.serverMissing
        }
        try await api(for: config).new(session: key.name, project: project)
        await tree.refreshAfterAction(serverID: key.serverID)
        guard servers.server(id: key.serverID) != nil else {
            throw AppError.serverMissing
        }
        openSessions.open(key)
    }

    private func api(for config: ServerConfig) async throws -> HostAPI {
        // как в `TreeRefresher`: без подтверждённого отпечатка ядро сохранило бы ключ молча (§8)
        guard config.hostKeyFingerprint != nil else {
            throw AppError.hostKeyUnconfirmed
        }
        let credentials = try await auth(config)
        // пока ждали ключ, сервер могли удалить: `pool.connection` вернул бы его в пул
        guard servers.server(id: config.id) != nil else {
            throw AppError.serverMissing
        }
        let connection = await pool.connection(for: config, auth: credentials)
        // `connect()` не из `.disconnected` начал бы новую эпоху, как в `TreeRefresher`
        if await connection.state == .disconnected {
            try await connection.connect()
        }
        // удалили во время `pool.connection` или `connect()`: убрать соединение, как в `TreeRefresher`
        guard servers.server(id: config.id) != nil else {
            await pool.remove(id: config.id)
            throw AppError.serverMissing
        }
        return await connection.api
    }

    /// Для ручного входа с Mac; без `-d`, чтобы не выкинуть iPad. Имя пришло из `list`
    /// сервера, поэтому `'` внутри экранируется: команду вставят в шелл.
    func attachCommand(_ key: OpenSessionKey) -> String {
        "tmux attach -t '=\(key.name.replacingOccurrences(of: "'", with: #"'\''"#))'"
    }

    func copyAttachCommand(_ key: OpenSessionKey) {
        UIPasteboard.general.string = attachCommand(key)
    }
}
