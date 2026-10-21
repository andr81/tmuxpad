import Foundation
import Testing
@testable import TmuxPad

@MainActor
@Suite struct InputPumpTests {
    @Test func delegateSendsArriveInOrder() async throws {
        let received = Recorded()
        let pump = InputPump(sink: { received.append(String(decoding: $0, as: UTF8.self)) })
        let delegate = TerminalDelegate(pump: pump, resize: { _, _ in })
        let view = TmuxTerminalView()
        let sent = (0..<100).map { "k\($0);" }
        for chunk in sent {
            delegate.send(source: view, data: Array(chunk.utf8)[...])
        }
        try await waitUntil { received.values.count == sent.count }
        #expect(received.values == sent)
        pump.finish()
    }

    @Test func errorDoesNotStopThePump() async throws {
        let received = Recorded()
        let errors = Recorded()
        let pump = InputPump(
            sink: { bytes in
                let text = String(decoding: bytes, as: UTF8.self)
                if text == "bad" {
                    throw CancellationError()
                }
                received.append(text)
            },
            onError: { errors.append("\(type(of: $0))") })
        for text in ["a", "bad", "b"] {
            pump.send(Data(text.utf8))
        }
        try await waitUntil { received.values.count == 2 }
        #expect(received.values == ["a", "b"])
        #expect(errors.values == ["CancellationError"])
        pump.finish()
    }

    @Test func sizeChangeResizes() async throws {
        let sizes = Recorded()
        let delegate = TerminalDelegate(
            pump: InputPump(sink: { _ in }),
            resize: { cols, rows in sizes.append("\(cols)x\(rows)") })
        delegate.sizeChanged(source: TmuxTerminalView(), newCols: 120, newRows: 40)
        try await waitUntil { sizes.values == ["120x40"] }
    }

    @Test func pinchStepsByThreshold() {
        var base: CGFloat = 1
        #expect(TmuxTerminalView.pinchSteps(from: &base, to: 1.1) == [])
        #expect(TmuxTerminalView.pinchSteps(from: &base, to: 1.25) == [1, 1])
        #expect(TmuxTerminalView.pinchSteps(from: &base, to: 0.9) == [-1, -1])
    }
}
