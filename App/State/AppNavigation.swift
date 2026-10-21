import Foundation
import Observation

/// Что открыто поверх дерева и терминала: мастера и видимость сайдбара. Общее для кнопок
/// сайдбара и команд `⌘N`, `⌘O`, `⌘0` в `TmuxPadApp` — те работают и при фокусе в терминале.
@MainActor
@Observable
final class AppNavigation {
    /// Мастер «Новая сессия»: `[+]` — пустой, «Новая сессия здесь» — с сервером и проектом.
    var newSessionTarget: NewSessionTarget?
    var showAttach = false
    var sidebarHidden = false
}

struct NewSessionTarget: Identifiable {
    let id = UUID()
    var serverID: UUID?
    var project: String?
}
