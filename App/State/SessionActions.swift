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
            let connection = await pool.connection(for: config, auth: try await auth(config))
            // `connect()` не из `.disconnected` начал бы новую эпоху, как в `TreeRefresher`
            if await connection.state == .disconnected {
                try await connection.connect()
            }
            do {
                try await connection.api.kill(session: key.name)
            } catch HostError.noSession {
            }
        }
        openSessions.close(key)
        await tree.refresh(serverID: key.serverID)
    }

    /// Для ручного входа с Mac; без `-d`, чтобы не выкинуть iPad. Имя прошло валидацию,
    /// одинарные кавычки его не ломают.
    func attachCommand(_ key: OpenSessionKey) -> String {
        "tmux attach -t '=\(key.name)'"
    }

    func copyAttachCommand(_ key: OpenSessionKey) {
        UIPasteboard.general.string = attachCommand(key)
    }
}
