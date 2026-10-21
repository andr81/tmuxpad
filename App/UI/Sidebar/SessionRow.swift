import SwiftUI
import TmuxPadCore

/// `●` — открыта в приложении, `○` — существует; `attached` — подключены чужие клиенты (§3.1).
struct SessionRow: View {
    let node: SessionNode

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: node.isOpen ? "●" : "○")
                .foregroundStyle(node.isOpen ? Color.accentColor : .secondary)
            Text(verbatim: node.session.name)
                .lineLimit(1)
            Spacer()
            if node.session.otherClients > 0 {
                Text(verbatim: "attached")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(Self.activityText(node.session.lastActivity, now: context.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    /// «5 мин назад».
    static func activityText(_ date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: min(date, now), relativeTo: now)
    }
}

/// Контекст-меню сессии (§3.2); подтверждения показывает `SidebarView`.
@MainActor
struct SessionMenu {
    let serverID: UUID
    let actions: SessionActions?
    let confirmKill: (SessionNode) -> Void
    let confirmTake: (SessionNode) -> Void

    @ViewBuilder
    func items(for node: SessionNode) -> some View {
        let key = OpenSessionKey(serverID: serverID, name: node.session.name)
        Button("Открыть", systemImage: "terminal") {
            actions?.open(key)
        }
        if node.isOpen {
            Button("Отключиться", systemImage: "eject") {
                actions?.detach(key)
            }
        }
        if node.session.otherClients > 0 {
            Button("Забрать", systemImage: "hand.raised") {
                confirmTake(node)
            }
        }
        Button("Завершить", systemImage: "xmark.circle", role: .destructive) {
            confirmKill(node)
        }
        Divider()
        Button("Скопировать tmux attach", systemImage: "doc.on.doc") {
            actions?.copyAttachCommand(key)
        }
    }
}
