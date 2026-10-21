import Foundation
import Testing
@testable import TmuxPad

@MainActor
struct NetworkMonitorTests {
    nonisolated static let wifi = PathSnapshot(satisfied: true, interfaces: ["wifi"])
    nonisolated static let cellular = PathSnapshot(satisfied: true, interfaces: ["cellular"])
    nonisolated static let both = PathSnapshot(satisfied: true, interfaces: ["wifi", "cellular"])
    nonisolated static let down = PathSnapshot(satisfied: false, interfaces: [])
    nonisolated static let downWifi = PathSnapshot(satisfied: false, interfaces: ["wifi"])

    @Test(arguments: [
        (wifi, wifi, false),
        (wifi, cellular, true),
        (cellular, wifi, true),
        (wifi, both, true),
        (both, wifi, true),
        (wifi, down, false),
        (down, wifi, true),
        (downWifi, wifi, true),
        (down, down, false),
        (down, downWifi, false),
    ])
    func changed(old: PathSnapshot, new: PathSnapshot, expected: Bool) {
        #expect(networkChanged(from: old, to: new) == expected)
    }

    @Test func summary() {
        #expect(Self.both.summary == "cellular+wifi")
        #expect(Self.downWifi.summary == "none")
    }

    @Test func firstSnapshotIsBaseline() async throws {
        let monitor = NetworkMonitor(debounce: .milliseconds(30))
        var events: [(PathSnapshot, PathSnapshot)] = []
        monitor.onChange = { events.append(($0, $1)) }
        monitor.receive(Self.wifi)
        try await Task.sleep(for: .milliseconds(100))
        #expect(events.isEmpty)
        monitor.receive(Self.cellular)
        try await waitUntil { events.count == 1 }
        #expect(events.first?.0 == Self.wifi)
        #expect(events.first?.1 == Self.cellular)
    }

    @Test func bounceIsDebounced() async throws {
        let monitor = NetworkMonitor(debounce: .milliseconds(50))
        var events: [(PathSnapshot, PathSnapshot)] = []
        monitor.onChange = { events.append(($0, $1)) }
        monitor.receive(Self.wifi)
        // Wi-Fi пропал и вернулся быстрее дребезга — не событие
        monitor.receive(Self.down)
        monitor.receive(Self.wifi)
        try await Task.sleep(for: .milliseconds(150))
        #expect(events.isEmpty)
        // пропал, устоялся, пришла сотовая — одно событие от `down`
        monitor.receive(Self.down)
        try await Task.sleep(for: .milliseconds(150))
        #expect(events.isEmpty)
        monitor.receive(Self.cellular)
        try await waitUntil { events.count == 1 }
        #expect(events.first?.0 == Self.down)
        #expect(events.first?.1 == Self.cellular)
    }
}
