import SwiftUI
import TmuxPadCore

/// «Новый проект» из шага проекта (§3.3): клон репозитория или пустая папка, имя с живой валидацией.
struct NewProjectStep: View {
    let flow: NewProjectFlow
    let snapshot: ServerSnapshot?
    /// Сервер недоступен: причина вместо подсказок, «Создать» неактивна.
    let unavailable: String?
    let creating: Bool
    /// Запись идёт через `NewProjectFlow`.
    @Binding var mode: NewProjectFlow.Mode
    @Binding var url: String
    @Binding var name: String
    /// Return в поле — «Создать», если можно.
    let submit: () -> Void

    @FocusState private var focus: Field?

    private enum Field {
        case url
        case name
    }

    var body: some View {
        Form {
            Section {
                Picker("Проект", selection: $mode) {
                    Text("Клонировать").tag(NewProjectFlow.Mode.clone)
                    Text("Пустая папка").tag(NewProjectFlow.Mode.empty)
                }
                .pickerStyle(.segmented)
            }
            if mode == .clone {
                Section {
                    TextField("https://github.com/user/repo.git", text: $url)
                        .focused($focus, equals: .url)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                        .submitLabel(.next)
                        .onSubmit { focus = .name }
                } header: {
                    Text("Адрес репозитория")
                } footer: {
                    if flow.urlIssue == .invalid {
                        Text("Нужен адрес https://, ssh://, git:// или user@host:path, без пароля, токена и пробелов")
                            .foregroundStyle(.red)
                    } else {
                        Text("Клонирует сервер своими ключами или gh auth; вопросы git и ssh задать нельзя")
                    }
                }
            }
            Section {
                TextField("Имя проекта", text: $name)
                    .focused($focus, equals: .name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                    .onSubmit(submit)
            } header: {
                Text("Имя проекта")
            } footer: {
                if let text = unavailable ?? Self.footer(issue: flow.nameIssue(snapshot: snapshot), name: flow.name, serverIssue: flow.serverIssue) {
                    Text(text)
                        .foregroundStyle(.red)
                }
            }
            if creating {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(mode == .clone ? "Клонирование…" : "Создание…")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Новый проект")
        .onAppear {
            focus = mode == .clone ? .url : .name
        }
    }

    /// Пустое имя подсказки не требует: кнопка «Создать» просто неактивна.
    static func footer(issue: NewProjectFlow.NameIssue?, name: String, serverIssue: String?) -> String? {
        switch issue {
        case .invalid:
            "Допустимы латинские буквы, цифры, ., _ и -, до 128 символов; точка не может быть первой"
        case .exists:
            "Проект \(name) уже есть"
        case .empty, nil:
            serverIssue
        }
    }
}
