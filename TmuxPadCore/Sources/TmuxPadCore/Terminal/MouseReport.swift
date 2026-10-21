import Foundation

/// Что прислал экран терминала одним буфером (§3.5): SwiftTerm отдаёт клавиатуру и мышиные
/// отчёты одним делегатным `send`.
public enum TerminalInput: Sendable, Equatable {
    /// Ввод: перед ним после скролла нужен `copy-cancel`.
    case keyboard
    /// Среди отчётов есть колесо вверх: tmux входит в copy-mode, UI показывает чип.
    case wheelUp
    /// Прочие мышиные отчёты и отчёты о фокусе: идут в PTY мимо `copy-cancel`.
    case otherMouse
}

/// Разбор исходящих байтов терминала на мышиные отчёты xterm.
///
/// Буфер мышиный, только если целиком состоит из отчётов: SGR `ESC [ < Pb ; Px ; Py (M|m)`
/// (поля — 1–4 десятичные цифры) или X10 `ESC [ M Cb Cx Cy` (три байта ≥ 32), а также отчёты о
/// фокусе `ESC [ I` / `ESC [ O` (режим 1004): SwiftTerm шлёт их тем же `send` при смене first
/// responder, и `copy-cancel` из-за них вывел бы pane из copy-mode без ввода. Всё прочее —
/// `.keyboard`: лишний `copy-cancel` лучше проглоченного ввода. X10 в режиме 1005 (UTF-8) при
/// колонке или строке > 223 кодирует координату двумя байтами и разберётся как `.keyboard` —
/// допустимо, tmux с `mouse on` включает SGR (1006).
public enum MouseReport {
    private static let esc: UInt8 = 0x1B
    private static let bracket: UInt8 = 0x5B
    private static let less: UInt8 = 0x3C
    private static let upperM: UInt8 = 0x4D
    private static let focusIn: UInt8 = 0x49
    private static let focusOut: UInt8 = 0x4F
    private static let lowerM: UInt8 = 0x6D
    private static let semicolon: UInt8 = 0x3B
    /// Биты модификаторов shift, meta, ctrl в коде кнопки.
    private static let modifiers = 4 | 8 | 16
    private static let wheelUpButton = 64

    public static func classify(_ bytes: Data) -> TerminalInput {
        let buffer = [UInt8](bytes)
        guard !buffer.isEmpty else {
            return .keyboard
        }
        var index = 0
        var wheelUp = false
        while index < buffer.count {
            guard let (button, next) = report(buffer, at: index) else {
                return .keyboard
            }
            if button & ~modifiers == wheelUpButton {
                wheelUp = true
            }
            index = next
        }
        return wheelUp ? .wheelUp : .otherMouse
    }

    /// Отчёт с позиции `start`: код кнопки и позиция за ним; `nil` — не отчёт.
    private static func report(_ buffer: [UInt8], at start: Int) -> (button: Int, next: Int)? {
        guard start + 2 < buffer.count, buffer[start] == esc, buffer[start + 1] == bracket else {
            return nil
        }
        let kind = buffer[start + 2]
        if kind == focusIn || kind == focusOut {
            // не кнопка: код 0 не колесо вверх
            return (0, start + 3)
        }
        if kind == less {
            return sgr(buffer, from: start + 3)
        }
        if kind == upperM {
            let fields = start + 3
            guard fields + 3 <= buffer.count, buffer[fields..<fields + 3].allSatisfy({ $0 >= 32 }) else {
                return nil
            }
            return (Int(buffer[fields]) - 32, fields + 3)
        }
        return nil
    }

    /// `Pb ; Px ; Py (M|m)` с позиции `start`.
    private static func sgr(_ buffer: [UInt8], from start: Int) -> (button: Int, next: Int)? {
        var index = start
        var fields: [Int] = []
        while fields.count < 3 {
            var value = 0
            var digits = 0
            while index < buffer.count, (0x30...0x39).contains(buffer[index]), digits < 4 {
                value = value * 10 + Int(buffer[index] - 0x30)
                digits += 1
                index += 1
            }
            guard digits > 0, index < buffer.count else {
                return nil
            }
            fields.append(value)
            let terminator = buffer[index]
            index += 1
            if fields.count < 3 {
                guard terminator == semicolon else {
                    return nil
                }
            } else {
                guard terminator == upperM || terminator == lowerM else {
                    return nil
                }
            }
        }
        return (fields[0], index)
    }
}
