import SwiftUI
import TmuxPadCore

/// Журнал диагностики: новые события сверху, фильтр по серверу, «Поделиться».
struct DiagnosticsView: View {
    @Environment(DiagnosticsModel.self) private var model
    /// `nil` — все серверы.
    @State private var server: String?

    var body: some View {
        let events = model.newestFirst(server: server)
        List {
            ForEach(Array(events.enumerated()), id: \.offset) { _, event in
                DiagnosticsRow(event: event)
            }
        }
        .overlay {
            if events.isEmpty {
                ContentUnavailableView("Журнал пока пуст", systemImage: "list.bullet.rectangle")
            }
        }
        .navigationTitle("Диагностика")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: model.exportText(server: server)) {
                    Label("Поделиться", systemImage: "square.and.arrow.up")
                }
                .disabled(events.isEmpty)
            }
            ToolbarItem(placement: .secondaryAction) {
                Picker("Сервер", selection: $server) {
                    Text("Все").tag(String?.none)
                    ForEach(model.servers, id: \.self) { label in
                        Text(label).tag(String?.some(label))
                    }
                }
            }
        }
    }
}

private struct DiagnosticsRow: View {
    let event: DiagnosticsEvent

    /// `HH:mm:ss` независимо от 12/24-часовой настройки устройства.
    private static let time = Date.VerbatimFormatStyle(
        format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits)",
        timeZone: .current,
        calendar: .current
    )

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: event.kind.symbol)
                .foregroundStyle(event.kind == .error ? .red : .secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(event.date, format: Self.time)
                        .monospacedDigit()
                    Text(event.server)
                    Text(event.kind.rawValue)
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                Text(event.message)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            }
        }
    }
}

private extension DiagnosticsEvent.Kind {
    var symbol: String {
        switch self {
        case .connect: "link"
        case .disconnect: "xmark.circle"
        case .reconnect: "arrow.clockwise"
        case .ping: "dot.radiowaves.left.and.right"
        case .exec: "terminal"
        case .terminal: "rectangle.split.3x1"
        case .hostKey: "key"
        case .error: "exclamationmark.triangle"
        }
    }
}

#Preview {
    NavigationStack {
        DiagnosticsView()
    }
    .appEnvironment(try! AppEnvironment.inMemory())
}
