import Foundation

struct TimeoutError: Error, CustomStringConvertible {
    var duration: Duration
    var description: String { "timed out after \(duration)" }
}

/// Тело или `TimeoutError` через `duration` — чтобы зависший канал не вешал прогон.
func withTimeout<T: Sendable>(_ duration: Duration, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw TimeoutError(duration: duration)
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
