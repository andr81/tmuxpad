import Foundation

/// Узел проекта в дереве сайдбара (§3.1).
public struct ProjectNode: Hashable, Sendable, Identifiable {
    /// `nil` — группа «Без проекта»: сессии, созданные не прямо в корне проектов.
    public var name: String?
    /// `nil` — папки проекта нет, а tmux-сессия с ним жива; у группы «Без проекта» тоже `nil`.
    public var path: String?
    public var sessions: [SessionNode]

    /// Пустое имя проект не пройдёт валидацию, поэтому `""` у группы «Без проекта» не совпадёт ни с чьим.
    public var id: String { name ?? "" }

    public init(name: String?, path: String?, sessions: [SessionNode]) {
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
    /// `nil` — группа «Без проекта».
    public var project: String?
    public var sessions: [RemoteSession]

    public init(project: String?, sessions: [RemoteSession]) {
        self.project = project
        self.sessions = sessions
    }
}

/// Построение дерева сессий из снимка `list` — чистые функции без состояния.
public enum SessionTree {
    /// Проекты и сессии по имени без учёта регистра. Сессия, чей проект пропал из снимка,
    /// попадает в узел с `path == nil`, иначе её нельзя было бы ни открыть, ни убить.
    /// Сессии без проекта — в узле с `name == nil` последним, он есть, только пока в нём есть сессии.
    public static func build(
        snapshot: ServerSnapshot, openSessions: Set<String>, showEmptyProjects: Bool
    ) -> [ProjectNode] {
        let byProject = Dictionary(grouping: snapshot.sessions, by: \.project)
        var nodes: [String: ProjectNode] = [:]
        for project in snapshot.projects where nodes[project.name] == nil {
            nodes[project.name] = ProjectNode(name: project.name, path: project.path, sessions: [])
        }
        var unassigned: ProjectNode?
        for (project, sessions) in byProject {
            let sorted = sessions
                .sorted { nameOrder($0.name, $1.name) }
                .map { SessionNode(session: $0, isOpen: openSessions.contains($0.name)) }
            guard let project else {
                unassigned = ProjectNode(name: nil, path: nil, sessions: sorted)
                continue
            }
            nodes[project, default: ProjectNode(name: project, path: nil, sessions: [])]
                .sessions = sorted
        }
        let projects = nodes.values
            .filter { showEmptyProjects || !$0.sessions.isEmpty }
            .sorted { nameOrder($0.id, $1.id) }
        return projects + (unassigned.map { [$0] } ?? [])
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
                return left != right ? left > right : projectOrder(lhs.project, rhs.project)
            }
    }

    /// `localizedStandardCompare` на Linux без локали недоступен: регистр снимается вручную,
    /// при равенстве — исходное имя, чтобы `API` и `api` стояли детерминированно.
    static func nameOrder(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.lowercased()
        let right = rhs.lowercased()
        return left != right ? left < right : lhs < rhs
    }

    /// Проекты по имени, «Без проекта» (`nil`) — после них.
    private static func projectOrder(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case let (left?, right?): nameOrder(left, right)
        case (_?, nil): true
        case (nil, _): false
        }
    }

    private static func activityOrder(_ lhs: RemoteSession, _ rhs: RemoteSession) -> Bool {
        lhs.lastActivity != rhs.lastActivity
            ? lhs.lastActivity > rhs.lastActivity
            : nameOrder(lhs.name, rhs.name)
    }
}
