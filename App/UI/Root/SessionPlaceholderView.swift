import SwiftUI
import TmuxPadCore

/// Деталь до терминала (план 6): путь к выделенной сессии и её состояние.
struct SessionPlaceholderView: View {
    let key: OpenSessionKey

    @Environment(ServerStore.self) private var servers
    @Environment(TreeModel.self) private var tree

    var body: some View {
        let session = tree.states[key.serverID]?.snapshot?.sessions.first { $0.name == key.name }
        ContentUnavailableView {
            Label {
                Text(verbatim: [servers.server(id: key.serverID)?.label, session?.project, key.name]
                    .compactMap { $0 }
                    .joined(separator: " › "))
            } icon: {
                Image(systemName: "terminal")
            }
        } description: {
            VStack {
                if let session {
                    Text(session.otherClients > 0 ? "Подключены другие клиенты" : "Других клиентов нет")
                } else {
                    Text("Сессии нет в последнем снимке")
                }
                Text("Терминал появится в плане 6")
            }
        }
    }
}
