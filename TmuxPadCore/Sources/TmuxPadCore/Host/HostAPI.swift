import Foundation

/// Кто выполняет exec-строки: `SSHConnection` напрямую или пул через очередь на 2 слота.
public protocol ExecRunner: Sendable {
    func exec(_ command: String, stdin: Data?, timeout: Duration) async throws -> ExecResult
}

/// Подкоманды host-скрипта (§7) поверх exec-каналов: рендер строки, коды выхода → `HostError`,
/// разбор вывода, событие в журнал.
public struct HostAPI: Sendable {
    public static let defaultTimeout: Duration = .seconds(20)
    /// Столько символов stderr попадает в ошибку.
    static let stderrLimit = 500

    public let runner: any ExecRunner
    public let environment: HostEnvironment
    public let log: DiagnosticsLog?
    /// Метка сервера в журнале.
    public let server: String
    public let timeout: Duration

    public init(
        runner: any ExecRunner,
        environment: HostEnvironment,
        log: DiagnosticsLog? = nil,
        server: String = "",
        timeout: Duration = HostAPI.defaultTimeout
    ) {
        self.runner = runner
        self.environment = environment
        self.log = log
        self.server = server
        self.timeout = timeout
    }

    /// Выполняет команду; ненулевой код → `HostError`.
    @discardableResult
    public func run(_ command: HostCommand, stdin: Data? = nil) async throws -> ExecResult {
        let result = try await execute(command, stdin: stdin)
        guard result.exitCode == 0 else {
            throw HostError.from(command: command, exitCode: result.exitCode, stderr: String(result.stderrText.prefix(Self.stderrLimit)))
        }
        return result
    }

    /// Выполняет команду и возвращает результат с любым кодом выхода.
    func execute(_ command: HostCommand, stdin: Data? = nil) async throws -> ExecResult {
        let line = try command.render(env: environment)
        // в журнал — подкоманда и имена, без значений переменных окружения
        let label = ([command.name] + ((try? command.arguments()) ?? [])).joined(separator: " ")
        let result: ExecResult
        do {
            result = try await runner.exec(line, stdin: stdin, timeout: timeout)
        } catch {
            await log?.record(server: server, kind: .error, "\(label) failed: \(error)")
            throw error
        }
        await log?.record(server: server, kind: .exec, "\(label) exit \(result.exitCode) in \(result.duration)")
        return result
    }

    /// Версия установленного скрипта; нет скрипта → `HostError.scriptMissing`.
    public func version() async throws -> Int {
        let text = try await run(.version).stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "tmuxpad-host "
        guard text.hasPrefix(prefix), let version = Int(text.dropFirst(prefix.count)) else {
            throw HostError.badOutput("bad version: \(text.prefix(100))")
        }
        return version
    }

    public func list() async throws -> ServerSnapshot {
        try ListParser.parse(try await run(.list).stdoutText, fetchedAt: Date())
    }

    public func new(session: String, project: String) async throws {
        try await run(.new(session: session, project: project))
    }

    public func kill(session: String) async throws {
        try await run(.kill(session: session))
    }

    public func copyCancel(session: String) async throws {
        try await run(.copyCancel(session: session))
    }

    /// Код 1 с разобранным отчётом — не ошибка, а `DoctorReport.ok == false`.
    public func setup() async throws -> DoctorReport {
        try await report(.setup)
    }

    public func doctor() async throws -> DoctorReport {
        try await report(.doctor)
    }

    /// Токен Claude — только через stdin.
    public func auth(token: String) async throws {
        guard Self.isValidToken(token) else {
            throw HostError.badRequest("invalid token")
        }
        try await run(.auth, stdin: Data((token + "\n").utf8))
    }

    /// Exec-строка `attach` для PTY-канала.
    public func attachCommand(session: String) throws -> String {
        try HostCommand.attach(session: session).render(env: environment)
    }

    /// Exec-строка `take` для PTY-канала.
    public func takeCommand(session: String) throws -> String {
        try HostCommand.take(session: session).render(env: environment)
    }

    private func report(_ command: HostCommand) async throws -> DoctorReport {
        let result = try await execute(command)
        guard result.exitCode == 0 || result.exitCode == 1 else {
            throw HostError.from(command: command, exitCode: result.exitCode, stderr: String(result.stderrText.prefix(Self.stderrLimit)))
        }
        do {
            let report = try DoctorParser.parse(result.stdoutText)
            guard !report.lines.isEmpty else {
                throw HostError.badOutput("empty \(command.name) output")
            }
            return report
        } catch where result.exitCode != 0 {
            // код 1 без отчёта — обычная ошибка, а не отчёт
            throw HostError.failed(code: result.exitCode, stderr: String(result.stderrText.prefix(Self.stderrLimit)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Как в скрипте: `^[A-Za-z0-9_-]+$`.
    static func isValidToken(_ token: String) -> Bool {
        !token.isEmpty && token.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-")
        }
    }
}

extension HostAPI {
    /// Значения окружения из конфига сервера и UUID устройства.
    public init(runner: any ExecRunner, config: ServerConfig, deviceID: UUID, log: DiagnosticsLog? = nil) {
        self.init(
            runner: runner,
            environment: HostEnvironment(client: deviceID, projectsRoot: config.projectsRoot, startCommand: config.startCommand),
            log: log,
            server: config.label
        )
    }
}
