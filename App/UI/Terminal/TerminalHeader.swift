import SwiftUI
import TmuxPadCore

/// «server › project › session» над терминалом.
struct TerminalHeader: View {
    let key: OpenSessionKey
    let project: String?

    @Environment(ServerStore.self) private var servers

    var body: some View {
        HStack {
            Text(verbatim: [servers.server(id: key.serverID)?.label, project, key.name]
                .compactMap { $0 }
                .joined(separator: " › "))
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
