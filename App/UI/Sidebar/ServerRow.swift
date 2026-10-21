import SwiftUI
import TmuxPadCore

/// Заголовок секции сервера: метка, состояние и кнопка, которая тут поможет (§3.1, §9).
struct ServerRow: View {
    let server: ServerConfig
    let state: ServerTreeState?
    let retry: () -> Void
    let check: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if Self.status(server: server, state: state) != nil {
                        Text(verbatim: "⚠")
                    }
                    Text(server.label)
                        .font(.headline)
                    if state?.refreshing == true {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
                if let status = Self.status(server: server, state: state) {
                    Text(status.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let stale = Self.staleCaption(state) {
                    Text(stale)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            switch Self.status(server: server, state: state)?.action {
            case .retry:
                Button("Повторить", action: retry)
                    .buttonStyle(.borderless)
            case .check:
                Button("Проверить", action: check)
                    .buttonStyle(.borderless)
            case nil:
                EmptyView()
            }
        }
        .textCase(nil)
    }

    enum Action: Equatable {
        /// `refresh(force: true)`.
        case retry
        /// `ServerCheckView`: повтор тут не поможет.
        case check
    }

    struct Status: Equatable {
        var text: String
        var action: Action
    }

    /// `nil` — сервер онлайн или ещё не опрашивался. Причины ядра — английские, пользователю
    /// показывается русский текст по состоянию.
    static func status(server: ServerConfig, state: ServerTreeState?) -> Status? {
        guard let state else {
            return nil
        }
        if let attention = state.attention {
            switch attention {
            case .authFailed: return Status(text: "Сервер не принял ключ", action: .check)
            case .hostKeyChanged: return Status(text: "Ключ сервера изменился", action: .check)
            default: return Status(text: userText(attention), action: .check)
            }
        }
        switch state.reachability {
        case .unknown, .online:
            return nil
        case .offline:
            return Status(text: "Нет связи", action: .retry)
        case .needsSetup:
            // без отпечатка ядро не подключается: «Подключение не проверено»
            let text = server.hostKeyFingerprint == nil ? "Подключение не проверено" : "Требуется подготовка"
            return Status(text: text, action: .check)
        }
    }

    /// Офлайн со снимком: дерево рисуется серым, подпись — время снимка.
    static func staleCaption(_ state: ServerTreeState?) -> String? {
        guard let state, isStale(state), let snapshot = state.snapshot else {
            return nil
        }
        return "по состоянию на \(snapshot.fetchedAt.formatted(date: .omitted, time: .shortened))"
    }

    static func isStale(_ state: ServerTreeState?) -> Bool {
        guard let state, state.snapshot != nil else {
            return false
        }
        if case .offline = state.reachability {
            return true
        }
        return false
    }
}
