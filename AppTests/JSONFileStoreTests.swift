import Foundation
import Testing
@testable import TmuxPad

final class JSONFileStoreTests {
    let directory = temporaryDirectory()

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func missingFileLoadsNil() throws {
        let store = JSONFileStore<[String]>(fileName: "x.json", directory: directory)
        #expect(try store.load() == nil)
    }

    @Test func saveCreatesDirectoryAndRoundTrips() throws {
        let store = JSONFileStore<[String: Int]>(fileName: "x.json", directory: directory.appending(path: "nested"))
        try store.save(["b": 2, "a": 1])
        #expect(try store.load() == ["a": 1, "b": 2])
        try store.save(["c": 3])
        #expect(try store.load() == ["c": 3])
        let text = try String(contentsOf: store.url, encoding: .utf8)
        #expect(text.contains("\n"))
    }

    @Test func brokenJSONThrowsAndKeepsFile() throws {
        let store = JSONFileStore<[String]>(fileName: "x.json", directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: store.url)
        #expect(throws: DecodingError.self) { try store.load() }
        #expect(try Data(contentsOf: store.url) == Data("{not json".utf8))
    }

    @Test func atomicWriteLeavesNoTemporaryFiles() throws {
        let store = JSONFileStore<[String]>(fileName: "x.json", directory: directory)
        try store.save(["a"])
        try store.save(["b"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["x.json"])
    }
}
