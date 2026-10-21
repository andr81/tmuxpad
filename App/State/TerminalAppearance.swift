import Foundation
import Observation

/// Размер шрифта терминалов (§3.5): одно значение на устройство в `UserDefaults`, меняется
/// сразу во всех открытых `TmuxTerminalView` — pinch любого из них и «Размер шрифта» в `[⋯]`.
/// SwiftTerm сам пересчитывает сетку и зовёт `sizeChanged` → `resize`.
@MainActor
@Observable
final class TerminalAppearance {
    private(set) var fontSize: Int

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let views = NSHashTable<TmuxTerminalView>.weakObjects()

    init(defaults: UserDefaults) {
        self.defaults = defaults
        fontSize = TerminalSettings.fontSize(defaults)
    }

    /// Терминал открыт: текущий шрифт и pinch. Закрытый уходит сам — ссылка слабая.
    func attach(_ view: TmuxTerminalView) {
        views.add(view)
        view.setFontSize(fontSize)
        view.onFontStep = { [weak self] step in
            guard let self else {
                return
            }
            setFontSize(fontSize + step)
        }
    }

    /// Значение вне `TerminalSettings.fontSizeRange` прижимается к границе.
    func setFontSize(_ size: Int) {
        let range = TerminalSettings.fontSizeRange
        let clamped = min(max(size, range.lowerBound), range.upperBound)
        guard clamped != fontSize else {
            return
        }
        fontSize = clamped
        defaults.set(clamped, forKey: TerminalSettings.fontSizeKey)
        for view in views.allObjects {
            view.setFontSize(clamped)
        }
    }
}
