import Foundation
import SwiftTerm
import Testing
import UIKit
@testable import TmuxPad

@MainActor
struct CompactKeyBarTests {
    let view = TmuxTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    let recorder = SentRecorder()

    init() {
        view.terminalDelegate = recorder
    }

    /// Панель стоит у view, как после `TerminalAppearance`: SwiftTerm читает Ctrl у view, только
    /// когда панель не `TerminalAccessory`.
    private func installed() -> CompactKeyBar {
        let bar = CompactKeyBar(terminal: view)
        view.inputAccessoryView = bar
        return bar
    }

    private func button(_ bar: CompactKeyBar, _ label: String) throws -> UIButton {
        let buttons = bar.subviews.flatMap(\.subviews).compactMap { $0 as? UIButton }
        return try #require(buttons.first { $0.accessibilityLabel == label })
    }

    @Test func keysReachDelegate() throws {
        let bar = installed()
        try button(bar, "Escape").sendActions(for: .touchDown)
        try button(bar, "Tab").sendActions(for: .touchDown)
        try button(bar, "Вверх").sendActions(for: .touchDown)
        try button(bar, "Вверх").sendActions(for: .touchUpInside)
        #expect(recorder.sent == [[0x1b], [0x09], EscapeSequences.moveUpNormal])
    }

    @Test func controlIsStickyUntilNextKey() throws {
        let bar = installed()
        let control = try button(bar, "Control")
        control.sendActions(for: .touchDown)
        #expect(view.controlModifier)
        #expect(control.isSelected)
        // Ctrl+C: SwiftTerm применяет модификатор и сбрасывает его
        view.insertText("c")
        #expect(recorder.sent.last == [0x03])
        #expect(!view.controlModifier)
        #expect(!control.isSelected)
    }

    @Test func compactBarIsShorterThanFull() {
        #expect(CompactKeyBar(terminal: view).intrinsicContentSize.height < 48)
    }
}

final class SentRecorder: TerminalViewDelegate {
    private(set) var sent: [[UInt8]] = []

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        sent.append(Array(data))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
