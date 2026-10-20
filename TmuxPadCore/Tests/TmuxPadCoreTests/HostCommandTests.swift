import Foundation
import Testing
@testable import TmuxPadCore

@Suite struct HostCommandTests {
    let env = HostEnvironment(
        client: UUID(uuidString: "0F8E4C2A-1B3D-4E5F-9A7B-6C5D4E3F2A10")!,
        projectsRoot: "projects",
        startCommand: "claude"
    )

    @Test func list() throws {
        #expect(try HostCommand.list.render(env: env) ==
            #"env TMUXPAD_CLIENT='0f8e4c2a-1b3d-4e5f-9a7b-6c5d4e3f2a10' TMUXPAD_PROJECTS='projects' TMUXPAD_CMD='claude' "$HOME"/.local/bin/tmuxpad-host.sh list"#)
    }

    @Test func new() throws {
        #expect(try HostCommand.new(session: "api", project: "my.app").render(env: env) ==
            #"env TMUXPAD_CLIENT='0f8e4c2a-1b3d-4e5f-9a7b-6c5d4e3f2a10' TMUXPAD_PROJECTS='projects' TMUXPAD_CMD='claude' "$HOME"/.local/bin/tmuxpad-host.sh new 'api' 'my.app'"#)
    }

    @Test func sessionCommands() throws {
        let tail = { (command: HostCommand) throws -> String in
            try command.render(env: env).components(separatedBy: "tmuxpad-host.sh ").last!
        }
        #expect(try tail(.attach(session: "s")) == "attach 's'")
        #expect(try tail(.take(session: "s")) == "take 's'")
        #expect(try tail(.copyCancel(session: "s")) == "copy-cancel 's'")
        #expect(try tail(.kill(session: "s")) == "kill 's'")
        #expect(try tail(.version) == "version")
        #expect(try tail(.setup) == "setup")
        #expect(try tail(.doctor) == "doctor")
        #expect(try tail(.auth) == "auth")
    }

    @Test func spacesInStartCommandStayQuoted() throws {
        var env = env
        env.startCommand = "sleep 1000"
        #expect(try HostCommand.doctor.render(env: env).contains("TMUXPAD_CMD='sleep 1000' "))
    }

    @Test func quoteInStartCommandIsRejected() {
        var env = env
        env.startCommand = "claude --x 'y'"
        #expect(!Validation.isSafeShellValue(env.startCommand))
        #expect(throws: HostError.badRequest("invalid start command")) {
            try HostCommand.list.render(env: env)
        }
    }

    @Test func badProjectsRootIsRejected() {
        var env = env
        env.projectsRoot = "a\nb"
        #expect(throws: HostError.badRequest("invalid projects root")) {
            try HostCommand.list.render(env: env)
        }
    }

    @Test func invalidNamesAreRejected() {
        #expect(throws: HostError.badRequest("invalid session name: a b")) {
            try HostCommand.attach(session: "a b").render(env: env)
        }
        #expect(throws: HostError.badRequest("invalid session name: my.app")) {
            try HostCommand.new(session: "my.app", project: "api").render(env: env)
        }
        #expect(throws: HostError.badRequest("invalid project name: .hidden")) {
            try HostCommand.new(session: "api", project: ".hidden").render(env: env)
        }
        #expect(throws: HostError.badRequest("invalid session name: x'; rm -rf ~; '")) {
            try HostCommand.kill(session: "x'; rm -rf ~; '").render(env: env)
        }
    }

    @Test func installHasNoEnvPrefix() throws {
        #expect(try HostCommand.install.render(env: env) ==
            "mkdir -p ~/.local/bin && cat > ~/.local/bin/tmuxpad-host.sh && chmod +x ~/.local/bin/tmuxpad-host.sh")
    }

    @Test func shellQuote() {
        #expect(HostCommand.shellQuote("a") == "'a'")
        #expect(HostCommand.shellQuote("it's") == #"'it'\''s'"#)
        #expect(HostCommand.shellQuote("") == "''")
    }
}
