import SwiftTerm
import UIKit

/// Настройки терминала в `UserDefaults`; экран настроек — план 7.
enum TerminalSettings {
    static let fontSizeKey = "terminal.fontSize"
    static let optionAsMetaKey = "terminal.optionAsMeta"
    static let bellKey = "terminal.bell"

    static let defaultFontSize = 14
    static let fontSizeRange = 9...32

    static func fontSize(_ defaults: UserDefaults) -> Int {
        guard let value = defaults.object(forKey: fontSizeKey) as? Int else {
            return defaultFontSize
        }
        return min(max(value, fontSizeRange.lowerBound), fontSizeRange.upperBound)
    }

    static func optionAsMeta(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: optionAsMetaKey) as? Bool ?? true
    }

    /// `sound` (по умолчанию) или `off`.
    static func bellEnabled(_ defaults: UserDefaults) -> Bool {
        defaults.string(forKey: bellKey) != "off"
    }

    static func font(size: Int) -> UIFont {
        UIFont.monospacedSystemFont(ofSize: CGFloat(size), weight: .regular)
    }
}

/// `TerminalView` открытой сессии: создаётся один раз и живёт, пока терминал открыт (§5).
/// ⌘-клавиши SwiftTerm 1.99.0 в `pressesBegan` пропускает, поэтому шорткаты приложения работают
/// без своего `pressesBegan`. Экранная панель — встроенный `TerminalAccessory`.
final class TmuxTerminalView: TerminalView {
    /// Порог накопленного масштаба pinch на шаг шрифта.
    static let pinchThreshold: CGFloat = 0.12

    /// Pinch насобирал шаг: +1 или −1 pt. Размер меняет владелец (`TerminalAppearance`).
    var onFontStep: ((Int) -> Void)?

    private var pinchBase: CGFloat = 1

    init(frame: CGRect = .zero, defaults: UserDefaults = .standard) {
        super.init(frame: frame, font: TerminalSettings.font(size: TerminalSettings.fontSize(defaults)))
        optionAsMetaKey = TerminalSettings.optionAsMeta(defaults)
        allowMouseReporting = true
        bellStyle = TerminalSettings.bellEnabled(defaults) ? .sound : .none
        addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:))))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func setFontSize(_ size: Int) {
        font = TerminalSettings.font(size: size)
    }

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
