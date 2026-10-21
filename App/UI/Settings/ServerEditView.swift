import SwiftUI
import TmuxPadCore

/// Форма сервера по таблице §3.6. Новый сервер — в sheet, существующий — в навигации настроек.
struct ServerEditView: View {
    let isNew: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appEnvironment) private var env
    @Environment(ServerStore.self) private var servers
    @Environment(KeyLibrary.self) private var keys
    @State private var draft: ServerConfig
    @State private var confirmReset = false
    @State private var error: String?

    init(config: ServerConfig, isNew: Bool) {
        self.isNew = isNew
        _draft = State(initialValue: config)
    }

    private var canSave: Bool {
        servers.issues(for: draft, keys: keys.keys).isEmpty
    }

    var body: some View {
        Form {
            Section {
                field("Название", text: $draft.label, issue: labelIssue)
                field("Адрес", text: $draft.host, issue: coreIssue("host is empty"), prompt: "IP или DNS")
                numberField("Порт", value: $draft.port, issue: coreIssue("port must be 1...65535"))
                field("Пользователь", text: $draft.user, issue: coreIssue("user must be non-empty without spaces"))
            }
            Section {
                Picker("Ключ", selection: $draft.keyID) {
                    if keys.key(id: draft.keyID) == nil {
                        Text("Не выбран").tag(draft.keyID)
                    }
                    ForEach(keys.keys) { key in
                        Text(key.name).tag(key.id)
                    }
                }
                issueText(keyIssue)
            }
            Section("Сервер") {
                field(
                    "Папка проектов", text: $draft.projectsRoot,
                    issue: coreIssue("projects root must be non-empty without quotes or control characters"),
                    prompt: "projects"
                )
                field(
                    "Команда запуска", text: $draft.startCommand,
                    issue: coreIssue("start command must be non-empty without quotes or control characters"),
                    prompt: "claude"
                )
                numberField("Keepalive, с", value: $draft.keepaliveSeconds, issue: coreIssue("keepalive must be 5...300 seconds"))
            }
            Section {
                LabeledContent("Отпечаток хост-ключа") {
                    Text(draft.hostKeyFingerprint ?? "ещё не подключались")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                if draft.hostKeyFingerprint != nil {
                    Button("Сбросить отпечаток", role: .destructive) { confirmReset = true }
                }
            } footer: {
                Text("Запоминается при первом подключении; при смене ключа сервера подключение блокируется.")
            }
        }
        .navigationTitle(isNew ? "Новый сервер" : draft.label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isNew {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Сохранить", action: save)
                    .disabled(!canSave)
            }
        }
        .confirmationDialog("Сбросить отпечаток?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Сбросить", role: .destructive, action: resetFingerprint)
        } message: {
            Text("При следующем подключении приложение спросит, доверять ли ключу сервера.")
        }
        .errorAlert(message: $error)
    }

    // MARK: - Поля

    private func field(_ title: String, text: Binding<String>, issue: String?, prompt: String? = nil) -> some View {
        VStack(alignment: .leading) {
            LabeledContent(title) {
                TextField(title, text: text, prompt: prompt.map { Text($0) })
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            issueText(issue)
        }
    }

    private func numberField(_ title: String, value: Binding<Int>, issue: String?) -> some View {
        VStack(alignment: .leading) {
            LabeledContent(title) {
                TextField(title, value: value, format: .number.grouping(.never))
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numberPad)
            }
            issueText(issue)
        }
    }

    @ViewBuilder
    private func issueText(_ issue: String?) -> some View {
        if let issue {
            Text(issue)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private var labelIssue: String? {
        draft.label.trimmingCharacters(in: .whitespaces).isEmpty ? "Укажите название" : nil
    }

    private var keyIssue: String? {
        keys.key(id: draft.keyID) == nil ? "Выберите ключ" : nil
    }

    /// Строка `validationIssues()` ядра для поля, по-русски.
    private func coreIssue(_ issue: String) -> String? {
        draft.validationIssues().contains(issue) ? serverIssueText(issue) : nil
    }

    // MARK: - Действия

    private func save() {
        do {
            if isNew {
                try servers.add(draft)
            } else {
                try servers.update(draft)
            }
            dismiss()
        } catch {
            self.error = userText(error)
        }
    }

    /// Сбрасывает доверие по сохранённому адресу и очищает поле, в форме и в `servers.json`.
    private func resetFingerprint() {
        let saved = servers.server(id: draft.id)
        Task {
            do {
                if let saved, let env {
                    try await env.hostKeys.reset(host: saved.host, port: saved.port)
                }
                draft.hostKeyFingerprint = nil
                if var saved {
                    saved.hostKeyFingerprint = nil
                    try servers.update(saved)
                }
            } catch {
                self.error = userText(error)
            }
        }
    }
}
