import SwiftTerm
import SwiftUI
import UIKit

/// Настройки терминала в `UserDefaults` (§3.6); экран — `TerminalSettingsView`, хранит и
/// рассылает их `TerminalAppearance`.
enum TerminalSettings {
    static let fontNameKey = "terminal.fontName"
    static let fontSizeKey = "terminal.fontSize"
    static let themeKey = "terminal.theme"
    static let optionAsMetaKey = "terminal.optionAsMeta"
    static let bellKey = "terminal.bell"
    static let keyBarKey = "terminal.keyBar"

    static let defaultFontSize = 14
    static let fontSizeRange = 9...32

    static func fontName(_ defaults: UserDefaults) -> TerminalFont {
        defaults.string(forKey: fontNameKey).flatMap(TerminalFont.init(rawValue:)) ?? TerminalStyle.standard.font
    }

    static func fontSize(_ defaults: UserDefaults) -> Int {
        guard let value = defaults.object(forKey: fontSizeKey) as? Int else {
            return defaultFontSize
        }
        return min(max(value, fontSizeRange.lowerBound), fontSizeRange.upperBound)
    }

    static func theme(_ defaults: UserDefaults) -> AppTheme {
        defaults.string(forKey: themeKey).flatMap(AppTheme.init(rawValue:)) ?? TerminalStyle.standard.theme
    }

    static func optionAsMeta(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: optionAsMetaKey) as? Bool ?? TerminalStyle.standard.optionAsMeta
    }

    /// `sound` (по умолчанию) или `off`.
    static func bellEnabled(_ defaults: UserDefaults) -> Bool {
        defaults.string(forKey: bellKey).map { $0 != "off" } ?? TerminalStyle.standard.bell
    }

    static func keyBar(_ defaults: UserDefaults) -> KeyBarMode {
        defaults.string(forKey: keyBarKey).flatMap(KeyBarMode.init(rawValue:)) ?? TerminalStyle.standard.keyBar
    }

    static func style(_ defaults: UserDefaults) -> TerminalStyle {
        TerminalStyle(
            font: fontName(defaults),
            fontSize: fontSize(defaults),
            theme: theme(defaults),
            optionAsMeta: optionAsMeta(defaults),
            bell: bellEnabled(defaults),
            keyBar: keyBar(defaults)
        )
    }
}

/// Шрифт терминала. SF Mono в iOS-приложениях недоступен.
enum TerminalFont: String, CaseIterable, Identifiable {
    case system
    case menlo = "Menlo"
    case courierNew = "Courier New"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Системный моноширинный"
        case .menlo: "Menlo"
        case .courierNew: "Courier New"
        }
    }

    /// Шрифта нет на устройстве — системный моноширинный.
    func uiFont(size: Int) -> UIFont {
        let size = CGFloat(size)
        let name = switch self {
        case .system: nil as String?
        case .menlo: "Menlo-Regular"
        case .courierNew: "CourierNewPSMT"
        }
        return name.flatMap { UIFont(name: $0, size: size) } ?? UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

/// Панель клавиш над клавиатурой (§3.5).
enum KeyBarMode: String, CaseIterable, Identifiable {
    /// Встроенный `TerminalAccessory` SwiftTerm.
    case full
    /// `CompactKeyBar`: Esc, Ctrl, Tab и стрелки.
    case compact
    case hidden

    var id: String { rawValue }

    var title: String {
        switch self {
        case .full: "Полная"
        case .compact: "Компактная"
        case .hidden: "Скрыта"
        }
    }
}

/// Тема приложения и терминала.
enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Как система"
        case .light: "Светлая"
        case .dark: "Тёмная"
        }
    }

    /// Для `preferredColorScheme`: `nil` — как система.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Цвета терминала под светлую и тёмную тему; ANSI-палитра — SwiftTerm по умолчанию.
struct TerminalPalette: Equatable {
    let foreground: UIColor
    let background: UIColor
    let caret: UIColor

    static let light = TerminalPalette(
        foreground: UIColor(white: 0.1, alpha: 1),
        background: UIColor(white: 1, alpha: 1),
        caret: UIColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1)
    )
    static let dark = TerminalPalette(
        foreground: UIColor(white: 0.9, alpha: 1),
        background: UIColor(white: 0.08, alpha: 1),
        caret: UIColor(red: 0.45, green: 0.7, blue: 1, alpha: 1)
    )

    static func of(_ style: UIUserInterfaceStyle) -> TerminalPalette {
        style == .dark ? dark : light
    }
}

