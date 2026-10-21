import SwiftUI

/// Раздел «Терминал» (§3.6): всё меняется сразу во всех открытых терминалах.
struct TerminalSettingsView: View {
    @Environment(TerminalAppearance.self) private var appearance

    var body: some View {
        @Bindable var appearance = appearance
        Form {
            Section("Шрифт") {
                Picker("Шрифт", selection: $appearance.font) {
                    ForEach(TerminalFont.allCases) { font in
                        Text(font.title).tag(font)
                    }
                }
                Stepper(
                    value: Binding(get: { appearance.fontSize }, set: { appearance.setFontSize($0) }),
                    in: TerminalSettings.fontSizeRange
                ) {
                    LabeledContent("Размер", value: "\(appearance.fontSize) pt")
                }
            }
            Section {
                Picker("Тема", selection: $appearance.theme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
            } footer: {
                Text("Тема приложения и терминала.")
            }
            Section {
                Toggle("Option как Meta", isOn: $appearance.optionAsMeta)
                Picker("Звонок", selection: $appearance.bell) {
                    Text("Звук").tag(true)
                    Text("Выключен").tag(false)
                }
            } footer: {
                Text("Option на аппаратной клавиатуре отправляет Esc-префикс, как Alt в терминале.")
            }
        }
        .navigationTitle("Терминал")
    }
}

#Preview {
    NavigationStack { TerminalSettingsView() }.appEnvironment(try! AppEnvironment.inMemory())
}
