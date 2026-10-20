import Foundation
@testable import TmuxPadCore

struct FakeError: Error, Equatable, CustomStringConvertible {
    var description: String
}

/// Соединение без сети: ответы `exec` из очереди, журнал вызовов, ручной обрыв.
final class FakeConnection: SSHConnection, @unchecked Sendable {
    struct Response {
        var matches: @Sendable (String) -> Bool
        var result: Result<ExecResult, Error>
    }

    struct Call: Equatable {
        var command: String
        var stdin: Data?
    }

    private let lock = NSLock()
    private var responses: [Response] = []
    private var calls: [Call] = []
    private var connected = true
    let onDisconnect: AsyncStream<Void>
    private let disconnectContinuation: AsyncStream<Void>.Continuation

    init() {
        (onDisconnect, disconnectContinuation) = AsyncStream.makeStream()
    }

    /// Первый подходящий ответ уходит из очереди; без подходящего — код 0 и пустой вывод.
    func respond(when matches: @escaping @Sendable (String) -> Bool, with result: Result<ExecResult, Error>) {
        lock.withLock { responses.append(Response(matches: matches, result: result)) }
    }

    /// Ответ на команду, содержащую `fragment`.
    func respond(containing fragment: String, exitCode: Int = 0, stdout: String = "", stderr: String = "") {
        respond(when: { $0.contains(fragment) }, with: .success(Self.result(exitCode: exitCode, stdout: stdout, stderr: stderr)))
    }

    static func result(exitCode: Int = 0, stdout: String = "", stderr: String = "") -> ExecResult {
        ExecResult(exitCode: exitCode, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8), duration: .milliseconds(1))
    }

    var execCalls: [Call] {
        lock.withLock { calls }
    }

    /// Изображает обрыв: `onDisconnect` срабатывает, `isConnected == false`.
    func disconnect() {
        lock.withLock { connected = false }
        disconnectContinuation.yield()
        disconnectContinuation.finish()
    }

    var isConnected: Bool {
        lock.withLock { connected }
    }

    func exec(_ command: String, stdin: Data?, environment: [String: String], timeout: Duration) async throws -> ExecResult {
        let result: Result<ExecResult, Error> = lock.withLock {
            calls.append(Call(command: command, stdin: stdin))
            guard connected else {
                return .failure(SSHError.disconnected)
            }
            if let index = responses.firstIndex(where: { $0.matches(command) }) {
                return responses.remove(at: index).result
            }
            return .success(Self.result())
        }
        return try result.get()
    }

    func openPTY(command: String, term: String, cols: Int, rows: Int, environment: [String: String]) async throws -> any PTYChannel {
        throw FakeError(description: "openPTY unimplemented")
    }

    func close() async {
        disconnect()
    }
}
