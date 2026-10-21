import Foundation
import Testing
import TmuxPadCore
@testable import TmuxPad

/// Docker-стенд sshd + tmux из `host/tests/bench.sh`. `scripts/ios-test.sh` экспортирует
/// `TEST_RUNNER_TMUXPAD_BENCH_*`, `xcodebuild` срезает префикс; без переменных тесты стенда
/// пропускаются.
enum Bench {
    static let environment = ProcessInfo.processInfo.environment

    static var isAvailable: Bool {
        environment["TMUXPAD_BENCH_PORT"] != nil && keyText != nil
    }

    static var port: Int {
        Int(environment["TMUXPAD_BENCH_PORT"] ?? "") ?? 22
    }

    static var user: String {
        environment["TMUXPAD_BENCH_USER"] ?? "dev"
    }

    /// Приватный ключ стенда, OpenSSH-текст из `TMUXPAD_BENCH_KEY_B64`.
    static var keyText: String? {
        guard let base64 = environment["TMUXPAD_BENCH_KEY_B64"], let data = Data(base64Encoded: base64) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func config(keyID: UUID, label: String = "bench") -> ServerConfig {
        ServerConfig(label: label, host: "127.0.0.1", port: port, user: user, keyID: keyID)
    }

    /// Ключ стенда в `InMemoryKeyStore` окружения и сервер с ним в `ServerStore`.
    @MainActor
    static func addServer(to env: AppEnvironment) async throws -> ServerConfig {
        let key = try await env.keys.importKey(name: "bench", text: keyText ?? "", passphrase: nil)
        try env.servers.add(config(keyID: key.id))
        return env.servers.servers.last!
    }

    /// Сервер стенда с подтверждённым отпечатком и установленным скриптом.
    @MainActor
    static func preparedServer(in env: AppEnvironment) async throws -> ServerConfig {
        let server = try await addServer(to: env)
        let model = ServerCheckModel(serverID: server.id, environment: env)
        await model.check().value
        await model.trust().value
        await model.prepare().value
        guard case .done(.ready, _) = model.state else {
            Issue.record("expected done(.ready), got \(model.state)")
            throw CancellationError()
        }
        return try #require(env.servers.server(id: server.id))
    }

    /// Отдельное соединение со свежим `InMemoryHostKeyStore`, команда, отключение.
    static func exec(_ command: String) async throws -> ExecResult {
        let key = SSHPrivateKey(try SSHKeys.importOpenSSHEd25519(keyText ?? ""))
        let connection = ServerConnection(
            config: config(keyID: UUID()),
            deviceID: UUID(),
            transport: CitadelTransport(),
            auth: .privateKey(key, user: user),
            hostKeys: InMemoryHostKeyStore()
        )
        try await connection.connect()
        do {
            let result = try await connection.exec(command)
            await connection.disconnect()
            return result
        } catch {
            await connection.disconnect()
            throw error
        }
    }

    /// Сброс состояния стенда — та же строка, что `reset` в `host/tests/lib.sh` и в `Bench`
    /// ядра; заодно удаляется установленный host-скрипт, чтобы проверка начиналась с `missing`.
    static func reset() async throws {
        let result = try await exec("""
            tmux kill-server 2>/dev/null; rm -rf ~/.tmuxpad ~/.claude ~/claude-args.log ~/.tmux.conf ~/proj-link ~/projects ~/elsewhere ~/.local/bin/tmuxpad-host.sh; \
            mkdir -p ~/projects/api ~/projects/web ~/projects/my.app; touch ~/projects/README.md
            """)
        guard result.exitCode == 0 else {
            throw SSHError.connectFailed("bench reset failed: \(result.stderrText)")
        }
    }
}
