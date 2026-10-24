import Foundation
import SwiftTerm
import Testing
import TmuxPadCore
import UIKit
@testable import TmuxPad

@MainActor
struct TerminalSettingsTests {
    let defaults = UserDefaults(suiteName: "dev.tmuxpad.test.\(UUID().uuidString)")!

    /// Открытые терминалы без сети с общим `TerminalAppearance`.
    private func open(_ appearance: TerminalAppearance, _ names: [String] = ["api", "web"]) -> [TmuxTerminalView] {
        let model = OpenSessionsModel()
        let dependencies = OpenTerminal.Dependencies(
            connection: { _ in throw AppError.serverMissing },
            snapshot: { _ in nil },
            log: nil,
            appearance: appearance
        )
        model.makeTerminal = { OpenTerminal(key: $0, dependencies: dependencies) }
        let server = UUID()
        for name in names {
            model.open(OpenSessionKey(serverID: server, name: name))
        }
        return model.terminals.values.map(\.view)
    }

    @Test func defaultsWhenUnset() {
        #expect(TerminalSettings.style(defaults) == .standard)
        #expect(TerminalSettings.fontSize(defaults) == TerminalSettings.defaultFontSize)
        #expect(TerminalSettings.optionAsMeta(defaults))
        #expect(TerminalSettings.bellEnabled(defaults))
        #expect(TerminalSettings.keyBar(defaults) == .full)
    }

    @Test(arguments: [(100, 32), (1, 9), (20, 20)])
    func storedFontSizeIsClamped(_ stored: Int, _ expected: Int) {
        defaults.set(stored, forKey: TerminalSettings.fontSizeKey)
        #expect(TerminalSettings.fontSize(defaults) == expected)
    }

    @Test func unknownStoredValuesFallBack() {
        defaults.set("Comic Sans", forKey: TerminalSettings.fontNameKey)
        defaults.set("sepia", forKey: TerminalSettings.themeKey)
        #expect(TerminalSettings.fontName(defaults) == .system)
        #expect(TerminalSettings.theme(defaults) == .system)
    }

    @Test func bellOff() {
        defaults.set("off", forKey: TerminalSettings.bellKey)
        #expect(!TerminalSettings.bellEnabled(defaults))
    }

    @Test func storedStyleReachesNewTerminal() throws {
        defaults.set("Menlo", forKey: TerminalSettings.fontNameKey)
        defaults.set(18, forKey: TerminalSettings.fontSizeKey)
        defaults.set("dark", forKey: TerminalSettings.themeKey)
        defaults.set(false, forKey: TerminalSettings.optionAsMetaKey)
        defaults.set("off", forKey: TerminalSettings.bellKey)
        defaults.set("compact", forKey: TerminalSettings.keyBarKey)
        let view = try #require(open(TerminalAppearance(defaults: defaults), ["api"]).first)
        #expect(view.font.fontName == "Menlo-Regular")
        #expect(view.font.pointSize == 18)
        #expect(view.palette == .dark)
        #expect(!view.optionAsMetaKey)
        #expect(view.bellStyle == .none)
        #expect(view.inputAccessoryView is CompactKeyBar)
    }

    @Test func fontReachesOpenTerminals() {
        let appearance = TerminalAppearance(defaults: defaults)
        let views = open(appearance)
        appearance.font = .menlo
        #expect(views.map(\.font.fontName) == ["Menlo-Regular", "Menlo-Regular"])
        appearance.font = .courierNew
        #expect(views.map(\.font.fontName) == ["CourierNewPSMT", "CourierNewPSMT"])
        #expect(views.allSatisfy { $0.font.pointSize == CGFloat(TerminalSettings.defaultFontSize) })
        #expect(defaults.string(forKey: TerminalSettings.fontNameKey) == "Courier New")
    }

    @Test func sizeReachesOpenTerminals() {
        let appearance = TerminalAppearance(defaults: defaults)
        appearance.font = .menlo
        let views = open(appearance)
        appearance.setFontSize(22)
        #expect(views.map(\.font.pointSize) == [22, 22])
        #expect(views.map(\.font.fontName) == ["Menlo-Regular", "Menlo-Regular"])
    }

    @Test func themeReachesOpenTerminals() {
        let appearance = TerminalAppearance(defaults: defaults)
        let views = open(appearance)
        appearance.theme = .dark
        #expect(views.map(\.palette) == [.dark, .dark])
        #expect(views.allSatisfy { $0.overrideUserInterfaceStyle == .dark })
        #expect(views.allSatisfy { $0.nativeBackgroundColor == TerminalPalette.dark.background })
        appearance.theme = .light
        #expect(views.map(\.palette) == [.light, .light])
        #expect(views.allSatisfy { $0.nativeForegroundColor == TerminalPalette.light.foreground })
        appearance.theme = .system
        #expect(views.allSatisfy { $0.overrideUserInterfaceStyle == .unspecified })
        #expect(defaults.string(forKey: TerminalSettings.themeKey) == "system")
        #expect(AppTheme.dark.colorScheme == .dark)
        #expect(AppTheme.system.colorScheme == nil)
    }

    @Test func optionAsMetaReachesOpenTerminals() {
        let appearance = TerminalAppearance(defaults: defaults)
        let views = open(appearance)
        #expect(views.allSatisfy { $0.optionAsMetaKey })
        appearance.optionAsMeta = false
        #expect(views.allSatisfy { !$0.optionAsMetaKey })
        #expect(!TerminalSettings.optionAsMeta(defaults))
    }

    @Test func bellReachesOpenTerminals() {
        let appearance = TerminalAppearance(defaults: defaults)
        let views = open(appearance)
        #expect(views.allSatisfy { $0.bellStyle == .sound })
        appearance.bell = false
        #expect(views.allSatisfy { $0.bellStyle == .none })
        #expect(defaults.string(forKey: TerminalSettings.bellKey) == "off")
        appearance.bell = true
        #expect(views.allSatisfy { $0.bellStyle == .sound })
    }

    @Test func keyBarReachesOpenTerminals() {
        let appearance = TerminalAppearance(defaults: defaults)
        let views = open(appearance)
        #expect(views.allSatisfy { $0.inputAccessoryView is TerminalAccessory })
        appearance.keyBar = .compact
        #expect(views.allSatisfy { $0.inputAccessoryView is CompactKeyBar })
        #expect(defaults.string(forKey: TerminalSettings.keyBarKey) == "compact")
        appearance.keyBar = .hidden
        #expect(views.allSatisfy { $0.inputAccessoryView == nil })
        appearance.keyBar = .full
        #expect(views.allSatisfy { $0.inputAccessoryView is TerminalAccessory })
    }

    @Test func sameKeyBarKeepsAccessoryAndControl() throws {
        let appearance = TerminalAppearance(defaults: defaults)
        let view = try #require(open(appearance, ["api"]).first)
        appearance.keyBar = .compact
        let bar = view.inputAccessoryView
        view.controlModifier = true
        appearance.bell = false
        #expect(view.inputAccessoryView === bar)
        #expect(view.controlModifier)
    }

    @Test func applyKeepsViewInstanceAndSkipsSameFont() {
        let appearance = TerminalAppearance(defaults: defaults)
        let view = TmuxTerminalView()
        appearance.attach(view)
        let font = view.font
        appearance.bell = false
        #expect(view.font === font)
        appearance.theme = .dark
        #expect(view.font === font)
    }
}
