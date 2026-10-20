import NIOCore
import NIOEmbedded
@preconcurrency import NIOSSH
import Testing
@testable import TmuxPadCore

@Suite struct TOFUTests {
    let loop = EmbeddedEventLoop()
    let key = SSHKeys.generateEd25519().privateKey.publicKey

    private func validate(_ validator: TOFUHostKeyValidator) throws {
        let promise = loop.makePromise(of: Void.self)
        validator.validateHostKey(hostKey: key, validationCompletePromise: promise)
        try promise.futureResult.wait()
    }

    @Test func firstSeen() throws {
        let validator = TOFUHostKeyValidator(expected: nil)
        try validate(validator)
        #expect(validator.result == .init(seen: SSHKeys.fingerprint(key), firstSeen: true))
    }

    @Test func match() throws {
        let validator = TOFUHostKeyValidator(expected: SSHKeys.fingerprint(key))
        try validate(validator)
        #expect(validator.result == .init(seen: SSHKeys.fingerprint(key), firstSeen: false))
    }

    @Test func mismatch() {
        let other = SSHKeys.fingerprint(SSHKeys.generateEd25519().privateKey.publicKey)
        let validator = TOFUHostKeyValidator(expected: other)
        let changed = SSHError.hostKeyChanged(expected: other, actual: SSHKeys.fingerprint(key))
        #expect(throws: changed) {
            try validate(validator)
        }
        #expect(validator.result?.mismatch == changed)
    }
}
