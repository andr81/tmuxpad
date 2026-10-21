import SwiftUI
import TmuxPadCore

/// Дерево Сервер → Проект → Сессия (§3.1, §3.2).
struct SidebarView: View {
    let openSettings: () -> Void

    @Environment(\.appEnvironment) private var env
    @Environment(ServerStore.self) private var servers
    @Environment(TreeModel.self) private var tree
    @Environment(OpenSessionsModel.self) private var openSessions
    /// Свёрнутые проекты, строки `serverID/project`; по умолчанию всё раскрыто.
    @SceneStorage("sidebar.collapsed") private var collapsed = ""
    @State private var checkTarget: ServerTarget?
    @State private var pending: Pending?
    @State private var errorMessage: String?
    /// «Новая сессия здесь»; мастер появится в задаче 3 этого плана.
    @State private var newSessionTarget: NewSessionTarget?

    var body: some View {
        @Bindable var tree = tree
        List(selection: selection) {
            ForEach(servers.servers) { server in
                serverSection(server)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Сессии")
        .refreshable {
            await tree.refresh(force: true)
        }
        .overlay {
            if servers.servers.isEmpty {
                ContentUnavailableView {
                    Label("Серверов нет", systemImage: "server.rack")
                } description: {
                    Text("Добавьте сервер в настройках")
                } actions: {
                    Button("Открыть настройки", action: openSettings)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Ещё", systemImage: "ellipsis.circle") {
                    Toggle("Показывать все проекты", isOn: $tree.showEmptyProjects)
                }
            }
        }
        .sheet(item: $checkTarget, onDismiss: nil) { target in
            NavigationStack {
                ServerCheckView(serverID: target.id, action: .check)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Готово") { checkTarget = nil }
                        }
                    }
            }
            .onDisappear {
                // после «Доверять» или «Подготовить» дерево перечитывает сервер
                Task { await tree.markPrepared(target.id) }
            }
        }
        .confirmationDialog(
            pending?.title ?? "",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible,
            presenting: pending
        ) { pending in
            switch pending {
            case let .kill(key):
                Button("Завершить", role: .destructive) { kill(key) }
            case let .take(key):
                Button("Забрать", role: .destructive) { env?.actions.take(key) }
            }
        } message: { pending in
            Text(pending.message)
        }
        .errorAlert(message: $errorMessage)
    }

    private func serverSection(_ server: ServerConfig) -> some View {
        let state = tree.states[server.id]
        let menu = SessionMenu(
            serverID: server.id,
            actions: env?.actions,
            confirmKill: { pending = .kill(OpenSessionKey(serverID: server.id, name: $0.session.name)) },
            confirmTake: { pending = .take(OpenSessionKey(serverID: server.id, name: $0.session.name)) }
        )
        return Section {
            ForEach(tree.nodes(for: server.id)) { project in
                ProjectRow(
                    serverID: server.id,
                    project: project,
                    isExpanded: expanded(server.id, project.name),
                    newSession: { newSessionTarget = NewSessionTarget(serverID: server.id, project: project.name) },
                    sessionMenu: menu
                )
                .foregroundStyle(ServerRow.isStale(state) ? .secondary : .primary)
            }
        } header: {
            ServerRow(
                server: server,
                state: state,
                retry: { Task { await tree.refresh(serverID: server.id, force: true) } },
                check: { checkTarget = ServerTarget(id: server.id) }
            )
        }
    }

    /// Выбор строки сессии открывает её.
    private var selection: Binding<OpenSessionKey?> {
        Binding(
            get: { openSessions.selection },
            set: { key in
                if let key {
                    env?.actions.open(key)
                }
            }
        )
    }

    private func expanded(_ serverID: UUID, _ project: String) -> Binding<Bool> {
        let id = "\(serverID.uuidString)/\(project)"
        return Binding(
            get: { !collapsedSet.contains(id) },
            set: { isExpanded in
                var set = collapsedSet
                if isExpanded {
                    set.remove(id)
                } else {
                    set.insert(id)
                }
                collapsed = set.sorted().joined(separator: "\n")
            }
        )
    }

    private var collapsedSet: Set<String> {
        Set(collapsed.split(separator: "\n").map(String.init))
    }

    private func kill(_ key: OpenSessionKey) {
        Task {
            do {
                try await env?.actions.kill(key)
            } catch {
                errorMessage = userText(error)
            }
        }
    }
}

struct ServerTarget: Identifiable {
    let id: UUID
}

struct NewSessionTarget: Equatable {
    var serverID: UUID?
    var project: String?
}

/// Действие, ждущее подтверждения.
private enum Pending {
    case kill(OpenSessionKey)
    case take(OpenSessionKey)

    var title: String {
        switch self {
        case let .kill(key): "Завершить сессию «\(key.name)»?"
        case let .take(key): "Забрать сессию «\(key.name)»?"
        }
    }

    var message: String {
        switch self {
        case .kill: "Процессы в ней будут убиты."
        case .take: "Другие клиенты будут отключены."
        }
    }
}
