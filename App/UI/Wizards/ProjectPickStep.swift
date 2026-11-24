import SwiftUI
import TmuxPadCore

/// Выбор проекта с поиском и кнопкой «Новый проект»; пусто — «В `<корень>` нет папок» (§3.3, §9).
struct ProjectPickStep: View {
    let projects: [RemoteProject]
    let projectsRoot: String
    let selected: String?
    /// Причина недоступности сервера: при одном сервере шаг выбора сервера пропущен.
    let unavailable: String?
    let pick: (String) -> Void
    /// «Новый проект»: пустая папка или клон.
    let newProject: () -> Void

    @State private var query = ""

    var body: some View {
        List(filtered, id: \.name) { project in
            Button {
                pick(project.name)
            } label: {
                HStack {
                    Label(project.name, systemImage: "folder")
                    Spacer()
                    if project.name == selected {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
        .overlay {
            if let unavailable {
                ContentUnavailableView("Сервер недоступен", systemImage: "exclamationmark.triangle", description: Text(unavailable))
            } else if projects.isEmpty {
                ContentUnavailableView {
                    Label("Нет проектов", systemImage: "folder")
                } description: {
                    Text("В \(projectsRoot) нет папок")
                } actions: {
                    Button("Новый проект", action: newProject)
                }
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .searchable(text: $query, prompt: "Проект")
        .navigationTitle("Проект")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Новый проект", systemImage: "folder.badge.plus", action: newProject)
                    .disabled(unavailable != nil)
            }
        }
    }

    private var filtered: [RemoteProject] {
        let sorted = projects.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard !query.isEmpty else {
            return sorted
        }
        return sorted.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
}
