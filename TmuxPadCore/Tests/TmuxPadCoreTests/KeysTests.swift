import Foundation
@preconcurrency import NIOSSH
import Testing
@testable import TmuxPadCore

@Suite struct KeysTests {
    @Test func generatedKeyExportsAndParses() throws {
        let generated = SSHKeys.generateEd25519(comment: "ipad")
        let parts = generated.publicKeyOpenSSH.split(separator: " ")
        #expect(parts.count == 3)
        #expect(parts[0] == "ssh-ed25519")
        #expect(parts[1].hasPrefix("AAAA"))
        #expect(parts[2] == "ipad")
        let parsed = try NIOSSHPublicKey(openSSHPublicKey: generated.publicKeyOpenSSH)
        #expect(parsed == generated.privateKey.publicKey)
    }

    @Test func generatedPrivateKeyRoundTrips() throws {
        let generated = SSHKeys.generateEd25519()
        let imported = try SSHKeys.importOpenSSHEd25519(generated.privateKeyOpenSSH)
        #expect(imported.publicKey == generated.privateKey.publicKey)
    }

    @Test func fingerprintShape() {
        let key = SSHKeys.generateEd25519().privateKey.publicKey
        let fingerprint = SSHKeys.fingerprint(key)
        #expect(fingerprint.hasPrefix("SHA256:"))
        #expect(fingerprint.count == 7 + 43)
        #expect(!fingerprint.contains("="))
        #expect(SSHKeys.fingerprint(key) == fingerprint)
    }

    @Test func authorizedKeysCommand() {
        let pub = SSHKeys.generateEd25519().publicKeyOpenSSH
        let command = SSHKeys.authorizedKeysCommand(publicKey: pub)
        #expect(command == "mkdir -p ~/.ssh && echo '\(pub)' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys")
    }

    @Test func invalidKeyThrowsOwnError() {
        #expect(throws: KeyError.self) {
            try SSHKeys.importOpenSSHEd25519("-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----\n")
        }
    }

    #if os(Linux) || os(macOS)
    /// Ключ от `ssh-keygen`: импорт и отпечаток как у `ssh-keygen -l`.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh-keygen")))
    func importsSSHKeygenKey() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tmuxpad-keys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("key").path
        try run("/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "test", "-f", path)

        let key = try SSHKeys.importOpenSSHEd25519(try String(contentsOfFile: path, encoding: .utf8))
        let pub = try String(contentsOfFile: path + ".pub", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(SSHKeys.publicKeyOpenSSH(key, comment: "test") == pub)

        // "256 SHA256:… test (ED25519)"
        let line = try run("/usr/bin/ssh-keygen", "-l", "-f", path + ".pub")
        let expected = line.split(separator: " ")[1]
        #expect(SSHKeys.fingerprint(key.publicKey) == String(expected))
    }

    @discardableResult
    private func run(_ executable: String, _ arguments: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return String(decoding: data, as: UTF8.self)
    }
    #endif
}
