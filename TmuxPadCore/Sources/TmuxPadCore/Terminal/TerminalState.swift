import Foundation

/// Состояние терминальной сессии для плашек UI (§6, §6.1).
public enum TerminalState: Sendable, Equatable {
    case connecting
    /// PTY-канал `attach` открыт, вывод идёт.
    case live
    /// Переоткрываем канал: молчаливый повтор после выбивания, `reconnect()`, `take()`, ожидание
    /// пула после обрыва соединения.
    case reconnecting
    /// Сессии на сервере больше нет или приложение сделало `detach()`.
    case ended
    /// Чужой `attach -d` выбил нас второй раз за `kickWindow`: «Переподключить» / «Забрать» / «Закрыть».
    case disconnectedByOther
    /// Канал недоступен: ошибка, которую повтор не лечит, или пул в `.failed` после обрыва — тогда
    /// сессия сама переоткроется, когда пул подключится.
    case offline(String)
}
