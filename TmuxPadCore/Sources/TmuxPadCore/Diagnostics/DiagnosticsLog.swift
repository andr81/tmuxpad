import Foundation

/// Событие журнала диагностики (§3.6). Без секретов и без байтов терминала.
public struct DiagnosticsEvent: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case connect
        case disconnect
        case reconnect
        case ping
        case exec
        case terminal
        case hostKey
        case error
    }

    public var date: Date
    /// Метка сервера.
    public var server: String
    public var kind: Kind
    public var message: String

    public init(date: Date = Date(), server: String, kind: Kind, message: String) {
        self.date = date
        self.server = server
        self.kind = kind
        self.message = message
    }
}

/// Кольцевой журнал последних событий для экрана «Диагностика» и «Поделиться».
public actor DiagnosticsLog {
    public static let defaultCapacity = 2000

    public let capacity: Int
    /// Живой поток новых событий; один потребитель.
    public nonisolated let updates: AsyncStream<DiagnosticsEvent>

    private let continuation: AsyncStream<DiagnosticsEvent>.Continuation
    private var buffer: [DiagnosticsEvent] = []
    /// Индекс самого старого события, когда буфер заполнен.
    private var head = 0

    public init(capacity: Int = DiagnosticsLog.defaultCapacity) {
        precondition(capacity > 0, "capacity must be positive")
        self.capacity = capacity
        (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(capacity))
    }

    deinit {
        continuation.finish()
    }

    public func record(_ event: DiagnosticsEvent) {
        if buffer.count < capacity {
            buffer.append(event)
        } else {
            buffer[head] = event
            head = (head + 1) % capacity
        }
        continuation.yield(event)
    }

    public func record(server: String, kind: DiagnosticsEvent.Kind, _ message: String) {
        record(DiagnosticsEvent(server: server, kind: kind, message: message))
    }

    /// События от старых к новым.
    public func events() -> [DiagnosticsEvent] {
        Array(buffer[head...] + buffer[..<head])
    }

    /// Одна строка на событие: `<ISO-8601> <сервер> <вид> <сообщение>`.
    public func export() -> String {
        events().map(Self.format).joined(separator: "\n")
    }

    static func format(_ event: DiagnosticsEvent) -> String {
        let message = event.message
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        return "\(event.date.formatted(.iso8601)) \(event.server) \(event.kind.rawValue) \(message)"
    }
}
