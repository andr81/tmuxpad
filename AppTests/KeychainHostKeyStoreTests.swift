import Foundation
import Testing
@testable import TmuxPad

final class KeychainHostKeyStoreTests {
    let keychain = Keychain.test("hostkey")

    deinit {
        keychain.removeAll()
    }

    @Test func saveReadReset() async throws {
        let store = KeychainHostKeyStore(keychain: keychain)
        #expect(try await store.fingerprint(for: "example.com", port: 22) == nil)
        try await store.save("SHA256:abc", for: "example.com", port: 22)
        try await store.save("SHA256:other", for: "example.com", port: 2222)
        #expect(try await store.fingerprint(for: "example.com", port: 22) == "SHA256:abc")
        #expect(try await store.fingerprint(for: "example.com", port: 2222) == "SHA256:other")
        #expect(try keychain.accounts() == ["example.com:22", "example.com:2222"])
        try await store.save("SHA256:new", for: "example.com", port: 22)
        #expect(try await store.fingerprint(for: "example.com", port: 22) == "SHA256:new")
        try await store.reset(host: "example.com", port: 22)
        #expect(try await store.fingerprint(for: "example.com", port: 22) == nil)
        #expect(try await store.fingerprint(for: "example.com", port: 2222) == "SHA256:other")
    }
}
