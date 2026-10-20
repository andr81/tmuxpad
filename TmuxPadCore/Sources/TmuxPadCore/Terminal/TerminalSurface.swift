import Foundation

/// Экран терминала (§5): приложение реализует его на SwiftTerm, ядро только пишет в него.
/// Вызовы приходят с произвольного исполнителя; прыжок на main — дело реализации.
public protocol TerminalSurface: AnyObject, Sendable {
    /// Байты вывода PTY-канала.
    func feed(_ bytes: Data)
    /// Текущий размер в символах; читается при открытии канала.
    var size: (cols: Int, rows: Int) { get }
    func stateChanged(_ state: TerminalState)
    /// Чип «Прокрутка ✕» (§3.5): pane, вероятно, в copy-mode. Вызывается только при смене
    /// значения, не с main.
    func copyModeSuspected(_ suspected: Bool)
}

extension TerminalSurface {
    public func copyModeSuspected(_ suspected: Bool) {}
}
