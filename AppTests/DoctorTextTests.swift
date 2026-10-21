import Testing
import TmuxPadCore
@testable import TmuxPad

struct DoctorTextTests {
    @Test func knownKeysAreTranslated() {
        #expect(doctorTitle("tmux") == "tmux ≥ 3.1")
        #expect(doctorTitle("claude") == "claude в login PATH")
        #expect(doctorTitle("claude_name") == "claude поддерживает --name")
        #expect(doctorTitle("projects") == "Корень проектов")
        #expect(doctorTitle("script") == "host-скрипт")
    }

    @Test func unknownKeyKeepsItsName() {
        #expect(doctorTitle("locale") == "locale")
    }

    @Test func bootstrapStatusIsRussian() {
        #expect(bootstrapStatusText(.missing) == "Не установлен")
        #expect(bootstrapStatusText(.ready(version: 2)) == "Установлен, версия 2")
        #expect(bootstrapStatusText(.outdated(installed: 1, bundled: 2)) == "Устарел: версия 1, в приложении 2")
    }
}
