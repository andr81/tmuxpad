import Foundation
import SwiftTerm
import Testing
import TmuxPadCore
@testable import TmuxPad

/// Терминал против стенда: `OpenSessionsModel` окружения, настоящие пул и `TerminalSession`.
@MainActor
@Suite(.serialized, .enabled(if: Bench.isAvailable), .timeLimit(.minutes(2)))
final class TerminalBenchTests {
    let directory = temporaryDirectory()
    let env: AppEnvironment

    init() async throws {
        env = try AppEnvironment.inMemory(directory: directory)
        try await Bench.reset()
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
        let env = env
        Task { @MainActor in
            await env.pool.disconnectAll()
        }
    }

    /// Сессия `NAME` в проекте `api` на стенде, открытая в приложении и уже `.live`.
    private func openLive(_ name: String) async throws -> OpenTerminal {
        let server = try await Bench.preparedServer(in: env)
        let created = try await Bench.exec("~/.local/bin/tmuxpad-host.sh new \(name) api")
        #expect(created.exitCode == 0, "\(created.stderrText)")
        env.tree.setServers(env.servers.servers)
        await env.tree.refresh(serverID: server.id)
        let key = OpenSessionKey(serverID: server.id, name: name)
        env.openSessions.open(key)
        let terminal = try #require(env.openSessions.terminals[key])
        try await waitUntil(timeout: .seconds(15)) { terminal.state == .live }
        return terminal
    }

    private func finish() async {
        for key in env.openSessions.roster.tabs {
            env.openSessions.close(key)
        }
        await env.pool.disconnectAll()
    }

    /// Ввод так, как его отдаёт SwiftTerm: через делегат view.
    private func type(_ text: String, into terminal: OpenTerminal) throws {
        let delegate = try #require(terminal.view.terminalDelegate)
        delegate.send(source: terminal.view, data: Array(text.utf8)[...])
    }

    @Test func openGoesLiveWithPrompt() async throws {
        let terminal = try await openLive("live")
        #expect(terminal.project == "api")
        #expect(env.openSessions.selectedTerminal === terminal)
        // шелл стенда — bash пользователя `dev`, приглашение `dev@…$ `
        try await waitUntil(timeout: .seconds(10)) { screenText(terminal.view).contains("dev@") }
        await finish()
    }

    @Test func typedCommandRuns() async throws {
        let terminal = try await openLive("echo")
        // заглушка claude ждёт в `sleep`: Ctrl-C возвращает шелл
        try await waitUntil(timeout: .seconds(10)) { screenText(terminal.view).contains("dev@") }
        try type("\u{3}", into: terminal)
        try await waitUntil(timeout: .seconds(10)) { promptReturned(terminal) }
        #expect(promptReturned(terminal), "\(screenText(terminal.view))")
        try type("echo h''i\r", into: terminal)
        // `h''i` — в эхе ввода, `hi` отдельной строкой — только в выводе команды
        try await waitUntil(timeout: .seconds(10)) { lines(terminal).contains("hi") }
        #expect(lines(terminal).contains("hi"), "\(screenText(terminal.view))")
        await finish()
    }

    @Test func wheelUpEntersCopyModeAndTypingLeavesIt() async throws {
        let terminal = try await openLive("wheel")
        try await waitUntil(timeout: .seconds(10)) { screenText(terminal.view).contains("dev@") }
        #expect(try await paneInMode("wheel") == "0")
        // SGR: колесо вверх в колонке 10, строке 5 — так его отдаёт SwiftTerm при `allowMouseReporting`
        try type("\u{1b}[<64;10;5M", into: terminal)
        try await waitUntil(timeout: .seconds(10)) { terminal.showsScrollChip }
        #expect(terminal.showsScrollChip)
        try await waitForExec { try await self.paneInMode("wheel") == "1" }
        try type("x", into: terminal)
        try await waitUntil(timeout: .seconds(10)) { !terminal.showsScrollChip }
        #expect(!terminal.showsScrollChip)
        try await waitForExec { try await self.paneInMode("wheel") == "0" }
        await finish()
    }

    @Test func killFromOutsideEndsTerminal() async throws {
        let terminal = try await openLive("doomed")
        let killed = try await Bench.exec("tmux kill-session -t '=doomed'")
        #expect(killed.exitCode == 0, "\(killed.stderrText)")
        try await waitUntil(timeout: .seconds(15)) { terminal.state == .ended }
        #expect(terminal.state == .ended)
        await finish()
    }

    @Test func secondTakeByOtherDeviceWithinMinuteShowsBanner() async throws {
        let terminal = try await openLive("shared")
        // другое устройство: свой пул и свой `deviceID`
        let otherDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: otherDirectory) }
        let other = try AppEnvironment.inMemory(directory: otherDirectory)
        #expect(other.deviceID != env.deviceID)
        let otherServer = try await Bench.preparedServer(in: other)
        let otherKey = OpenSessionKey(serverID: otherServer.id, name: "shared")
        other.openSessions.open(otherKey, take: true)
        let taker = try #require(other.openSessions.terminals[otherKey])
        try await waitUntil(timeout: .seconds(15)) { taker.state == .live }
        // первое выбивание — молча: наш терминал подключается снова, рядом с чужим
        try await waitForExec { try await self.clients("shared") == 2 }
        try await waitUntil(timeout: .seconds(15)) { terminal.state == .live }
        #expect(terminal.state == .live)
        await taker.take()
        try await waitUntil(timeout: .seconds(15)) { terminal.state == .disconnectedByOther }
        #expect(terminal.state == .disconnectedByOther)
        #expect(taker.state == .live)
        other.openSessions.close(otherKey)
        await other.pool.disconnectAll()
        await finish()
    }

    private func paneInMode(_ name: String) async throws -> String {
        let result = try await Bench.exec("tmux display -p -t '=\(name):' '#{pane_in_mode}'")
        return result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Клиенты tmux, подключённые к сессии `name`.
    private func clients(_ name: String) async throws -> Int {
        let result = try await Bench.exec("tmux list-clients -t '=\(name)' -F '#{client_pid}'")
        return result.stdoutText.split(separator: "\n").count
    }

    /// Опрос условия на стенде (каждый шаг — своё соединение `Bench.exec`).
    private func waitForExec(timeout: Duration = .seconds(15), _ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !(try await condition()) {
            guard ContinuousClock.now < deadline else {
                Issue.record("условие на стенде не выполнилось за \(timeout)")
                return
            }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    /// Пустое приглашение `dev@…$`: у первого в строке ещё команда запуска claude.
    private func promptReturned(_ terminal: OpenTerminal) -> Bool {
        lines(terminal).contains { $0.hasPrefix("dev@") && $0.hasSuffix("$") }
    }

    /// Непустые строки экрана без хвостовых пробелов.
    private func lines(_ terminal: OpenTerminal) -> [String] {
        screenText(terminal.view)
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
