import Foundation
import Testing
import TmuxPadCore
@testable import TmuxPad

@MainActor
final class KeyLibraryTests {
    let directory = temporaryDirectory()
    let env: AppEnvironment

    init() throws {
        env = try AppEnvironment.inMemory(directory: directory)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func createAndDelete() async throws {
        let key = try await env.keys.create(kind: .ed25519, name: "iPad Ed25519")
        #expect(env.keys.keys == [key])
        #expect(env.keys.key(id: key.id) == key)
        try await env.keys.delete(key.id)
        #expect(env.keys.keys.isEmpty)
    }

    @Test func secureEnclaveUnavailableInMemory() async throws {
        #expect(!env.keys.secureEnclaveAvailable)
        await #expect(throws: KeyStoreError.secureEnclaveUnavailable) {
            try await self.env.keys.create(kind: .secureEnclaveP256, name: "se")
        }
    }

    @Test func importWithPassphrase() async throws {
        let key = try await env.keys.importKey(
            name: "imported", text: KeychainKeyStoreTests.encryptedKey, passphrase: "secret123"
        )
        #expect(key.publicKeyOpenSSH == KeychainKeyStoreTests.encryptedKeyPublic + " tmuxpad-imported")
        #expect(env.keys.keys == [key])
        let server = ServerConfig(label: "a", host: "h", user: "dev", keyID: key.id)
        guard case let .privateKey(privateKey, user) = try await env.auth(for: server) else {
            Issue.record("unexpected auth")
            return
        }
        #expect(user == "dev")
        #expect(SSHKeys.publicKeyOpenSSH(privateKey.key, comment: "tmuxpad-imported") == key.publicKeyOpenSSH)
    }

    @Test func importGarbageFails() async throws {
        await #expect(throws: KeyError.self) {
            try await self.env.keys.importKey(name: "x", text: "garbage", passphrase: nil)
        }
        #expect(env.keys.keys.isEmpty)
    }

    @Test func deleteKeyInUseFails() async throws {
        let key = try await env.keys.create(kind: .ed25519, name: "k")
        try env.servers.add(ServerConfig(label: "prod", host: "h1", user: "dev", keyID: key.id))
        try env.servers.add(ServerConfig(label: "dev", host: "h2", user: "dev", keyID: key.id))
        await #expect(throws: KeyLibraryError.inUse(["prod", "dev"])) {
            try await self.env.keys.delete(key.id)
        }
        #expect(env.keys.keys == [key])
    }

    @Test func authWithoutKeyFails() async throws {
        let server = ServerConfig(label: "a", host: "h", user: "dev", keyID: UUID())
        await #expect(throws: AppError.keyMissing(server.keyID)) {
            try await self.env.auth(for: server)
        }
    }
}
