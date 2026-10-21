import SwiftUI
import TmuxPadCore

/// Выбор сервера в мастерах; недоступные неактивны и показывают причину (§3.3, §9).
struct ServerPickStep: View {
    let servers: [ServerConfig]
    let states: [UUID: ServerTreeState]
    let selected: UUID?
    let pick: (UUID) -> Void

    var body: some View {
        List(servers) { server in
            let reason = Self.unavailableReason(server: server, state: states[server.id])
            Button {
                pick(server.id)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(server.label)
                        if let reason {
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if server.id == selected {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .disabled(reason != nil)
        }
        .navigationTitle("Сервер")
    }

    /// `nil` — сервер онлайн и снимок есть: можно выбирать.
    static func unavailableReason(server: ServerConfig, state: ServerTreeState?) -> String? {
        if let status = ServerRow.status(server: server, state: state) {
            return status.text
        }
        guard case .online = state?.reachability, state?.snapshot != nil else {
            return "Подключение…"
        }
        return nil
    }
}
