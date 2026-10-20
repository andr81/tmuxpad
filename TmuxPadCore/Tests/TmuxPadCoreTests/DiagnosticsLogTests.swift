import Foundation
import Testing
@testable import TmuxPadCore

@Suite struct DiagnosticsLogTests {
    @Test func evictsOldestBeyondCapacity() async {
        let log = DiagnosticsLog()
        for i in 0..<2001 {
            await log.record(server: "dev", kind: .exec, "event \(i)")
        }
        let events = await log.events()
        #expect(events.count == 2000)
        #expect(events.first?.message == "event 1")
        #expect(events.last?.message == "event 2000")
    }

    @Test func keepsOrderAfterWrapping() async {
        let log = DiagnosticsLog(capacity: 3)
        for i in 0..<7 {
            await log.record(server: "dev", kind: .ping, "\(i)")
        }
        #expect(await log.events().map(\.message) == ["4", "5", "6"])
    }

    @Test func exportFormat() async {
        let log = DiagnosticsLog()
        await log.record(DiagnosticsEvent(
            date: Date(timeIntervalSince1970: 1_760_990_000), server: "dev", kind: .connect, message: "connected"))
        await log.record(DiagnosticsEvent(
            date: Date(timeIntervalSince1970: 1_760_990_001), server: "prod", kind: .hostKey, message: "line1\nline2"))
        #expect(await log.export() == """
        2025-10-20T19:53:20Z dev connect connected
        2025-10-20T19:53:21Z prod hostKey line1 line2
        """)
    }

    @Test func updatesStreamYieldsEvents() async {
        let log = DiagnosticsLog()
        await log.record(server: "dev", kind: .error, "boom")
        var iterator = log.updates.makeAsyncIterator()
        let event = await iterator.next()
        #expect(event?.message == "boom")
        #expect(event?.kind == .error)
    }
}
