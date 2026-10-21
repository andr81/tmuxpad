import Foundation
import SwiftTerm
import Testing
@testable import TmuxPad

/// Спайк фазы 0: `TerminalView` вне экрана, делегат замыкает ввод на вывод.
@MainActor
@Suite struct EchoTests {
    @Test func typedTextIsEchoed() async throws {
        let view = TmuxTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = EchoDelegate()
        view.terminalDelegate = delegate
        view.insertText("hello")
        try await waitUntil { screenText(view).contains("hello") }
        #expect(screenText(view).contains("hello"))
    }
}

/// Текст всех видимых строк.
func screenText(_ view: TerminalView) -> String {
    view.visibleRowsText(0..<view.terminalDimensions.rows).joined(separator: "\n")
}

private final class EchoDelegate: TerminalViewDelegate {
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        source.feed(byteArray: data)
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
