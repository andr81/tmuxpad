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
    private let sizes: AsyncStream<(cols: Int, rows: Int)>.Continuation
    private let resizer: Task<Void, Never>

    /// Размеры уходят в `resize` по одному и по порядку: tmux оставляет последний пришедший, а
    /// `Task` на каждый `sizeChanged` мог бы прислать устаревший последним. Из очереди
    /// берётся только последний, промежуточные при pinch не нужны.
    init(pump: InputPump, resize: @escaping @Sendable (Int, Int) async throws -> Void) {
        self.pump = pump
        let (stream, continuation) = AsyncStream<(cols: Int, rows: Int)>.makeStream(bufferingPolicy: .bufferingNewest(1))
        sizes = continuation
        resizer = Task {
            for await size in stream {
                try? await resize(size.cols, size.rows)
            }
        }
    }

    deinit {
        sizes.finish()
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        pump.send(Data(data))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        requestResize(cols: newCols, rows: newRows)
    }

    /// Размер в PTY; и повторно, когда канал открылся (`OpenTerminal`).
    func requestResize(cols: Int, rows: Int) {
        sizes.yield((cols, rows))
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        guard String(data: content, encoding: .utf8) != nil else {
            return
        }
        UIPasteboard.general.setData(content, forPasteboardType: UTType.utf8PlainText.identifier)
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = Self.openableURL(link) else {
            return
        }
        UIApplication.shared.open(url)
    }

    /// Ссылку присылает сервер: открываем только `http`/`https`, не `tel:`, `file:` и схемы приложений.
    static func openableURL(_ link: String) -> URL? {
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }

    func setTerminalTitle(source: TerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func scrolled(source: TerminalView, position: Double) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
