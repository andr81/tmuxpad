import Testing
@testable import TmuxPadCore

@Suite struct HostErrorTests {
    @Test func exitCodes() {
        let new = HostCommand.new(session: "a", project: "b")
        #expect(HostError.from(command: .list, exitCode: 127, stderr: "") == .scriptMissing)
        #expect(HostError.from(command: .doctor, exitCode: 126, stderr: "") == .scriptMissing)
        #expect(HostError.from(command: .list, exitCode: 2, stderr: "no projects root\n") == .projectsRootMissing)
        #expect(HostError.from(command: new, exitCode: 2, stderr: "invalid project: b\n") == .badRequest("invalid project: b"))
        #expect(HostError.from(command: .auth, exitCode: 2, stderr: "") == .badRequest(""))
        #expect(HostError.from(command: new, exitCode: 3, stderr: "exists") == .sessionExists)
        #expect(HostError.from(command: .attach(session: "a"), exitCode: 4, stderr: "") == .noSession)
        #expect(HostError.from(command: .take(session: "a"), exitCode: 4, stderr: "") == .noSession)
        #expect(HostError.from(command: new, exitCode: 1, stderr: " tmux failed \n") == .failed(code: 1, stderr: "tmux failed"))
        #expect(HostError.from(command: .doctor, exitCode: 1, stderr: "") == .failed(code: 1, stderr: ""))
        #expect(HostError.from(command: .list, exitCode: 255, stderr: "x") == .failed(code: 255, stderr: "x"))
    }

    @Test func descriptionsAreHumanReadable() {
        #expect(HostError.sessionExists.description == "A session with this name already exists.")
        #expect(HostError.failed(code: 1, stderr: "boom").description == "The command failed with exit code 1: boom")
        #expect(SSHError.hostKeyChanged(expected: "SHA256:a", actual: "SHA256:b").description
            == "The server host key has changed (expected SHA256:a, got SHA256:b).")
        #expect(SSHError.channelRefused.description == "The server refused to open another channel.")
    }
}
