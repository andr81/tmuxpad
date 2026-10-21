import Foundation
import Testing
@testable import TmuxPad

final class KeychainTests {
    let keychain = Keychain.test("keychain")

    deinit {
        keychain.removeAll()
    }

    @Test func missingAccountReadsNil() throws {
        #expect(try keychain.read(account: "nope") == nil)
    }

    @Test func writeOverwriteReadDelete() throws {
        try keychain.write(Data("one".utf8), account: "a")
        #expect(try keychain.read(account: "a") == Data("one".utf8))
        try keychain.write(Data("two".utf8), account: "a")
        #expect(try keychain.read(account: "a") == Data("two".utf8))
        try keychain.delete(account: "a")
        #expect(try keychain.read(account: "a") == nil)
        try keychain.delete(account: "a")
    }

    @Test func accountsListsOnlyThisService() throws {
        let other = Keychain.test("keychain-other")
        defer { other.removeAll() }
        try keychain.write(Data("1".utf8), account: "b")
        try keychain.write(Data("2".utf8), account: "a")
        try other.write(Data("3".utf8), account: "c")
        #expect(try keychain.accounts() == ["a", "b"])
        #expect(try other.accounts() == ["c"])
    }
}
