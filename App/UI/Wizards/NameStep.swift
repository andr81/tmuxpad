import SwiftUI
import TmuxPadCore

/// Имя сессии: валидация вживую и экран конфликта «Сессия `X` уже есть» (§3.3, §9).
struct NameStep: View {
    let flow: NewSessionFlow
    let issue: NewSessionFlow.NameIssue?
    /// Запись идёт через `NewSessionFlow.editName`.
    @Binding var name: String
    let attach: () -> Void
    /// Return в поле — «Создать», если можно.
    let submit: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        Form {
            Section {
                TextField("Имя сессии", text: $name)
                    .focused($focused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                    .onSubmit(submit)
            } header: {
                if let project = flow.project {
                    Text("Проект \(project)")
                }
            } footer: {
                if let text = Self.footer(issue: issue, serverIssue: flow.serverIssue) {
                    Text(text)
                        .foregroundStyle(.red)
                }
            }
            if issue == .exists {
                Section {
                    Button("Подключиться", systemImage: "arrow.right.circle", action: attach)
                    Button("Другое имя", systemImage: "pencil") {
                        focused = true
                    }
                } header: {
                    Text("Сессия \(flow.name) уже есть")
                }
            }
        }
        .navigationTitle("Имя")
        .onAppear {
            focused = true
        }
    }

    /// Пустое имя подсказки не требует: кнопка «Создать» просто неактивна.
    static func footer(issue: NewSessionFlow.NameIssue?, serverIssue: String?) -> String? {
        if issue == .invalid {
            return "Допустимы латинские буквы, цифры, _ и -, до 64 символов"
        }
        return serverIssue
    }
}
