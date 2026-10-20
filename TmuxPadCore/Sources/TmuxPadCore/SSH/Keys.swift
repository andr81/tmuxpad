import Citadel
import Crypto
import Foundation
import NIOCore
@preconcurrency import NIOSSH

public enum KeyError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidKey(String)

    public var description: String {
        switch self {
        case let .invalidKey(message): "The key could not be read: \(message)"
        }
    }
}

/// Ed25519-ключи и отпечатки. Secure Enclave P-256 приложение заворачивает в
/// `NIOSSHPrivateKey(secureEnclaveP256Key:)` само.
public enum SSHKeys {
    public struct GeneratedKey: Sendable {
        public var privateKey: SSHPrivateKey
        /// `openssh-key-v1` без шифра — для `KeyStore`.
        public var privateKeyOpenSSH: String
        public var publicKeyOpenSSH: String
    }

    public static func generateEd25519(comment: String = "tmuxpad") -> GeneratedKey {
        let raw = Curve25519.Signing.PrivateKey()
        let key = NIOSSHPrivateKey(ed25519Key: raw)
        return GeneratedKey(
            privateKey: SSHPrivateKey(key),
            privateKeyOpenSSH: raw.makeSSHRepresentation(comment: comment),
            publicKeyOpenSSH: publicKeyOpenSSH(key, comment: comment)
        )
    }

    /// Читает OpenSSH-файл Ed25519 (`openssh-key-v1`, без шифра или с bcrypt + passphrase).
    public static func importOpenSSHEd25519(_ text: String, passphrase: String? = nil) throws -> NIOSSHPrivateKey {
        do {
            let raw = try Curve25519.Signing.PrivateKey(sshEd25519: text, decryptionKey: passphrase.map { Data($0.utf8) })
            return NIOSSHPrivateKey(ed25519Key: raw)
        } catch {
            throw KeyError.invalidKey(String(describing: error))
        }
    }

    /// `ssh-ed25519 AAAA… comment`.
    public static func publicKeyOpenSSH(_ key: NIOSSHPrivateKey, comment: String) -> String {
        let line = String(openSSHPublicKey: key.publicKey)
        return comment.isEmpty ? line : "\(line) \(comment)"
    }

    /// `SHA256:<base64 без '='>` от wire-формата ключа, как у `ssh-keygen -l`.
    public static func fingerprint(_ key: NIOSSHPublicKey) -> String {
        var buffer = ByteBufferAllocator().buffer(capacity: 128)
        key.write(to: &buffer)
        let digest = SHA256.hash(data: Data(buffer.readableBytesView))
        let base64 = Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:\(base64)"
    }

    /// Команда §3.7, которую пользователь вставляет на сервере.
    public static func authorizedKeysCommand(publicKey: String) -> String {
        "mkdir -p ~/.ssh && echo '\(publicKey)' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
    }
}
