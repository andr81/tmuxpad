import SwiftUI

struct RootView: View {
    var body: some View {
        NavigationSplitView {
            List {}
                .navigationTitle("Серверы")
        } detail: {
            Text("Выберите сессию")
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    RootView()
}
