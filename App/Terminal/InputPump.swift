import Foundation
import TmuxPadCore

/// Поток ввода одного терминала. Делегат SwiftTerm зовёт `send` на main синхронно, и
/// `Task` на каждый вызов не держал бы порядок байтов; поэтому один поток и одна задача, которая
/// по очереди отдаёт байты приёмнику (`TerminalSession.input`).
final class InputPump: Sendable {
    private let continuation: AsyncStream<Data>.Continuation
    private let consumer: Task<Void, Never>

    /// `onError` — ошибки приёмника (`SSHError.disconnected`); после ошибки поток работает дальше.
    init(
        sink: @escaping @Sendable (Data) async throws -> Void,
        onError: @escaping @Sendable (Error) async -> Void = { _ in }
    ) {
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation
        consumer = Task {
            for await bytes in stream {
                do {
                    try await sink(bytes)
                } catch {
                    await onError(error)
                }
            }
        }
    }

    /// Ввод в сессию; ошибки — в журнал диагностики, плашку покажет состояние сессии.
    convenience init(session: TerminalSession, log: DiagnosticsLog?, server: String) {
        self.init(
            sink: { try await session.input($0) },
            onError: { error in
                await log?.record(server: server, kind: .terminal, "input failed: \(error)")
            })
    }

    deinit {
        continuation.finish()
    }

    func send(_ bytes: Data) {
        continuation.yield(bytes)
    }

    /// Терминал закрыт: невыданные байты отбрасываются.
    func finish() {
        continuation.finish()
        consumer.cancel()
    }
}
