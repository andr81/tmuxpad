import Foundation

/// Валидация имён и значений до подстановки в exec-строку (§8). Правила те же, что в host-скрипте.
public enum Validation {
    public static func isValidSessionName(_ name: String) -> Bool {
        name.wholeMatch(of: /[A-Za-z0-9_-]{1,64}/) != nil
    }

    public static func isValidProjectName(_ name: String) -> Bool {
        name.wholeMatch(of: /[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}/) != nil
    }

    /// Значение можно положить в одинарные кавычки: не пусто, без `'`, без управляющих символов.
    public static func isSafeShellValue(_ value: String) -> Bool {
        !value.isEmpty && !value.unicodeScalars.contains { scalar in
            scalar == "'" || scalar.properties.generalCategory == .control
        }
    }
}

extension ServerConfig {
    /// Пустой массив — конфиг годен.
    public func validationIssues() -> [String] {
        var issues: [String] = []
        if host.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append("host is empty")
        }
        if !(1...65535).contains(port) {
            issues.append("port must be 1...65535")
        }
        if user.isEmpty || user.contains(where: \.isWhitespace) {
            issues.append("user must be non-empty without spaces")
        }
        if !Validation.isSafeShellValue(projectsRoot) {
            issues.append("projects root must be non-empty without quotes or control characters")
        }
        if !Validation.isSafeShellValue(startCommand) {
            issues.append("start command must be non-empty without quotes or control characters")
        }
        if !(5...300).contains(keepaliveSeconds) {
            issues.append("keepalive must be 5...300 seconds")
        }
        return issues
    }
}
