import SwiftUI
import TmuxPadCore

/// Мастер «Подключиться» (§3.4): sheet со стеком шагов из `AttachFlow`; тап — обычный `attach`.
struct AttachWizard: View {
    /// «Создать» на пустом сервере: sidebar открывает «Новая сессия» с этим сервером.
    let createNew: (UUID) -> Void

    @Environment(\.appEnvironment) private var env
    @Environment(\.dismiss) private var dismiss
    @Environment(ServerStore.self) private var servers
    @Environment(TreeModel.self) private var tree
    @Environment(OpenSessionsModel.self) private var openSessions
    @State private var flow: AttachFlow
    @State private var path: [AttachFlow.Step] = []

    init(servers: [ServerConfig], createNew: @escaping (UUID) -> Void) {
        self.createNew = createNew
        _flow = State(initialValue: AttachFlow(servers: servers))
    }

    var body: some View {
        NavigationStack(path: $path) {
            step(flow.steps[0])
                .navigationDestination(for: AttachFlow.Step.self) { step($0) }
        }
    }

    @ViewBuilder
    private func step(_ step: AttachFlow.Step) -> some View {
        Group {
            switch step {
            case .server:
                ServerPickStep(servers: servers.servers, states: tree.states, selected: flow.serverID) { id in
                    flow.selectServer(id)
                    if let next = flow.step(after: .server) {
                        path.append(next)
                    }
                }
            case .sessions:
                sessions
            }
        }
        .toolbar {
            if step == flow.steps[0] {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
            }
        }
    }

    private var sessions: some View {
        let groups = flow.groups(snapshot: snapshot)
        return List {
            ForEach(groups, id: \.project) { group in
                Section(group.project) {
                    ForEach(group.sessions, id: \.name) { session in
                        Button {
                            attach(session.name)
                        } label: {
                            SessionRow(node: SessionNode(session: session, isOpen: isOpen(session.name)))
                        }
                        .tint(.primary)
                    }
                }
            }
        }
        .overlay {
            if let unavailable {
                ContentUnavailableView("Сервер недоступен", systemImage: "exclamationmark.triangle", description: Text(unavailable))
            } else if groups.isEmpty {
                ContentUnavailableView {
                    Label("Сессий нет", systemImage: "terminal")
                } description: {
                    Text("На сервере нет сессий")
                } actions: {
                    if let serverID = flow.serverID {
                        Button("Создать") {
                            createNew(serverID)
                            dismiss()
                        }
                    }
                }
            }
        }
        .navigationTitle(server?.label ?? "Подключиться")
    }

    private var server: ServerConfig? {
        flow.serverID.flatMap { servers.server(id: $0) }
    }

    private var snapshot: ServerSnapshot? {
        flow.serverID.flatMap { tree.states[$0]?.snapshot }
    }

    /// При одном сервере шаг выбора пропущен, поэтому причина показывается здесь.
    private var unavailable: String? {
        server.flatMap { ServerPickStep.unavailableReason(server: $0, state: tree.states[$0.id]) }
    }

    private func isOpen(_ name: String) -> Bool {
        flow.key(for: name).map(openSessions.isOpen) ?? false
    }

    private func attach(_ name: String) {
        guard let key = flow.key(for: name) else {
            return
        }
        env?.actions.open(key)
        dismiss()
    }
}
