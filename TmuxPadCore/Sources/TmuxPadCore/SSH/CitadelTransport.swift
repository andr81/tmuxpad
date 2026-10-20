import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
@preconcurrency import NIOSSH

/// `SSHTransport` на стеке Citadel (swift-nio-ssh): TCP-канал поднимает свой `ClientBootstrap`,
/// на него вешается `NIOSSHHandler`, каналы ядро открывает через `NIOSSHHandler.createChannel`
/// (§5.2: в API Citadel нет PTY + exec и EOF для stdin). От самого Citadel — ключи OpenSSH.
public final class CitadelTransport: SSHTransport {
    private let log: DiagnosticsLog?

    public init(log: DiagnosticsLog? = nil) {
        self.log = log
    }

    public func connect(_ endpoint: SSHEndpoint, auth: SSHAuth, hostKeys: any HostKeyStore) async throws -> ConnectOutcome {
        let label = "\(endpoint.host):\(endpoint.port)"
        do {
            let outcome = try await connect0(endpoint, auth: auth, hostKeys: hostKeys)
            await log?.record(server: label, kind: .connect, "connected as \(auth.user)")
            if outcome.firstSeen {
                await log?.record(server: label, kind: .hostKey, "first seen \(outcome.hostKeyFingerprint)")
            }
            return outcome
        } catch {
            let kind: DiagnosticsEvent.Kind = if case .hostKeyChanged = error as? SSHError { .hostKey } else { .error }
            await log?.record(server: label, kind: kind, "connect failed: \(error)")
            throw error
        }
    }

    private func connect0(_ endpoint: SSHEndpoint, auth: SSHAuth, hostKeys: any HostKeyStore) async throws -> ConnectOutcome {
        let expected = try await hostKeys.fingerprint(for: endpoint.host, port: endpoint.port)
        let tofu = TOFUHostKeyValidator(expected: expected)

        // SSH-хендлеры ставятся в инициализаторе канала, до соединения: баннер сервера приходит
        // сразу после TCP и без хендлера пропал бы в хвосте пайплайна. Не через
        // `SSHClient.connect(on:settings:)` Citadel 0.12.1: тот трогает `syncOperations` пайплайна
        // не с event loop канала и падает на precondition NIO.
        let eventLoop = MultiThreadedEventLoopGroup.singleton.next()
        let authenticated = eventLoop.makePromise(of: Void.self)
        let channel: Channel
        do {
            channel = try await ClientBootstrap(group: eventLoop)
                .connectTimeout(TimeAmount(endpoint.connectTimeout))
                .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandlers(
                            NIOSSHHandler(
                                role: .client(SSHClientConfiguration(userAuthDelegate: KeyAuthDelegate(auth: auth), serverAuthDelegate: tofu)),
                                allocator: channel.allocator,
                                inboundChildChannelInitializer: nil
                            ),
                            AuthenticatedHandler(authenticated: authenticated)
                        )
                    }
                }
                .connect(host: endpoint.host, port: endpoint.port)
                .get()
        } catch {
            authenticated.fail(error)
            throw SSHError.connectFailed(String(describing: error))
        }

        let sshHandler: NIOLoopBound<NIOSSHHandler>
        do {
            let deadline = eventLoop.scheduleTask(in: TimeAmount(endpoint.connectTimeout)) {
                authenticated.fail(SSHError.timeout)
            }
            channel.closeFuture.whenComplete { _ in
                authenticated.fail(SSHError.disconnected)
            }
            try await authenticated.futureResult.always { _ in deadline.cancel() }.get()
            sshHandler = try await eventLoop.submit {
                NIOLoopBound(try channel.pipeline.syncOperations.handler(type: NIOSSHHandler.self), eventLoop: eventLoop)
            }.get()
        } catch {
            try? await channel.close()
            if let mismatch = tofu.result?.mismatch {
                throw mismatch
            }
            throw Self.map(error)
        }

        guard let seen = tofu.result else {
            try? await channel.close()
            throw SSHError.connectFailed("host key was not validated")
        }
        if seen.firstSeen {
            do {
                try await hostKeys.save(seen.seen, for: endpoint.host, port: endpoint.port)
            } catch {
                try? await channel.close()
                throw error
            }
        }
        let connection = CitadelConnection(channel: channel, sshHandler: sshHandler, timeout: endpoint.connectTimeout)
        return ConnectOutcome(connection: connection, hostKeyFingerprint: seen.seen, firstSeen: seen.firstSeen)
    }

    static func map(_ error: Error) -> SSHError {
        switch error {
        case let error as SSHError:
            error
        default:
            .connectFailed(String(describing: error))
        }
    }
}

