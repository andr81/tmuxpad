import SwiftUI
import TmuxPadCore

/// Деталь открытой сессии: заголовок и терминал выделенной сессии.
struct TerminalScreen: View {
    let terminal: OpenTerminal

    var body: some View {
        VStack(spacing: 0) {
            TerminalHeader(key: terminal.key, project: terminal.project)
            Divider()
            TerminalHost(view: terminal.view)
                // низ терминала сам следует за клавиатурой (`keyboardLayoutGuide`)
                .ignoresSafeArea(.keyboard)
        }
    }
}

/// `TerminalContainerView` в SwiftUI; один контейнер на деталь, терминалы в нём меняются.
private struct TerminalHost: UIViewRepresentable {
    let view: TmuxTerminalView

    func makeUIView(context: Context) -> TerminalContainerView {
        let container = TerminalContainerView()
        container.show(view)
        return container
    }

    func updateUIView(_ container: TerminalContainerView, context: Context) {
        container.show(view)
    }
}
