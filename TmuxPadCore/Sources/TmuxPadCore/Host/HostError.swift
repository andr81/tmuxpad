import Foundation

/// Ошибки подкоманд host-скрипта: коды выхода §7 и разбор вывода.
public enum HostError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Шелл не нашёл или не смог запустить скрипт (127, 126).
    case scriptMissing
    /// Код 2: аргументы, имена или окружение; текст — stderr.
    case badRequest(String)
    /// Код 3 у `new`.
    case sessionExists
    /// Код 4 у `attach`/`take`.
    case noSession
    /// Код 2 у `list`.
    case projectsRootMissing
    case failed(code: Int, stderr: String)
    /// Вывод не разобрался.
    case badOutput(String)

    public static func from(command: HostCommand, exitCode: Int, stderr: String) -> HostError {
        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        switch exitCode {
        case 126, 127:
            return .scriptMissing
        case 2:
            if case .list = command {
                return .projectsRootMissing
            }
            return .badRequest(message)
        case 3:
            return .sessionExists
        case 4:
            return .noSession
        default:
            return .failed(code: exitCode, stderr: message)
        }
    }

    public var description: String {
        switch self {
        case .scriptMissing:
            "The host script is not installed on the server."
        case let .badRequest(message):
            message.isEmpty ? "The server rejected the request." : "The server rejected the request: \(message)"
        case .sessionExists:
            "A session with this name already exists."
        case .noSession:
            "The session no longer exists."
        case .projectsRootMissing:
            "The projects folder does not exist on the server."
        case let .failed(code, stderr):
            stderr.isEmpty ? "The command failed with exit code \(code)." : "The command failed with exit code \(code): \(stderr)"
        case let .badOutput(message):
            "Unexpected output from the server: \(message)"
        }
    }
}

/// Ошибки транспорта SSH.
public enum SSHError: Error, Equatable, Sendable, CustomStringConvertible {
    case connectFailed(String)
    case authFailed
    case hostKeyChanged(expected: String, actual: String)
    /// Сервер не открыл канал — предел `MaxSessions`.
    case channelRefused
    case timeout
    case disconnected

    public var description: String {
        switch self {
        case let .connectFailed(message):
            "Could not connect: \(message)"
        case .authFailed:
            "The server did not accept the key."
        case let .hostKeyChanged(expected, actual):
            "The server host key has changed (expected \(expected), got \(actual))."
        case .channelRefused:
            "The server refused to open another channel."
        case .timeout:
            "The server did not respond in time."
        case .disconnected:
            "The connection was lost."
        }
    }
}
