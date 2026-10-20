import Foundation

/// Состояние host-скрипта на сервере относительно версии в пакете.
public enum BootstrapStatus: Sendable, Equatable {
    case missing
    case outdated(installed: Int, bundled: Int)
    case ready(version: Int)
    /// Проверить не удалось: сеть, неожиданный вывод.
    case unreachable(String)
}

/// Установка и обновление host-скрипта через stdin (§7).
public struct HostBootstrap: Sendable {
    public let script: Data
    public let bundledVersion: Int

    /// Скрипт из ресурсов пакета.
    public init() throws {
        try self.init(script: HostScript.data)
    }

    public init(script: Data) throws {
        self.script = script
        self.bundledVersion = try HostScript.version(of: script)
    }

    public func status(api: HostAPI) async -> BootstrapStatus {
        do {
            let installed = try await api.version()
            return installed < bundledVersion ? .outdated(installed: installed, bundled: bundledVersion) : .ready(version: installed)
        } catch HostError.scriptMissing {
            return .missing
        } catch {
            return .unreachable("\(error)")
        }
    }

    /// Пишет скрипт в `~/.local/bin/tmuxpad-host.sh` и проверяет версию после.
    public func install(api: HostAPI) async throws {
        try await api.run(.install, stdin: script)
        let installed = try await api.version()
        guard installed == bundledVersion else {
            throw HostError.badOutput("installed version \(installed), expected \(bundledVersion)")
        }
    }

    /// Ставит скрипт, если его нет или он старее, затем `setup`.
    public func prepare(api: HostAPI) async throws -> DoctorReport {
        // не через `status`: ошибка сети должна выйти как есть
        let installed: Int?
        do {
            installed = try await api.version()
        } catch HostError.scriptMissing {
            installed = nil
        }
        if (installed ?? 0) < bundledVersion {
            try await install(api: api)
        }
        return try await api.setup()
    }
}