/// Предлагает серверу один ключ; отказ — `SSHError.authFailed`. Вызывается только на event loop.
private final class KeyAuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let auth: SSHAuth
    private var offered = false

    init(auth: SSHAuth) {
        self.auth = auth
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !offered, availableMethods.contains(.publicKey) else {
            nextChallengePromise.fail(SSHError.authFailed)
            return
        }
        offered = true
        switch auth {
        case let .privateKey(key, user):
            nextChallengePromise.succeed(
                NIOSSHUserAuthenticationOffer(username: user, serviceName: "", offer: .privateKey(.init(privateKey: key.key)))
            )
        }
    }
}

/// Ловит `UserAuthSuccessEvent` и ошибки рукопожатия.
private final class AuthenticatedHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    private let authenticated: EventLoopPromise<Void>

    init(authenticated: EventLoopPromise<Void>) {
        self.authenticated = authenticated
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent {
            authenticated.succeed(())
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        authenticated.fail(error)
        context.close(promise: nil)
    }
}

/// Соединение: TCP-канал с `NIOSSHHandler`.
public final class CitadelConnection: SSHConnection {
    private let channel: Channel
    private let sshHandler: NIOLoopBound<NIOSSHHandler>
    /// Таймаут открытия канала.
    private let channelTimeout: Duration
    public let onDisconnect: AsyncStream<Void>

    init(channel: Channel, sshHandler: NIOLoopBound<NIOSSHHandler>, timeout: Duration) {
        self.channel = channel
        self.sshHandler = sshHandler
        self.channelTimeout = timeout
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        onDisconnect = stream
        channel.closeFuture.whenComplete { _ in
            continuation.yield(())
            continuation.finish()
        }
    }

    public var isConnected: Bool {
        channel.isActive
    }

    public func exec(_ command: String, stdin: Data?, environment: [String: String], timeout: Duration) async throws -> ExecResult {
        let clock = ContinuousClock()
        let start = clock.now
        // `timeout` — на всю команду вместе с открытием канала: пинг обязан уложиться в свои 5 с
        let session = try await open(
            SessionRequest(command: command, environment: Self.sorted(environment), pty: nil),
            timeout: min(channelTimeout, timeout)
        )
        // Быстрая команда может закрыть канал раньше, чем дойдут stdin и EOF: это не ошибка,
        // итог решают код выхода и вывод.
        if let stdin, !stdin.isEmpty {
            try? await session.write(stdin)
        }
        try? await session.eof()
        let remaining = max(timeout - (clock.now - start), .zero)
        guard await session.waitClosed(timeout: remaining) else {
            throw SSHError.timeout
        }
        var stdout = Data()
        var stderr = Data()
        do {
            for try await chunk in session.stdout {
                stdout.append(chunk)
            }
            for try await chunk in session.stderr {
                stderr.append(chunk)
            }
        } catch {
            throw SSHError.disconnected
        }
        guard let code = session.exit else {
            // Канал закрылся без exit-status: оборвалось соединение или команду убили сигналом.
            throw SSHError.disconnected
        }
        return ExecResult(exitCode: code, stdout: stdout, stderr: stderr, duration: clock.now - start)
    }

    public func openPTY(command: String, term: String, cols: Int, rows: Int, environment: [String: String]) async throws -> any PTYChannel {
        let session = try await open(SessionRequest(
            command: command,
            environment: Self.sorted(environment),
            pty: PTYRequest(term: term, cols: cols, rows: rows)
        ))
        return CitadelPTY(session: session)
    }

    public func close() async {
        try? await channel.close()
    }

    private func open(_ request: SessionRequest, timeout: Duration? = nil) async throws -> SessionChannel {
        guard channel.isActive else {
            throw SSHError.disconnected
        }
        return try await SessionChannel.open(on: sshHandler, request: request, timeout: timeout ?? channelTimeout)
    }

    private static func sorted(_ environment: [String: String]) -> [(name: String, value: String)] {
        environment.sorted { $0.key < $1.key }.map { (name: $0.key, value: $0.value) }
    }
}

final class CitadelPTY: PTYChannel {
    private let session: SessionChannel

    init(session: SessionChannel) {
        self.session = session
    }

    var output: AsyncThrowingStream<Data, Error> {
        session.stdout
    }

    var exitCode: Int? {
        session.exit
    }

    func send(_ data: Data) async throws {
        try await session.write(data)
    }

    func resize(cols: Int, rows: Int) async throws {
        try await session.resize(cols: cols, rows: rows)
    }

    func close() async {
        await session.close()
    }
}
