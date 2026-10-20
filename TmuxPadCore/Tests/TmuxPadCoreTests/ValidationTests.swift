import Foundation
import Testing
@testable import TmuxPadCore

@Suite struct ValidationTests {
    @Test(arguments: [
        ("a", true),
        (String(repeating: "a", count: 64), true),
        (String(repeating: "a", count: 65), false),
        ("api_2-x", true),
        ("", false),
        ("a b", false),
        ("my.app", false),
        ("-dash", true),
        ("имя", false),
        ("a'b", false),
    ])
    func sessionNames(name: String, valid: Bool) {
        #expect(Validation.isValidSessionName(name) == valid)
    }

    @Test(arguments: [
        ("a", true),
        ("my.app", true),
        (".hidden", false),
        ("a b", false),
        ("", false),
        ("_x.y-z", true),
        (String(repeating: "p", count: 128), true),
        (String(repeating: "p", count: 129), false),
        ("a/b", false),
    ])
    func projectNames(name: String, valid: Bool) {
        #expect(Validation.isValidProjectName(name) == valid)
    }

    @Test(arguments: [
        ("claude", true),
        ("sleep 1000", true),
        ("~/projects", true),
        ("", false),
        ("it's", false),
        ("a\nb", false),
        ("a\tb", false),
    ])
    func shellValues(value: String, safe: Bool) {
        #expect(Validation.isSafeShellValue(value) == safe)
    }

    @Test(arguments: [
        ("my.project", "my-project"),
        ("a  b", "a-b"),
        ("...", "session"),
        ("Проект", "session"),
        ("", "session"),
        ("api_2", "api_2"),
        ("-a.-.b-", "a-b"),
        ("Мой app.v2", "app-v2"),
        (String(repeating: "x", count: 200), String(repeating: "x", count: 64)),
        (String(repeating: "x", count: 63) + ".y", String(repeating: "x", count: 63)),
    ])
    func suggestedSessionNames(project: String, expected: String) {
        #expect(Validation.suggestedSessionName(from: project) == expected)
    }

    @Test(arguments: [
        "my.project", "a  b", "...", "Проект", "", "-", "_", ".hidden", "a\tb\nc", "x'y\"z",
        "a/b/c", "1.2.3", "🙂 emoji", String(repeating: "ab.", count: 50), "-" + String(repeating: "a", count: 70),
    ])
    func suggestedSessionNameIsAlwaysValid(project: String) {
        #expect(Validation.isValidSessionName(Validation.suggestedSessionName(from: project)))
    }

    @Test func validConfigHasNoIssues() {
        let config = ServerConfig(label: "dev", host: "example.com", user: "dev", keyID: UUID())
        #expect(config.validationIssues().isEmpty)
    }

    @Test func invalidConfigReportsEveryIssue() {
        let config = ServerConfig(
            label: "dev", host: " ", port: 0, user: "a b", keyID: UUID(),
            projectsRoot: "it's", startCommand: "", keepaliveSeconds: 4
        )
        #expect(config.validationIssues().count == 6)
    }
}
