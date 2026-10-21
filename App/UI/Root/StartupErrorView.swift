import SwiftUI

/// Окружение не собралось (Keychain, битый `servers.json`): работать дальше нельзя.
struct StartupErrorView: View {
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("TmuxPad не запустился", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        }
    }
}

#Preview {
    StartupErrorView(message: "Ошибка Keychain (код -25308)")
}
