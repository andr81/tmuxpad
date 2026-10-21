import Foundation
@testable import TmuxPadCore

struct FakeError: Error, Equatable, CustomStringConvertible {
    var description: String
}

/// Транспорт без сети: считает попытки, по сценарию падает, выдаёт `FakeConnection`.
final class FakeTransport: SSHTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0
    private var failures = 0
    private var failure: Error = SSHError.connectFailed("fake refused")
    private var made: [FakeConnection] = []
    private var prepare: (@Sendable (FakeConnection) -> Void)?

    /// Следующие `count` попыток падают с `error`.
    func failNextConnects(_ count: Int, with error: Error = SSHError.connectFailed("fake refused")) {
        lock.withLock {
            failures = count
            failure = error
        }
    }

    /// Настройка каждого нового соединения до выдачи.
    func onConnect(_ body: @escaping @Sendable (FakeConnection) -> Void) {
        lock.withLock { prepare = body }
    }

    var connectAttempts: Int {
        lock.withLock { attempts }
    }

    var connections: [FakeConnection] {
        lock.withLock { made }
    }

    var lastConnection: FakeConnection? {
        connections.last
    }

    /// Обрыв последнего соединения.
    func dropConnection() {
        lastConnection?.disconnect()
    }

    func connect(_ endpoint: SSHEndpoint, auth: SSHAuth, hostKeys: any HostKeyStore) async throws -> ConnectOutcome {
        let result: Result<FakeConnection, Error> = lock.withLock {
            attempts += 1
            if failures > 0 {
                failures -= 1
                return .failure(failure)
            }
            let connection = FakeConnection()
            prepare?(connection)
            made.append(connection)
            return .success(connection)
        }
        return ConnectOutcome(connection: try result.get(), hostKeyFingerprint: "SHA256:fake", firstSeen: false)
    }
}

/// Соединение без сети: ответы `exec` из очереди, журнал вызовов, ручной обрыв, PTY с ручным выводом.
final class FakeConnection: SSHConnection, @unchecked Sendable {
    struct Response {
        var matches: @Sendable (String) -> Bool
        var result: Result<ExecResult, Error>
    }

    struct Call: Equatable {
        var command: String
        var stdin: Data?
    }

    private let lock = NSLock()
    private var responses: [Response] = []
    /// Постоянные ответы по фрагменту команды; новый ответ на тот же фрагмент заменяет старый.
    private var standing: [(fragment: String, result: ExecResult)] = []
    private var calls: [Call] = []
    private var connected = true
    private var delay: Duration?
    private var hang = false
    private var inFlight = 0
    private var peakInFlight = 0
    private var ptys: [FakePTY] = []
    private var ptyErrors: [Error] = []
    private var events: [String] = []
    let onDisconnect: AsyncStream<Void>
    private let disconnectContinuation: AsyncStream<Void>.Continuation

    init() {
        (onDisconnect, disconnectContinuation) = AsyncStream.makeStream()
    }

    /// Первый подходящий ответ уходит из очереди; без подходящего — код 0 и пустой вывод.
    func respond(when matches: @escaping @Sendable (String) -> Bool, with result: Result<ExecResult, Error>) {
        lock.withLock { responses.append(Response(matches: matches, result: result)) }
    }

    /// Ответ на команду, содержащую `fragment`.
    func respond(containing fragment: String, exitCode: Int = 0, stdout: String = "", stderr: String = "") {
        respond(when: { $0.contains(fragment) }, with: .success(Self.result(exitCode: exitCode, stdout: stdout, stderr: stderr)))
    }

    /// Ответ на каждую команду с `fragment`, из очереди не уходит; очередь `respond` проверяется раньше.
    func respondAlways(containing fragment: String, exitCode: Int = 0, stdout: String = "", stderr: String = "") {
        let result = Self.result(exitCode: exitCode, stdout: stdout, stderr: stderr)
        lock.withLock {
            standing.removeAll { $0.fragment == fragment }
            standing.append((fragment, result))
        }
    }

    /// Сколько `exec` содержали `fragment`.
    func execCount(containing fragment: String) -> Int {
        execCalls.filter { $0.command.contains(fragment) }.count
    }

