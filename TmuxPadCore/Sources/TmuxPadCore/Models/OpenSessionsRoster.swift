import Foundation

/// Открытая в приложении сессия: сервер и имя tmux-сессии.
public struct OpenSessionKey: Hashable, Codable, Sendable {
    public var serverID: UUID
    public var name: String

    public init(serverID: UUID, name: String) {
        self.serverID = serverID
        self.name = name
    }
}

/// Открытые терминалы всего приложения (§5): порядок вкладок для `⌘1…⌘9` и восстановления,
/// давность активации для вытеснения сверх `limit`. Значение, а не актор: модель приложения
/// живёт на main и держит его у себя.
///
/// Давность — монотонный счётчик, а не `Date`: тесты детерминированы, `Codable` не тащит часы.
/// В JSON попадают `tabs` и порядок давности; `limit` не пишется, чтобы сохранённое значение
/// не перебило новое умолчание.
public struct OpenSessionsRoster: Codable, Sendable, Equatable {
    public static let defaultLimit = 8

    public let limit: Int
    /// В порядке открытия.
    public private(set) var tabs: [OpenSessionKey] = []
    private var recency: [OpenSessionKey: Int] = [:]
    private var clock = 0

    public init(limit: Int = OpenSessionsRoster.defaultLimit) {
        precondition(limit >= 1, "roster limit must be at least 1")
        self.limit = limit
    }

    /// Последняя активированная вкладка.
    public var active: OpenSessionKey? {
        recency.max { $0.value < $1.value }?.key
    }

    /// Открывает (или активирует уже открытый) и возвращает вытесненных: самые давно неактивные,
    /// кроме только что открытого, пока вкладок больше `limit`. Их надо отключить (`detach`).
    public mutating func open(_ key: OpenSessionKey) -> [OpenSessionKey] {
        if !tabs.contains(key) {
            tabs.append(key)
        }
        touch(key)
        return evictOverLimit(keeping: key)
    }

    /// Для ключа, которого нет во вкладках, ничего не делает.
    public mutating func activate(_ key: OpenSessionKey) {
        guard tabs.contains(key) else { return }
        touch(key)
    }

    public mutating func close(_ key: OpenSessionKey) {
        tabs.removeAll { $0 == key }
        recency[key] = nil
    }

    /// Сервер удалили — закрываются все его вкладки.
    public mutating func close(serverID: UUID) {
        for key in tabs where key.serverID == serverID {
            close(key)
        }
    }

    /// `index` 1-based, как `⌘1…⌘9`.
    public func tab(at index: Int) -> OpenSessionKey? {
        tabs.indices.contains(index - 1) ? tabs[index - 1] : nil
    }

    /// Следующая вкладка по кругу (`⌘]`); для неизвестного ключа — первая.
    public func next(after key: OpenSessionKey) -> OpenSessionKey? {
        guard let index = tabs.firstIndex(of: key) else { return tabs.first }
        return tabs[(index + 1) % tabs.count]
    }

    /// Предыдущая вкладка по кругу (`⌘[`); для неизвестного ключа — последняя.
    public func previous(before key: OpenSessionKey) -> OpenSessionKey? {
        guard let index = tabs.firstIndex(of: key) else { return tabs.last }
        return tabs[(index + tabs.count - 1) % tabs.count]
    }

    private mutating func touch(_ key: OpenSessionKey) {
        clock += 1
        recency[key] = clock
    }

    private mutating func evictOverLimit(keeping kept: OpenSessionKey?) -> [OpenSessionKey] {
        var evicted: [OpenSessionKey] = []
        while tabs.count > limit {
            let oldest = tabs
                .filter { $0 != kept }
                .min { (recency[$0] ?? 0) < (recency[$1] ?? 0) }
            guard let oldest else { break }
            close(oldest)
            evicted.append(oldest)
        }
        return evicted
    }

    /// От давно неактивного к последнему активированному.
    private var recencyOrder: [OpenSessionKey] {
        recency.sorted { $0.value < $1.value }.map(\.key)
    }

    /// Значения счётчика не сравниваются: важен только порядок давности.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.limit == rhs.limit && lhs.tabs == rhs.tabs && lhs.recencyOrder == rhs.recencyOrder
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case tabs
        /// От давно неактивного к последнему активированному.
        case recency
    }

    /// Дубликаты в `tabs` и давность ключей вне `tabs` отбрасываются; вкладки без давности
    /// считаются самыми старыми. Если вкладок больше `limit`, лишние давно неактивные выпадают.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        for key in try container.decode([OpenSessionKey].self, forKey: .tabs) where !tabs.contains(key) {
            tabs.append(key)
        }
        let order = try container.decodeIfPresent([OpenSessionKey].self, forKey: .recency) ?? []
        for key in tabs where !order.contains(key) {
            touch(key)
        }
        for key in order where tabs.contains(key) {
            touch(key)
        }
        _ = evictOverLimit(keeping: nil)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tabs, forKey: .tabs)
        try container.encode(recencyOrder, forKey: .recency)
    }
}
