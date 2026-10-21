import SwiftUI
import TmuxPadCore

/// Проект с сессиями, раскрываемый (§3.1).
struct ProjectRow: View {
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
                Text(project.name)
            } icon: {
                Image(systemName: project.path == nil ? "folder.badge.questionmark" : "folder")
            }
            .contextMenu {
                Button("Новая сессия здесь", systemImage: "plus", action: newSession)
            }
        }
    }
}
