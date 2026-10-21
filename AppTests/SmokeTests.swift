import Testing
import TmuxPadCore

@Test func appEnvironmentBuilds() throws {
    // The package resource must be reachable from the app bundle.
    #expect(try HostScript.version >= 1)
}
