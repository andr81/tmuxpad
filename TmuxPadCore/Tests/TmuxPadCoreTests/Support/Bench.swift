import Foundation
@testable import TmuxPadCore

/// Docker-стенд sshd + tmux из `host/tests/bench.sh`; переменные выставляет `scripts/test.sh`.
enum Bench {
    static let environment = ProcessInfo.processInfo.environment

    static var isAvailable: Bool {
        environment["TMUXPAD_BENCH_PORT"] != nil
    }

    static var endpoint: SSHEndpoint {
        SSHEndpoint(host: "127.0.0.1", port: Int(environment["TMUXPAD_BENCH_PORT"] ?? "") ?? 22, connectTimeout: .seconds(10))
    }

    static var user: String {
        environment["TMUXPAD_BENCH_USER"] ?? "dev"
    }

    /// Ключ стенда из файла.
    static func auth() throws -> SSHAuth {
        let path = environment["TMUXPAD_BENCH_KEY"] ?? ""
        let text = try String(contentsOfFile: path, encoding: .utf8)
        return .privateKey(SSHPrivateKey(try SSHKeys.importOpenSSHEd25519(text)), user: user)
    }

    /// Первое подключение со свежим `InMemoryHostKeyStore`.
    static func connect(hostKeys: InMemoryHostKeyStore = InMemoryHostKeyStore()) async throws -> any SSHConnection {
        try await CitadelTransport().connect(endpoint, auth: try auth(), hostKeys: hostKeys).connection
    }

    /// Сброс состояния стенда — та же строка, что `reset` в `host/tests/lib.sh`.
    static func reset(_ connection: any SSHConnection) async throws {
        let result = try await connection.exec("""
            tmux kill-server 2>/dev/null; rm -rf ~/.tmuxpad ~/.claude ~/claude-args.log ~/.tmux.conf ~/proj-link ~/projects ~/elsewhere; \
            mkdir -p ~/projects/api ~/projects/web ~/projects/my.app; touch ~/projects/README.md
            """)
        guard result.exitCode == 0 else {
            throw SSHError.connectFailed("bench reset failed: \(result.stderrText)")
        }
    }

    /// `tmux ARGS` на стенде, stdout.
    @discardableResult
    static func tmux(_ connection: any SSHConnection, _ args: String) async throws -> String {
        try await connection.exec("tmux \(args)").stdoutText
    }
}

extension Bench {
    /// UUID устройства в тестах стенда.
    static let deviceID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!

    /// `HostAPI` на соединении стенда; `TMUXPAD_CMD` — `sleep 1000`, чтобы заглушка claude не мешала.
    static func api(_ connection: any SSHConnection, projectsRoot: String = "projects", startCommand: String = "sleep 1000") -> HostAPI {
        HostAPI(
            runner: connection,
            environment: HostEnvironment(client: deviceID, projectsRoot: projectsRoot, startCommand: startCommand),
            server: "bench"
        )
    }

    /// Тело со стендом в монопольном владении: сбросы и tmux-сессии разных suite не должны
    /// пересекаться, а suite Swift Testing идут параллельно.
    static func exclusive<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        await BenchLock.shared.acquire()
        do {
            let value = try await body()
            await BenchLock.shared.release()
            return value
        } catch {
            await BenchLock.shared.release()
            throw error
        }
    }

    /// Свежее соединение со сбросом стенда, тело с таймаутом, затем закрытие.
    static func withReset(
        timeout: Duration = .seconds(60),
        _ body: @escaping @Sendable (any SSHConnection) async throws -> Void
    ) async throws {
        try await exclusive {
            try await withTimeout(timeout) {
                let connection = try await connect()
                do {
                    try await reset(connection)
                    try await body(connection)
                } catch {
                    await connection.close()
                    throw error
                }
                await connection.close()
            }
        }
    }

    /// Клиент tmux с хоста через `ssh -tt -n` — «чужой» для приложения, как `tmux_bg` в `lib.sh`.
    static func foreignClient(_ remoteCommand: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "ssh", "-tt", "-n",
            "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
            "-o", "ConnectTimeout=5", "-o", "LogLevel=ERROR",
            "-i", environment["TMUXPAD_BENCH_KEY"] ?? "", "-p", String(endpoint.port),
            "\(user)@127.0.0.1", remoteCommand,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    /// Ждёт `condition` с опросом каждые 100 мс, не дольше `timeout`.
    static func eventually(
        _ timeout: Duration = .seconds(5),
        _ condition: @Sendable () async throws -> Bool
    ) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if try await condition() {
                return true
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return try await condition()
    }
}

/// FIFO-замок стенда для `Bench.exclusive`.
actor BenchLock {
    static let shared = BenchLock()

    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
