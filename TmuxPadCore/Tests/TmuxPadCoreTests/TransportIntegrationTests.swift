import Foundation
import Testing
@testable import TmuxPadCore

@Suite(.serialized, .enabled(if: Bench.isAvailable))
struct TransportIntegrationTests {
    /// Соединение со стендом на время теста.
    private func withConnection(_ body: @escaping @Sendable (any SSHConnection) async throws -> Void) async throws {
        try await withTimeout(.seconds(30)) {
            let connection = try await Bench.connect()
            do {
                try await body(connection)
            } catch {
                await connection.close()
                throw error
            }
            await connection.close()
        }
    }

    /// Читает вывод PTY, пока `done` не вернёт `true` или поток не кончится; для каждого куска
    /// зовёт `onChunk` с накопленным текстом.
    @discardableResult
    private func read(
        _ pty: any PTYChannel,
        onChunk: (String) async throws -> Void = { _ in },
        until done: (String) -> Bool = { _ in false }
    ) async throws -> String {
        var text = ""
        for try await chunk in pty.output {
            text += String(decoding: chunk, as: UTF8.self)
            try await onChunk(text)
            if done(text) {
                break
            }
        }
        return text
    }

    @Test func connectAndEcho() async throws {
        try await withConnection { connection in
            let result = try await connection.exec("echo ok")
            #expect(result.exitCode == 0)
            #expect(result.stdoutText == "ok\n")
            #expect(result.stderr.isEmpty)
        }
    }

    @Test func exitCodeAndStderr() async throws {
        try await withConnection { connection in
            let result = try await connection.exec("echo err >&2; exit 3")
            #expect(result.exitCode == 3)
            #expect(result.stderrText == "err\n")
            #expect(result.stdout.isEmpty)
        }
    }

    /// Быстрая команда шлёт EOF раньше нашего EOF stdin; форк swift-nio-ssh рвал на этом канал
    /// вместе с exit-status (примерно раз на 50 exec).
    @Test func fastExecsKeepExitStatus() async throws {
        try await withConnection { connection in
            for index in 0..<200 {
                let result = try await connection.exec("echo \(index); exit 3")
                #expect(result.exitCode == 3)
                #expect(result.stdoutText == "\(index)\n")
            }
        }
    }

    @Test func stdinWithEOF() async throws {
        try await withConnection { connection in
            let input = Data((0..<100 * 1024).map { UInt8(truncatingIfNeeded: $0 * 7 + 3) })
            let result = try await connection.exec("cat", stdin: input)
            #expect(result.exitCode == 0)
            #expect(result.stdout == input)
        }
    }

    @Test func ptyExec() async throws {
        try await withConnection { connection in
            let pty = try await connection.openPTY(
                command: "tty; stty size; sleep 0.2", term: "xterm-256color", cols: 100, rows: 30, environment: [:]
            )
            let text = try await read(pty)
            #expect(text.contains("/dev/pts/"))
            #expect(text.contains("30 100"))
            #expect(pty.exitCode == 0)
        }
    }

    @Test func ptyResize() async throws {
        try await withConnection { connection in
            // bash откладывает trap до конца переднего плана, поэтому короткие sleep в цикле
            let pty = try await connection.openPTY(
                command: "trap 'stty size' WINCH; echo ready; for i in $(seq 100); do sleep 0.1; done",
                term: "xterm-256color", cols: 80, rows: 24, environment: [:]
            )
            var resized = false
            let text = try await read(pty, onChunk: { text in
                if !resized, text.contains("ready") {
                    resized = true
                    try await pty.resize(cols: 120, rows: 40)
                }
            }, until: { $0.contains("40 120") })
            #expect(text.contains("40 120"))
            await pty.close()
        }
    }

    /// Стенд принимает `LANG LC_*` по `AcceptEnv`, но `LANG` потом перетирает pam_env из
    /// `/etc/default/locale` (так же и у OpenSSH-клиента), поэтому доставку env-запроса видно
    /// по `LC_*`-переменной.
    @Test func envRequestLang() async throws {
        try await withConnection { connection in
            let result = try await connection.exec(
                #"echo "$LC_TMUXPAD""#,
                stdin: nil,
                environment: ["LANG": "en_US.UTF-8", "LC_TMUXPAD": "on"],
                timeout: .seconds(10)
            )
            #expect(result.exitCode == 0)
            #expect(result.stdoutText == "on\n")
        }
    }

    @Test func tofuFirstThenMismatch() async throws {
        try await withTimeout(.seconds(30)) {
            let store = InMemoryHostKeyStore()
            let first = try await CitadelTransport().connect(Bench.endpoint, auth: try Bench.auth(), hostKeys: store)
            await first.connection.close()
            #expect(first.firstSeen)
            #expect(first.hostKeyFingerprint.hasPrefix("SHA256:"))
            #expect(await store.fingerprint(for: Bench.endpoint.host, port: Bench.endpoint.port) == first.hostKeyFingerprint)

            let again = try await CitadelTransport().connect(Bench.endpoint, auth: try Bench.auth(), hostKeys: store)
            await again.connection.close()
            #expect(!again.firstSeen)
            #expect(again.hostKeyFingerprint == first.hostKeyFingerprint)

            let bogus = "SHA256:" + String(repeating: "A", count: 43)
            await store.save(bogus, for: Bench.endpoint.host, port: Bench.endpoint.port)
            await #expect(throws: SSHError.hostKeyChanged(expected: bogus, actual: first.hostKeyFingerprint)) {
                _ = try await CitadelTransport().connect(Bench.endpoint, auth: try Bench.auth(), hostKeys: store)
            }
            // отпечаток не перезаписан
            #expect(await store.fingerprint(for: Bench.endpoint.host, port: Bench.endpoint.port) == bogus)
        }
    }

    @Test func wrongKeyFails() async throws {
        try await withTimeout(.seconds(30)) {
            let auth = SSHAuth.privateKey(SSHKeys.generateEd25519().privateKey, user: Bench.user)
            await #expect(throws: SSHError.authFailed) {
                _ = try await CitadelTransport().connect(Bench.endpoint, auth: auth, hostKeys: InMemoryHostKeyStore())
            }
        }
    }

    @Test func maxSessions() async throws {
        try await withConnection { connection in
            var ptys: [any PTYChannel] = []
            for _ in 0..<10 {
                ptys.append(try await connection.openPTY(command: "sleep 30", term: "xterm-256color", cols: 80, rows: 24, environment: [:]))
            }
            let clock = ContinuousClock()
            let start = clock.now
            await #expect(throws: SSHError.channelRefused) {
                _ = try await connection.openPTY(command: "sleep 30", term: "xterm-256color", cols: 80, rows: 24, environment: [:])
            }
            #expect(clock.now - start < .seconds(5))
            for pty in ptys {
                await pty.close()
            }
            // соединение пережило отказ
            #expect(try await connection.exec("echo ok").stdoutText == "ok\n")
        }
    }

    @Test func disconnectIsObserved() async throws {
        try await withConnection { connection in
            // $PPID — sshd-процесс сеанса: его смерть рвёт TCP
            _ = try? await connection.exec("kill -9 $PPID", stdin: nil, environment: [:], timeout: .seconds(5))
            try await withTimeout(.seconds(5)) {
                for await _ in connection.onDisconnect {
                    break
                }
            }
            #expect(!connection.isConnected)
        }
    }
}
