import Foundation

/// Интервалы и пределы пула (§5, §6). `Duration`, чтобы юнит-тесты задавали миллисекунды.
public struct PoolSettings: Sendable, Equatable {
    /// Период exec-пинга `true`.
    public var keepalive: Duration
    /// Сколько ждать ответа на пинг.
    public var pingTimeout: Duration
    /// Ожидания перед попытками реконнекта; после последней — `.failed`.
    public var backoff: [Duration]
    public var connectTimeout: Duration
    /// Одновременных exec-каналов на соединение.
    public var execSlots: Int
    /// PTY-каналов на соединение; `execSlots + ptySlots` не больше `MaxSessions` (10).
    public var ptySlots: Int
    public var execTimeout: Duration

    public init(
        keepalive: Duration = .seconds(15),
        pingTimeout: Duration = .seconds(5),
        backoff: [Duration] = [.seconds(1), .seconds(2), .seconds(5), .seconds(10)],
        connectTimeout: Duration = .seconds(15),
        execSlots: Int = 2,
        ptySlots: Int = 8,
        execTimeout: Duration = .seconds(20)
    ) {
        self.keepalive = keepalive
        self.pingTimeout = pingTimeout
        self.backoff = backoff
        self.connectTimeout = connectTimeout
        self.execSlots = execSlots
        self.ptySlots = ptySlots
        self.execTimeout = execTimeout
    }

    /// Значения по умолчанию, keepalive — из конфига сервера.
    public init(config: ServerConfig) {
        self.init(keepalive: .seconds(max(1, config.keepaliveSeconds)))
    }
}
