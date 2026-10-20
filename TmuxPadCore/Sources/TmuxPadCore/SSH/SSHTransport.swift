import Foundation
@preconcurrency import NIOSSH

/// Куда подключаться.
public struct SSHEndpoint: Sendable, Hashable {
    public var host: String
    public var port: Int
    public var connectTimeout: Duration

    public init(host: String, port: Int = 22, connectTimeout: Duration = .seconds(15)) {
        self.host = host
        self.port = port
        self.connectTimeout = connectTimeout
    }
}

/// Приватный ключ NIOSSH. `NIOSSHPrivateKey` не помечен `Sendable`, хотя это неизменяемое
/// значение (ключи swift-crypto и Secure Enclave — value-типы или неизменяемые ссылки), поэтому
/// обёртка объявляет `Sendable` вручную.
public struct SSHPrivateKey: @unchecked Sendable {
    public let key: NIOSSHPrivateKey

    public init(_ key: NIOSSHPrivateKey) {
        self.key = key
    }

    public var publicKey: NIOSSHPublicKey { key.publicKey }
}

/// Чем аутентифицироваться.
public enum SSHAuth: Sendable {
    case privateKey(SSHPrivateKey, user: String)

    public var user: String {
        switch self {
        case let .privateKey(_, user): user
        }
    }
}

/// Результат exec-канала.
public struct ExecResult: Sendable, Equatable {
    public var exitCode: Int
    public var stdout: Data
    public var stderr: Data
    public var duration: Duration

    public init(exitCode: Int, stdout: Data, stderr: Data, duration: Duration) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.duration = duration
    }

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

/// Результат `connect`: соединение и отпечаток хост-ключа; `firstSeen` — ключ видим впервые
/// и только что сохранён (UI показывает «Доверять»).
public struct ConnectOutcome: Sendable {
    public var connection: any SSHConnection
    public var hostKeyFingerprint: String
    public var firstSeen: Bool

    public init(connection: any SSHConnection, hostKeyFingerprint: String, firstSeen: Bool) {
        self.connection = connection
        self.hostKeyFingerprint = hostKeyFingerprint
        self.firstSeen = firstSeen
    }
}

/// Транспорт SSH (§12): поднимает одно соединение на сервер.
public protocol SSHTransport: Sendable {
    func connect(_ endpoint: SSHEndpoint, auth: SSHAuth, hostKeys: any HostKeyStore) async throws -> ConnectOutcome
}

/// Одно SSH-соединение; внутри — exec- и PTY-каналы.
public protocol SSHConnection: AnyObject, ExecRunner {
    /// Exec-канал: `stdin` (если есть) пишется и закрывается EOF; ждёт выхода не дольше `timeout`.
    func exec(_ command: String, stdin: Data?, environment: [String: String], timeout: Duration) async throws -> ExecResult
    /// PTY + exec `command`.
    func openPTY(command: String, term: String, cols: Int, rows: Int, environment: [String: String]) async throws -> any PTYChannel
    /// Срабатывает один раз, когда соединение закрылось по любой причине.
    var onDisconnect: AsyncStream<Void> { get }
    var isConnected: Bool { get }
    func close() async
}

extension SSHConnection {
    public func exec(_ command: String, stdin: Data? = nil, timeout: Duration = .seconds(30)) async throws -> ExecResult {
        try await exec(command, stdin: stdin, environment: [:], timeout: timeout)
    }
}

/// PTY-канал терминала.
public protocol PTYChannel: AnyObject, Sendable {
    /// Байты вывода до закрытия канала.
    var output: AsyncThrowingStream<Data, Error> { get }
    func send(_ data: Data) async throws
    func resize(cols: Int, rows: Int) async throws
    func close() async
    /// Код выхода команды; `nil`, пока канал открыт или если сервер его не прислал.
    var exitCode: Int? { get }
}
