import Foundation
import Observation
import TmuxPadCore

/// События журнала для экрана «Диагностика». Живёт в `AppEnvironment` всё время работы приложения.
@MainActor
@Observable
final class DiagnosticsModel {
    /// От старых к новым, не больше `capacity`.
    private(set) var events: [DiagnosticsEvent] = []

    @ObservationIgnored let capacity: Int
    @ObservationIgnored private var subscription: Task<Void, Never>?

    /// Единственный потребитель `log.updates`: поток буферизует события с создания журнала
    /// (`bufferingNewest(capacity)`), поэтому отдельный снимок `log.events()` не нужен — он
    /// задвоил бы события, записанные до старта подписки.
    init(log: DiagnosticsLog, capacity: Int = DiagnosticsLog.defaultCapacity) {
        self.capacity = capacity
        subscription = Task { [weak self] in
            for await event in log.updates {
                guard let self else { return }
                self.append(event)
            }
        }
    }

    deinit {
        subscription?.cancel()
    }

    /// Метки серверов из журнала, по алфавиту.
    var servers: [String] {
        Set(events.map(\.server)).sorted()
    }

    /// События сервера или все (`nil`), от новых к старым.
    func newestFirst(server: String? = nil) -> [DiagnosticsEvent] {
        events.reversed().filter { server == nil || $0.server == server }
    }

    /// Текст для «Поделиться», формат `DiagnosticsLog.export()`: от старых к новым.
    func exportText(server: String? = nil) -> String {
        events
            .filter { server == nil || $0.server == server }
            .map(Self.format)
            .joined(separator: "\n")
    }

    private func append(_ event: DiagnosticsEvent) {
        events.append(event)
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
    }

    private static func format(_ event: DiagnosticsEvent) -> String {
        let message = event.message
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        return "\(event.date.formatted(.iso8601)) \(event.server) \(event.kind.rawValue) \(message)"
    }
}
