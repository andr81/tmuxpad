import SwiftTerm
import UIKit

/// Компактная панель клавиш (§3.5): Esc, Ctrl, Tab и стрелки одной узкой полосой — для
/// аппаратной клавиатуры без Esc. Клавиши идут через `TerminalView.send`, как у встроенного
/// `TerminalAccessory`, а значит через делегат в `InputPump`.
final class CompactKeyBar: UIInputView, UIInputViewAudioFeedback {
    static let height: CGFloat = 32

    /// Задержка перед автоповтором стрелки и его шаг.
    static let repeatDelay: TimeInterval = 0.5
    static let repeatInterval: TimeInterval = 0.1

    private weak var terminal: TerminalView?
    private var repeatTimer: Timer?
    private(set) var controlButton: UIButton!

    init(terminal: TerminalView) {
        self.terminal = terminal
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: Self.height), inputViewStyle: .keyboard)
        allowsSelfSizing = true

        let escape = key(title: "esc", label: "Escape") { $0.send([0x1b]) }
        controlButton = makeButton(title: "ctrl", label: "Control")
        controlButton.addAction(UIAction { [weak self] _ in self?.toggleControl() }, for: .touchDown)
        let tab = key(symbol: "arrow.right.to.line.compact", label: "Tab") { $0.send([0x09]) }
        let arrows = [
            repeatingKey(symbol: "arrow.left", label: "Влево") { $0.sendKeyLeft() },
            repeatingKey(symbol: "arrow.down", label: "Вниз") { $0.sendKeyDown() },
            repeatingKey(symbol: "arrow.up", label: "Вверх") { $0.sendKeyUp() },
            repeatingKey(symbol: "arrow.right", label: "Вправо") { $0.sendKeyRight() },
        ]
        let row = UIStackView(arrangedSubviews: [escape, controlButton, tab, UIView()] + arrows)
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
        // Ctrl сбрасывает сам SwiftTerm после следующей клавиши
        NotificationCenter.default.addObserver(
            self, selector: #selector(controlReset), name: .terminalViewControlModifierReset, object: terminal
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.height)
    }

    var enableInputClicksWhenVisible: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            stopRepeat()
        }
    }

    private func toggleControl() {
        guard let terminal else {
            return
        }
        UIDevice.current.playInputClick()
        terminal.controlModifier.toggle()
        controlButton.isSelected = terminal.controlModifier
    }

    @objc private func controlReset() {
        controlButton.isSelected = false
    }

    private func press(_ action: @MainActor (TerminalView) -> Void) {
        guard let terminal else {
            return
        }
        UIDevice.current.playInputClick()
        action(terminal)
    }

    private func key(title: String? = nil, symbol: String? = nil, label: String, _ action: @escaping @MainActor (TerminalView) -> Void) -> UIButton {
        let button = makeButton(title: title, symbol: symbol, label: label)
        button.addAction(UIAction { [weak self] _ in self?.press(action) }, for: .touchDown)
        return button
    }

    /// Стрелка: нажатие сразу, при удержании — повтор, как у клавиатуры.
    private func repeatingKey(symbol: String, label: String, _ action: @escaping @MainActor @Sendable (TerminalView) -> Void) -> UIButton {
        let button = makeButton(symbol: symbol, label: label)
        button.addAction(UIAction { [weak self] _ in self?.startRepeat(action) }, for: .touchDown)
        button.addAction(UIAction { [weak self] _ in self?.stopRepeat() }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return button
    }

    private func startRepeat(_ action: @escaping @MainActor @Sendable (TerminalView) -> Void) {
        stopRepeat()
        press(action)
        repeatTimer = Timer.scheduledTimer(withTimeInterval: Self.repeatDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: Self.repeatInterval, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.press(action)
                    }
                }
            }
        }
    }

    private func stopRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    private func makeButton(title: String? = nil, symbol: String? = nil, label: String) -> UIButton {
        var config = UIButton.Configuration.gray()
        config.buttonSize = .small
        config.cornerStyle = .medium
        config.title = title
        config.image = symbol.flatMap { UIImage(systemName: $0) }
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 13)
        config.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12)
        let button = UIButton(configuration: config)
        button.accessibilityLabel = label
        // выбранный Ctrl — залитый, как у `TerminalAccessory`
        button.configurationUpdateHandler = { button in
            var config = button.configuration
            config?.baseBackgroundColor = button.isSelected ? .tintColor : nil
            config?.baseForegroundColor = button.isSelected ? .white : .label
            button.configuration = config
        }
        return button
    }
}
