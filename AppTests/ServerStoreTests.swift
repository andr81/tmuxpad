import Foundation
import Testing
import TmuxPadCore
@testable import TmuxPad

@MainActor
final class ServerStoreTests {
    let directory = temporaryDirectory()
    let env: AppEnvironment

    init() throws {
        env = try AppEnvironment.inMemory(directory: directory)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func config(_ label: String, host: String = "example.com", keyID: UUID = UUID()) -> ServerConfig {
        ServerConfig(label: label, host: host, user: "dev", keyID: keyID)
    }

    @Test func addAppendsAndPersists() throws {
        try env.servers.add(config("a"))
        try env.servers.add(config("b"))
        #expect(env.servers.servers.map(\.label) == ["a", "b"])
        #expect(env.servers.servers.map(\.sortIndex) == [0, 1])

        let reopened = try AppEnvironment.inMemory(directory: directory)
        #expect(reopened.servers.servers == env.servers.servers)
    }

    @Test func updateReplacesById() throws {
        try env.servers.add(config("a"))
        var server = env.servers.servers[0]
        server.port = 2222
        try env.servers.update(server)
        #expect(env.servers.servers == [server])
    }

    @Test func duplicateDropsFingerprintAndGoesAfterOriginal() throws {
        var original = config("prod")
        original.hostKeyFingerprint = "SHA256:abc"
        try env.servers.add(original)
        try env.servers.add(config("dev"))
        let source = env.servers.servers[0]

        let copy = try env.servers.duplicate(source)
        #expect(copy.id != source.id)
        #expect(copy.label == "prod копия")
        #expect(copy.hostKeyFingerprint == nil)
        #expect(copy.host == source.host && copy.keyID == source.keyID)
        #expect(env.servers.servers.map(\.label) == ["prod", "prod копия", "dev"])
        #expect(env.servers.servers.map(\.sortIndex) == [0, 1, 2])
    }

    @Test func deleteRemovesFromPoolAndResetsHostKey() async throws {
        let key = try await env.keys.create(kind: .ed25519, name: "k")
        try env.servers.add(config("a", keyID: key.id))
        let server = env.servers.servers[0]
        _ = await env.pool.connection(for: server, auth: try await env.auth(for: server))
        try await env.hostKeys.save("SHA256:abc", for: server.host, port: server.port)
        #expect(await env.pool.existing(id: server.id) != nil)

        try await env.servers.delete(id: server.id)
        #expect(env.servers.servers.isEmpty)
        #expect(await env.pool.existing(id: server.id) == nil)
        #expect(try await env.hostKeys.fingerprint(for: server.host, port: server.port) == nil)
        #expect(try AppEnvironment.inMemory(directory: directory).servers.servers.isEmpty)
    }

    @Test func deleteKeepsHostKeySharedWithAnotherServer() async throws {
        try env.servers.add(config("a"))
        let server = env.servers.servers[0]
        try env.servers.duplicate(server)
        try await env.hostKeys.save("SHA256:abc", for: server.host, port: server.port)

        try await env.servers.delete(id: server.id)
        #expect(try await env.hostKeys.fingerprint(for: server.host, port: server.port) == "SHA256:abc")
    }

    @Test func moveRenumbers() throws {
        for label in ["a", "b", "c"] {
            try env.servers.add(config(label))
        }
        try env.servers.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(env.servers.servers.map(\.label) == ["c", "a", "b"])
        #expect(env.servers.servers.map(\.sortIndex) == [0, 1, 2])
        let reopened = try AppEnvironment.inMemory(directory: directory)
        #expect(reopened.servers.servers.map(\.label) == ["c", "a", "b"])
    }

    @Test func issues() async throws {
        let key = try await env.keys.create(kind: .ed25519, name: "k")
        #expect(env.servers.issues(for: config("ok", keyID: key.id), keys: env.keys.keys).isEmpty)

        let emptyLabel = env.servers.issues(for: config(" ", keyID: key.id), keys: env.keys.keys)
        #expect(emptyLabel == ["Укажите название"])

        let unknownKey = env.servers.issues(for: config("a"), keys: env.keys.keys)
        #expect(unknownKey == ["Выберите ключ"])

        var bad = config("a", host: "", keyID: key.id)
        bad.port = 0
        #expect(env.servers.issues(for: bad, keys: env.keys.keys) == ["Укажите адрес", "Порт — от 1 до 65535"])
    }

    @Test func brokenFileFailsLoad() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: directory.appending(path: "servers.json"))
        #expect(throws: (any Error).self) {
            try AppEnvironment.inMemory(directory: directory)
        }
    }
}
