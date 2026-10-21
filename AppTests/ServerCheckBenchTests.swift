import Foundation
import Testing
import TmuxPadCore
@testable import TmuxPad

/// `ServerCheckModel` против стенда: TOFU, установка скрипта, `doctor`, токен.
@MainActor
@Suite(.serialized, .enabled(if: Bench.isAvailable), .timeLimit(.minutes(2)))
final class ServerCheckBenchTests {
    struct UnexpectedState: Error {}

    let directory = temporaryDirectory()
    let env: AppEnvironment

    init() async throws {
        env = try AppEnvironment.inMemory(directory: directory)
        try await Bench.reset()
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func finish() async {
        await env.pool.disconnectAll()
    }

    /// Проверка до вопроса «Доверять» и сам ответ.
    private func checkTrusted(_ model: ServerCheckModel) async throws -> String {
        await model.check().value
        guard case let .trustPrompt(fingerprint) = model.state else {
            Issue.record("expected trustPrompt, got \(model.state)")
            throw UnexpectedState()
        }
        await model.trust().value
        return fingerprint
    }

    @Test func firstCheckAsksTrustThenPrepareAndRecheck() async throws {
        let server = try await Bench.addServer(to: env)
        let model = ServerCheckModel(serverID: server.id, environment: env)

        await model.check().value
        guard case let .trustPrompt(fingerprint) = model.state else {
            Issue.record("expected trustPrompt, got \(model.state)")
            return
        }
        let connection = try #require(await env.pool.existing(id: server.id))
        #expect(await connection.hostKeyFingerprint == fingerprint)
        #expect(fingerprint.hasPrefix("SHA256:"))

        await model.trust().value
        #expect(model.state == .done(.missing, nil))
        #expect(env.servers.server(id: server.id)?.hostKeyFingerprint == fingerprint)

        await model.prepare().value
        guard case let .done(.ready(version), report?) = model.state else {
            Issue.record("expected done(.ready, report), got \(model.state)")
            return
        }
        #expect(version == env.bootstrap.bundledVersion)
        #expect(report.ok, "\(report.lines)")

        // новый экран: соединение в пуле то же, `hostKeyFirstSeen` у него по-прежнему true
        let again = ServerCheckModel(serverID: server.id, environment: env)
        await again.check().value
        guard case let .done(.ready, report?) = again.state else {
            Issue.record("expected done(.ready, report), got \(again.state)")
            return
        }
        #expect(report.ok)
        await finish()
    }

    @Test func changedHostKeyBlocksUntilReset() async throws {
        let server = try await Bench.addServer(to: env)
        let model = ServerCheckModel(serverID: server.id, environment: env)
        let fingerprint = try await checkTrusted(model)

        await env.pool.existing(id: server.id)?.disconnect()
        try await env.hostKeys.save("SHA256:forged", for: server.host, port: server.port)
        await model.check().value
        #expect(model.state == .hostKeyChanged(expected: "SHA256:forged", actual: fingerprint))

        await model.resetHostKey().value
        #expect(model.state == .trustPrompt(fingerprint: fingerprint))
        #expect(env.servers.server(id: server.id)?.hostKeyFingerprint == nil)
        await finish()
    }

    /// Отпечаток подтверждён в конфиге, а `HostKeyStore` пуст (бэкап восстановлен на новом
    /// iPad): другой ключ — это смена ключа, а не первый коннект.
    @Test func confirmedKeyMismatchBlocksWithoutStoredKey() async throws {
        let server = try await Bench.addServer(to: env)
        let model = ServerCheckModel(serverID: server.id, environment: env)
        let fingerprint = try await checkTrusted(model)

        await env.pool.existing(id: server.id)?.disconnect()
        var config = try #require(env.servers.server(id: server.id))
        config.hostKeyFingerprint = "SHA256:confirmed"
        try env.servers.update(config)
        try await env.hostKeys.reset(host: server.host, port: server.port)

        await model.check().value
        #expect(model.state == .hostKeyChanged(expected: "SHA256:confirmed", actual: fingerprint))
        #expect(try await env.hostKeys.fingerprint(for: server.host, port: server.port) == "SHA256:confirmed")
        #expect(await env.pool.existing(id: server.id)?.state.isConnected == false)

        // повторная проверка упирается в ту же блокировку уже в ядре
        await model.check().value
        #expect(model.state == .hostKeyChanged(expected: "SHA256:confirmed", actual: fingerprint))

        await model.resetHostKey().value
        #expect(model.state == .trustPrompt(fingerprint: fingerprint))
        await finish()
    }

    /// То же, но сервер ещё и отвергает вход: смена ключа видна раньше `authFailed`, а ядро не
    /// запоминает чужой ключ как первый увиденный.
    @Test func confirmedKeyMismatchWinsOverAuthFailed() async throws {
        let server = try await Bench.addServer(to: env)
        let fingerprint = try await checkTrusted(ServerCheckModel(serverID: server.id, environment: env))
        await env.pool.disconnectAll()
        try await env.hostKeys.reset(host: server.host, port: server.port)

        let key = try await env.keys.create(kind: .ed25519, name: "foreign")
        var foreign = Bench.config(keyID: key.id)
        foreign.hostKeyFingerprint = "SHA256:confirmed"
        try env.servers.add(foreign)
        let model = ServerCheckModel(serverID: foreign.id, environment: env)

        await model.check().value
        #expect(model.state == .hostKeyChanged(expected: "SHA256:confirmed", actual: fingerprint))
        #expect(try await env.hostKeys.fingerprint(for: server.host, port: server.port) == "SHA256:confirmed")
        await finish()
    }

    @Test func rejectForgetsHostKey() async throws {
        let server = try await Bench.addServer(to: env)
        let model = ServerCheckModel(serverID: server.id, environment: env)
        await model.check().value
        guard case .trustPrompt = model.state else {
            Issue.record("expected trustPrompt, got \(model.state)")
            return
        }

        let rejecting = model.reject()
        #expect(model.state == .running(.rejecting))
        await rejecting.value
        #expect(model.state == .idle)
        #expect(try await env.hostKeys.fingerprint(for: server.host, port: server.port) == nil)
        #expect(await env.pool.existing(id: server.id)?.state == .disconnected)
        #expect(env.servers.server(id: server.id)?.hostKeyFingerprint == nil)
        await finish()
    }

    @Test func foreignKeyIsAuthFailed() async throws {
        let key = try await env.keys.create(kind: .ed25519, name: "foreign")
        try env.servers.add(Bench.config(keyID: key.id))
        let server = env.servers.servers[0]
        let model = ServerCheckModel(serverID: server.id, environment: env)

        await model.check().value
        #expect(model.state == .authFailed)
        await finish()
    }

    @Test func tokenReachesServerAndNotTheLog() async throws {
        let server = try await Bench.addServer(to: env)
        let model = ServerCheckModel(serverID: server.id, environment: env)
        _ = try await checkTrusted(model)
        await model.prepare().value

        await model.sendToken("tok_123").value
        #expect(model.tokenSent)
        #expect(model.state == .idle)

        let connection = try #require(await env.pool.existing(id: server.id))
        let file = try await connection.exec("cat ~/.tmuxpad/env")
        #expect(file.stdoutText.contains("CLAUDE_CODE_OAUTH_TOKEN='tok_123'"))
        let mode = try await connection.exec("stat -c %a ~/.tmuxpad/env")
        #expect(mode.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines) == "600")
        #expect(!(await env.log.export()).contains("tok_123"))
        await finish()
    }

    @Test func copyOfTrustedServerConnectsWithoutPrompt() async throws {
        let server = try await Bench.addServer(to: env)
        let fingerprint = try await checkTrusted(ServerCheckModel(serverID: server.id, environment: env))

        let copy = try env.servers.duplicate(try #require(env.servers.server(id: server.id)))
        let model = ServerCheckModel(serverID: copy.id, environment: env)
        await model.check().value
        #expect(model.state == .done(.missing, nil))
        #expect(env.servers.server(id: copy.id)?.hostKeyFingerprint == fingerprint)
        await finish()
    }

    /// Бэкап на новом iPad: `HostKeyStore` пуст, у оригинала подтверждён другой ключ. Копия без
    /// своего отпечатка получает блокировку, а не вопрос «Доверять… впервые».
    @Test func copyWithoutFingerprintBlocksOnKeyConfirmedElsewhere() async throws {
        let server = try await Bench.addServer(to: env)
        let fingerprint = try await checkTrusted(ServerCheckModel(serverID: server.id, environment: env))
        await env.pool.existing(id: server.id)?.disconnect()

        var original = try #require(env.servers.server(id: server.id))
        let copy = try env.servers.duplicate(original)
        original.hostKeyFingerprint = "SHA256:confirmed"
        try env.servers.update(original)
        try await env.hostKeys.reset(host: server.host, port: server.port)

        let model = ServerCheckModel(serverID: copy.id, environment: env)
        await model.check().value
        #expect(model.state == .hostKeyChanged(expected: "SHA256:confirmed", actual: fingerprint))
        #expect(try await env.hostKeys.fingerprint(for: server.host, port: server.port) == "SHA256:confirmed")

        // «Сбросить» очищает отпечаток и у оригинала, иначе блокировка не снялась бы
        await model.resetHostKey().value
        #expect(model.state == .trustPrompt(fingerprint: fingerprint))
        #expect(env.servers.server(id: server.id)?.hostKeyFingerprint == nil)
        await finish()
    }

    /// Ключ в `HostKeyStore` без подтверждения в конфиге — например, приложение закрыли при
    /// открытом вопросе или поле сбросили при живом соединении — вопрос задаётся снова.
    @Test func unconfirmedKeyAsksAgain() async throws {
        let server = try await Bench.addServer(to: env)
        let model = ServerCheckModel(serverID: server.id, environment: env)
        await model.check().value
        guard case let .trustPrompt(fingerprint) = model.state else {
            Issue.record("expected trustPrompt, got \(model.state)")
            return
        }

        // вопрос остался без ответа, соединение переподключилось: `hostKeyFirstSeen` уже false
        await env.pool.existing(id: server.id)?.disconnect()
        let again = ServerCheckModel(serverID: server.id, environment: env)
        await again.check().value
        #expect(again.state == .trustPrompt(fingerprint: fingerprint))
        #expect(env.servers.server(id: server.id)?.hostKeyFingerprint == nil)

        await again.trust().value
        #expect(env.servers.server(id: server.id)?.hostKeyFingerprint == fingerprint)

        // «Сбросить отпечаток» в форме при живом соединении
        try await env.servers.resetFingerprint(id: server.id)
        await again.check().value
        #expect(again.state == .trustPrompt(fingerprint: fingerprint))
        #expect(try await env.hostKeys.fingerprint(for: server.host, port: server.port) == nil)

        // ядро на живом соединении ключ не пересохраняет: это делает «Доверять»
        await again.trust().value
        #expect(try await env.hostKeys.fingerprint(for: server.host, port: server.port) == fingerprint)
        await finish()
    }
}
