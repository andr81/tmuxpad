import SwiftUI

struct RootView: View {
    @Environment(ServerStore.self) private var servers
    @Environment(KeyLibrary.self) private var keys
    @Environment(TreeModel.self) private var tree
    @Environment(OpenSessionsModel.self) private var openSessions
    @Environment(AppNavigation.self) private var navigation
    @Environment(TerminalAppearance.self) private var appearance
    @Environment(\.appEnvironment) private var env
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppLock.self) private var lock
    /// Экран блокировки и шторка — в своём окне над листами (§3.8).
    @State private var lockOverlay: LockOverlayWindow?
    @State private var showSettings = false
    @State private var showOnboarding = false
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
                    .accessibilityIdentifier("root.settings")
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
            // кнопку сайдбара ставит сам `NavigationSplitView`; `⌘0` — в `SessionCommands`
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .preferredColorScheme(appearance.theme.colorScheme)
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
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView { showOnboarding = false }
                .preferredColorScheme(appearance.theme.colorScheme)
        }
        .onAppear {
            // раз за запуск; пройденный или пропущенный онбординг не возвращается
            if let env, OnboardingFlag.shouldShow(defaults: env.defaults, hasKeys: !keys.keys.isEmpty, hasServers: !servers.servers.isEmpty) {
                showOnboarding = true
            }
        }
        .onChange(of: servers.servers, initial: true) { _, list in
            tree.setServers(list)
        }
        .preferredColorScheme(appearance.theme.colorScheme)
        .background(WindowSceneReader { scene in
            if lockOverlay == nil, let env {
                lockOverlay = LockOverlayWindow(lock: env.lock, appearance: env.appearance)
            }
            lockOverlay?.attach(to: scene)
        })
        // фон и возврат: блокировку решает `AppLock`, опрос дерева и соединения ведёт координатор
        .onChange(of: scenePhase, initial: true) { _, phase in
            lock.scenePhaseChanged(phase)
            lockOverlay?.phaseChanged(phase)
            forwardToLifecycle(phase)
        }
        // разблокировали: возврат, который координатор ещё не видел (§3.8)
        .onChange(of: lock.isLocked) { _, locked in
            lockOverlay?.update()
            if !locked {
                forwardToLifecycle(scenePhase)
            }
        }
    }

    /// Пока приложение заблокировано, координатор не получает `.active`: ни восстановления
    /// сессий, ни опроса дерева, ни SSH до разблокировки. Уход в фон идёт как обычно.
    private func forwardToLifecycle(_ phase: ScenePhase) {
        if phase == .active, lock.isLocked {
            return
        }
        env?.lifecycle.scenePhaseChanged(phase)
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
