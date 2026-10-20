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
