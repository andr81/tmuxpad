import Foundation

/// Codable-значение в JSON-файле. Без секретов, поэтому файл попадает в бэкап: потеря списка
/// серверов при переносе на новый iPad хуже.
struct JSONFileStore<Value: Codable>: Sendable {
    let url: URL

    /// `directory` по умолчанию — Application Support/TmuxPad.
    init(fileName: String, directory: URL? = nil) {
        let base = directory ?? URL.applicationSupportDirectory.appending(path: "TmuxPad", directoryHint: .isDirectory)
        url = base.appending(path: fileName, directoryHint: .notDirectory)
    }

    /// `nil`, если файла нет; битый JSON — ошибка, файл не трогается.
    func load() throws -> Value? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
        return try JSONDecoder().decode(Value.self, from: data)
    }

    func save(_ value: Value) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