    static func result(exitCode: Int = 0, stdout: String = "", stderr: String = "") -> ExecResult {
        ExecResult(exitCode: exitCode, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8), duration: .milliseconds(1))
    }

    var execCalls: [Call] {
        lock.withLock { calls }
    }

    /// Общий порядок событий: `exec <команда>` и `pty <ввод>` — чтобы проверять, что было раньше.
    var journal: [String] {
        lock.withLock { events }
    }

    private func note(_ event: String) {
        lock.withLock { events.append(event) }
    }

    /// Каждый `exec` ждёт `delay` перед ответом.
    var execDelay: Duration? {
        get { lock.withLock { delay } }
        set { lock.withLock { delay = newValue } }
    }

    /// `exec` не отвечает до своего таймаута, затем `SSHError.timeout`.
    var hangExec: Bool {
        get { lock.withLock { hang } }
        set { lock.withLock { hang = newValue } }
    }

    /// Следующие `count` вызовов `openPTY` бросают `error`, соединение остаётся живым.
    func failNextPTYs(_ count: Int, with error: Error) {
        lock.withLock { ptyErrors = Array(repeating: error, count: count) }
    }

    /// Наибольшее число одновременных `exec`.
    var maxConcurrentExecs: Int {
        lock.withLock { peakInFlight }
    }

    /// Открытых PTY.
    var openPTYCount: Int {
        lock.withLock { ptys.filter { !$0.isClosed }.count }
    }

    var openedPTYs: [FakePTY] {
        lock.withLock { ptys }
    }

    /// Изображает обрыв, как настоящий транспорт: `onDisconnect` срабатывает, `isConnected == false`,
    /// вывод PTY кончается без ошибки и без кода выхода.
    func disconnect() {
        let open = lock.withLock {
            connected = false
            return ptys
        }
        for pty in open {
            pty.close(exitCode: nil)
        }
        disconnectContinuation.yield()
        disconnectContinuation.finish()
    }

    var isConnected: Bool {
        lock.withLock { connected }
    }

    func exec(_ command: String, stdin: Data?, environment: [String: String], timeout: Duration) async throws -> ExecResult {
        let (delay, hang) = lock.withLock {
            calls.append(Call(command: command, stdin: stdin))
            events.append("exec " + command)
            inFlight += 1
            peakInFlight = max(peakInFlight, inFlight)
            return (self.delay, self.hang)
        }
        defer { lock.withLock { inFlight -= 1 } }
        if hang {
            try await Task.sleep(for: timeout)
            throw SSHError.timeout
        }
        if let delay {
            try await Task.sleep(for: delay)
        }
        let result: Result<ExecResult, Error> = lock.withLock {
            guard connected else {
                return .failure(SSHError.disconnected)
            }
            if let index = responses.firstIndex(where: { $0.matches(command) }) {
                return responses.remove(at: index).result
            }
            if let response = standing.first(where: { command.contains($0.fragment) }) {
                return .success(response.result)
            }
            return .success(Self.result())
        }
        return try result.get()
    }

    func openPTY(command: String, term: String, cols: Int, rows: Int, environment: [String: String]) async throws -> any PTYChannel {
        try lock.withLock {
            guard connected else {
                throw SSHError.disconnected
            }
            if !ptyErrors.isEmpty {
                throw ptyErrors.removeFirst()
            }
            let pty = FakePTY(command: command, cols: cols, rows: rows, environment: environment)
            pty.onSend = { [weak self] data in self?.note("pty " + String(decoding: data, as: UTF8.self)) }
            ptys.append(pty)
            return pty
        }
    }

    func close() async {
        disconnect()
    }
}

/// PTY-канал фейка: вывод — `emit`, конец — `close(exitCode:)`; ввод и resize копятся.
final class FakePTY: PTYChannel, @unchecked Sendable {
    let command: String
    let environment: [String: String]
    let output: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let lock = NSLock()
    private var code: Int?
    private var closed = false
    private var sentData: [Data] = []
    private var sizes: [(cols: Int, rows: Int)]
    var onSend: (@Sendable (Data) -> Void)?

    init(command: String, cols: Int, rows: Int, environment: [String: String]) {
        self.command = command
        self.environment = environment
        sizes = [(cols, rows)]
        (output, continuation) = AsyncThrowingStream.makeStream()
    }

    var exitCode: Int? {
        lock.withLock { code }
    }

    var isClosed: Bool {
        lock.withLock { closed }
    }

    var sent: [Data] {
        lock.withLock { sentData }
    }

    var resizes: [(cols: Int, rows: Int)] {
        lock.withLock { sizes }
    }

    func emit(_ data: Data) {
        continuation.yield(data)
    }

    /// Сервер закрыл канал с кодом выхода.
    func close(exitCode: Int?) {
        lock.withLock {
            code = exitCode
            closed = true
        }
        continuation.finish()
    }

    func fail(_ error: Error) {
        lock.withLock { closed = true }
        continuation.finish(throwing: error)
    }

    func send(_ data: Data) async throws {
        try lock.withLock {
            guard !closed else {
                throw SSHError.disconnected
            }
            sentData.append(data)
        }
        onSend?(data)
    }

    func resize(cols: Int, rows: Int) async throws {
        lock.withLock { sizes.append((cols, rows)) }
    }

    func close() async {
        close(exitCode: nil)
    }
}
