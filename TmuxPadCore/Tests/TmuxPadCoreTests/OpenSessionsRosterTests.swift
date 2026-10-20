import Foundation
import Testing
@testable import TmuxPadCore

@Suite struct OpenSessionsRosterTests {
    private let server = UUID()
    private let other = UUID()

    private func key(_ name: String, _ serverID: UUID? = nil) -> OpenSessionKey {
        OpenSessionKey(serverID: serverID ?? server, name: name)
    }

    @Test func ninthOpenEvictsLeastRecentlyActive() {
        var roster = OpenSessionsRoster()
        for index in 1...8 {
            #expect(roster.open(key("s\(index)")).isEmpty)
        }
        roster.activate(key("s1"))
        #expect(roster.open(key("s9")) == [key("s2")])
        #expect(roster.tabs.map(\.name) == ["s1", "s3", "s4", "s5", "s6", "s7", "s8", "s9"])
        #expect(roster.active == key("s9"))
    }

    @Test func reopeningActivatesWithoutEviction() {
        var roster = OpenSessionsRoster(limit: 2)
        _ = roster.open(key("a"))
        _ = roster.open(key("b"))
        #expect(roster.open(key("a")).isEmpty)
        #expect(roster.tabs == [key("a"), key("b")])
        #expect(roster.active == key("a"))
        #expect(roster.open(key("c")) == [key("b")])
    }

    @Test func justOpenedIsNeverEvicted() {
        var roster = OpenSessionsRoster(limit: 1)
        _ = roster.open(key("a"))
        #expect(roster.open(key("b")) == [key("a")])
        #expect(roster.tabs == [key("b")])
    }

    @Test func activateUnknownKeyIsIgnored() {
        var roster = OpenSessionsRoster()
        _ = roster.open(key("a"))
        roster.activate(key("nope"))
        #expect(roster.tabs == [key("a")])
        #expect(roster.active == key("a"))
    }

    @Test func closeRemovesTabAndRecency() {
        var roster = OpenSessionsRoster(limit: 2)
        _ = roster.open(key("a"))
        _ = roster.open(key("b"))
        roster.close(key("b"))
        #expect(roster.tabs == [key("a")])
        #expect(roster.active == key("a"))
        #expect(roster.open(key("c")).isEmpty)
    }

    @Test func closeServerRemovesAllItsTabs() {
        var roster = OpenSessionsRoster()
        _ = roster.open(key("a"))
        _ = roster.open(key("x", other))
        _ = roster.open(key("b"))
        roster.close(serverID: server)
        #expect(roster.tabs == [key("x", other)])
        #expect(roster.active == key("x", other))
    }

    @Test func tabAtIsOneBased() {
        var roster = OpenSessionsRoster()
        _ = roster.open(key("a"))
        _ = roster.open(key("b"))
        #expect(roster.tab(at: 1) == key("a"))
        #expect(roster.tab(at: 2) == key("b"))
        #expect(roster.tab(at: 0) == nil)
        #expect(roster.tab(at: 3) == nil)
    }

    @Test func nextAndPreviousWrapAround() {
        var roster = OpenSessionsRoster()
        #expect(roster.next(after: key("a")) == nil)
        #expect(roster.previous(before: key("a")) == nil)
        for name in ["a", "b", "c"] {
            _ = roster.open(key(name))
        }
        #expect(roster.next(after: key("a")) == key("b"))
        #expect(roster.next(after: key("c")) == key("a"))
        #expect(roster.previous(before: key("a")) == key("c"))
        #expect(roster.previous(before: key("b")) == key("a"))
        #expect(roster.next(after: key("nope")) == key("a"))
        #expect(roster.previous(before: key("nope")) == key("c"))
    }

    @Test func codableKeepsTabsAndEvictionOrderWithoutLimit() throws {
        var roster = OpenSessionsRoster(limit: 3)
        for name in ["a", "b", "c"] {
            _ = roster.open(key(name))
        }
        roster.activate(key("a"))
        let data = try JSONEncoder().encode(roster)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys) == ["tabs", "recency"])

        var decoded = try JSONDecoder().decode(OpenSessionsRoster.self, from: data)
        #expect(decoded.limit == OpenSessionsRoster.defaultLimit)
        #expect(decoded.tabs == roster.tabs)
        #expect(decoded.active == key("a"))
        for index in 1...5 {
            _ = decoded.open(key("n\(index)"))
        }
        #expect(decoded.open(key("n6")) == [key("b")])
        #expect(decoded.open(key("n7")) == [key("c")])
        #expect(decoded.open(key("n8")) == [key("a")])
    }

    @Test func roundTripIsEqual() throws {
        var roster = OpenSessionsRoster()
        _ = roster.open(key("a"))
        _ = roster.open(key("b"))
        roster.activate(key("a"))
        let decoded = try JSONDecoder().decode(OpenSessionsRoster.self, from: JSONEncoder().encode(roster))
        #expect(decoded == roster)
    }

    @Test func decodingDropsForeignRecencyAndDuplicateTabs() throws {
        let a = key("a"), b = key("b"), ghost = key("ghost")
        struct Stored: Encodable {
            var tabs: [OpenSessionKey]
            var recency: [OpenSessionKey]
        }
        let data = try JSONEncoder().encode(Stored(tabs: [a, b, a], recency: [ghost, b, a, ghost]))
        var decoded = try JSONDecoder().decode(OpenSessionsRoster.self, from: data)
        #expect(decoded.tabs == [a, b])
        let reencoded = try JSONDecoder().decode([String: [OpenSessionKey]].self, from: JSONEncoder().encode(decoded))
        #expect(reencoded["recency"] == [b, a])
        decoded.close(a)
        decoded.close(b)
        #expect(decoded.active == nil)
    }

    @Test func decodingTabsWithoutRecencyTreatsThemAsOldest() throws {
        let a = key("a"), b = key("b")
        struct Stored: Encodable {
            var tabs: [OpenSessionKey]
            var recency: [OpenSessionKey]
        }
        let data = try JSONEncoder().encode(Stored(tabs: [a, b], recency: [a]))
        let decoded = try JSONDecoder().decode(OpenSessionsRoster.self, from: data)
        #expect(decoded.active == a)
        let reencoded = try JSONDecoder().decode([String: [OpenSessionKey]].self, from: JSONEncoder().encode(decoded))
        #expect(reencoded["recency"] == [b, a])
    }

    @Test func decodingTrimsTabsOverDefaultLimit() throws {
        let keys = (1...10).map { key("s\($0)") }
        struct Stored: Encodable {
            var tabs: [OpenSessionKey]
            var recency: [OpenSessionKey]
        }
        let data = try JSONEncoder().encode(Stored(tabs: keys, recency: keys.reversed()))
        let decoded = try JSONDecoder().decode(OpenSessionsRoster.self, from: data)
        #expect(decoded.tabs == Array(keys.prefix(8)))
    }
}
