import Foundation

/// Состояние соединения с сервером для UI и журнала (§6).
public enum ConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case connected(since: Date)
    /// Попытка `attempt` из `PoolSettings.backoff`, считая с 1.
    case reconnecting(attempt: Int)
    /// Попытки кончились или ошибка не лечится повтором; ждёт `reconnectNow()`.
    case failed(String)

    public var isConnected: Bool {
        if case .connected = self { true } else { false }
    }
}
