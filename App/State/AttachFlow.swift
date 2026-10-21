import Foundation
import TmuxPadCore

/// Шаги мастера «Подключиться» без UI (§3.4): сервер → сессии по проектам → `attach`.
struct AttachFlow: Equatable {
    enum Step: Hashable {
        case server
        case sessions
    }

    /// Шаги по порядку; последний — всегда `.sessions`.
    let steps: [Step]
    private(set) var serverID: UUID?

    /// При одном сервере шаг сервера пропускается.
    init(servers: [ServerConfig]) {
        let only = servers.count == 1 ? servers.first?.id : nil
        steps = only == nil ? [.server, .sessions] : [.sessions]
        serverID = only
    }

    /// Шаг после `step`; `nil` — последний.
    func step(after step: Step) -> Step? {
        guard let index = steps.firstIndex(of: step), index + 1 < steps.count else {
            return nil
        }
        return steps[index + 1]
    }

    mutating func selectServer(_ id: UUID) {
        serverID = id
    }

    /// Группы по проектам, свежие сверху; пусто — сессий нет или снимка ещё нет.
    func groups(snapshot: ServerSnapshot?) -> [ActivityGroup] {
        snapshot.map(SessionTree.byActivity) ?? []
    }

    /// Ключ для `openSessions.open` по тапу на сессию.
    func key(for session: String) -> OpenSessionKey? {
        serverID.map { OpenSessionKey(serverID: $0, name: session) }
    }
}
