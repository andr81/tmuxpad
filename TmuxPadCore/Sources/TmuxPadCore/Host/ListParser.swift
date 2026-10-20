import Foundation

/// Разбор вывода `list` версии 1 (§7).
public enum ListParser {
    public static func parse(_ text: String, fetchedAt: Date) throws -> ServerSnapshot {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard let header = lines.first else {
            throw HostError.badOutput("empty list output")
        }
        let headerFields = header.split(separator: "\t", omittingEmptySubsequences: false)
        guard headerFields.count == 2, headerFields[0] == "V" else {
            throw HostError.badOutput("missing list header")
        }
        guard headerFields[1] == "1" else {
            throw HostError.badOutput("unsupported list version \(headerFields[1])")
        }

        var projects: [RemoteProject] = []
        var sessions: [RemoteSession] = []
        for line in lines.dropFirst() {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            switch fields[0] {
            case "S":
                guard fields.count == 5, let others = Int(fields[2]), let activity = Int(fields[4]) else {
                    throw HostError.badOutput("bad session line: \(line)")
                }
                sessions.append(RemoteSession(
                    name: String(fields[1]),
                    project: String(fields[3]),
                    otherClients: others,
                    lastActivity: Date(timeIntervalSince1970: TimeInterval(activity))
                ))
            case "P":
                // путь — всё после второго `\t`
                let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count == 3 else {
                    throw HostError.badOutput("bad project line: \(line)")
                }
                projects.append(RemoteProject(name: String(parts[1]), path: String(parts[2])))
            default:
                // неизвестные префиксы — для будущих версий формата
                continue
            }
        }
        return ServerSnapshot(projects: projects, sessions: sessions, fetchedAt: fetchedAt)
    }
}
