import SwiftUI
import TmuxPadCore

/// Мастер «Новая сессия» (§3.3): sheet со стеком шагов из `NewSessionFlow`.
struct NewSessionWizard: View {
    @Environment(\.appEnvironment) private var env
    @Environment(\.dismiss) private var dismiss
    @Environment(ServerStore.self) private var servers
    @Environment(TreeModel.self) private var tree
    @State private var flow: NewSessionFlow
    @State private var path: [NewSessionFlow.Step] = []
    @State private var creating = false
    @State private var errorMessage: String?

    init(target: NewSessionTarget, servers: [ServerConfig]) {
        _flow = State(initialValue: NewSessionFlow(servers: servers, serverID: target.serverID, project: target.project))
    }

    var body: some View {
        NavigationStack(path: $path) {
            step(flow.steps[0])
                .navigationDestination(for: NewSessionFlow.Step.self) { step($0) }
        }
        .interactiveDismissDisabled(creating)
        .errorAlert(message: $errorMessage)
    }

    @ViewBuilder
    private func step(_ step: NewSessionFlow.Step) -> some View {
        Group {
            switch step {
            case .server:
                ServerPickStep(servers: servers.servers, states: tree.states, selected: flow.serverID) { id in
                    flow.selectServer(id)
                    advance(from: .server)
                }
            case .project:
                ProjectPickStep(
                    projects: snapshot?.projects ?? [],
                    projectsRoot: server?.projectsRoot ?? "",
                    selected: flow.project,
                    unavailable: server.flatMap { ServerPickStep.unavailableReason(server: $0, state: tree.states[$0.id]) }
                ) { name in
                    flow.selectProject(name)
                    advance(from: .project)
                }
            case .name:
                NameStep(
                    flow: flow,
                    issue: flow.nameIssue(snapshot: snapshot),
                    name: Binding(get: { flow.name }, set: { flow.editName($0) }),
                    attach: attachExisting,
                    submit: create
                )
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        if creating {
                            ProgressView()
                        } else {
                            Button("Создать", action: create)
                                .disabled(!flow.canCreate(snapshot: snapshot))
                        }
                    }
                }
            }
        }
        .toolbar {
            if step == flow.steps[0] {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                        .disabled(creating)
                }
            }
        }
    }

    private var server: ServerConfig? {
        flow.serverID.flatMap { servers.server(id: $0) }
    }

    private var snapshot: ServerSnapshot? {
        flow.serverID.flatMap { tree.states[$0]?.snapshot }
    }

    private func advance(from step: NewSessionFlow.Step) {
        if let next = flow.step(after: step) {
            path.append(next)
        }
    }

    private func attachExisting() {
        guard let key = flow.key else {
            return
        }
        env?.actions.open(key)
        dismiss()
    }

    private func create() {
        guard !creating, flow.canCreate(snapshot: snapshot), let actions = env?.actions else {
            return
        }
        creating = true
        let request = flow
        Task {
            let outcome = await request.create(using: actions)
            creating = false
            flow.apply(outcome)
            switch outcome {
            case .created:
                dismiss()
            case let .failed(message):
                errorMessage = message
            case .conflict, .invalid:
                break
            }
        }
    }
}
