import Foundation
import Network

/// Снимок пути `NWPathMonitor`: доступна ли сеть и через какие типы интерфейсов.
struct PathSnapshot: Equatable, Sendable {
    var satisfied: Bool
    /// `wifi`, `cellular`, `wiredEthernet`, `loopback`, `other`.
    var interfaces: Set<String>

    init(satisfied: Bool, interfaces: Set<String>) {
        self.satisfied = satisfied
        self.interfaces = interfaces
    }

    init(_ path: NWPath) {
        satisfied = path.status == .satisfied
        interfaces = Set(path.availableInterfaces.map { Self.name($0.type) })
    }

    /// Для журнала: `wifi`, `cellular+wifi`, `none`.
    var summary: String {
        satisfied && !interfaces.isEmpty ? interfaces.sorted().joined(separator: "+") : "none"
    }

    private static func name(_ type: NWInterface.InterfaceType) -> String {
        switch type {
        case .wifi: "wifi"
        case .cellular: "cellular"
        case .wiredEthernet: "wiredEthernet"
        case .loopback: "loopback"
        case .other: "other"
        @unknown default: "other"
        }
    }
}

/// Сеть сменилась, если путь стал доступен или при доступном сменился набор интерфейсов
/// (Wi-Fi ↔ сотовая). Пропажа сети — не смена: keepalive и так похоронит соединение.
func networkChanged(from old: PathSnapshot, to new: PathSnapshot) -> Bool {
    new.satisfied && (!old.satisfied || old.interfaces != new.interfaces)
}

/// `NWPathMonitor` на своей очереди. Первый снимок после `start` — точка отсчёта, не событие;
/// снимки сглаживаются дребезгом `debounce`, событие — сравнение с прошлым устоявшимся.
@MainActor
final class NetworkMonitor {
    /// Прошлый и новый устоявшийся снимок.
    var onChange: ((PathSnapshot, PathSnapshot) -> Void)?

    private let debounce: Duration
    private var monitor: NWPathMonitor?
    private var settled: PathSnapshot?
    private var pending: Task<Void, Never>?

    init(debounce: Duration = .seconds(1)) {
        self.debounce = debounce
    }

    func start() {
        guard monitor == nil else {
            return
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let snapshot = PathSnapshot(path)
            Task { @MainActor in self?.receive(snapshot) }
        }
        monitor.start(queue: DispatchQueue(label: "dev.tmuxpad.network"))
        self.monitor = monitor
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        pending?.cancel()
        pending = nil
        settled = nil
    }

    /// Снимок пути; отдельно от `NWPathMonitor` — для тестов.
    func receive(_ snapshot: PathSnapshot) {
        guard settled != nil else {
            settled = snapshot
            return
        }
        pending?.cancel()
        let debounce = debounce
        pending = Task { [weak self] in
            do {
                try await Task.sleep(for: debounce)
            } catch {
                return
            }
            guard !Task.isCancelled else {
                return
            }
            self?.settle(snapshot)
        }
    }

    private func settle(_ snapshot: PathSnapshot) {
        pending = nil
        guard let old = settled else {
            settled = snapshot
            return
        }
        settled = snapshot
        if networkChanged(from: old, to: snapshot) {
            onChange?(old, snapshot)
        }
    }
}
