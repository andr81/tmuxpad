import Foundation
import SwiftTerm
import UIKit
import UniformTypeIdentifiers

/// Делегат `TerminalView` открытой сессии: ввод — в `InputPump`, размер — в PTY, OSC 52 — в
/// буфер обмена iPad. Чтение буфера сервером не разрешаем (§8 по духу): `clipboardRead` —
/// реализация SwiftTerm по умолчанию, `nil`. Звонок — тоже по умолчанию (отклик вибрацией),
/// включает и выключает его `bellStyle` view.
final class TerminalDelegate: TerminalViewDelegate {
    private let pump: InputPump
    private let resize: @Sendable (Int, Int) async throws -> Void

    init(pump: InputPump, resize: @escaping @Sendable (Int, Int) async throws -> Void) {
        self.pump = pump
        self.resize = resize
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        pump.send(Data(data))
    }

    /// Порядок не важен: на стороне tmux побеждает последний размер.
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        let resize = resize
        Task {
            try? await resize(newCols, newRows)
        }
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        guard String(data: content, encoding: .utf8) != nil else {
            return
        }
        UIPasteboard.general.setData(content, forPasteboardType: UTType.utf8PlainText.identifier)
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return
        }
        UIApplication.shared.open(url)
    }

    func setTerminalTitle(source: TerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func scrolled(source: TerminalView, position: Double) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
