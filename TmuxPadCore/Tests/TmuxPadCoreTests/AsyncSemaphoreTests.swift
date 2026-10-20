import Foundation
import Testing
@testable import TmuxPadCore

/// Счётчик одновременных владельцев слота.
private actor Occupancy {
    private(set) var current = 0
    private(set) var peak = 0
    private(set) var order: [Int] = []

    func enter(_ id: Int) {
        current += 1
        peak = max(peak, current)
        order.append(id)
    }

    func leave() {
        current -= 1
    }
}

struct AsyncSemaphoreTests {
    @Test func atMostTwoInside() async throws {
        let semaphore = AsyncSemaphore(slots: 2)
        let occupancy = Occupancy()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in 0..<5 {
                group.addTask {
                    try await semaphore.withSlot {
                        await occupancy.enter(id)
                        try await Task.sleep(for: .milliseconds(30))
                        await occupancy.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(await occupancy.peak == 2)
        #expect(await occupancy.order.count == 5)
    }

    @Test func fifoOrder() async throws {
        let semaphore = AsyncSemaphore(slots: 1)
        let occupancy = Occupancy()
        try await semaphore.acquire()
        var tasks: [Task<Void, Error>] = []
        for id in 0..<4 {
            tasks.append(Task {
                try await semaphore.acquire()
                await occupancy.enter(id)
                await semaphore.release()
            })
            // следующая задача встаёт в очередь строго после предыдущей
            try await Task.sleep(for: .milliseconds(20))
        }
        await semaphore.release()
        for task in tasks {
            try await task.value
        }
        #expect(await occupancy.order == [0, 1, 2, 3])
    }

    @Test func cancelledWaiterGetsNoSlot() async throws {
        let semaphore = AsyncSemaphore(slots: 1)
        let occupancy = Occupancy()
        try await semaphore.acquire()
        let cancelled = Task {
            try await semaphore.acquire()
            await occupancy.enter(0)
        }
        let waiting = Task {
            try await semaphore.acquire()
            await occupancy.enter(1)
            await semaphore.release()
        }
        try await Task.sleep(for: .milliseconds(30))
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        await semaphore.release()
        try await withTimeout(.seconds(2)) { try await waiting.value }
        #expect(await occupancy.order == [1])
        // слот вернулся: свободен снова
        try await withTimeout(.seconds(2)) { try await semaphore.acquire() }
    }
}
