// Соответствие RFB/X11 keysym -> виртуальные коды клавиш macOS (US-раскладка).
// Хватает для работы с Claude: буквы, цифры, пунктуация, Esc/Tab/стрелки/Ctrl/Cmd.
import Foundation
import CoreGraphics

struct KeyStroke { let code: CGKeyCode; let shift: Bool }

enum Keymap {
    // Символ ASCII -> (код, нужен ли Shift) для US-раскладки
    private static let charMap: [Character: KeyStroke] = {
        var m: [Character: KeyStroke] = [:]
        func add(_ s: String, _ code: CGKeyCode, shifted: String? = nil) {
            if let c = s.first { m[c] = KeyStroke(code: code, shift: false) }
            if let sh = shifted, let c = sh.first { m[c] = KeyStroke(code: code, shift: true) }
        }
        add("a", 0); add("s", 1); add("d", 2); add("f", 3); add("h", 4)
        add("g", 5); add("z", 6); add("x", 7); add("c", 8); add("v", 9)
        add("b", 11); add("q", 12); add("w", 13); add("e", 14); add("r", 15)
        add("y", 16); add("t", 17); add("o", 31); add("u", 32); add("i", 34)
        add("p", 35); add("l", 37); add("j", 38); add("k", 40); add("n", 45)
        add("m", 46)
        // Заглавные — те же коды с Shift
        for (lower, ks) in m where lower.isLetter {
            m[Character(lower.uppercased())] = KeyStroke(code: ks.code, shift: true)
        }
        // Цифры и их Shift-символы
        add("1", 18, shifted: "!"); add("2", 19, shifted: "@")
        add("3", 20, shifted: "#"); add("4", 21, shifted: "$")
        add("5", 23, shifted: "%"); add("6", 22, shifted: "^")
        add("7", 26, shifted: "&"); add("8", 28, shifted: "*")
        add("9", 25, shifted: "("); add("0", 29, shifted: ")")
        // Пунктуация
        add("=", 24, shifted: "+"); add("-", 27, shifted: "_")
        add("]", 30, shifted: "}"); add("[", 33, shifted: "{")
        add("'", 39, shifted: "\""); add(";", 41, shifted: ":")
        add("\\", 42, shifted: "|"); add(",", 43, shifted: "<")
        add("/", 44, shifted: "?"); add(".", 47, shifted: ">")
        add("`", 50, shifted: "~")
        add(" ", 49)
        return m
    }()

    // Спец-клавиши по keysym (0xFFxx)
    private static let specialMap: [UInt32: CGKeyCode] = [
        0xff0d: 36,  // Return
        0xff8d: 76,  // KP_Enter
        0xff09: 48,  // Tab
        0xff08: 51,  // BackSpace
        0xffff: 117, // Delete (forward)
        0xff1b: 53,  // Escape
        0xff51: 123, // Left
        0xff52: 126, // Up
        0xff53: 124, // Right
        0xff54: 125, // Down
        0xff50: 115, // Home
        0xff57: 119, // End
        0xff55: 116, // PageUp
        0xff56: 121, // PageDown
    ]

    // Модификаторы по keysym
    static func modifierFlag(_ keysym: UInt32) -> CGEventFlags? {
        switch keysym {
        case 0xffe1, 0xffe2: return .maskShift
        case 0xffe3, 0xffe4: return .maskControl
        case 0xffe9, 0xffea: return .maskAlternate       // Alt/Option
        case 0xffe7, 0xffe8, 0xffeb, 0xffec: return .maskCommand // Meta/Super -> Cmd
        default: return nil
        }
    }

    /// keysym -> (код, нужен ли Shift сам по себе). nil если не знаем.
    static func stroke(for keysym: UInt32) -> KeyStroke? {
        if let code = specialMap[keysym] { return KeyStroke(code: code, shift: false) }
        // Печатные ASCII: keysym == код символа
        if keysym >= 0x20 && keysym <= 0x7e, let scalar = Unicode.Scalar(keysym) {
            return charMap[Character(scalar)]
        }
        return nil
    }

    /// Только спец-клавиши (Enter/Esc/Tab/стрелки/…): код или nil.
    static func specialKeycode(_ keysym: UInt32) -> CGKeyCode? {
        specialMap[keysym]
    }

    // Легаси X11-кириллица (0x6xx, порядок KOI8-R) -> Unicode. RealVNC шлёт именно их.
    private static let cyrillic: [UInt32: UInt32] = [
        0x6c0: 0x044e, 0x6c1: 0x0430, 0x6c2: 0x0431, 0x6c3: 0x0446, 0x6c4: 0x0434,
        0x6c5: 0x0435, 0x6c6: 0x0444, 0x6c7: 0x0433, 0x6c8: 0x0445, 0x6c9: 0x0438,
        0x6ca: 0x0439, 0x6cb: 0x043a, 0x6cc: 0x043b, 0x6cd: 0x043c, 0x6ce: 0x043d,
        0x6cf: 0x043e, 0x6d0: 0x043f, 0x6d1: 0x044f, 0x6d2: 0x0440, 0x6d3: 0x0441,
        0x6d4: 0x0442, 0x6d5: 0x0443, 0x6d6: 0x0436, 0x6d7: 0x0432, 0x6d8: 0x044c,
        0x6d9: 0x044b, 0x6da: 0x0437, 0x6db: 0x0448, 0x6dc: 0x044d, 0x6dd: 0x0449,
        0x6de: 0x0447, 0x6df: 0x044a,
        0x6e0: 0x042e, 0x6e1: 0x0410, 0x6e2: 0x0411, 0x6e3: 0x0426, 0x6e4: 0x0414,
        0x6e5: 0x0415, 0x6e6: 0x0424, 0x6e7: 0x0413, 0x6e8: 0x0425, 0x6e9: 0x0418,
        0x6ea: 0x0419, 0x6eb: 0x041a, 0x6ec: 0x041b, 0x6ed: 0x041c, 0x6ee: 0x041d,
        0x6ef: 0x041e, 0x6f0: 0x041f, 0x6f1: 0x042f, 0x6f2: 0x0420, 0x6f3: 0x0421,
        0x6f4: 0x0422, 0x6f5: 0x0423, 0x6f6: 0x0416, 0x6f7: 0x0412, 0x6f8: 0x042c,
        0x6f9: 0x042b, 0x6fa: 0x0417, 0x6fb: 0x0428, 0x6fc: 0x042d, 0x6fd: 0x0429,
        0x6fe: 0x0427, 0x6ff: 0x042a,
        0x6a3: 0x0451, 0x6b3: 0x0401,   // ё Ё
    ]

    /// keysym -> вводимый символ (для layout-независимого набора). nil если не печатный.
    static func unicodeScalar(_ keysym: UInt32) -> Unicode.Scalar? {
        if keysym >= 0x20 && keysym <= 0x7e { return Unicode.Scalar(keysym) }   // ASCII
        if keysym >= 0xa0 && keysym <= 0xff { return Unicode.Scalar(keysym) }   // Latin-1
        if let u = cyrillic[keysym] { return Unicode.Scalar(u) }                // кириллица
        if keysym >= 0x01000000 && keysym <= 0x0110ffff {                        // Unicode keysym
            return Unicode.Scalar(keysym & 0x00ffffff)
        }
        return nil
    }
}
