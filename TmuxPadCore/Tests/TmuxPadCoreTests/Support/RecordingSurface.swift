import Foundation
@testable import TmuxPadCore

/// Экран для тестов: копит байты, состояния и вызовы `copyModeSuspected`, размер задаётся.
final class RecordingSurface: TerminalSurface, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var recorded: [TerminalState] = []
    private var suspicions: [Bool] = []
    private var currentSize: (cols: Int, rows: Int)

    init(cols: Int = 80, rows: Int = 24) {
        currentSize = (cols, rows)
    }

    var size: (cols: Int, rows: Int) {
        get { lock.withLock { currentSize } }
        set { lock.withLock { currentSize = newValue } }
    }

    func feed(_ bytes: Data) {
        lock.withLock { self.bytes.append(bytes) }
    }

    func stateChanged(_ state: TerminalState) {
        lock.withLock { recorded.append(state) }
    }

    func copyModeSuspected(_ suspected: Bool) {
        lock.withLock { suspicions.append(suspected) }
    }

    /// Аргументы `copyModeSuspected` по порядку.
    var copyModeCalls: [Bool] {
        lock.withLock { suspicions }
    }

    var output: Data {
        lock.withLock { bytes }
    }

    var text: String {
        String(decoding: output, as: UTF8.self)
    }

    var states: [TerminalState] {
        lock.withLock { recorded }
    }

    /// Ждёт, пока последнее состояние не станет `state`.
    func waitFor(_ state: TerminalState, _ timeout: Duration = .seconds(3)) async throws -> Bool {
        try await Bench.eventually(timeout) { self.states.last == state }
    }
}
