import SwiftUI
import TmuxPadCore

struct ServersView: View {
    @Environment(ServerStore.self) private var servers
    @Environment(KeyLibrary.self) private var keys
    @State private var sheet: Sheet?
    @State private var pendingDelete: ServerConfig?
    /// Ключ, созданный из «Добавить сервер»: форма сервера открывается, когда закроется sheet ключа.
    @State private var createdKeyID: UUID?
    @State private var error: String?

    private enum Sheet: Identifiable {
        /// Ключей нет: сначала ключ, потом сервер.
        case newKey
        case newServer(ServerConfig)

        var id: String {
            switch self {
            case .newKey: "newKey"
            case let .newServer(config): config.id.uuidString
            }
        }
    }

    var body: some View {
        List {
            ForEach(servers.servers) { server in
                NavigationLink {
                    ServerEditView(config: server, isNew: false)
                } label: {
                    VStack(alignment: .leading) {
                        Text(server.label)
                        Text(verbatim: "\(server.user)@\(server.host):\(server.port)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    Button("Удалить", systemImage: "trash", role: .destructive) { pendingDelete = server }
                }
                .contextMenu {
                    Button("Дублировать", systemImage: "plus.square.on.square") { duplicate(server) }
                    Button("Удалить", systemImage: "trash", role: .destructive) { pendingDelete = server }
                }
            }
            .onMove { source, destination in
                perform { try servers.move(fromOffsets: source, toOffset: destination) }
            }
        }
        .overlay {
            if servers.servers.isEmpty {
                ContentUnavailableView("Серверов нет", systemImage: "server.rack")
            }
        }
        .navigationTitle("Серверы")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Добавить сервер", systemImage: "plus", action: add)
                    .accessibilityIdentifier("servers.add")
            }
            ToolbarItem(placement: .secondaryAction) {
                EditButton()
            }
        }
        .sheet(item: $sheet, onDismiss: {
            if let keyID = createdKeyID {
                createdKeyID = nil
                sheet = .newServer(newServer(keyID: keyID))
            }
        }) { sheet in
            switch sheet {
            case .newKey:
                NewKeyView { key in createdKeyID = key.id }
            case let .newServer(config):
                NavigationStack {
                    ServerEditView(config: config, isNew: true)
                }
            }
        }
        .confirmationDialog(
            "Удалить сервер «\(pendingDelete?.label ?? "")»?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { server in
            Button("Удалить", role: .destructive) { delete(server) }
        } message: { _ in
            Text("Сессии tmux на сервере останутся.")
        }
        .errorAlert(message: $error)
    }

    private func add() {
        if let key = keys.keys.first {
            sheet = .newServer(newServer(keyID: key.id))
        } else {
            sheet = .newKey
        }
    }

    private func newServer(keyID: UUID) -> ServerConfig {
        ServerConfig(label: "", host: "", user: "", keyID: keyID)
    }

    private func duplicate(_ server: ServerConfig) {
        perform { try servers.duplicate(server) }
    }

    private func delete(_ server: ServerConfig) {
        Task {
            do {
                try await servers.delete(id: server.id)
            } catch {
                self.error = userText(error)
            }
        }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            self.error = userText(error)
        }
    }
}

#Preview {
    NavigationStack { ServersView() }.appEnvironment(try! AppEnvironment.inMemory())
}
