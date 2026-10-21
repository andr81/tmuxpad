import SwiftUI
import TmuxPadCore

/// `[⋯]` над терминалом (§3.2): действия — через `SessionActions` и `OpenTerminal`,
/// подтверждения показывает `TerminalScreen`.
struct TerminalMenu: View {
    let terminal: OpenTerminal
    let confirm: (SessionConfirmation) -> Void

    @Environment(\.appEnvironment) private var env
    @State private var showFontSize = false

    var body: some View {
        Menu {
            Button("Отключиться", systemImage: "eject") {
                env?.actions.detach(terminal.key)
            }
            Button("Забрать", systemImage: "hand.raised") {
                confirm(.take(terminal.key))
            }
            Button("Завершить", systemImage: "xmark.circle", role: .destructive) {
                confirm(.kill(terminal.key))
            }
            Button("Переподключить", systemImage: "arrow.clockwise") {
                Task { await terminal.reconnect() }
            }
            Divider()
            Button("Размер шрифта", systemImage: "textformat.size") {
                showFontSize = true
            }
        } label: {
            Label("Ещё", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .popover(isPresented: $showFontSize) {
            FontSizeControl()
                .padding()
                .presentationCompactAdaptation(.popover)
        }
    }
}

/// Тот же эффект, что pinch: размер сразу во всех открытых терминалах.
private struct FontSizeControl: View {
    @Environment(TerminalAppearance.self) private var appearance

    var body: some View {
        Stepper(
            value: Binding(get: { appearance.fontSize }, set: { appearance.setFontSize($0) }),
            in: TerminalSettings.fontSizeRange
        ) {
            Text("Шрифт: \(appearance.fontSize) pt")
                .monospacedDigit()
        }
        .frame(minWidth: 240)
    }
}
