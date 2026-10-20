import Foundation
import Testing
@testable import TmuxPadCore

struct MouseReportTests {
    static func bytes(_ text: String) -> Data {
        Data(text.utf8)
    }

    static func x10(_ codes: [UInt8]) -> Data {
        Data([0x1B, 0x5B, 0x4D] + codes)
    }

    @Test(arguments: [
        ("\u{1B}[<64;10;5M", TerminalInput.wheelUp),
        ("\u{1B}[<80;10;5M", .wheelUp),
        ("\u{1B}[<65;10;5M", .otherMouse),
        ("\u{1B}[<0;3;4M", .otherMouse),
        ("\u{1B}[<0;3;4m", .otherMouse),
        ("\u{1B}[<65;1;1M\u{1B}[<64;1;1M", .wheelUp),
        ("\u{1B}[<65;1;1M\u{1B}[<0;1;1m", .otherMouse),
        ("\u{1B}[<64;1000;1000M", .wheelUp),
        ("\u{1B}[A", .keyboard),
        ("\u{1B}[<", .keyboard),
        ("\u{1B}[<64;10;5", .keyboard),
        ("\u{1B}[<64;10M", .keyboard),
        ("\u{1B}[<64;10;12345M", .keyboard),
        ("\u{1B}[64;10;5M", .keyboard),
        ("hello", .keyboard),
        ("", .keyboard),
        ("\u{1B}[<64;1;1Ma", .keyboard),
        ("a\u{1B}[<64;1;1M", .keyboard),
    ])
    func classifiesText(_ text: String, _ expected: TerminalInput) {
        #expect(MouseReport.classify(Self.bytes(text)) == expected)
    }

    @Test func x10WheelUp() {
        #expect(MouseReport.classify(Self.x10([96, 40, 40])) == .wheelUp)
    }

    @Test func x10Click() {
        #expect(MouseReport.classify(Self.x10([32, 40, 40])) == .otherMouse)
    }

    @Test func x10ByteBelow32IsKeyboard() {
        #expect(MouseReport.classify(Self.x10([96, 31, 40])) == .keyboard)
    }

    @Test func x10ShortIsKeyboard() {
        #expect(MouseReport.classify(Self.x10([96, 40])) == .keyboard)
    }
}
