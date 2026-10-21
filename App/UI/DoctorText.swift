import SwiftUI
import TmuxPadCore

/// Заголовок строки `doctor` по её ключу; незнакомый ключ показывается своим именем.
func doctorTitle(_ key: String) -> String {
    switch key {
    case "tmux": "tmux ≥ 3.1"
    case "claude": "claude в login PATH"
    case "claude_name": "claude поддерживает --name"
    case "projects": "Корень проектов"
    case "script": "host-скрипт"
    default: key
    }
}

func bootstrapStatusText(_ status: BootstrapStatus) -> String {
    switch status {
    case .missing: "Не установлен"
    case let .outdated(installed, bundled): "Устарел: версия \(installed), в приложении \(bundled)"
    case let .ready(version): "Установлен, версия \(version)"
    case let .unreachable(message): "Не удалось проверить: \(message)"
    }
}

extension DoctorLine.Level {
    /// ✓ / ⚠ / ✗.
    var symbol: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .fail: "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .ok: .green
        case .warn: .orange
        case .fail: .red
        }
    }
}

/// Чеклист `doctor`: значок и заголовок, под ними сообщение сервера как есть.
struct DoctorReportView: View {
    let report: DoctorReport

    var body: some View {
        ForEach(Array(report.lines.enumerated()), id: \.offset) { _, line in
            Label {
                VStack(alignment: .leading) {
                    Text(doctorTitle(line.key))
                    Text(verbatim: line.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } icon: {
                Image(systemName: line.level.symbol)
                    .foregroundStyle(line.level.color)
            }
        }
    }
}
