import SwiftUI
import TmuxPadCore

/// «Передать токен Claude»: токен уходит в stdin `auth` и пишется в `~/.tmuxpad/env` сервера.
/// Поле очищается после передачи и при уходе с экрана.
struct TokenView: View {
    let serverID: UUID

    @Environment(\.appEnvironment) private var env
    @State private var model: ServerCheckModel?
    @State private var token = ""

    private var trimmed: String {
        token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Form {
            Section {
                SecureField("Токен", text: $token)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit(send)
            } footer: {
                Text("Токен из claude setup-token. Он хранится только на сервере, в ~/.tmuxpad/env с правами 0600; в приложении и журнале его нет.")
            }
            if let model {
                Section {
                    status(model)
                    Button("Передать", systemImage: "paperplane", action: send)
                        .disabled(trimmed.isEmpty || model.isRunning)
                }
            }
        }
        .navigationTitle("Токен Claude")
        .navigationBarTitleDisplayMode(.inline)
        .modifier(OptionalAlerts(model: model, onTrusted: send))
        .task {
            if model == nil, let env {
                model = ServerCheckModel(serverID: serverID, environment: env)
            }
        }
        .onDisappear { token = "" }
    }

    @ViewBuilder
    private func status(_ model: ServerCheckModel) -> some View {
        switch model.state {
        case .running:
            HStack {
                ProgressView()
                Text("Передача…")
                    .padding(.leading, 8)
            }
        case let .failed(message):
            Text(message)
                .foregroundStyle(.red)
        case .authFailed:
            Text("Сервер не принял ключ")
                .foregroundStyle(.red)
        case .hostKeyChanged:
            Text("Ключ сервера изменился — подключение заблокировано")
                .foregroundStyle(.red)
        case .idle where model.tokenSent:
            Label("Токен передан", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .idle, .trustPrompt, .done:
            EmptyView()
        }
    }

    /// После «Доверять» передача продолжается сама, пока токен ещё в поле.
    private func send() {
        guard let model, !trimmed.isEmpty, !model.isRunning else {
            return
        }
        let task = model.sendToken(trimmed)
        Task {
            await task.value
            if model.tokenSent {
                token = ""
            }
        }
    }
}

/// `serverCheckAlerts`, когда модель ещё не создана.
private struct OptionalAlerts: ViewModifier {
    let model: ServerCheckModel?
    let onTrusted: @MainActor () -> Void

    func body(content: Content) -> some View {
        if let model {
            content.serverCheckAlerts(model, onTrusted: onTrusted)
        } else {
            content
        }
    }
}
