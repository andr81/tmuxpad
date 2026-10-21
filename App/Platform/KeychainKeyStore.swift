import Citadel
import CryptoKit
import Foundation
@preconcurrency import NIOSSH
import Security
import TmuxPadCore

enum KeyStoreError: Error, Equatable {
    case secureEnclaveUnavailable
    case unsupportedKind
    /// Метаданные ключа есть, а приватной части в Keychain нет.
    case notFound
}

/// Ключи пользователя: метаданные в `keys.json`, приватная часть в Keychain (account — `id`).
/// Ed25519 хранится OpenSSH-текстом без шифра, Secure Enclave — `dataRepresentation`,
/// годным только на этом устройстве.
actor KeychainKeyStore: AppKeyStore {
    private let keychain: Keychain
    private let metadata: JSONFileStore<[SSHKeyInfo]>

    init(keychain: Keychain = .keys, metadata: JSONFileStore<[SSHKeyInfo]> = JSONFileStore(fileName: "keys.json")) {
        self.keychain = keychain
        self.metadata = metadata
    }

    /// Без изоляции: читает только `keys.json`, запись в него атомарная. `AppEnvironment.live()`
    /// берёт отсюда начальный список синхронно.
    nonisolated func list() throws -> [SSHKeyInfo] {
        (try metadata.load() ?? []).sorted { $0.createdAt < $1.createdAt }
    }

    /// Только `.ed25519`: ключи Secure Enclave создаёт `createSecureEnclave`.
    func save(_ info: SSHKeyInfo, privateKeyOpenSSH: String) throws {
        guard info.kind == .ed25519 else {
            throw KeyStoreError.unsupportedKind
        }
        _ = try SSHKeys.importOpenSSHEd25519(privateKeyOpenSSH)
        try store(info, secret: Data(privateKeyOpenSSH.utf8))
    }

    func privateKey(for id: UUID) throws -> SSHPrivateKey? {
        guard let info = try list().first(where: { $0.id == id }) else {
            return nil
        }
        guard let data = try keychain.read(account: id.uuidString) else {
            throw KeyStoreError.notFound
        }
        switch info.kind {
        case .ed25519:
            return SSHPrivateKey(try SSHKeys.importOpenSSHEd25519(String(decoding: data, as: UTF8.self)))
        case .secureEnclaveP256:
            let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data)
            return SSHPrivateKey(NIOSSHPrivateKey(secureEnclaveP256Key: key))
        }
    }

    func delete(_ id: UUID) throws {
        try metadata.save(try list().filter { $0.id != id })
        try keychain.delete(account: id.uuidString)
    }

    func createEd25519(name: String) throws -> SSHKeyInfo {
        let (info, text) = Self.newEd25519(name: name)
        try store(info, secret: Data(text.utf8))
        return info
    }

    /// Face ID на использование ключа — план 7, пока только `.privateKeyUsage`.
    func createSecureEnclave(name: String) throws -> SSHKeyInfo {
        guard SecureEnclave.isAvailable else {
            throw KeyStoreError.secureEnclaveUnavailable
        }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage, &error
        ) else {
            throw error!.takeRetainedValue() as Error
        }
        let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
        let nioKey = NIOSSHPrivateKey(secureEnclaveP256Key: key)
        let info = SSHKeyInfo(
            name: name,
            kind: .secureEnclaveP256,
            publicKeyOpenSSH: SSHKeys.publicKeyOpenSSH(nioKey, comment: Self.comment(for: name))
        )
        try store(info, secret: key.dataRepresentation)
        return info
    }

    /// OpenSSH Ed25519, с паролем или без; хранится без шифра — его защищает Keychain.
    func importEd25519(name: String, text: String, passphrase: String?) throws -> SSHKeyInfo {
        let (info, plain) = try Self.decryptEd25519(name: name, text: text, passphrase: passphrase)
        try store(info, secret: Data(plain.utf8))
        return info
    }

    /// Новый Ed25519: метаданные и OpenSSH-текст без шифра.
    static func newEd25519(name: String) -> (SSHKeyInfo, String) {
        let raw = Curve25519.Signing.PrivateKey()
        return (ed25519Info(name: name, raw), openSSHText(raw, comment: comment(for: name)))
    }

    /// Импортируемый OpenSSH Ed25519 → метаданные и тот же ключ текстом без шифра.
    static func decryptEd25519(name: String, text: String, passphrase: String?) throws -> (SSHKeyInfo, String) {
        let comment = comment(for: name)
        let raw: Curve25519.Signing.PrivateKey
        do {
            raw = try Curve25519.Signing.PrivateKey(
                sshEd25519: text,
                decryptionKey: passphrase.flatMap { $0.isEmpty ? nil : Data($0.utf8) }
            )
        } catch {
            throw KeyError.invalidKey(String(describing: error))
        }
        return (ed25519Info(name: name, raw), openSSHText(raw, comment: comment))
    }

    private static func ed25519Info(name: String, _ raw: Curve25519.Signing.PrivateKey) -> SSHKeyInfo {
        SSHKeyInfo(
            name: name,
            kind: .ed25519,
            publicKeyOpenSSH: SSHKeys.publicKeyOpenSSH(NIOSSHPrivateKey(ed25519Key: raw), comment: comment(for: name))
        )
    }

    /// `openssh-key-v1` без шифра. Не `makeSSHRepresentation` Citadel (и не
    /// `SSHKeys.generateEd25519` ядра поверх него): когда длина приватной секции кратна 8 —
    /// комментарий длиной 5 по модулю 8, например `tmuxpad-bench`, — тот дописывает 8 байт
    /// выравнивания вместо 0, и такой файл не читает сам Citadel.
    static func openSSHText(_ key: Curve25519.Signing.PrivateKey, comment: String) -> String {
        func uint32(_ value: UInt32) -> Data {
            withUnsafeBytes(of: value.bigEndian) { Data($0) }
        }
        func string(_ bytes: Data) -> Data {
            uint32(UInt32(bytes.count)) + bytes
        }
        let publicKey = key.publicKey.rawRepresentation
        let publicBlob = string(Data("ssh-ed25519".utf8)) + string(publicKey)
        let check = uint32(UInt32.random(in: .min ... .max))
        var secret = check + check + publicBlob + string(key.rawRepresentation + publicKey) + string(Data(comment.utf8))
        var pad: UInt8 = 1
        while secret.count % 8 != 0 {
            secret.append(pad)
            pad += 1
        }
        let none = string(Data("none".utf8))
        let body = Data("openssh-key-v1\0".utf8) + none + none + string(Data()) + uint32(1) + string(publicBlob) + string(secret)
        let base64 = body.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN OPENSSH PRIVATE KEY-----\n\(base64)\n-----END OPENSSH PRIVATE KEY-----\n"
    }

    /// Комментарий публичного ключа: `tmuxpad-<имя>` без пробелов.
    static func comment(for name: String) -> String {
        let words = name.split(whereSeparator: \.isWhitespace)
        return (["tmuxpad"] + words).joined(separator: "-")
    }

    /// Сначала секрет, потом метаданные; при ошибке записи метаданных секрет удаляется.
    private func store(_ info: SSHKeyInfo, secret: Data) throws {
        try keychain.write(secret, account: info.id.uuidString)
        do {
            try metadata.save(try list().filter { $0.id != info.id } + [info])
        } catch {
            try? keychain.delete(account: info.id.uuidString)
            throw error
        }
    }
}
