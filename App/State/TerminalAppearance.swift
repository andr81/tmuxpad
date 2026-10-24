import Foundation
import Observation

/// Настройки терминалов (§3.5, §3.6): одно значение каждого на устройство в `UserDefaults`,
/// меняются сразу во всех открытых `TmuxTerminalView` без их пересоздания — раздел «Терминал»
/// настроек, pinch и «Размер шрифта» в `[⋯]`. После смены шрифта SwiftTerm сам пересчитывает
/// сетку и зовёт `sizeChanged` → `resize`. Тема заодно — тема всего приложения.
@MainActor
@Observable
final class TerminalAppearance {
    private(set) var fontSize: Int
    var font: TerminalFont {
        didSet { changed(TerminalSettings.fontNameKey, font.rawValue) }
    }
    var theme: AppTheme {
        didSet { changed(TerminalSettings.themeKey, theme.rawValue) }
    }
    var optionAsMeta: Bool {
        didSet { changed(TerminalSettings.optionAsMetaKey, optionAsMeta) }
    }
    var bell: Bool {
        didSet { changed(TerminalSettings.bellKey, bell ? "sound" : "off") }
    }
    var keyBar: KeyBarMode {
        didSet { changed(TerminalSettings.keyBarKey, keyBar.rawValue) }
    }

    var style: TerminalStyle {
        TerminalStyle(font: font, fontSize: fontSize, theme: theme, optionAsMeta: optionAsMeta, bell: bell, keyBar: keyBar)
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let views = NSHashTable<TmuxTerminalView>.weakObjects()

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let style = TerminalSettings.style(defaults)
        fontSize = style.fontSize
        font = style.font
        theme = style.theme
        optionAsMeta = style.optionAsMeta
        bell = style.bell
        keyBar = style.keyBar
    }

    /// Терминал открыт: текущие настройки и pinch. Закрытый уходит сам — ссылка слабая.
    func attach(_ view: TmuxTerminalView) {
        views.add(view)
        view.apply(style)
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
        changed(TerminalSettings.fontSizeKey, clamped)
    }

    private func changed(_ key: String, _ value: Any) {
        defaults.set(value, forKey: key)
        let style = style
        for view in views.allObjects {
            view.apply(style)
        }
    }
}
