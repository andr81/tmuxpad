/// Разбор вывода `doctor` и `setup`: TSV `ok|warn|fail<TAB>KEY<TAB>MESSAGE`.
public enum DoctorParser {
    public static func parse(_ text: String) throws -> DoctorReport {
        var lines: [DoctorLine] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            // сообщение может содержать табуляцию — всё после второго `\t`
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let level = DoctorLine.Level(rawValue: String(parts[0])) else {
                throw HostError.badOutput("bad doctor line: \(line)")
            }
            lines.append(DoctorLine(level: level, key: String(parts[1]), message: String(parts[2])))
        }
        return DoctorReport(lines: lines)
    }
}
