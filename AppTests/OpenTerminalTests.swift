import Foundation
import Testing
import TmuxPadCore
@testable import TmuxPad

/// `OpenTerminal` без сети: соединение — заглушка, которая считает вызовы и бросает ошибку.
@MainActor
struct OpenTerminalTests {
    let key = OpenSessionKey(serverID: UUID(), name: "api")
    let defaults = UserDefaults(suiteName: "dev.tmuxpad.test.\(UUID().uuidString)")!

    @MainActor
    final class Calls {
        var count = 0
    }

    @MainActor
    final class Snapshot {
        var value: ServerSnapshot?
    }

    private func terminal(
        calls: Calls = Calls(),
        snapshot: @escaping @MainActor (UUID) -> ServerSnapshot? = { _ in nil }
    ) -> OpenTerminal {
        OpenTerminal(key: key, dependencies: OpenTerminal.Dependencies(
            connection: { _ in
                calls.count += 1
                try await Task.sleep(for: .milliseconds(100))
                throw AppError.serverMissing
            },
            snapshot: snapshot,
            log: nil,
            defaults: defaults,
            appearance: TerminalAppearance(defaults: defaults)
        ))
    }

    private func snapshot(projects: [String], sessions: [(String, String)]) -> ServerSnapshot {
        ServerSnapshot(
            projects: projects.map { RemoteProject(name: $0, path: "/p/\($0)") },
            sessions: sessions.map { RemoteSession(name: $0.0, project: $0.1, otherClients: 0, lastActivity: Date()) },
            fetchedAt: Date()
        )
    }

    @Test func concurrentRetriesShareOneAttempt() async throws {
        let calls = Calls()
        let terminal = terminal(calls: calls)
        terminal.start()
        try await waitUntil { terminal.state != .connecting }
        #expect(calls.count == 1)
        // двойной тап «Повторить»: второй ждёт попытку первого, а не начинает свою
        let first = Task { await terminal.retry() }
        let second = Task { await terminal.retry() }
        await first.value
        await second.value
        #expect(calls.count == 2)
        #expect(terminal.session == nil)
        #expect(terminal.state == .offline(userText(AppError.serverMissing)))
    }

    @Test func retryAfterFailureTriesAgain() async throws {
        let calls = Calls()
        let terminal = terminal(calls: calls)
        terminal.start()
        try await waitUntil { terminal.state != .connecting }
        await terminal.retry()
        await terminal.retry()
        #expect(calls.count == 3)
    }

    @Test func closedTerminalDoesNotConnect() async {
        let calls = Calls()
        let terminal = terminal(calls: calls)
        terminal.close()
        terminal.start()
        await terminal.reconnect()
        await terminal.take()
        #expect(calls.count == 0)
        #expect(terminal.session == nil)
    }

    @Test func recreateWithoutKnownProjectThrows() {
        let terminal = terminal()
        #expect(terminal.project == nil)
        #expect(throws: AppError.projectUnknown) {
            try terminal.recreateProject()
        }
    }

    @Test func recreateWhenProjectIsGoneThrows() {
        let current = Snapshot()
        current.value = snapshot(projects: ["api"], sessions: [("api", "api")])
        let terminal = terminal(snapshot: { _ in current.value })
        #expect(terminal.project == "api")
        current.value = snapshot(projects: ["web"], sessions: [])
        #expect(throws: AppError.projectNotFound("api")) {
            try terminal.recreateProject()
        }
    }

    @Test func recreateProjectFromOpeningSnapshot() throws {
        let current = Snapshot()
        current.value = snapshot(projects: ["api"], sessions: [("api", "api")])
        let terminal = terminal(snapshot: { _ in current.value })
        #expect(try terminal.recreateProject() == "api")
    }
}

@MainActor
struct TerminalDelegateTests {
    @Test(arguments: ["https://example.com/a", "http://example.com", "HTTPS://Example.com"])
    func webLinksOpen(_ link: String) {
        #expect(TerminalDelegate.openableURL(link) != nil)
    }

    @Test(arguments: ["tel:123", "file:///etc/passwd", "javascript:alert(1)", "tmuxpad://x", "example.com", ""])
    func otherLinksDoNotOpen(_ link: String) {
        #expect(TerminalDelegate.openableURL(link) == nil)
    }
}

@MainActor
struct TerminalSettingsTests {
    let defaults = UserDefaults(suiteName: "dev.tmuxpad.test.\(UUID().uuidString)")!

    @Test func defaultsWhenUnset() {
        #expect(TerminalSettings.fontSize(defaults) == TerminalSettings.defaultFontSize)
        #expect(TerminalSettings.optionAsMeta(defaults))
        #expect(TerminalSettings.bellEnabled(defaults))
    }

    @Test(arguments: [(100, 32), (1, 9), (20, 20)])
    func storedFontSizeIsClamped(_ stored: Int, _ expected: Int) {
        defaults.set(stored, forKey: TerminalSettings.fontSizeKey)
        #expect(TerminalSettings.fontSize(defaults) == expected)
    }

    @Test func bellOff() {
        defaults.set("off", forKey: TerminalSettings.bellKey)
        #expect(!TerminalSettings.bellEnabled(defaults))
    }
}

/// Инвариант «один `TmuxTerminalView` на терминал»: контейнер меняет view, а не пересоздаёт.
@MainActor
struct TerminalContainerViewTests {
    @Test func showSwapsSameInstances() {
        let container = TerminalContainerView()
        let first = TmuxTerminalView()
        let second = TmuxTerminalView()
        container.show(first)
        #expect(first.superview === container)
        container.show(second)
        #expect(first.superview == nil)
        #expect(second.superview === container)
        container.show(first)
        #expect(container.current === first)
        #expect(first.superview === container)
        #expect(second.superview == nil)
        #expect(container.subviews.filter { $0 is TmuxTerminalView }.count == 1)
        container.show(nil)
        #expect(first.superview == nil)
        #expect(container.current == nil)
    }
}
