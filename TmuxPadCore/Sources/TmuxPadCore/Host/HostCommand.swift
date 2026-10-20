import Foundation

/// Значения переменных окружения host-скрипта для одного сервера.
public struct HostEnvironment: Sendable, Hashable {
    /// UUID устройства, `TMUXPAD_CLIENT`.
    public var client: UUID
    /// `TMUXPAD_PROJECTS`.
    public var projectsRoot: String
    /// `TMUXPAD_CMD`.
    public var startCommand: String

    public init(client: UUID, projectsRoot: String, startCommand: String) {
        self.client = client
        self.projectsRoot = projectsRoot
        self.startCommand = startCommand
    }
}

/// Подкоманда host-скрипта (§7) и установка самого скрипта.
public enum HostCommand: Sendable, Hashable {
    case version
    case list
    case new(session: String, project: String)
    case attach(session: String)
    case take(session: String)
    case copyCancel(session: String)
    case kill(session: String)
    case setup
    case doctor
    /// Токен — только через stdin.
    case auth
    /// Скрипт размером `bytes` — через stdin.
    case install(bytes: Int)

    static let scriptPath = "\"$HOME\"/.local/bin/tmuxpad-host.sh"

    /// Пишет во временный файл и подменяет скрипт `mv` только после сверки размера: оборванный
    /// посреди передачи канал даёт `cat` обычный EOF, и без сверки на сервере остался бы обрубок.
    static func installCommand(bytes: Int) -> String {
        let tmp = "~/.local/bin/.tmuxpad-host.sh.tmp"
        return "mkdir -p ~/.local/bin && cat > \(tmp) && [ \"$(wc -c < \(tmp))\" -eq \(bytes) ] && chmod +x \(tmp) && mv -f \(tmp) ~/.local/bin/tmuxpad-host.sh"
    }

    /// Имя подкоманды скрипта, для журнала и сообщений.
    public var name: String {
        switch self {
        case .version: "version"
        case .list: "list"
        case .new: "new"
        case .attach: "attach"
        case .take: "take"
        case .copyCancel: "copy-cancel"
        case .kill: "kill"
        case .setup: "setup"
        case .doctor: "doctor"
        case .auth: "auth"
        case .install: "install"
        }
    }

    /// Строка для exec-канала в форме §5. Имена проходят `Validation`, значения окружения —
    /// `Validation.isSafeShellValue`, иначе `HostError.badRequest`.
    public func render(env: HostEnvironment) throws -> String {
        if case let .install(bytes) = self {
            return Self.installCommand(bytes: bytes)
        }
        let args = try arguments()
        guard Validation.isSafeShellValue(env.projectsRoot) else {
            throw HostError.badRequest("invalid projects root")
        }
        guard Validation.isSafeShellValue(env.startCommand) else {
            throw HostError.badRequest("invalid start command")
        }
        let prefix = [
            "env",
            "TMUXPAD_CLIENT=" + Self.shellQuote(env.client.uuidString.lowercased()),
            "TMUXPAD_PROJECTS=" + Self.shellQuote(env.projectsRoot),
            "TMUXPAD_CMD=" + Self.shellQuote(env.startCommand),
            Self.scriptPath,
            name,
        ]
        return (prefix + args.map(Self.shellQuote)).joined(separator: " ")
    }

    func arguments() throws -> [String] {
        switch self {
        case .version, .list, .setup, .doctor, .auth, .install:
            return []
        case let .new(session, project):
            try Self.checkSession(session)
            guard Validation.isValidProjectName(project) else {
                throw HostError.badRequest("invalid project name: \(project)")
            }
            return [session, project]
        case let .attach(session), let .take(session), let .copyCancel(session), let .kill(session):
            try Self.checkSession(session)
            return [session]
        }
    }

    private static func checkSession(_ session: String) throws {
        guard Validation.isValidSessionName(session) else {
            throw HostError.badRequest("invalid session name: \(session)")
        }
    }

    /// Одинарные кавычки POSIX-шелла: `'` внутри → `'\''`.
    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
