import Foundation
import Testing
@testable import TmuxPad

final class DeviceIdentityTests {
    let keychain = Keychain.test("device")

    deinit {
        keychain.removeAll()
    }

    @Test func createdOnceThenStable() throws {
        #expect(try keychain.read(account: DeviceIdentity.account) == nil)
        let first = try DeviceIdentity.load(keychain: keychain)
        #expect(try DeviceIdentity.load(keychain: keychain) == first)
        #expect(try keychain.read(account: DeviceIdentity.account) == Data(first.uuidString.utf8))
    }

    @Test func garbageIsAnError() throws {
        try keychain.write(Data("not-a-uuid".utf8), account: DeviceIdentity.account)
        #expect(throws: KeychainError.unexpectedData) { try DeviceIdentity.load(keychain: keychain) }
    }
}
