import Foundation
import Observation
import TmuxPadCore

/// Список серверов в `servers.json`; файл переписывается после каждой правки. Ошибка записи —
/// исключение, а `servers` остаётся прежним.
@MainActor
@Observable
final class ServerStore {
    /// По `sortIndex`.
    private(set) var servers: [ServerConfig]

    @ObservationIgnored private let file: JSONFileStore<[ServerConfig]>
    @ObservationIgnored private let pool: ConnectionPool
    @ObservationIgnored private let hostKeys: any HostKeyStore

    /// Битый `servers.json` — ошибка: молча начать с пустого списка значит потерять его при
    /// первой правке.
    init(file: JSONFileStore<[ServerConfig]>, pool: ConnectionPool, hostKeys: any HostKeyStore) throws {
        self.file = file
        self.pool = pool
        self.hostKeys = hostKeys
        servers = (try file.load() ?? []).sorted { $0.sortIndex < $1.sortIndex }
    }

    func server(id: UUID) -> ServerConfig? {
        servers.first { $0.id == id }
    }

    /// В конец списка.
    func add(_ config: ServerConfig) throws {
        var config = config
        config.sortIndex = (servers.map(\.sortIndex).max() ?? -1) + 1
        try commit(servers + [config])
    }

    func update(_ config: ServerConfig) throws {
        guard let index = servers.firstIndex(where: { $0.id == config.id }) else {
            return
        }
        var updated = servers
        updated[index] = config
        try commit(updated)
    }

    /// Копия сразу после оригинала, без отпечатка: доверие подтверждается заново.
    @discardableResult
    func duplicate(_ config: ServerConfig) throws -> ServerConfig {
        var copy = config
        copy.id = UUID()
        copy.label = "\(config.label) копия"
        copy.hostKeyFingerprint = nil
        var updated = servers
        let index = updated.firstIndex { $0.id == config.id }.map { $0 + 1 } ?? updated.endIndex
        updated.insert(copy, at: index)
        try commit(renumbered(updated))
        return copy
    }

    /// Убирает сервер из списка и пула. Доверенный отпечаток `host:port` сбрасывается, если
    /// других серверов с тем же адресом не осталось: запись в `HostKeyStore` у них общая.
    func delete(id: UUID) async throws {
        guard let config = server(id: id) else {
            return
        }
        try commit(servers.filter { $0.id != id })
        await pool.remove(id: id)
        if !servers.contains(where: { $0.host == config.host && $0.port == config.port }) {
            try await hostKeys.reset(host: config.host, port: config.port)
        }
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) throws {
        var updated = servers
        updated.move(fromOffsets: source, toOffset: destination)
        try commit(renumbered(updated))
    }

    /// Русские тексты для формы: проверки ядра, пустая метка, неизвестный ключ.
    func issues(for config: ServerConfig, keys: [SSHKeyInfo]) -> [String] {
        var issues: [String] = []
        if config.label.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append("Укажите название")
        }
        issues += config.validationIssues().map(serverIssueText)
        if !keys.contains(where: { $0.id == config.keyID }) {
            issues.append("Выберите ключ")
        }
        return issues
    }

    private func renumbered(_ list: [ServerConfig]) -> [ServerConfig] {
        list.enumerated().map { index, config in
            var config = config
            config.sortIndex = index
            return config
        }
    }

    private func commit(_ list: [ServerConfig]) throws {
        try file.save(list)
        servers = list
    }
}
