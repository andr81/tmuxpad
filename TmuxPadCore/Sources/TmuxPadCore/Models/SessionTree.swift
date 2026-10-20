import Foundation

/// Узел проекта в дереве сайдбара (§3.1).
public struct ProjectNode: Hashable, Sendable, Identifiable {
    public var name: String
    /// `nil` — папки проекта нет, а tmux-сессия с ним жива.
    public var path: String?
    public var sessions: [SessionNode]

    public var id: String { name }

    public init(name: String, path: String?, sessions: [SessionNode]) {
        self.name = name
        self.path = path
        self.sessions = sessions
    }
}

/// Сессия в дереве: `isOpen` — `●` (открыта в приложении), иначе `○`.
public struct SessionNode: Hashable, Sendable, Identifiable {
    public var session: RemoteSession
    public var isOpen: Bool

    public var id: String { session.name }

    public init(session: RemoteSession, isOpen: Bool) {
        self.session = session
        self.isOpen = isOpen
    }
}

/// Группа мастера «Подключиться» (§3.4).
public struct ActivityGroup: Hashable, Sendable {
    public var project: String
    public var sessions: [RemoteSession]

    public init(project: String, sessions: [RemoteSession]) {
        self.project = project
        self.sessions = sessions
    }
}

/// Построение дерева сессий из снимка `list` — чистые функции без состояния.
public enum SessionTree {
    /// Проекты и сессии по имени без учёта регистра. Сессия, чей проект пропал из снимка,
    /// попадает в узел с `path == nil`, иначе её нельзя было бы ни открыть, ни убить.
    public static func build(
        snapshot: ServerSnapshot, openSessions: Set<String>, showEmptyProjects: Bool
    ) -> [ProjectNode] {
        let byProject = Dictionary(grouping: snapshot.sessions, by: \.project)
        var nodes: [String: ProjectNode] = [:]
        for project in snapshot.projects where nodes[project.name] == nil {
            nodes[project.name] = ProjectNode(name: project.name, path: project.path, sessions: [])
        }
        for (project, sessions) in byProject {
            let sorted = sessions
                .sorted { nameOrder($0.name, $1.name) }
                .map { SessionNode(session: $0, isOpen: openSessions.contains($0.name)) }
            nodes[project, default: ProjectNode(name: project, path: nil, sessions: [])]
                .sessions = sorted
        }
        return nodes.values
            .filter { showEmptyProjects || !$0.sessions.isEmpty }
            .sorted { nameOrder($0.name, $1.name) }
    }

    /// Группы по самой свежей активности, сессии внутри — по `lastActivity` по убыванию.
    public static func byActivity(snapshot: ServerSnapshot) -> [ActivityGroup] {
        Dictionary(grouping: snapshot.sessions, by: \.project)
            .map { project, sessions in
                ActivityGroup(project: project, sessions: sessions.sorted(by: activityOrder))
            }
            .sorted { lhs, rhs in
                let left = lhs.sessions[0].lastActivity
                let right = rhs.sessions[0].lastActivity
                return left != right ? left > right : nameOrder(lhs.project, rhs.project)
            }
    }

    /// `localizedStandardCompare` на Linux без локали недоступен: регистр снимается вручную,
    /// при равенстве — исходное имя, чтобы `API` и `api` стояли детерминированно.
    static func nameOrder(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.lowercased()
        let right = rhs.lowercased()
        return left != right ? left < right : lhs < rhs
    }

    private static func activityOrder(_ lhs: RemoteSession, _ rhs: RemoteSession) -> Bool {
        lhs.lastActivity != rhs.lastActivity
            ? lhs.lastActivity > rhs.lastActivity
            : nameOrder(lhs.name, rhs.name)
    }
}
