import Foundation
import SwiftTerm
import Testing
import UIKit
@testable import TmuxPad

@MainActor
struct TerminalKeyBarTests {
    let view = TmuxTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    let recorder = SentRecorder()

    init() {
        view.terminalDelegate = recorder
    }

    /// Панель стоит у view, как после `TerminalAppearance`: SwiftTerm читает Ctrl у view, только
    /// когда панель не его `TerminalAccessory`.
    private func installed() -> TerminalKeyBar {
        let bar = TerminalKeyBar(terminal: view)
        view.inputAccessoryView = bar
        return bar
    }

    private func button(_ bar: TerminalKeyBar, _ label: String) throws -> UIButton {
        let buttons = bar.subviews.flatMap(\.subviews).compactMap { $0 as? UIButton }
        return try #require(buttons.first { $0.accessibilityLabel == label })
    }

    @Test func keysReachDelegate() throws {
        let bar = installed()
        try button(bar, "Escape").sendActions(for: .touchDown)
        try button(bar, "Tab").sendActions(for: .touchDown)
        try button(bar, "Shift-Tab").sendActions(for: .touchDown)
        try button(bar, "Новая строка").sendActions(for: .touchDown)
        try button(bar, "Вверх").sendActions(for: .touchDown)
        try button(bar, "Вверх").sendActions(for: .touchUpInside)
        #expect(recorder.sent == [[0x1b], [0x09], [0x1b, 0x5b, 0x5a], [0x0a], EscapeSequences.moveUpNormal])
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

    /// iPhone 12 mini в портрете: все кнопки, включая «скрыть клавиатуру», влезают в ширину.
    @Test func keysFitNarrowPhone() throws {
        let bar = TerminalKeyBar(terminal: view)
        bar.frame = CGRect(x: 0, y: 0, width: 375, height: TerminalKeyBar.height)
        bar.layoutIfNeeded()
        let buttons = bar.subviews.flatMap(\.subviews).compactMap { $0 as? UIButton }
        #expect(buttons.count == 10)
        let frames = buttons.map { $0.convert($0.bounds, to: bar) }.sorted { $0.minX < $1.minX }
        for (frame, next) in zip(frames, frames.dropFirst()) {
            #expect(frame.maxX <= next.minX)
        }
        #expect(try #require(frames.first).minX >= 0)
        #expect(try #require(frames.last).maxX <= 375)
        // «ctrl» не обрезан: кнопка не уже своего текста
        let control = try button(bar, "Control")
        let title = try #require(control.titleLabel)
        #expect(control.bounds.width >= title.intrinsicContentSize.width)
    }

    @Test func hideButtonDismissesKeyboard() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        window.addSubview(view)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let bar = installed()
        #expect(view.becomeFirstResponder())
        try button(bar, "Скрыть клавиатуру").sendActions(for: .touchUpInside)
        #expect(!view.isFirstResponder)
        view.toggleKeyboard()
        #expect(view.isFirstResponder)
        view.toggleKeyboard()
        #expect(!view.isFirstResponder)
    }

    @Test func barIsOneNarrowRow() {
        #expect(TerminalKeyBar(terminal: view).intrinsicContentSize.height == TerminalKeyBar.height)
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
