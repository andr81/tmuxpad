import SwiftUI
import TmuxPadCore

/// Деталь открытой сессии: заголовок с `[⋯]`, терминал выделенной сессии, поверх — плашка
/// состояния и чип «Прокрутка ✕».
struct TerminalScreen: View {
    let terminal: OpenTerminal

    @Environment(\.appEnvironment) private var env
    @State private var pending: SessionConfirmation?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            TerminalHeader(key: terminal.key, project: terminal.project) {
                TerminalMenu(terminal: terminal) { pending = $0 }
            }
            Divider()
            TerminalHost(view: terminal.view, acceptsInput: terminal.state == .live)
                // низ терминала сам следует за клавиатурой (`keyboardLayoutGuide`)
                .ignoresSafeArea(.keyboard)
                .overlay(alignment: .topTrailing) {
                    if terminal.showsScrollChip, terminal.state == .live {
                        ScrollChip {
                            Task { await terminal.cancelCopyMode() }
                        }
                    }
                }
                .overlay {
                    TerminalOverlay(terminal: terminal, confirm: { pending = $0 }, fail: { errorMessage = $0 })
                }
        }
        .confirmationDialog(
            pending?.title ?? "",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible,
            presenting: pending
        ) { pending in
            switch pending {
            case let .kill(key):
                Button("Завершить", role: .destructive) { kill(key) }
            case let .take(key):
                Button("Забрать", role: .destructive) { env?.actions.take(key) }
            }
        } message: { pending in
            Text(pending.message)
        }
        .errorAlert(message: $errorMessage)
    }

    private func kill(_ key: OpenSessionKey) {
        Task {
            do {
                try await env?.actions.kill(key)
            } catch {
                errorMessage = userText(error)
            }
        }
    }
}

/// `TerminalContainerView` в SwiftUI; один контейнер на деталь, терминалы в нём меняются.
private struct TerminalHost: UIViewRepresentable {
    let view: TmuxTerminalView
    /// `false` при плашке: терминал отдаёт first responder, ввод заблокирован.
    let acceptsInput: Bool

    func makeUIView(context: Context) -> TerminalContainerView {
        let container = TerminalContainerView()
        container.acceptsInput = acceptsInput
        container.show(view)
        return container
    }

    func updateUIView(_ container: TerminalContainerView, context: Context) {
        // сначала `acceptsInput`: `show` нового терминала при плашке не должен его фокусировать
        container.acceptsInput = acceptsInput
        container.show(view)
    }
}
