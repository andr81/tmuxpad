import CryptoKit
import Foundation
import Testing
import TmuxPadCore
@testable import TmuxPad

final class KeychainKeyStoreTests {
    /// `ssh-keygen -t ed25519 -N secret123 -C test`.
    static let encryptedKey = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABCGBYo140
        yjN7eW8PxZsQBoAAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIKiWj7zNgw0ZlcFl
        1taG+/xDj0jfndUlpchcLw1R0ZaTAAAAkEy+Cz7b31mYEbsSok4/TM+eNaWDSytScy23Rs
        MnCPgjAfA6nKO4HJ0FCSapkGHMZUVnzB1mnhroxTIXu61hugT3XJrEbOBvEdx4Ti5rNV91
        wvUD4ZYVJD07jYtgUGsODp3zpT77P1yXMpXlXiezYHYXoin1lbZWylhe3yfMdtg/1NAFoC
        Eq79R+FsEn7qRmLg==
        -----END OPENSSH PRIVATE KEY-----

        """
    static let encryptedKeyPublic = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKiWj7zNgw0ZlcFl1taG+/xDj0jfndUlpchcLw1R0ZaT"

    let keychain = Keychain.test("keys")
    let directory = temporaryDirectory()
    let store: KeychainKeyStore

    init() {
        store = KeychainKeyStore(keychain: keychain, metadata: JSONFileStore(fileName: "keys.json", directory: directory))
    }

    deinit {
        keychain.removeAll()
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func ed25519FullCycle() async throws {
        let info = try await store.createEd25519(name: "My iPad")
        #expect(info.kind == .ed25519)
        #expect(info.publicKeyOpenSSH.hasPrefix("ssh-ed25519 "))
        #expect(info.publicKeyOpenSSH.hasSuffix(" tmuxpad-My-iPad"))
        #expect(try store.list() == [info])
        #expect(try keychain.accounts() == [info.id.uuidString])

        let key = try #require(try await store.privateKey(for: info.id))
        #expect(SSHKeys.publicKeyOpenSSH(key.key, comment: "tmuxpad-My-iPad") == info.publicKeyOpenSSH)

        // Метаданные переживают новый экземпляр хранилища.
        let reopened = KeychainKeyStore(keychain: keychain, metadata: JSONFileStore(fileName: "keys.json", directory: directory))
        #expect(try reopened.list() == [info])

        try await store.delete(info.id)
        #expect(try store.list().isEmpty)
        #expect(try keychain.accounts().isEmpty)
        #expect(try await store.privateKey(for: info.id) == nil)
    }

    /// Комментарий любой длины по модулю 8: `makeSSHRepresentation` Citadel давал нечитаемый
    /// файл при длине 5 (`tmuxpad-bench`).
    @Test(arguments: 0..<8) func ed25519TextReadsBackForEveryCommentLength(extra: Int) throws {
        let name = String(repeating: "x", count: 5 + extra)
        let (info, text) = KeychainKeyStore.newEd25519(name: name)
        let key = try SSHKeys.importOpenSSHEd25519(text)
        #expect(SSHKeys.publicKeyOpenSSH(key, comment: KeychainKeyStore.comment(for: name)) == info.publicKeyOpenSSH)

        let (imported, plain) = try KeychainKeyStore.decryptEd25519(name: name, text: text, passphrase: nil)
        #expect(imported.publicKeyOpenSSH == info.publicKeyOpenSSH)
        _ = try SSHKeys.importOpenSSHEd25519(plain)
    }

    @Test func listIsSortedByCreation() async throws {
        let first = try await store.createEd25519(name: "a")
        let second = try await store.createEd25519(name: "b")
        #expect(try store.list().map(\.id) == [first.id, second.id])
    }

    @Test func importWithPassphrase() async throws {
        let info = try await store.importEd25519(name: "laptop", text: Self.encryptedKey, passphrase: "secret123")
        #expect(info.publicKeyOpenSSH == Self.encryptedKeyPublic + " tmuxpad-laptop")
        // Хранится без шифра: ключ читается без пароля.
        let stored = try #require(try keychain.read(account: info.id.uuidString))
        _ = try SSHKeys.importOpenSSHEd25519(String(decoding: stored, as: UTF8.self))
        let key = try #require(try await store.privateKey(for: info.id))
        #expect(SSHKeys.publicKeyOpenSSH(key.key, comment: "") == Self.encryptedKeyPublic)
    }

    @Test func importWithWrongPassphraseFails() async throws {
        await #expect(throws: KeyError.self) {
            try await self.store.importEd25519(name: "x", text: Self.encryptedKey, passphrase: "wrong")
        }
        #expect(try store.list().isEmpty)
    }

    @Test func importGarbageIsInvalidKey() async throws {
        await #expect {
            try await self.store.importEd25519(name: "x", text: "garbage", passphrase: nil)
        } throws: { error in
            if case KeyError.invalidKey = error { true } else { false }
        }
        #expect(try store.list().isEmpty)
        #expect(try keychain.accounts().isEmpty)
    }

    @Test func protocolSaveAcceptsOnlyEd25519() async throws {
        let generated = SSHKeys.generateEd25519(comment: "c")
        let info = SSHKeyInfo(name: "saved", kind: .ed25519, publicKeyOpenSSH: generated.publicKeyOpenSSH)
        try await store.save(info, privateKeyOpenSSH: generated.privateKeyOpenSSH)
        #expect(try await store.privateKey(for: info.id) != nil)

        let se = SSHKeyInfo(name: "se", kind: .secureEnclaveP256, publicKeyOpenSSH: "x")
        await #expect(throws: KeyStoreError.unsupportedKind) {
            try await self.store.save(se, privateKeyOpenSSH: generated.privateKeyOpenSSH)
        }
    }

    @Test func missingSecretIsNotFound() async throws {
        let info = try await store.createEd25519(name: "x")
        try keychain.delete(account: info.id.uuidString)
        await #expect(throws: KeyStoreError.notFound) { try await self.store.privateKey(for: info.id) }
    }

    @Test func commentHasNoSpaces() {
        #expect(KeychainKeyStore.comment(for: "  work  iPad ") == "tmuxpad-work-iPad")
        #expect(KeychainKeyStore.comment(for: "") == "tmuxpad")
    }

    @Test(.enabled(if: !SecureEnclave.isAvailable))
    func secureEnclaveUnavailableThrows() async throws {
        await #expect(throws: KeyStoreError.secureEnclaveUnavailable) {
            try await self.store.createSecureEnclave(name: "se")
        }
    }

    @Test(.enabled(if: SecureEnclave.isAvailable))
    func secureEnclaveFullCycle() async throws {
        let info = try await store.createSecureEnclave(name: "se")
        #expect(info.kind == .secureEnclaveP256)
        #expect(info.publicKeyOpenSSH.hasPrefix("ecdsa-sha2-nistp256 "))
        let key = try #require(try await store.privateKey(for: info.id))
        #expect(SSHKeys.publicKeyOpenSSH(key.key, comment: "tmuxpad-se") == info.publicKeyOpenSSH)
        try await store.delete(info.id)
        #expect(try keychain.accounts().isEmpty)
    }
}
