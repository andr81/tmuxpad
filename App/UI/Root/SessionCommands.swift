import SwiftUI

/// Меню «Сессии» (§3.2): на iPad видно по удержанию ⌘ и работает при фокусе в терминале —
/// SwiftTerm пропускает клавиши с ⌘. Комбинации объявлены только здесь, не на кнопках тулбара.
struct SessionCommands: Commands {
    /// `nil` — хост тестов или ошибка запуска: пункты ничего не делают.
    let env: AppEnvironment?

    var body: some Commands {
        CommandMenu("Сессии") {
            Button("Новая сессия") {
                guard let env, !env.servers.servers.isEmpty else {
                    return
                }
                env.navigation.newSessionTarget = NewSessionTarget()
            }
            .keyboardShortcut("n", modifiers: .command)
            Button("Подключиться") {
                guard let env, !env.servers.servers.isEmpty else {
                    return
                }
                env.navigation.showAttach = true
            }
            .keyboardShortcut("o", modifiers: .command)
            Button("Сайдбар") {
                env?.navigation.sidebarHidden.toggle()
            }
            .keyboardShortcut("0", modifiers: .command)
            Divider()
            Button("Предыдущая") {
                env?.openSessions.selectPrevious()
            }
            .keyboardShortcut("[", modifiers: .command)
            Button("Следующая") {
                env?.openSessions.selectNext()
            }
            .keyboardShortcut("]", modifiers: .command)
            ForEach(1...9, id: \.self) { index in
                Button("Сессия \(index)") {
                    env?.openSessions.select(index: index)
                }
                .keyboardShortcut(KeyEquivalent(Character(String(index))), modifiers: .command)
            }
        }
    }
}
