import Foundation
import Testing
@testable import TmuxPad

/// Запрос к системе: считает вызовы, ответ задаёт тест; `gate` держит запрос открытым.
final class FakePrompt: BiometricPrompt, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    var granted = true
    var delay: Duration = .zero

    var calls: Int {
        lock.withLock { _calls }
    }

    func evaluate(reason: String) async throws -> Bool {
        lock.withLock { _calls += 1 }
        try await Task.sleep(for: delay)
        return granted
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Bool
    private var _locks = 0

    init(_ value: Bool) {
        _value = value
    }

    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }

    var locks: Int {
        lock.withLock { _locks }
    }

    func locked() {
        lock.withLock { _locks += 1 }
    }
}

struct KeyUnlockerTests {
    let prompt = FakePrompt()
    let required = Flag(true)

    private func unlocker() -> KeyUnlocker {
        let required = required
        return KeyUnlocker(prompt: prompt, isRequired: { required.value }, onLock: { required.locked() })
    }

    @Test func secondCallDoesNotAsk() async throws {
        let unlocker = unlocker()
        try await unlocker.authenticate()
        try await unlocker.authenticate()
        #expect(prompt.calls == 1)
    }

    @Test func asksAgainAfterBackground() async throws {
        let unlocker = unlocker()
        try await unlocker.authenticate()
        await unlocker.lock()
        #expect(required.locks == 1)
        try await unlocker.authenticate()
        #expect(prompt.calls == 2)
    }

    @Test func onUnlockFollowsGrantedPromptOnly() async throws {
        let unlocks = Flag(false)
        let unlocker = KeyUnlocker(prompt: prompt, isRequired: { true }, onUnlock: { unlocks.locked() })
        prompt.granted = false
        await #expect(throws: AppError.biometricsDenied) {
            try await unlocker.authenticate()
        }
        #expect(unlocks.locks == 0)
        prompt.granted = true
        try await unlocker.authenticate()
        try await unlocker.authenticate()
        #expect(unlocks.locks == 1)
    }

    @Test func denialThrowsAndAsksAgainNextTime() async throws {
        let unlocker = unlocker()
        prompt.granted = false
        await #expect(throws: AppError.biometricsDenied) {
            try await unlocker.authenticate()
        }
        prompt.granted = true
        try await unlocker.authenticate()
        #expect(prompt.calls == 2)
    }

    @Test func parallelCallsShareOnePrompt() async throws {
        let unlocker = unlocker()
        prompt.delay = .milliseconds(50)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask { try await unlocker.authenticate() }
            }
            try await group.waitForAll()
        }
        #expect(prompt.calls == 1)
    }

    @Test func notRequiredNeverAsks() async throws {
        required.value = false
        let unlocker = unlocker()
        try await unlocker.authenticate()
        await unlocker.lock()
        #expect(prompt.calls == 0)
        // кеш ключей чистится только при включённой проверке
        #expect(required.locks == 0)
    }

    @Test func promptStartedBeforeBackgroundDoesNotUnlockAfterIt() async throws {
        let unlocker = unlocker()
        prompt.delay = .milliseconds(500)
        let first = Task { try await unlocker.authenticate() }
        // запрос уже открыт, а не ещё не начат
        try await waitUntil { prompt.calls == 1 }
        await unlocker.lock()
        try await first.value
        prompt.delay = .zero
        try await unlocker.authenticate()
        #expect(prompt.calls == 2)
    }
}
