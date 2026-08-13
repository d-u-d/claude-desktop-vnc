// Инъекция ввода в систему через CGEvent. Координаты — из framebuffer в
// глобальные точки экрана по origin/scale окна. Модификаторы применяются
// флагами к событиям символов (Cmd+C, Shift+буква и т.п.).
import CoreGraphics
import Foundation

final class InputInjector {
    private var lastButtons: UInt8 = 0
    private var lastPos = CGPoint(x: -1, y: -1)
    private var mods: CGEventFlags = []
    private let src = CGEventSource(stateID: .hidSystemState)

    func pointer(buttons: UInt8, xFb: Int, yFb: Int, frame: Frame) {
        // Пиксель кадра клиента соответствует пикселю нашего кадра один к
        // одному: сервер никогда не масштабирует картинку, а при расхождении
        // размеров кадрирует её до размера framebuffer клиента (см. RFBServer).
        // Поэтому перевод — просто деление на scale (пикселей на точку).
        var sx = frame.originX + CGFloat(xFb) / frame.scale
        var sy = frame.originY + CGFloat(yFb) / frame.scale
        // Зажимаем координаты в прямоугольник кадра — клики у краёв не должны
        // улетать за его пределы на соседний дисплей.
        let winW = CGFloat(frame.width) / frame.scale
        let winH = CGFloat(frame.height) / frame.scale
        sx = min(max(sx, frame.originX), frame.originX + winW - 1)
        sy = min(max(sy, frame.originY), frame.originY + winH - 1)
        let pos = CGPoint(x: sx, y: sy)
        let prev = lastButtons
        let leftHeld = buttons & 1 != 0
        let rightHeld = buttons & 4 != 0

        if pos != lastPos {
            let type: CGEventType = leftHeld ? .leftMouseDragged
                : (rightHeld ? .rightMouseDragged : .mouseMoved)
            let btn: CGMouseButton = rightHeld ? .right : .left
            postMouse(type, pos, btn)
            lastPos = pos
        }

        func edge(_ mask: UInt8, _ down: CGEventType, _ up: CGEventType,
                  _ btn: CGMouseButton) {
            let was = prev & mask, now = buttons & mask
            if now != 0 && was == 0 { postMouse(down, pos, btn) }
            if now == 0 && was != 0 { postMouse(up, pos, btn) }
        }
        edge(1, .leftMouseDown, .leftMouseUp, .left)
        edge(4, .rightMouseDown, .rightMouseUp, .right)
        edge(2, .otherMouseDown, .otherMouseUp, .center)

        if buttons & 8 != 0 && prev & 8 == 0 { scroll(+3) }   // колесо вверх
        if buttons & 16 != 0 && prev & 16 == 0 { scroll(-3) } // колесо вниз
        lastButtons = buttons
    }

    func key(down: Bool, keysym: UInt32) {
        if let flag = Keymap.modifierFlag(keysym) {
            if down { mods.insert(flag) } else { mods.remove(flag) }
            return
        }
        // Спец-клавиши (Enter/Esc/Tab/стрелки/Backspace) — по коду
        if let code = Keymap.specialKeycode(keysym) {
            postKeycode(code, down, mods)
            return
        }
        // Шорткаты с Cmd/Ctrl — по коду (Unicode не даёт сочетаний)
        if mods.contains(.maskCommand) || mods.contains(.maskControl),
           let ks = Keymap.stroke(for: keysym) {
            var f = mods
            if ks.shift { f.insert(.maskShift) }
            postKeycode(ks.code, down, f)
            return
        }
        // Печатные символы — layout-независимо, вводим сам символ.
        // Unicode-строка учитывается только на session-tap, не на HID.
        if let scalar = Keymap.unicodeScalar(keysym) {
            let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)
            var utf16 = Array(String(scalar).utf16)
            e?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            e?.post(tap: .cgSessionEventTap)
        }
    }

    private func postKeycode(_ code: CGKeyCode, _ down: Bool, _ flags: CGEventFlags) {
        let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
        e?.flags = flags
        e?.post(tap: .cghidEventTap)
    }

    private func postMouse(_ type: CGEventType, _ pos: CGPoint, _ btn: CGMouseButton) {
        let e = CGEvent(mouseEventSource: src, mouseType: type,
                        mouseCursorPosition: pos, mouseButton: btn)
        e?.flags = mods
        e?.post(tap: .cghidEventTap)
    }

    private func scroll(_ amount: Int32) {
        let e = CGEvent(scrollWheelEvent2Source: src, units: .line,
                        wheelCount: 1, wheel1: amount, wheel2: 0, wheel3: 0)
        e?.post(tap: .cghidEventTap)
    }
}
