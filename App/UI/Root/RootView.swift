import SwiftUI

struct RootView: View {
    @Environment(ServerStore.self) private var servers
    @Environment(TreeModel.self) private var tree
    @Environment(OpenSessionsModel.self) private var openSessions
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
    /// «Создать» из пустого мастера «Подключиться»: «Новая сессия» откроется, когда тот закроется.
    @State private var createAfterAttach: UUID?

    var body: some View {
        @Bindable var navigation = navigation
        NavigationSplitView(columnVisibility: columnVisibility) {
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
                if let terminal = openSessions.selectedTerminal {
                    TerminalScreen(terminal: terminal)
                } else {
                    Text("Выберите сессию")
                        .foregroundStyle(.secondary)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // `⌘0` — в `SessionCommands`
                    Button("Сайдбар", systemImage: "sidebar.left") {
                        navigation.sidebarHidden.toggle()
                    }
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        // мастера — здесь, а не в сайдбаре: `⌘N` и `⌘O` открывают их и при скрытом сайдбаре
        .sheet(item: $navigation.newSessionTarget) { target in
            NewSessionWizard(target: target, servers: servers.servers)
        }
        .sheet(isPresented: $navigation.showAttach, onDismiss: {
            if let serverID = createAfterAttach {
                createAfterAttach = nil
                navigation.newSessionTarget = NewSessionTarget(serverID: serverID)
            }
        }) {
            AttachWizard(servers: servers.servers) { createAfterAttach = $0 }
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

    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { navigation.sidebarHidden ? .detailOnly : .all },
            set: { navigation.sidebarHidden = $0 == .detailOnly }
        )
    }
}

#Preview {
    RootView().appEnvironment(try! AppEnvironment.inMemory())
}
