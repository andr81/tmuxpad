import SwiftUI

struct RootView: View {
    @Environment(ServerStore.self) private var servers
    @State private var showSettings = false

    var body: some View {
        NavigationSplitView {
            List(servers.servers) { server in
                VStack(alignment: .leading) {
                    Text(server.label)
                    Text(verbatim: "\(server.user)@\(server.host)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Серверы")
            .overlay {
                if servers.servers.isEmpty {
                    ContentUnavailableView("Серверов нет", systemImage: "server.rack", description: Text("Добавьте сервер в настройках"))
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    showSettings = true
                } label: {
                    Label("Настройки", systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .keyboardShortcut(",", modifiers: .command)
                .padding()
                .background(.bar)
            }
        } detail: {
            Text("Выберите сессию")
                .foregroundStyle(.secondary)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }
}

#Preview {
    RootView().appEnvironment(try! AppEnvironment.inMemory())
}
