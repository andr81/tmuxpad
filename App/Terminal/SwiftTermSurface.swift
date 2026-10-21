import Foundation
import SwiftTerm
import TmuxPadCore

/// `TerminalSurface` ядра поверх `TerminalView` SwiftTerm (§5). Ядро зовёт не с main:
/// `feed(byteArray:)` и `terminalDimensions` у SwiftTerm `nonisolated` и рассчитаны на фоновый
/// поток, поэтому без прыжка на main. Состояние и чип уходят в замыкания — на main их переносит
/// владелец (`OpenTerminal`).
final class SwiftTermSurface: TerminalSurface, @unchecked Sendable {
    /// Размер, пока view нет.
    static let fallbackSize = (cols: 80, rows: 24)

    private weak var view: TerminalView?
    private let onState: @Sendable (TerminalState) -> Void
    private let onCopyModeSuspected: @Sendable (Bool) -> Void

    init(
        view: TerminalView,
        stateChanged: @escaping @Sendable (TerminalState) -> Void = { _ in },
        copyModeSuspected: @escaping @Sendable (Bool) -> Void = { _ in }
    ) {
        self.view = view
        onState = stateChanged
        onCopyModeSuspected = copyModeSuspected
    }

    func feed(_ bytes: Data) {
        view?.feed(byteArray: [UInt8](bytes)[...])
    }

    var size: (cols: Int, rows: Int) {
        guard let dimensions = view?.terminalDimensions else {
            return Self.fallbackSize
        }
        return (dimensions.cols, dimensions.rows)
    }

    func stateChanged(_ state: TerminalState) {
        onState(state)
    }

    func copyModeSuspected(_ suspected: Bool) {
        onCopyModeSuspected(suspected)
    }
}
