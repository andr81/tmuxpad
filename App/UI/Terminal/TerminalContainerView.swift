import UIKit

/// Держит `TmuxTerminalView` выделенной сессии: при смене выделения снимает старый и ставит
/// новый, сам `TerminalView` не пересоздаётся (§5). Низ — по клавиатуре: экранная клавиатура и
/// `TerminalAccessory` не закрывают нижние строки.
final class TerminalContainerView: UIView {
    private(set) weak var current: TmuxTerminalView?

    func show(_ view: TmuxTerminalView?) {
        guard current !== view else {
            return
        }
        current?.removeFromSuperview()
        current = view
        guard let view else {
            return
        }
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
        ])
        focus()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        focus()
    }

    /// Ввод — в текущий терминал; вне окна first responder не назначить.
    func focus() {
        guard window != nil, let current, !current.isFirstResponder else {
            return
        }
        _ = current.becomeFirstResponder()
    }
}
