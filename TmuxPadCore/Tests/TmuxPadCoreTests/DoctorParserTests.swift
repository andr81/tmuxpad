import Testing
@testable import TmuxPadCore

@Suite struct DoctorParserTests {
    @Test func allOk() throws {
        let text = """
        ok\ttmux\ttmux 3.4
        ok\tclaude\t/usr/local/bin/claude
        ok\tclaude_name\tclaude supports --name
        ok\tprojects\t3 projects in /home/dev/projects
        ok\tscript\ttmuxpad-host 1

        """
        let report = try DoctorParser.parse(text)
        #expect(report.lines.map(\.key) == ["tmux", "claude", "claude_name", "projects", "script"])
        #expect(report.lines.allSatisfy { $0.level == .ok })
        #expect(report.lines[3].message == "3 projects in /home/dev/projects")
        #expect(report.ok)
    }

    @Test func warnIsStillOk() throws {
        let report = try DoctorParser.parse("ok\ttmux\ttmux 3.4\nwarn\tclaude_name\tno --name\n")
        #expect(report.lines[1] == DoctorLine(level: .warn, key: "claude_name", message: "no --name"))
        #expect(report.ok)
    }

    @Test func failIsNotOk() throws {
        let report = try DoctorParser.parse("ok\ttmux\ttmux 3.4\nfail\tprojects\t/home/dev/nope does not exist\n")
        #expect(!report.ok)
    }

    @Test func messageKeepsTabs() throws {
        let report = try DoctorParser.parse("ok\tclaude\ta\tb\tc\n")
        #expect(report.lines == [DoctorLine(level: .ok, key: "claude", message: "a\tb\tc")])
    }

    @Test func emptyMessage() throws {
        #expect(try DoctorParser.parse("ok\tkey\t\n").lines == [DoctorLine(level: .ok, key: "key", message: "")])
    }

    @Test(arguments: ["bad\ttmux\tx", "ok\ttmux"])
    func badLine(line: String) {
        #expect(throws: HostError.badOutput("bad doctor line: \(line)")) {
            try DoctorParser.parse(line + "\n")
        }
    }
}
