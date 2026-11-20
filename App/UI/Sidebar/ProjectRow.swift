import SwiftUI
import TmuxPadCore

/// Проект с сессиями, раскрываемый (§3.1); узел без имени — группа «Без проекта».
struct ProjectRow: View {
    static let unassignedTitle = "Без проекта"

    let serverID: UUID
    let project: ProjectNode
    @Binding var isExpanded: Bool
    let newSession: () -> Void
    let sessionMenu: SessionMenu

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(project.sessions) { node in
                SessionRow(node: node)
                    .tag(OpenSessionKey(serverID: serverID, name: node.session.name))
                    .contextMenu { sessionMenu.items(for: node) }
                    .swipeActions(edge: .trailing) {
                        Button("Завершить", systemImage: "xmark.circle", role: .destructive) {
                            sessionMenu.confirmKill(node)
                        }
                    }
            }
        } label: {
            Label {
                Text(verbatim: project.name ?? Self.unassignedTitle)
            } icon: {
                Image(systemName: icon)
            }
            .contextMenu {
                if project.name != nil {
                    Button("Новая сессия здесь", systemImage: "plus", action: newSession)
                }
            }
        }
    }

    private var icon: String {
        if project.name == nil {
            return "tray"
        }
        return project.path == nil ? "folder.badge.questionmark" : "folder"
    }
}
