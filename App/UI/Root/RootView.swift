import SwiftUI

struct RootView: View {
    @Environment(ServerStore.self) private var servers
    @Environment(TreeModel.self) private var tree
    @Environment(OpenSessionsModel.self) private var openSessions
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(openSettings: { showSettings = true })
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
            Group {
                if let key = openSessions.selection {
                    SessionPlaceholderView(key: key)
                } else {
                    Text("Выберите сессию")
                        .foregroundStyle(.secondary)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Сайдбар", systemImage: "sidebar.left") {
                        columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                    }
                    .keyboardShortcut("0", modifiers: .command)
                }
            }
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
