import SwiftUI
import UIKit

/// Фаза сцены для корня оверлея: он живёт в своём окне, вне иерархии `RootView`.
@MainActor
@Observable
final class LockOverlayState {
    var phase: ScenePhase = .active
}

/// Экран блокировки и шторка — в отдельном `UIWindow` над всеми окнами сцены (§3.8): так они
/// закрывают и открытые листы (настройки, мастера, онбординг), и снимок для переключателя приложений.
@MainActor
final class LockOverlayWindow {
    private let lock: AppLock
    private let appearance: TerminalAppearance
    private let state = LockOverlayState()
    private var window: UIWindow?

    init(lock: AppLock, appearance: TerminalAppearance) {
        self.lock = lock
        self.appearance = appearance
    }

    func attach(to scene: UIWindowScene) {
        guard window?.windowScene !== scene else {
            return
        }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        let host = UIHostingController(rootView: LockOverlayRoot(state: state).environment(lock).environment(appearance))
        host.view.backgroundColor = .clear
        window.rootViewController = host
        window.isHidden = true
        self.window = window
        update()
    }

    func phaseChanged(_ phase: ScenePhase) {
        state.phase = phase
        update()
    }

    /// Блокировка — окно ключевое, ввод PIN идёт в него; шторка — только видна.
    func update() {
        guard let window else {
            return
        }
        let locked = lock.isLocked
        if locked || lock.shieldVisible(in: state.phase) {
            if window.isHidden {
                // экранная клавиатура терминала не должна остаться поверх блокировки
                for other in window.windowScene?.windows ?? [] where other !== window {
                    other.endEditing(true)
                }
            }
            if locked {
                window.makeKeyAndVisible()
            } else {
                window.isHidden = false
            }
        } else if !window.isHidden {
            window.isHidden = true
            window.windowScene?.windows.first { $0 !== window && !$0.isHidden }?.makeKey()
        }
    }
}

private struct LockOverlayRoot: View {
    let state: LockOverlayState
    @Environment(AppLock.self) private var lock
    @Environment(TerminalAppearance.self) private var appearance

    var body: some View {
        Group {
            if lock.isLocked {
                AppLockView(phase: state.phase)
            } else {
                PrivacyShield()
            }
        }
        .preferredColorScheme(appearance.theme.colorScheme)
    }
}

/// Шторка для снимка переключателя приложений.
struct PrivacyShield: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 44))
            Text("TmuxPad")
                .font(.title2)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }
}

/// Сцена `RootView`: окно появляется только после того, как view попал в иерархию.
struct WindowSceneReader: UIViewRepresentable {
    let onScene: @MainActor (UIWindowScene) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onScene = onScene
        return view
    }

    func updateUIView(_ uiView: ReaderView, context: Context) {}

    final class ReaderView: UIView {
        var onScene: (@MainActor (UIWindowScene) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let scene = window?.windowScene, let onScene else {
                return
            }
            // не во время обновления SwiftUI: обработчик меняет `@State`
            Task { @MainActor in onScene(scene) }
        }
    }
}
