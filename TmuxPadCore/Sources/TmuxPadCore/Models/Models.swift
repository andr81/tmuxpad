import Foundation

/// Сервер в списке приложения (§5.1).
public struct ServerConfig: Identifiable, Sendable, Codable, Hashable {
    public var id: UUID
    public var label: String
    /// IP или DNS.
    public var host: String
    public var port: Int
    public var user: String
    public var keyID: UUID
    /// Относительно `$HOME` или абсолютный.
    public var projectsRoot: String
    public var startCommand: String
    /// Интервал exec-пинга (§5).
    public var keepaliveSeconds: Int
    /// TOFU, `SHA256:…`.
    public var hostKeyFingerprint: String?
    public var sortIndex: Int

    public init(
        id: UUID = UUID(),
        label: String,
        host: String,
        port: Int = 22,
        user: String,
        keyID: UUID,
        projectsRoot: String = "projects",
        startCommand: String = "claude",
        keepaliveSeconds: Int = 15,
        hostKeyFingerprint: String? = nil,
        sortIndex: Int = 0
    ) {
        self.id = id
        self.label = label
        self.host = host
        self.port = port
        self.user = user
        self.keyID = keyID
        self.projectsRoot = projectsRoot
        self.startCommand = startCommand
        self.keepaliveSeconds = keepaliveSeconds
        self.hostKeyFingerprint = hostKeyFingerprint
        self.sortIndex = sortIndex
    }
}

/// Публичная часть ключа; приватная — только в `KeyStore`.
public struct SSHKeyInfo: Identifiable, Sendable, Codable, Hashable {
    public enum Kind: String, Sendable, Codable, Hashable {
        case secureEnclaveP256
        case ed25519
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    public var publicKeyOpenSSH: String
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, kind: Kind, publicKeyOpenSSH: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.kind = kind
        self.publicKeyOpenSSH = publicKeyOpenSSH
        self.createdAt = createdAt
    }
}

public struct RemoteProject: Sendable, Codable, Hashable {
    public var name: String
    public var path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

public struct RemoteSession: Sendable, Codable, Hashable {
    public var name: String
    public var project: String
    /// Клиенты не с этого устройства; > 0 → подпись `attached`.
    public var otherClients: Int
    public var lastActivity: Date

    public init(name: String, project: String, otherClients: Int, lastActivity: Date) {
        self.name = name
        self.project = project
        self.otherClients = otherClients
        self.lastActivity = lastActivity
    }
}

/// Разобранный вывод `list`.
public struct ServerSnapshot: Sendable, Codable, Hashable {
    public var projects: [RemoteProject]
    public var sessions: [RemoteSession]
    public var fetchedAt: Date

    public init(projects: [RemoteProject], sessions: [RemoteSession], fetchedAt: Date) {
        self.projects = projects
        self.sessions = sessions
        self.fetchedAt = fetchedAt
    }
}

/// `String` вместо `Error`, чтобы тип был `Equatable` и `Sendable`.
public enum ServerReachability: Sendable, Codable, Hashable {
    case unknown
    case online
    case offline(String)
    case needsSetup(String)
}

/// Строка вывода `doctor`.
public struct DoctorLine: Sendable, Codable, Hashable {
    public enum Level: String, Sendable, Codable, Hashable {
        case ok
        case warn
        case fail
    }

    public var level: Level
    public var key: String
    public var message: String

    public init(level: Level, key: String, message: String) {
        self.level = level
        self.key = key
        self.message = message
    }
}

public struct DoctorReport: Sendable, Codable, Hashable {
    public var lines: [DoctorLine]

    /// Нет ни одного `fail`.
    public var ok: Bool { !lines.contains { $0.level == .fail } }

    public init(lines: [DoctorLine]) {
        self.lines = lines
    }
}
