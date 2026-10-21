import SwiftUI

/// Настройки — sheet поверх корня.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ServerStore.self) private var servers
    @Environment(KeyLibrary.self) private var keys

    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    ServersView()
                } label: {
                    LabeledContent {
                        Text("\(servers.servers.count)")
                    } label: {
                        Label("Серверы", systemImage: "server.rack")
                    }
                }
                NavigationLink {
                    KeysView()
                } label: {
                    LabeledContent {
                        Text("\(keys.keys.count)")
                    } label: {
                        Label("Ключи", systemImage: "key")
                    }
                }
                NavigationLink {
                    DiagnosticsView()
                } label: {
                    Label("Диагностика", systemImage: "stethoscope")
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    SettingsView().appEnvironment(try! AppEnvironment.inMemory())
}
