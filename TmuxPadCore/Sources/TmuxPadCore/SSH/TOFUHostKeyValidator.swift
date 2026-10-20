import NIOConcurrencyHelpers
import NIOCore
@preconcurrency import NIOSSH

/// TOFU (§8): отпечатка нет — пропустить и запомнить как впервые увиденный; совпал — пропустить;
/// не совпал — `SSHError.hostKeyChanged`, соединение не поднимается. Сохраняет отпечаток в
/// `HostKeyStore` транспорт после успешного `connect`.
public final class TOFUHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, Sendable {
    public struct Result: Sendable, Equatable {
        public var seen: String
        public var firstSeen: Bool
        public var mismatch: SSHError?
    }

    /// Снимок из `HostKeyStore`, прочитанный до подключения.
    public let expected: String?
    private let box = NIOLockedValueBox<Result?>(nil)

    public init(expected: String?) {
        self.expected = expected
    }

    /// Что увидел валидатор; `nil`, если до проверки ключа дело не дошло.
    public var result: Result? {
        box.withLockedValue { $0 }
    }

    public func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let actual = SSHKeys.fingerprint(hostKey)
        guard let expected else {
            box.withLockedValue { $0 = Result(seen: actual, firstSeen: true) }
            validationCompletePromise.succeed(())
            return
        }
        if expected == actual {
            box.withLockedValue { $0 = Result(seen: actual, firstSeen: false) }
            validationCompletePromise.succeed(())
        } else {
            let error = SSHError.hostKeyChanged(expected: expected, actual: actual)
            box.withLockedValue { $0 = Result(seen: actual, firstSeen: false, mismatch: error) }
            validationCompletePromise.fail(error)
        }
    }
}
