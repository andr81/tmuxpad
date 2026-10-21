import SwiftUI

/// «Прокрутка ✕» (§3.5): pane, вероятно, в copy-mode; тап выводит из него.
struct ScrollChip: View {
    let cancel: () -> Void

    var body: some View {
        Button(action: cancel) {
            Label {
                Text("Прокрутка")
            } icon: {
                Image(systemName: "xmark")
            }
            .labelStyle(TrailingIconLabelStyle())
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .padding(8)
    }
}

/// Текст, потом значок: «Прокрутка ✕».
private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon
        }
    }
}
