import Foundation

/// Host-скрипт из ресурсов пакета — копия `host/tmuxpad-host.sh`.
public enum HostScript {
    public enum ScriptError: Error, Equatable, Sendable {
        case resourceMissing
        case versionMissing
    }

    /// Байты скрипта для установки через stdin.
    public static var data: Data {
        get throws {
            guard let url = Bundle.module.url(forResource: "tmuxpad-host", withExtension: "sh") else {
                throw ScriptError.resourceMissing
            }
            return try Data(contentsOf: url)
        }
    }

    /// Версия скрипта в пакете, из строки `VERSION=N`.
    public static var version: Int {
        get throws { try version(of: data) }
    }

    static func version(of script: Data) throws -> Int {
        let text = String(decoding: script, as: UTF8.self)
        for line in text.split(separator: "\n") where line.hasPrefix("VERSION=") {
            if let value = Int(line.dropFirst("VERSION=".count)) {
                return value
            }
        }
        throw ScriptError.versionMissing
    }
}
