import Foundation
import NIOConcurrencyHelpers
import NIOCore
@preconcurrency import NIOSSH

/// Запрос PTY для канала.
struct PTYRequest: Sendable {
    var term: String
    var cols: Int
    var rows: Int
}

/// Что открыть в канале: env-запросы, при `pty` — PTY, затем exec `command`.
struct SessionRequest: Sendable {
    var command: String
    var environment: [(name: String, value: String)]
    var pty: PTYRequest?
}

/// Один хендлер на все виды сессионных каналов (exec, exec со stdin, PTY + exec). Шлёт запросы,
/// когда канал открыт, ждёт ответы на PTY и exec, раскладывает stdout/stderr, ловит код выхода.
/// Живёт на event loop канала.
final class SessionChannelHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private let request: SessionRequest
    private let started: EventLoopPromise<Void>
    private let stdout: AsyncThrowingStream<Data, Error>.Continuation
    private let stderr: AsyncThrowingStream<Data, Error>.Continuation
    private let exit: NIOLockedValueBox<Int?>
    private let remoteEOF: NIOLockedValueBox<Bool>
    private var pendingReplies = 0
    private var requested = false
    private var context: ChannelHandlerContext?

    init(
        request: SessionRequest,
        started: EventLoopPromise<Void>,
        stdout: AsyncThrowingStream<Data, Error>.Continuation,
        stderr: AsyncThrowingStream<Data, Error>.Continuation,
        exit: NIOLockedValueBox<Int?>,
        remoteEOF: NIOLockedValueBox<Bool>
    ) {
        self.request = request
        self.started = started
        self.stdout = stdout
        self.stderr = stderr
        self.exit = exit
        self.remoteEOF = remoteEOF
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        do {
            try context.channel.syncOptions?.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
        } catch {
            errorCaught(context: context, error: error)
            return
        }
        if context.channel.isActive {
            sendRequests(context: context)
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        finish(error: SSHError.disconnected)
    }

    func channelActive(context: ChannelHandlerContext) {
        sendRequests(context: context)
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish(error: SSHError.disconnected)
        context.fireChannelInactive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case let .byteBuffer(buffer) = message.data else {
            return
        }
        let bytes = Data(buffer.readableBytesView)
        switch message.type {
        case .channel:
            stdout.yield(bytes)
        case .stdErr:
            // В PTY sshd сливает stderr в stdout сам; отдельный stderr бывает только у exec.
            if request.pty == nil {
                stderr.yield(bytes)
            } else {
                stdout.yield(bytes)
            }
        default:
            break
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            pendingReplies -= 1
            if pendingReplies == 0 {
                started.succeed(())
            }
        case is ChannelFailureEvent:
            started.fail(SSHError.channelRefused)
            context.close(promise: nil)
        case let status as SSHChannelRequestEvent.ExitStatus:
            exit.withLockedValue { $0 = status.exitStatus }
        case let channelEvent as ChannelEvent where channelEvent == .inputClosed:
            remoteEOF.withLockedValue { $0 = true }
            context.fireUserInboundEventTriggered(event)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        started.fail(error)
        stdout.finish(throwing: error)
        stderr.finish(throwing: error)
        context.close(promise: nil)
    }

    /// Таймаут открытия: закрыть канал, если он уже есть.
    func abort() {
        context?.close(promise: nil)
    }

    private func sendRequests(context: ChannelHandlerContext) {
        guard !requested else {
            return
        }
        requested = true
        // Без ответа: sshd молча отбрасывает то, чего нет в `AcceptEnv`.
        for variable in request.environment {
            context.triggerUserOutboundEvent(
                SSHChannelRequestEvent.EnvironmentRequest(wantReply: false, name: variable.name, value: variable.value),
                promise: nil
            )
        }
        if let pty = request.pty {
            pendingReplies += 1
            context.triggerUserOutboundEvent(
                SSHChannelRequestEvent.PseudoTerminalRequest(
                    wantReply: true,
                    term: pty.term,
                    terminalCharacterWidth: pty.cols,
                    terminalRowHeight: pty.rows,
                    terminalPixelWidth: 0,
                    terminalPixelHeight: 0,
                    terminalModes: SSHTerminalModes([:])
                ),
                promise: nil
            )
        }
        pendingReplies += 1
        context.triggerUserOutboundEvent(
            SSHChannelRequestEvent.ExecRequest(command: request.command, wantReply: true),
            promise: nil
        )
    }

    private func finish(error: Error) {
        started.fail(error)
        stdout.finish()
        stderr.finish()
    }
}

/// Открытый сессионный канал поверх `NIOSSHHandler`.
final class SessionChannel: Sendable {
    let channel: Channel
    let stdout: AsyncThrowingStream<Data, Error>
    let stderr: AsyncThrowingStream<Data, Error>
    private let exitBox: NIOLockedValueBox<Int?>
    /// Сервер прислал EOF; пишет хендлер на event loop канала.
    private let remoteEOF: NIOLockedValueBox<Bool>

    private init(
        channel: Channel,
        stdout: AsyncThrowingStream<Data, Error>,
        stderr: AsyncThrowingStream<Data, Error>,
        exit: NIOLockedValueBox<Int?>,
        remoteEOF: NIOLockedValueBox<Bool>
    ) {
        self.channel = channel
        self.stdout = stdout
        self.stderr = stderr
        self.exitBox = exit
        self.remoteEOF = remoteEOF
    }

    /// Код из `exit-status`; `nil`, пока его не было.
    var exit: Int? {
        exitBox.withLockedValue { $0 }
    }

    /// Открывает канал и ждёт ответа сервера на PTY и exec не дольше `timeout`
    /// (свой таймаут вместо 15 с Citadel). Отказ открыть канал или выполнить запрос —
    /// `SSHError.channelRefused`.
    static func open(on sshHandler: NIOLoopBound<NIOSSHHandler>, request: SessionRequest, timeout: Duration) async throws -> SessionChannel {
        let eventLoop = sshHandler.eventLoop
        let (stdout, stdoutContinuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let (stderr, stderrContinuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let exit = NIOLockedValueBox<Int?>(nil)
        let remoteEOF = NIOLockedValueBox(false)

        let future = eventLoop.flatSubmit { () -> EventLoopFuture<Channel> in
            let channelPromise = eventLoop.makePromise(of: Channel.self)
            let started = eventLoop.makePromise(of: Void.self)
            let handler = NIOLoopBound(
                SessionChannelHandler(
                    request: request,
                    started: started,
                    stdout: stdoutContinuation,
                    stderr: stderrContinuation,
                    exit: exit,
                    remoteEOF: remoteEOF
                ),
                eventLoop: eventLoop
            )
            sshHandler.value.createChannel(channelPromise, channelType: .session) { channel, _ in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(handler.value)
                }
            }
            let deadline = eventLoop.scheduleTask(in: TimeAmount(timeout)) {
                channelPromise.fail(SSHError.timeout)
                started.fail(SSHError.timeout)
                handler.value.abort()
            }
            channelPromise.futureResult.whenFailure { error in
                started.fail(error)
                stdoutContinuation.finish()
                stderrContinuation.finish()
            }
            started.futureResult.whenComplete { _ in
                deadline.cancel()
            }
            return channelPromise.futureResult.and(started.futureResult).map { channel, _ in channel }
        }

        do {
            let channel = try await future.get()
            return SessionChannel(channel: channel, stdout: stdout, stderr: stderr, exit: exit, remoteEOF: remoteEOF)
        } catch let error as SSHError {
            throw error
        } catch let error as NIOSSHError where error.type == .channelSetupRejected {
            throw SSHError.channelRefused
        } catch let error as NIOSSHError where error.type == .tcpShutdown || error.type == .creatingChannelAfterClosure {
            throw SSHError.disconnected
        } catch is ChannelError {
            throw SSHError.disconnected
        }
    }

    func write(_ data: Data) async throws {
        let message = SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(bytes: data)))
        do {
            try await channel.writeAndFlush(message)
        } catch {
            throw SSHError.disconnected
        }
    }

    /// EOF на stdin удалённой команды. Не после EOF сервера: форк swift-nio-ssh 0.3.x
    /// (`ChildChannelStateMachine.sendChannelEOF`) считает это нарушением протокола и рвёт канал
    /// вместе с ещё не пришедшим exit-status — быстрая команда успевает закрыть вывод раньше.
    /// Проверка и отправка — на event loop канала, там же хендлер ставит флаг.
    func eof() async throws {
        let channel = channel
        let remoteEOF = remoteEOF
        do {
            try await channel.eventLoop.flatSubmit {
                if remoteEOF.withLockedValue({ $0 }) {
                    return channel.eventLoop.makeSucceededVoidFuture()
                }
                return channel.close(mode: .output)
            }.get()
        } catch {
            throw SSHError.disconnected
        }
    }

    func resize(cols: Int, rows: Int) async throws {
        let request = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: cols,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0
        )
        do {
            try await channel.triggerUserOutboundEvent(request)
        } catch {
            throw SSHError.disconnected
        }
    }

    func close() async {
        try? await channel.close()
    }

    /// Ждёт закрытия канала не дольше `timeout`; по таймауту закрывает канал сам и возвращает `false`.
    func waitClosed(timeout: Duration) async -> Bool {
        let timedOut = NIOLockedValueBox(false)
        let deadline = channel.eventLoop.scheduleTask(in: TimeAmount(timeout)) { [channel] in
            timedOut.withLockedValue { $0 = true }
            channel.close(promise: nil)
        }
        try? await channel.closeFuture.get()
        deadline.cancel()
        return !timedOut.withLockedValue { $0 }
    }
}
