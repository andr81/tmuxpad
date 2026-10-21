import Foundation
import Testing
import TmuxPadCore
@testable import TmuxPad

@MainActor
struct TerminalAppearanceTests {
    let defaults = UserDefaults(suiteName: "dev.tmuxpad.test.\(UUID().uuidString)")!

    /// Открытые терминалы без сети, их шрифт — из общего `TerminalAppearance`.
    private func model(_ appearance: TerminalAppearance) -> OpenSessionsModel {
        let model = OpenSessionsModel()
        let dependencies = OpenTerminal.Dependencies(
            connection: { _ in throw AppError.serverMissing },
            snapshot: { _ in nil },
            log: nil,
            defaults: defaults,
            appearance: appearance
        )
        model.makeTerminal = { OpenTerminal(key: $0, dependencies: dependencies) }
        return model
    }

    private func fontSizes(_ model: OpenSessionsModel) -> [CGFloat] {
        model.terminals.values.map(\.view.font.pointSize)
    }

    @Test func sizeReachesAllOpenTerminalsAndPersists() {
        let appearance = TerminalAppearance(defaults: defaults)
        #expect(appearance.fontSize == TerminalSettings.defaultFontSize)
        let model = model(appearance)
        let server = UUID()
        for name in ["api", "web", "cli"] {
            model.open(OpenSessionKey(serverID: server, name: name))
        }
        appearance.setFontSize(20)
        #expect(fontSizes(model) == [20, 20, 20])
        #expect(defaults.integer(forKey: TerminalSettings.fontSizeKey) == 20)
        // открытый после смены — сразу с новым размером
        model.open(OpenSessionKey(serverID: server, name: "new"))
        #expect(fontSizes(model) == [20, 20, 20, 20])
        #expect(TerminalAppearance(defaults: defaults).fontSize == 20)
    }

    @Test func pinchStepChangesEveryTerminal() throws {
        let appearance = TerminalAppearance(defaults: defaults)
        let model = model(appearance)
        let server = UUID()
        model.open(OpenSessionKey(serverID: server, name: "api"))
        model.open(OpenSessionKey(serverID: server, name: "web"))
        let pinched = try #require(model.selectedTerminal)
        pinched.view.onFontStep?(1)
        pinched.view.onFontStep?(1)
        #expect(appearance.fontSize == TerminalSettings.defaultFontSize + 2)
        #expect(fontSizes(model) == Array(repeating: CGFloat(TerminalSettings.defaultFontSize + 2), count: 2))
        #expect(defaults.integer(forKey: TerminalSettings.fontSizeKey) == TerminalSettings.defaultFontSize + 2)
    }

    @Test func sizeIsClampedToRange() {
        let appearance = TerminalAppearance(defaults: defaults)
        appearance.setFontSize(100)
        #expect(appearance.fontSize == TerminalSettings.fontSizeRange.upperBound)
        appearance.setFontSize(1)
        #expect(appearance.fontSize == TerminalSettings.fontSizeRange.lowerBound)
        #expect(defaults.integer(forKey: TerminalSettings.fontSizeKey) == TerminalSettings.fontSizeRange.lowerBound)
    }
}
