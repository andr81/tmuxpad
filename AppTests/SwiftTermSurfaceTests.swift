import Foundation
import Testing
@testable import TmuxPad

@MainActor
@Suite struct SwiftTermSurfaceTests {
    @Test func bytesFedOffMainAppearInOrder() async throws {
        let view = TmuxTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let surface = SwiftTermSurface(view: view)
        let expected = (0..<40).map { String($0 % 10) }.joined()
        await Task.detached {
            for char in expected {
                surface.feed(Data(String(char).utf8))
            }
        }.value
        try await waitUntil { screenText(view).contains(expected) }
        #expect(screenText(view).contains(expected))
    }

    @Test func sizeFollowsFrame() async throws {
        let view = TmuxTerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let surface = SwiftTermSurface(view: view)
        let before = view.terminalDimensions
        #expect(surface.size == (before.cols, before.rows))

        view.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
        view.layoutIfNeeded()
        try await waitUntil { view.terminalDimensions != before }
        let after = view.terminalDimensions
        #expect(after.cols > before.cols)
        #expect(surface.size == (after.cols, after.rows))
    }

    @Test func sizeWithoutViewIsFallback() async throws {
        weak var probe: TmuxTerminalView?
        let surface: SwiftTermSurface = autoreleasepool {
            let view = TmuxTerminalView()
            probe = view
            return SwiftTermSurface(view: view)
        }
        try await waitUntil { probe == nil }
        #expect(surface.size == SwiftTermSurface.fallbackSize)
    }

    @Test func stateAndChipGoToClosures() {
        let seen = Recorded()
        let surface = SwiftTermSurface(
            view: TmuxTerminalView(),
            stateChanged: { seen.append("state \($0)") },
            copyModeSuspected: { seen.append("chip \($0)") })
        surface.stateChanged(.live)
        surface.copyModeSuspected(true)
        #expect(seen.values == ["state live", "chip true"])
    }
}

/// Потокобезопасный список для замыканий `@Sendable`.
final class Recorded: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    func append(_ item: String) {
        lock.withLock { items.append(item) }
    }

    var values: [String] {
        lock.withLock { items }
    }
}
