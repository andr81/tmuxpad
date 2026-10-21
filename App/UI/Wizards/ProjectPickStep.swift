import SwiftUI
import TmuxPadCore

/// Выбор проекта с поиском; пусто — «В `<корень>` нет папок» (§9).
struct ProjectPickStep: View {
    let projects: [RemoteProject]
    let projectsRoot: String
    let selected: String?
    /// Причина недоступности сервера: при одном сервере шаг выбора сервера пропущен.
    let unavailable: String?
    let pick: (String) -> Void

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
                ContentUnavailableView("Нет проектов", systemImage: "folder", description: Text("В \(projectsRoot) нет папок"))
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .searchable(text: $query, prompt: "Проект")
        .navigationTitle("Проект")
    }

    private var filtered: [RemoteProject] {
        let sorted = projects.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard !query.isEmpty else {
            return sorted
        }
        return sorted.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
}
