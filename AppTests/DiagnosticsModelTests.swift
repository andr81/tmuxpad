import Foundation
import SwiftUI
import Testing
import TmuxPadCore
import UIKit
@testable import TmuxPad

@MainActor
final class DiagnosticsModelTests {
    let directory = temporaryDirectory()
    let env: AppEnvironment

    init() throws {
        env = try AppEnvironment.inMemory(directory: directory)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func eventsBeforeAndAfterCreationArrive() async throws {
        let log = DiagnosticsLog()
        await log.record(server: "prod", kind: .connect, "before")
        let model = DiagnosticsModel(log: log)
        await log.record(server: "prod", kind: .exec, "after")
        try await waitUntil { model.events.count == 2 }
        #expect(model.events.map(\.message) == ["before", "after"])
        #expect(model.newestFirst().map(\.message) == ["after", "before"])
    }

    @Test func eventsKeepArrivingAfterScreenReopens() async throws {
        await env.log.record(server: "prod", kind: .connect, "first")
        try await waitUntil { env.diagnostics.events.count == 1 }
        for message in ["second", "third"] {
            var host: UIHostingController<AnyView>? = UIHostingController(
                rootView: AnyView(NavigationStack { DiagnosticsView() }.appEnvironment(env))
            )
            host?.loadViewIfNeeded()
            host?.view.layoutIfNeeded()
            host = nil
            await env.log.record(server: "prod", kind: .exec, message)
        }
        try await waitUntil { env.diagnostics.events.count == 3 }
        #expect(env.diagnostics.events.map(\.message) == ["first", "second", "third"])
    }

    @Test func capacityIsBounded() async throws {
        let log = DiagnosticsLog(capacity: 10)
        let model = DiagnosticsModel(log: log, capacity: 3)
        for index in 1...5 {
            await log.record(server: "s", kind: .ping, "\(index)")
        }
        try await waitUntil { model.events.last?.message == "5" }
        #expect(model.events.map(\.message) == ["3", "4", "5"])
    }

    @Test func filterAndExport() async throws {
        let log = DiagnosticsLog()
        let model = DiagnosticsModel(log: log)
        await log.record(server: "prod", kind: .connect, "up")
        await log.record(server: "dev", kind: .error, "line1\nline2")
        try await waitUntil { model.events.count == 2 }
        #expect(model.servers == ["dev", "prod"])
        #expect(model.newestFirst(server: "prod").map(\.message) == ["up"])
        #expect(model.exportText() == (await log.export()))
        let devLine = model.exportText(server: "dev")
        #expect(devLine.hasSuffix(" dev error line1 line2"))
        #expect(!devLine.contains("prod"))
    }
}

/// Ждёт условие на главном акторе, не дольше `timeout`.
@MainActor
func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("условие не выполнилось за \(timeout)")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
