import Foundation
import Testing
@testable import TmuxPadCore

@Suite struct ListParserTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func fullList() throws {
        let text = """
        V\t1
        S\tapi\t0\tapi\t1760990000
        S\tweb-2\t2\tweb\t1760990100
        P\tapi\t/home/dev/projects/api
        P\tmy.app\t/home/dev/projects/my.app
        P\tweb\t/home/dev/projects/web

        """
        let snapshot = try ListParser.parse(text, fetchedAt: now)
        #expect(snapshot.fetchedAt == now)
        #expect(snapshot.sessions == [
            RemoteSession(name: "api", project: "api", otherClients: 0,
                          lastActivity: Date(timeIntervalSince1970: 1_760_990_000)),
            RemoteSession(name: "web-2", project: "web", otherClients: 2,
                          lastActivity: Date(timeIntervalSince1970: 1_760_990_100)),
        ])
        #expect(snapshot.projects == [
            RemoteProject(name: "api", path: "/home/dev/projects/api"),
            RemoteProject(name: "my.app", path: "/home/dev/projects/my.app"),
            RemoteProject(name: "web", path: "/home/dev/projects/web"),
        ])
    }

    @Test func emptyList() throws {
        let snapshot = try ListParser.parse("V\t1\n", fetchedAt: now)
        #expect(snapshot.sessions.isEmpty)
        #expect(snapshot.projects.isEmpty)
    }

    @Test func unsupportedVersion() {
        #expect(throws: HostError.badOutput("unsupported list version 2")) {
            try ListParser.parse("V\t2\nS\ta\t0\ta\t1\n", fetchedAt: now)
        }
    }

    @Test func missingHeader() {
        #expect(throws: HostError.badOutput("empty list output")) {
            try ListParser.parse("", fetchedAt: now)
        }
        #expect(throws: HostError.badOutput("missing list header")) {
            try ListParser.parse("P\tapi\t/p\n", fetchedAt: now)
        }
    }

    @Test func unknownPrefixIsIgnored() throws {
        let snapshot = try ListParser.parse("V\t1\nX\tfuture\tfield\nP\tapi\t/p\n", fetchedAt: now)
        #expect(snapshot.projects == [RemoteProject(name: "api", path: "/p")])
    }

    @Test(arguments: [
        "S\tapi\t0\tapi",
        "S\tapi\t0\tapi\t1\textra",
        "S\tapi\tmany\tapi\t1",
        "S\tapi\t0\tapi\tsoon",
    ])
    func badSessionLine(line: String) {
        #expect(throws: HostError.badOutput("bad session line: \(line)")) {
            try ListParser.parse("V\t1\n\(line)\n", fetchedAt: now)
        }
    }

    @Test func badProjectLine() {
        #expect(throws: HostError.badOutput("bad project line: P\tapi")) {
            try ListParser.parse("V\t1\nP\tapi\n", fetchedAt: now)
        }
    }
}
