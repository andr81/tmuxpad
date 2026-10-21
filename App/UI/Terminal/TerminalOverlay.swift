import SwiftUI
import TmuxPadCore

/// Плашка поверх терминала по `TerminalState` (§3.5, §6, §6.1). Любая плашка перехватывает
/// касания, а `TerminalScreen` снимает с терминала first responder — ввод заблокирован.
struct TerminalOverlay: View {
    let terminal: OpenTerminal
    let confirm: (SessionConfirmation) -> Void
    let fail: (String) -> Void

    @Environment(\.appEnvironment) private var env

    var body: some View {
        switch terminal.state {
        case .live:
            EmptyView()
        case .connecting, .reconnecting:
            panel {
                ProgressView()
                Text("Переподключение…")
            }
        case .ended:
            panel {
                Text("Сессия завершена")
                    .font(.headline)
                HStack {
                    Button("Создать заново", action: recreate)
                        .buttonStyle(.borderedProminent)
                    Button("Закрыть", action: close)
                        .buttonStyle(.bordered)
                }
            }
        case .disconnectedByOther:
            panel {
                Text("Отключено другим клиентом")
                    .font(.headline)
                HStack {
                    Button("Переподключить") {
                        Task { await terminal.reconnect() }
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Забрать") {
                        confirm(.take(terminal.key))
                    }
                    .buttonStyle(.bordered)
                    Button("Закрыть", action: close)
                        .buttonStyle(.bordered)
                }
            }
        case let .offline(reason):
            panel {
                Text("Нет связи с сервером")
                    .font(.headline)
                Text(verbatim: reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                Button("Повторить") {
                    Task { await terminal.retry() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    /// Матовое стекло на весь терминал — последний экран виден под ним, касания не проходят.
    private func panel(@ViewBuilder content: () -> some View) -> some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
            VStack(spacing: 12) {
                content()
            }
            .padding(20)
            .frame(maxWidth: 420)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding()
        }
        .contentShape(Rectangle())
        .allowsHitTesting(true)
    }

    private func recreate() {
        Task {
            do {
                try await terminal.recreate()
                await env?.tree.refreshAfterAction(serverID: terminal.key.serverID)
            } catch {
                fail(userText(error))
            }
        }
    }

    private func close() {
        env?.actions.detach(terminal.key)
    }
}
