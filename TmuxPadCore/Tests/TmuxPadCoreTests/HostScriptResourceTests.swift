import Foundation
import Testing
@testable import TmuxPadCore

@Suite struct HostScriptResourceTests {
    /// Корень репозитория: три уровня вверх от каталога `TmuxPadCore/Tests/TmuxPadCoreTests/`.
    static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    @Test func resourceMatchesHostScript() throws {
        let original = try Data(contentsOf: Self.repositoryRoot.appendingPathComponent("host/tmuxpad-host.sh"))
        #expect(try HostScript.data == original, "copy host/tmuxpad-host.sh to Sources/TmuxPadCore/Resources/")
    }

    @Test func bundledVersion() throws {
        #expect(try HostScript.version == 1)
        #expect(try HostBootstrap().bundledVersion == 1)
    }

    @Test func versionLineIsRequired() {
        #expect(throws: HostScript.ScriptError.versionMissing) {
            try HostScript.version(of: Data("#!/bin/bash\necho VERSION=1\n".utf8))
        }
    }
}
