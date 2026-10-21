import Foundation
import Testing
import TmuxPadCore
@testable import TmuxPad

struct OnboardingStepTests {
    let key = UUID()
    let server = UUID()

    private func context(se: Bool = false, key: UUID? = nil, server: UUID? = nil) -> OnboardingContext {
        OnboardingContext(secureEnclaveAvailable: se, keyID: key, serverID: server)
    }

    @Test func firstStepPrefersSecureEnclave() {
        #expect(OnboardingStep.first(context: context(se: true)) == .key(.secureEnclaveP256))
        #expect(OnboardingStep.first(context: context(se: false)) == .key(.ed25519))
    }

    @Test func fullPath() {
        var step = OnboardingStep.first(context: context(se: true))
        var visited = [step]
        let full = context(se: true, key: key, server: server)
        while let next = OnboardingStep.next(after: step, context: full) {
            visited.append(next)
            step = next
        }
        #expect(visited == [
            .key(.secureEnclaveP256), .publicKey(key), .server(keyID: key),
            .check(serverID: server), .prepare(serverID: server), .done,
        ])
    }

    @Test func staysOnKeyStepUntilKeyCreated() {
        #expect(OnboardingStep.next(after: .key(.ed25519), context: context()) == .key(.ed25519))
        #expect(OnboardingStep.next(after: .key(.ed25519), context: context(key: key)) == .publicKey(key))
    }

    @Test func staysOnServerStepUntilServerSaved() {
        #expect(OnboardingStep.next(after: .server(keyID: key), context: context(key: key)) == .server(keyID: key))
        #expect(OnboardingStep.next(after: .server(keyID: key), context: context(key: key, server: server)) == .check(serverID: server))
    }

    @Test func deletedKeyReturnsToKeyStep() {
        let noKey = context(se: true, server: server)
        #expect(OnboardingStep.next(after: .publicKey(key), context: noKey) == .key(.secureEnclaveP256))
        #expect(OnboardingStep.next(after: .server(keyID: key), context: noKey) == .key(.secureEnclaveP256))
        #expect(OnboardingStep.next(after: .check(serverID: server), context: context(server: server)) == .key(.ed25519))
        #expect(OnboardingStep.next(after: .prepare(serverID: server), context: noKey) == .key(.secureEnclaveP256))
    }

    @Test func deletedServerReturnsToServerStep() {
        #expect(OnboardingStep.next(after: .check(serverID: server), context: context(key: key)) == .server(keyID: key))
        #expect(OnboardingStep.next(after: .prepare(serverID: server), context: context(key: key)) == .server(keyID: key))
    }

    @Test func doneFinishes() {
        #expect(OnboardingStep.next(after: .done, context: context(key: key, server: server)) == nil)
    }

    @Test func skipHidesOnboarding() {
        let defaults = UserDefaults(suiteName: "dev.tmuxpad.test.\(UUID().uuidString)")!
        #expect(OnboardingFlag.shouldShow(defaults: defaults, hasKeys: false, hasServers: false))
        #expect(!OnboardingFlag.shouldShow(defaults: defaults, hasKeys: true, hasServers: false))
        #expect(!OnboardingFlag.shouldShow(defaults: defaults, hasKeys: false, hasServers: true))
        OnboardingFlag.markDone(defaults)
        #expect(!OnboardingFlag.shouldShow(defaults: defaults, hasKeys: false, hasServers: false))
    }
}
