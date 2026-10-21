import Foundation
@testable import TmuxPad

extension Keychain {
    /// Свой сервис на каждый экземпляр suite: `dev.tmuxpad.test.<suite>.<UUID>`.
    static func test(_ suite: String) -> Keychain {
        Keychain(service: "dev.tmuxpad.test.\(suite).\(UUID().uuidString)")
    }

    func removeAll() {
        for account in (try? accounts()) ?? [] {
            try? delete(account: account)
        }
    }
}

func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
}
