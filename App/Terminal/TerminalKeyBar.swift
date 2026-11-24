import SwiftTerm
import UIKit

/// Панель клавиш над системной клавиатурой (§3.5): один узкий ряд того, чего нет ни на экранной
/// клавиатуре iPad, ни на чехлах — Esc, Ctrl, Tab, ⇧Tab, перевод строки и стрелки, и последней
/// кнопка «скрыть клавиатуру»: на iPhone своей такой нет. Клавиши идут через `TerminalView.send`,
/// а значит через делегат в `InputPump`.
final class TerminalKeyBar: UIInputView, UIInputViewAudioFeedback {
    static let height: CGFloat = 32

    /// Уже этой ширины (iPhone в портрете) кнопки делят ряд поровну и без пустого промежутка.
    static let compactWidth: CGFloat = 500

    /// Задержка перед автоповтором стрелки и его шаг.
    static let repeatDelay: TimeInterval = 0.5
    static let repeatInterval: TimeInterval = 0.1

    private weak var terminal: TerminalView?
    private var repeatTimer: Timer?
    private(set) var controlButton: UIButton!
    private let row = UIStackView()
    private let spacer = UIView()
    private var buttons: [UIButton] = []
    /// Применённая раскладка; `nil` — ещё ни одной.
    private var compact: Bool?

    init(terminal: TerminalView) {
        self.terminal = terminal
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: Self.height), inputViewStyle: .keyboard)
        allowsSelfSizing = true

        let escape = key(title: "esc", label: "Escape") { $0.send([0x1b]) }
        let control = makeButton(title: "ctrl", label: "Control")
        controlButton = control
        control.addAction(UIAction { [weak self] _ in self?.toggleControl() }, for: .touchDown)
        let tab = key(symbol: "arrow.right.to.line.compact", label: "Tab") { $0.send([0x09]) }
        // ⇧Tab в Claude Code переключает режимы (auto-accept, plan)
        let backTab = key(symbol: "arrow.left.to.line.compact", label: "Shift-Tab") { $0.send(EscapeSequences.cmdBackTab) }
        // Ctrl-J — новая строка в поле ввода Claude Code; Shift-Enter экранная клавиатура не даёт
        let newline = key(symbol: "return", label: "Новая строка") { $0.send([0x0a]) }
        let arrows = [
            repeatingKey(symbol: "arrow.left", label: "Влево") { $0.sendKeyLeft() },
            repeatingKey(symbol: "arrow.down", label: "Вниз") { $0.sendKeyDown() },
            repeatingKey(symbol: "arrow.up", label: "Вверх") { $0.sendKeyUp() },
            repeatingKey(symbol: "arrow.right", label: "Вправо") { $0.sendKeyRight() },
        ]
        let hide = makeButton(symbol: "keyboard.chevron.compact.down", label: "Скрыть клавиатуру")
        hide.addAction(UIAction { [weak self] _ in self?.hideKeyboard() }, for: .touchUpInside)
        buttons = [escape, control, tab, backTab, newline] + arrows + [hide]
        for view in [escape, control, tab, backTab, newline, spacer] + arrows + [hide] {
            row.addArrangedSubview(view)
        }
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

    override func layoutSubviews() {
        applyLayout(compact: bounds.width < Self.compactWidth)
        super.layoutSubviews()
    }

    /// Узкий экран: кнопки поровну на всю ширину, узкие отступы; иначе — свой размер и слева
    /// Esc…перевод строки, справа стрелки.
    private func applyLayout(compact: Bool) {
        guard compact != self.compact else {
            return
        }
        self.compact = compact
        row.distribution = compact ? .fillEqually : .fill
        row.spacing = compact ? 4 : 6
        spacer.isHidden = compact
        directionalLayoutMargins.leading = compact ? 4 : 8
        directionalLayoutMargins.trailing = compact ? 4 : 8
        let inset: CGFloat = compact ? 0 : 12
        for button in buttons {
            button.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: inset, bottom: 2, trailing: inset)
        }
    }

    private func hideKeyboard() {
        stopRepeat()
        _ = terminal?.resignFirstResponder()
    }

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
        let button = UIButton(configuration: config)
        button.accessibilityLabel = label
        // выбранный Ctrl — залитый
        button.configurationUpdateHandler = { button in
            var config = button.configuration
            config?.baseBackgroundColor = button.isSelected ? .tintColor : nil
            config?.baseForegroundColor = button.isSelected ? .white : .label
            button.configuration = config
        }
        return button
    }
}
