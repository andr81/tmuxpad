import Foundation
import Testing
import TmuxPadCore
@testable import TmuxPad

struct ErrorTextTests {
    static let errors: [any Error] = [
        SSHError.connectFailed("refused"), SSHError.authFailed,
        SSHError.hostKeyChanged(expected: "SHA256:a", actual: "SHA256:b"),
        SSHError.channelRefused, SSHError.timeout, SSHError.disconnected,
        HostError.scriptMissing, HostError.badRequest("bad name"), HostError.badRequest(""),
        HostError.sessionExists, HostError.noSession, HostError.projectsRootMissing,
        HostError.failed(code: 1, stderr: "boom"), HostError.failed(code: 1, stderr: ""),
        HostError.badOutput("V 9"),
        KeyError.invalidKey("x"),
        KeyStoreError.secureEnclaveUnavailable, KeyStoreError.unsupportedKind, KeyStoreError.notFound,
        KeyLibraryError.inUse(["prod"]), AppError.keyMissing(UUID()), AppError.serverMissing,
        AppError.hostKeyUnconfirmed, AppError.projectNotFound("api"), AppError.projectUnknown,
        AppError.biometricsDenied,
        KeychainError.status(-25308), KeychainError.unexpectedData,
    ]

    @Test(arguments: errors.indices)
    func everyErrorHasRussianText(_ index: Int) {
        let text = userText(Self.errors[index])
        #expect(text.contains { ("а"..."я").contains($0) || ("А"..."Я").contains($0) }, "\(text)")
    }

    @Test func detailsAreKept() {
        #expect(userText(SSHError.connectFailed("refused")) == "Не удалось подключиться: refused")
        #expect(userText(HostError.failed(code: 7, stderr: "boom")) == "Команда завершилась с кодом 7: boom")
        #expect(userText(KeyLibraryError.inUse(["prod", "dev"])) == "Ключ используется: prod, dev")
        #expect(userText(AppError.projectNotFound("api")) == "Проект api не найден на сервере")
    }

    @Test func unknownErrorIsDescribed() {
        struct Custom: Error, CustomStringConvertible {
            var description: String { "custom" }
        }
        #expect(userText(Custom()) == "custom")
    }

    @Test func everyCoreIssueIsTranslated() {
        var config = ServerConfig(label: "a", host: "", port: 0, user: "", keyID: UUID())
        config.projectsRoot = ""
        config.startCommand = ""
        config.keepaliveSeconds = 0
        let issues = config.validationIssues()
        #expect(issues.count == 6)
        for issue in issues {
            #expect(serverIssueText(issue) != issue)
        }
    }
}
