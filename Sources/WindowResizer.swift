// Разворачивает окно Claude под дисплей на время VNC-подключения (для чёткости
// на планшете с высоким разрешением) и возвращает прежний размер после отключения.
// Использует Accessibility (право уже выдано для ввода).
import Cocoa
import ApplicationServices

final class WindowResizer {
    private var savedPos: CGPoint?
    private var savedSize: CGSize?
    private var resized = false
    private let lock = NSLock()

    // MARK: — AX-геттеры/сеттеры

    private func getSize(_ el: AXUIElement) -> CGSize? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString,
                                            &ref) == .success else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(ref as! AXValue, .cgSize, &s) ? s : nil
    }
    private func getPos(_ el: AXUIElement) -> CGPoint? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString,
                                            &ref) == .success else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(ref as! AXValue, .cgPoint, &p) ? p : nil
    }
    private func setSize(_ el: AXUIElement, _ v: CGSize) {
        var s = v
        if let val = AXValueCreate(.cgSize, &s) {
            AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, val)
        }
    }
    private func setPos(_ el: AXUIElement, _ v: CGPoint) {
        var p = v
        if let val = AXValueCreate(.cgPoint, &p) {
            AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, val)
        }
    }

    private func claudeWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName == "Claude" }) else { return nil }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        var wins: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString,
                                            &wins) == .success,
              let arr = wins as? [AXUIElement] else { return nil }
        return arr.max(by: {
            let a = getSize($0) ?? .zero, b = getSize($1) ?? .zero
            return a.width * a.height < b.width * b.height
        })
    }

    // MARK: — публичное

    private func currentDisplayBounds(_ pos: CGPoint) -> CGRect {
        var did = CGDirectDisplayID(0); var cnt: UInt32 = 0
        CGGetDisplaysWithPoint(CGPoint(x: pos.x + 2, y: pos.y + 2), 1, &did, &cnt)
        let b = cnt > 0 ? CGDisplayBounds(did) : CGDisplayBounds(CGMainDisplayID())
        if did == CGMainDisplayID() {
            return CGRect(x: b.minX, y: b.minY + 25,
                          width: b.width, height: b.height - 25)
        }
        return b
    }

    // Целевой размер окна под iPad (4:3). Чем МЕНЬШЕ — тем КРУПНЕЕ текст на
    // экране планшета (iPad растягивает содержимое сильнее). Компромисс:
    // мельче окно → крупнее и читаемее шрифт, но чуть мягче (Dell рисует в 1×).
    private let targetW: CGFloat = 1024
    private let targetH: CGFloat = 768

    // Целевой прямоугольник по центру дисплея (или вписанный, если не влезает).
    private func targetRect(in r: CGRect) -> CGRect {
        var w = targetW, h = targetH
        if w > r.width || h > r.height {   // не влезает — вписываем 4:3
            let aspect = targetW / targetH
            w = r.width; h = r.height
            if w / h > aspect { w = h * aspect } else { h = w / aspect }
        }
        return CGRect(x: r.minX + (r.width - w) / 2,
                      y: r.minY + (r.height - h) / 2, width: w, height: h)
    }

    // Границы виртуального HiDPI-дисплея iPadVNC. Сами его НЕ ищем (по размеру
    // 1024×768 опознание было ненадёжным): замыкание проставляет main.swift,
    // внутри — VirtualDisplay.bounds(), который знает точный displayID.
    var virtualBounds: (() -> CGRect?)?

    private func isOnVirtual(_ pos: CGPoint) -> Bool {
        guard let v = virtualBounds?() else { return false }
        return v.contains(CGPoint(x: pos.x + 2, y: pos.y + 2))
    }

    // Прямоугольники всех АКТИВНЫХ дисплеев (виртуалка, если жива, тоже здесь).
    private func activeDisplayRects() -> [CGRect] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count)
        return (0..<Int(count)).map { CGDisplayBounds(ids[$0]) }
    }

    private func isOnAnyDisplay(_ pos: CGPoint) -> Bool {
        let p = CGPoint(x: pos.x + 2, y: pos.y + 2)
        return activeDisplayRects().contains { $0.contains(p) }
    }

    /// Вписать окно по ширине в дисплей. Claude отдаёт ширину больше
    /// запрошенной (просили 1024 — получили 1048, просили 1152 — 1176), и
    /// лишнее уезжает за правый край вместе с полосой прокрутки. Меряем
    /// перелёт и вычитаем его из запроса.
    ///
    /// Каждый замер — после паузы и отдельным заходом на main: чтение сразу
    /// после setSize отдаёт ещё старый размер, из-за чего прошлая попытка
    /// решила, что окно «не ужимается». Внутри main.sync такую паузу делать
    /// нельзя — заблокируем интерфейс, поэтому цикл живёт на фоновом потоке.
    private func fitWidth(to v: CGRect) {
        var ask = v.width
        var firstCorrection = true
        for _ in 0..<4 {
            usleep(250_000)                       // дать окну доехать
            var got = CGSize.zero
            DispatchQueue.main.sync {
                if let win = self.claudeWindow(), let s = self.getSize(win) {
                    got = s
                }
            }
            guard got.width > 0 else { return }
            let over = got.width - v.width
            if over <= 0.5 {
                Log.writeIfChanged("resize", "окно вписано: \(Int(got.width))"
                    + " при экране \(Int(v.width))")
                return
            }
            if firstCorrection {
                // Запрос РОВНО по ширине экрана окно «прищёлкивает» к большему
                // размеру (1152 → 1176). На точку меньше запрос исполняется
                // честно, и полоски обоев справа почти не остаётся.
                ask = v.width - 1
                firstCorrection = false
            } else {
                ask -= over
            }
            guard ask > 400 else {                // здравый предел
                Log.write("resize", "окно не вписывается: перелёт \(Int(over))")
                return
            }
            DispatchQueue.main.sync {
                guard let win = self.claudeWindow() else { return }
                self.setSize(win, CGSize(width: ask, height: v.height))
                self.setPos(win, v.origin)        // держим левый верхний угол
            }
        }
        Log.write("resize", "ширину подогнать не удалось за 4 попытки")
    }

    func maximizeForClient() {
        lock.lock(); defer { lock.unlock() }
        if resized { return }
        var target: CGRect?
        DispatchQueue.main.sync {
            guard let win = claudeWindow(), let pos = getPos(win),
                  let size = getSize(win) else { return }
            // «Дом» сохраняем только если окно на ФИЗИЧЕСКОМ дисплее
            if !isOnVirtual(pos) { savedPos = pos; savedSize = size }
            if let v = virtualBounds?() {
                // Перенос на HiDPI-виртуалку: крупный текст + Retina-резкость
                setPos(win, v.origin)
                setSize(win, v.size)
                target = v
            } else {
                // Фолбэк: 4:3 на физическом (мягче, но без застревания)
                let t = targetRect(in: currentDisplayBounds(pos))
                setPos(win, t.origin); setSize(win, t.size)
            }
            resized = true
        }
        if let v = target { fitWidth(to: v) }   // подгонка — уже вне main.sync
    }

    func restore() {
        lock.lock(); defer { lock.unlock() }
        // Раннего выхода по !resized больше нет: даже если мы ничего не двигали,
        // окно могло залипнуть в координатах уже погасшей виртуалки (сценарий
        // «клиент отвалился, дисплей исчез, окно осталось в минусовых x»).
        if !resized {
            rescueIfOffscreenLocked()
            return
        }
        DispatchQueue.main.sync {
            guard let win = claudeWindow() else { return }
            // Возврат на ФИЗИЧЕСКИЙ «дом»; позиция раньше размера (иначе край).
            // «Дом» годится, только если он попадает в живой дисплей — иначе
            // вернём окно туда, где его уже не видно.
            if let p = savedPos, let s = savedSize,
               s.width >= 800, s.height >= 600, !isOnVirtual(p),
               isOnAnyDisplay(p) {
                setPos(win, p); setSize(win, s)
            } else {
                setSaneDefault(win)               // главный физический дисплей
            }
            let now = getPos(win) ?? .zero
            let sz = getSize(win) ?? .zero
            Log.write("resize", "возврат окна: итог (\(Int(now.x)),\(Int(now.y))) " +
                "\(Int(sz.width))x\(Int(sz.height))")
        }
        resized = false; savedPos = nil; savedSize = nil
    }

    /// Спасатель: окно почти не видно (мало пересекается с живыми дисплеями либо
    /// висит в координатах уже исчезнувшей виртуалки) — вернуть на главный.
    /// Безопасно звать с фонового потока (внутри main.sync).
    func rescueIfOffscreen() { rescueIfOffscreenLocked() }

    // Без взятия lock: зовётся в том числе из restore(), который лок уже держит
    // (NSLock не реентрантный). Общего состояния не трогает — только геометрию.
    private func rescueIfOffscreenLocked() {
        DispatchQueue.main.sync {
            guard let win = claudeWindow(), let pos = getPos(win),
                  let size = getSize(win), size.width > 0, size.height > 0
            else { return }
            let frame = CGRect(origin: pos, size: size)
            let area = size.width * size.height
            var visible: CGFloat = 0
            for d in activeDisplayRects() {
                let i = frame.intersection(d)
                if !i.isNull { visible += i.width * i.height }
            }
            // Видно меньше половины окна, либо его угол вне всех дисплеев и
            // виртуалки уже нет (значит, окно застряло в её бывшей области).
            let mostlyHidden = visible < area / 2
            let strandedOnGoneVirtual = virtualBounds?() == nil
                && !isOnAnyDisplay(pos)
            guard mostlyHidden || strandedOnGoneVirtual else { return }
            Log.write("resize", "спасаю окно: было (\(Int(pos.x)),\(Int(pos.y))) " +
                "\(Int(size.width))x\(Int(size.height)), видно " +
                "\(Int(visible * 100 / area))%")
            setSaneDefault(win)
            let now = getPos(win) ?? .zero
            Log.write("resize", "спасено: (\(Int(now.x)),\(Int(now.y)))")
        }
    }

    private func setSaneDefault(_ win: AXUIElement) {
        let b = CGDisplayBounds(CGMainDisplayID())
        let w: CGFloat = 1600, h: CGFloat = 1000
        setPos(win, CGPoint(x: b.minX + (b.width - w) / 2,
                            y: b.minY + (b.height - h) / 2))
        setSize(win, CGSize(width: w, height: h))
    }

    /// Ждать, пока размер окна перестанет меняться (окончание анимации ресайза),
    /// чтобы первый кадр и ServerInit имели стабильный размер. Вызывать НЕ с main.
    func waitUntilStable() {
        var last = CGSize.zero
        var stable = 0
        for _ in 0..<30 {
            var cur = CGSize.zero
            DispatchQueue.main.sync {
                if let win = self.claudeWindow(), let s = self.getSize(win) {
                    cur = s
                }
            }
            if cur == last && cur.width > 0 {
                stable += 1
                if stable >= 2 { return }
            } else { stable = 0; last = cur }
            usleep(80_000)
        }
        Log.write("resize", "окно так и не устоялось, последний размер "
            + "\(Int(last.width))x\(Int(last.height))")
    }

    /// На старте: если окно подозрительно маленькое (сбой прошлой сессии) —
    /// вернуть разумный размер.
    private func unminimize(_ win: AXUIElement) {
        var val: CFTypeRef?
        if AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute as CFString,
                                         &val) == .success,
           (val as? Bool) == true {
            AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString,
                                         kCFBooleanFalse)
        }
    }

    func ensureSaneSize() {
        DispatchQueue.global().async {
            for _ in 0..<10 {   // окно может быть не готово сразу после старта
                var ok = false
                DispatchQueue.main.sync {
                    guard let win = self.claudeWindow() else { return }
                    self.unminimize(win)                    // развернуть свёрнутое
                    guard let sz = self.getSize(win),
                          let pos = self.getPos(win) else { return }
                    if sz.width < 800 || sz.height < 600 || self.isOnVirtual(pos) {
                        self.setSaneDefault(win)
                    }
                    ok = true
                }
                // Вне main.sync (вложенный main.sync с main-потока = дедлок):
                // добить случай «окно осталось в координатах мёртвой виртуалки».
                if ok { self.rescueIfOffscreen(); return }
                usleep(300_000)
            }
        }
    }
}