/// Все параметры терминала разом: `TerminalAppearance` отдаёт их каждому открытому view.
struct TerminalStyle: Equatable {
    var font: TerminalFont
    var fontSize: Int
    var theme: AppTheme
    var optionAsMeta: Bool
    var bell: Bool
    var keyBar: KeyBarMode

    /// Значения, когда в `UserDefaults` ничего нет.
    static let standard = TerminalStyle(
        font: .system,
        fontSize: TerminalSettings.defaultFontSize,
        theme: .system,
        optionAsMeta: true,
        bell: true,
        keyBar: .full
    )
}

/// `TerminalView` открытой сессии: создаётся один раз и живёт, пока терминал открыт (§5).
/// ⌘-клавиши SwiftTerm 1.99.0 в `pressesBegan` пропускает, поэтому шорткаты приложения работают
/// без своего `pressesBegan`. Панель клавиш — по настройке: встроенный `TerminalAccessory`,
/// `CompactKeyBar` или никакой.
final class TmuxTerminalView: TerminalView {
    /// Порог накопленного масштаба pinch на шаг шрифта.
    static let pinchThreshold: CGFloat = 0.12

    /// Pinch насобирал шаг: +1 или −1 pt. Размер меняет владелец (`TerminalAppearance`).
    var onFontStep: ((Int) -> Void)?

    private var pinchBase: CGFloat = 1

    /// Последний применённый стиль; до первого `apply` — по умолчанию.
    private(set) var style = TerminalStyle.standard

    /// Стоящая панель клавиш; `TerminalAccessory` ставит SwiftTerm при создании view.
    private(set) var keyBar = KeyBarMode.full

    override init(frame: CGRect = .zero) {
        super.init(frame: frame, font: TerminalStyle.standard.font.uiFont(size: TerminalStyle.standard.fontSize))
        allowMouseReporting = true
        addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:))))
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: TmuxTerminalView, _: UITraitCollection) in
            view.applyPalette()
        }
        applyNonFont()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Новые настройки без пересоздания view. Шрифт ставится, только если изменился: его
    /// установка пересчитывает сетку и шлёт `resize`.
    func apply(_ style: TerminalStyle) {
        let fontChanged = style.font != self.style.font || style.fontSize != self.style.fontSize
        self.style = style
        if fontChanged {
            font = style.font.uiFont(size: style.fontSize)
        }
        applyNonFont()
    }

    private func applyNonFont() {
        optionAsMetaKey = style.optionAsMeta
        bellStyle = style.bell ? .sound : .none
        applyKeyBar()
        // явная тема — своя у view, иначе от окна; палитру выбирает итоговый стиль
        overrideUserInterfaceStyle = style.theme.interfaceStyle
        applyPalette()
    }

    /// Панель меняется, только если сменилась настройка: иначе пересоздание сбросило бы залипший Ctrl.
    private func applyKeyBar() {
        guard style.keyBar != keyBar else {
            return
        }
        keyBar = style.keyBar
        switch keyBar {
        case .full:
            let accessory = TerminalAccessory(
                frame: CGRect(x: 0, y: 0, width: bounds.width, height: 48), inputViewStyle: .keyboard, container: self
            )
            accessory.sizeToFit()
            inputAccessoryView = accessory
        case .compact:
            inputAccessoryView = CompactKeyBar(terminal: self)
        case .hidden:
            inputAccessoryView = nil
        }
        controlModifier = false
        if isFirstResponder {
            reloadInputViews()
        }
    }

    /// Палитра по теме; «как система» — по стилю окна.
    private func applyPalette() {
        let interface = style.theme == .system ? traitCollection.userInterfaceStyle : style.theme.interfaceStyle
        let palette = TerminalPalette.of(interface)
        guard palette != self.palette else {
            return
        }
        self.palette = palette
        nativeForegroundColor = palette.foreground
        nativeBackgroundColor = palette.background
        layer.backgroundColor = palette.background.cgColor
        caretColor = palette.caret
    }

    /// Применённая палитра; `nil` — ещё ни одной.
    private(set) var palette: TerminalPalette?

    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinchBase = gesture.scale
        case .changed:
            for step in Self.pinchSteps(from: &pinchBase, to: gesture.scale) {
                onFontStep?(step)
            }
        default:
            break
        }
    }

    /// Шаги шрифта, которые даёт изменение масштаба `base` → `scale`; `base` сдвигается на
    /// каждый выданный шаг.
    static func pinchSteps(from base: inout CGFloat, to scale: CGFloat) -> [Int] {
        var steps: [Int] = []
        while scale - base >= pinchThreshold {
            base += pinchThreshold
            steps.append(1)
        }
        while base - scale >= pinchThreshold {
            base -= pinchThreshold
            steps.append(-1)
        }
        return steps
    }
}
