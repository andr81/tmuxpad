import SwiftUI

struct RootView: View {
    @Environment(ServerStore.self) private var servers
    @Environment(TreeModel.self) private var tree
    @Environment(\.scenePhase) private var scenePhase
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
        .onChange(of: servers.servers, initial: true) { _, list in
            tree.setServers(list)
        }
        // фон, смена сети и переподключение открытых сессий — план 7; здесь только опрос дерева
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                tree.start()
            } else {
                tree.stop()
            }
        }
    }
}

#Preview {
    RootView().appEnvironment(try! AppEnvironment.inMemory())
}
