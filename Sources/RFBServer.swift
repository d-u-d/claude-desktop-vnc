// Минимальный RFB (VNC) сервер. Этап B: рукопожатие 3.8, ServerInit,
// FramebufferUpdate с RAW-кодированием одного окна. Многобайтовые поля
// протокола — big-endian. Пиксели — 32bpp, формат BGRA (little-endian пиксель).
//
// Архитектура клиента — два потока:
//  * читатель  — принимает сообщения клиента и обрабатывает ввод СРАЗУ
//    (мышь/клавиатура не стоят в очереди за видео);
//  * отправитель — по сигналу захватывает кадр и шлёт FramebufferUpdate.
// Общее состояние — в ClientCtx под NSCondition. Все записи в сокет после
// рукопожатия делает только отправитель; zlib-поток (Deflater) принадлежит ему.
import Foundation
import Darwin

// Общий контекст клиента. Все поля читать/писать ТОЛЬКО под cond.lock().
private final class ClientCtx {
    let cond = NSCondition()
    var wantUpdate = false            // клиент запросил кадр
    var incremental = false           // флаг последнего FramebufferUpdateRequest
    var closed = false                // соединение рвётся — обоим потокам выйти
    var pf = PixelFormat.defaultBGRA  // текущий формат пикселей клиента
    var useZlib = false               // клиент поддерживает zlib-кодирование
    var supportsCursor = false        // клиент поддерживает Cursor-псевдокодировку
    var supportsDesktopSize = false   // клиент умеет менять размер на лету
    var fbW = 0, fbH = 0              // размер framebuffer у клиента (ServerInit)
    var lastFrame: Frame?             // последний кадр — для координат мыши
}

final class RFBServer {
    let port: UInt16
    let capturer: WindowCapturer
    var onStatus: ((String) -> Void)?
    var onConnect: (() -> Void)?      // до отправки размеров клиенту
    var onDisconnect: (() -> Void)?
    private var listenFD: Int32 = -1

    // Учёт активности: счётчик клиентов в AppDelegate врёт, если поток сессии
    // завис (так и случилось — сессия застряла на закрытии, и сторож считал,
    // что клиент на связи). Эти два числа — независимый признак жизни.
    private let statLock = NSLock()
    private var activeCount = 0
    private var lastActivity: CFAbsoluteTime = 0

    /// Сколько сессий считают себя активными.
    func liveSessions() -> Int {
        statLock.lock(); defer { statLock.unlock() }
        return activeCount
    }

    /// Секунд с последнего сообщения от любого клиента. Если сообщений не было
    /// вовсе — заведомо большое число.
    func secondsSinceActivity() -> Double {
        statLock.lock(); defer { statLock.unlock() }
        guard lastActivity > 0 else { return .greatestFiniteMagnitude }
        return CFAbsoluteTimeGetCurrent() - lastActivity
    }

    private func sessionBegan() {
        statLock.lock()
        activeCount += 1
        lastActivity = CFAbsoluteTimeGetCurrent()
        statLock.unlock()
    }

    private func sessionEnded() {
        statLock.lock(); activeCount = max(0, activeCount - 1); statLock.unlock()
    }

    private func touch() {
        statLock.lock(); lastActivity = CFAbsoluteTimeGetCurrent(); statLock.unlock()
    }

    init(port: UInt16, capturer: WindowCapturer) {
        self.port = port
        self.capturer = capturer
    }

    func start() {
        // Запись в сокет, который клиент уже закрыл, по умолчанию убивает
        // процесс сигналом SIGPIPE — мгновенно, без шанса что-то записать в
        // лог и прибраться. Ровно так приложение и умирало при каждом
        // отключении планшета: отправитель в этот момент гнал кадр на 12 МБ.
        // Ниже — глобальный запрет, а на каждом сокете ещё и SO_NOSIGPIPE.
        signal(SIGPIPE, SIG_IGN)
        let t = Thread { self.runAccept() }
        t.stackSize = 1 << 20
        t.start()
    }

    private func runAccept() {
        listenFD = socket(AF_INET, SOCK_STREAM, 0)
        guard listenFD >= 0 else { onStatus?("socket() не удался"); return }
        var yes: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &yes,
                   socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY   // 0.0.0.0 — доступно через WireGuard
        let bindOK = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindOK == 0 else { onStatus?("bind :\(port) не удался"); return }
        guard listen(listenFD, 4) == 0 else { onStatus?("listen не удался"); return }
        onStatus?("ждёт на :\(port)")

        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { continue }
            let t = Thread { self.handleClient(fd) }
            t.stackSize = 1 << 20
            t.start()
        }
    }

    // MARK: — работа с одним клиентом (поток-читатель)

    private func dbg(_ s: String) {}   // отладка отключена

    private func handleClient(_ fd: Int32) {
        let ctx = ClientCtx()
        let senderDone = DispatchSemaphore(value: 0)
        var senderStarted = false
        // Закрытие ровно один раз и только после завершения обоих потоков:
        // помечаем closed, будим отправителя, shutdown() выбивает его из send(),
        // ждём его завершения — и лишь потом close(fd) + onDisconnect.
        defer {
            var senderStuck = false
            if senderStarted {
                markClosed(ctx, fd)
                // С таймаутом: если отправитель завис (например, застрял в
                // захвате кадра), ждать его вечно нельзя — иначе вся сессия
                // не закрывается, счётчик клиентов не падает, виртуалка не
                // гаснет и новые подключения не проходят. Именно так и было.
                if senderDone.wait(timeout: .now() + 6) == .timedOut {
                    senderStuck = true
                    Log.write("rfb", "отправитель не завершился за 6 c — "
                        + "закрываю сессию, fd=\(fd) оставляю висеть")
                }
            }
            // fd закрываем, только если им точно никто не пользуется: закрыть
            // его под носом у живого потока опаснее, чем подтечь одним fd.
            if !senderStuck {
                close(fd)
                Log.write("rfb", "сессия закрыта, сокет освобождён")
            }
            sessionEnded()
            onDisconnect?()
        }

        sessionBegan()
        Log.write("rfb", "клиент подключился (fd=\(fd))")
        onStatus?("клиент подключился")
        // Развернуть окно ДО того, как узнаем размер для ServerInit, и дать
        // окну переразметиться.
        onConnect?()   // ресайз окна + ожидание стабилизации размера
        let input = InputInjector()
        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one,
                   socklen_t(MemoryLayout<Int32>.size))
        // Никаких SIGPIPE по этому сокету — send() вернёт EPIPE, и мы закроем
        // сессию штатно, вместо того чтобы умереть всем процессом.
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one,
                   socklen_t(MemoryLayout<Int32>.size))
        // Таймауты на recv/send: живой клиент шлёт FramebufferUpdateRequest
        // постоянно, а «молча пропавший» (планшет уснул, VPN отвалился) не
        // закрывает TCP — без таймаута оба потока висли бы вечно, onDisconnect
        // не приходил и виртуалка оставалась поднятой.
        var tv = timeval(tv_sec: 15, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv,
                   socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv,
                   socklen_t(MemoryLayout<timeval>.size))

        // 1. ProtocolVersion
        if !writeAll(fd, Array("RFB 003.008\n".utf8)) { return }
        guard let _ = readN(fd, 12) else { return }

        // 2. Security: типы = [None(1)]
        if !writeAll(fd, [1, 1]) { return }
        guard let sec = readN(fd, 1), sec[0] == 1 else { return }
        // SecurityResult = OK
        if !writeAll(fd, [0, 0, 0, 0]) { return }

        // 3. ClientInit (shared-flag) — читаем, игнорируем
        guard let _ = readN(fd, 1) else { return }

        // 4. Первый кадр, чтобы узнать размеры (с ретраями — окно могло ещё
        //    доводиться после ресайза)
        var first: Frame?
        for _ in 0..<10 {
            if let f = grabSync() { first = f; break }
            usleep(120_000)
        }
        guard let frame = first else {
            onStatus?("нет кадра (окно/права)"); return
        }
        ctx.lastFrame = frame   // до старта отправителя — лок не нужен

        // ServerInit
        var init_ = [UInt8]()
        init_ += beU16(UInt16(frame.width))
        init_ += beU16(UInt16(frame.height))
        init_ += pixelFormat()
        let name = Array("Claude".utf8)
        init_ += beU32(UInt32(name.count))
        init_ += name
        if !writeAll(fd, init_) { return }

        dbg("ServerInit отправлен \(frame.width)x\(frame.height)")
        Log.write("rfb", "ServerInit \(frame.width)x\(frame.height) "
            + "origin=(\(Int(frame.originX)),\(Int(frame.originY))) "
            + "scale=\(frame.scale)")
        ctx.fbW = frame.width; ctx.fbH = frame.height   // отправителя ещё нет
        // Рукопожатие завершено — дальше в сокет пишет ТОЛЬКО отправитель.
        let sender = Thread { self.runSender(fd, ctx: ctx, done: senderDone) }
        sender.stackSize = 1 << 20
        sender.start()
        senderStarted = true

        // 5. Цикл сообщений: только чтение + ввод, кадры не трогаем
        while true {
            guard let mt = readN(fd, 1) else { dbg("read msg-type: обрыв"); return }
            dbg("msg-type=\(mt[0])")
            touch()   // клиент жив — отметка для сторожа
            switch mt[0] {
            case 0: // SetPixelFormat: 3 паддинг + 16 формат
                _ = readN(fd, 3)
                if let raw = readN(fd, 16) {
                    let pf = PixelFormat.parse(raw)
                    ctx.cond.lock()
                    ctx.pf = pf
                    ctx.cond.unlock()
                }
            case 2: // SetEncodings: 1 паддинг + 2 count + count*4
                guard let h = readN(fd, 3) else { return }
                let count = Int(h[1]) << 8 | Int(h[2])
                if let enc = readN(fd, count * 4) {
                    var list = [Int32]()
                    for i in 0..<count {
                        let v = Int32(bitPattern:
                            UInt32(enc[i*4]) << 24 | UInt32(enc[i*4+1]) << 16
                            | UInt32(enc[i*4+2]) << 8 | UInt32(enc[i*4+3]))
                        list.append(v)
                    }
                    ctx.cond.lock()
                    ctx.useZlib = list.contains(6)        // zlib-кодирование
                    ctx.supportsCursor = list.contains(-239) // Cursor-псевдокодировка
                    ctx.supportsDesktopSize = list.contains(-223) // DesktopSize
                    let z = ctx.useZlib, ds = ctx.supportsDesktopSize
                    ctx.cond.unlock()
                    Log.write("rfb", "кодировки клиента: zlib=\(z) desktopSize=\(ds)")
                }
            case 3: // FramebufferUpdateRequest — только сигналим отправителю
                guard let r = readN(fd, 9) else { return }
                ctx.cond.lock()
                ctx.wantUpdate = true
                ctx.incremental = r[0] != 0
                ctx.cond.signal()
                ctx.cond.unlock()
            case 4: // KeyEvent: down-flag(1) + padding(2) + keysym(4)
                guard let k = readN(fd, 7) else { return }
                let down = k[0] != 0
                let keysym = UInt32(k[3]) << 24 | UInt32(k[4]) << 16
                    | UInt32(k[5]) << 8 | UInt32(k[6])
                input.key(down: down, keysym: keysym)
            case 5: // PointerEvent: button-mask(1) + x(2) + y(2)
                guard let p = readN(fd, 5) else { return }
                let buttons = p[0]
                let x = Int(p[1]) << 8 | Int(p[2])
                let y = Int(p[3]) << 8 | Int(p[4])
                // Геометрия — из последнего кадра отправителя (CoW-копия дешёвая)
                ctx.cond.lock()
                let geom = ctx.lastFrame
                ctx.cond.unlock()
                if let g = geom {
                    input.pointer(buttons: buttons, xFb: x, yFb: y, frame: g)
                }
            case 6: // ClientCutText
                guard let h = readN(fd, 7) else { return }
                let len = Int(h[3]) << 24 | Int(h[4]) << 16 | Int(h[5]) << 8 | Int(h[6])
                _ = readN(fd, len)
            default:
                dbg("НЕИЗВЕСТНЫЙ msg-type=\(mt[0]) — закрываю")
                return
            }
        }
    }

    // MARK: — поток-отправитель кадров

    private func runSender(_ fd: Int32, ctx: ClientCtx, done: DispatchSemaphore) {
        defer { done.signal() }
        let deflater = Deflater(level: 1)   // быстрый уровень; zlib-поток строго
                                            // последовательный — живёт только тут
        var lastBGRA: [UInt8]? = nil        // для пропуска неизменившихся кадров
        var cursorSent = false

        while true {
            // Ждём запрос кадра или закрытие
            ctx.cond.lock()
            while !ctx.wantUpdate && !ctx.closed { ctx.cond.wait() }
            if ctx.closed { ctx.cond.unlock(); return }
            ctx.wantUpdate = false
            let incremental = ctx.incremental
            let pf = ctx.pf
            let useZlib = ctx.useZlib
            let supportsCursor = ctx.supportsCursor
            let canResize = ctx.supportsDesktopSize
            var fbW = ctx.fbW, fbH = ctx.fbH
            ctx.cond.unlock()

            // Захват и запись — строго вне лока (могут занимать сотни мс)
            var frame: Frame?
            if let f = grabSync() {
                frame = f
                ctx.cond.lock()
                ctx.lastFrame = f   // свежая геометрия для координат мыши
                ctx.cond.unlock()
            } else {
                // Захват не удался — шлём последний известный кадр
                ctx.cond.lock()
                frame = ctx.lastFrame
                ctx.cond.unlock()
            }
            guard let fr = frame else { continue }

            // Один раз спрятать локальный курсор клиента (1×1 прозрачный)
            if supportsCursor && !cursorSent {
                _ = sendTransparentCursor(fd, pf); cursorSent = true
            }

            // Размер кадра разошёлся с framebuffer клиента (окно переехало или
            // сменился дисплей). Слать прямоугольник больше буфера клиента —
            // нарушение протокола: клиент либо обрежет, либо растянет, и тогда
            // координаты мыши поедут. Поэтому либо честно меняем размер
            // (DesktopSize), либо кадрируем до размера клиента — один пиксель
            // кадра всегда равен одному пикселю у клиента.
            var pixelsSource = fr.bgra
            var sendW = fr.width, sendH = fr.height
            if fr.width != fbW || fr.height != fbH {
                if canResize {
                    Log.write("rfb", "DesktopSize \(fbW)x\(fbH) -> "
                        + "\(fr.width)x\(fr.height)")
                    if !sendDesktopSize(fd, w: fr.width, h: fr.height) {
                        markClosed(ctx, fd); return
                    }
                    fbW = fr.width; fbH = fr.height
                    ctx.cond.lock(); ctx.fbW = fbW; ctx.fbH = fbH; ctx.cond.unlock()
                    lastBGRA = nil          // буфер клиента пересоздан
                } else {
                    Log.writeIfChanged("rfb", "кадрирую \(fr.width)x\(fr.height)"
                        + " -> \(fbW)x\(fbH) (клиент без DesktopSize)")
                    pixelsSource = Self.fit(fr.bgra, from: (fr.width, fr.height),
                                            to: (fbW, fbH))
                    sendW = fbW; sendH = fbH
                }
            }

            let ok: Bool
            if incremental, let prev = lastBGRA, prev == pixelsSource {
                // Экран не изменился — не гоним кадр заново, лёгкий троттлинг
                usleep(40_000)
                ok = sendEmptyUpdate(fd)
            } else {
                ok = useZlib
                    ? sendFramebufferZlib(fd, pixelsSource, sendW, sendH, pf, deflater)
                    : sendFramebufferRaw(fd, pixelsSource, sendW, sendH, pf)
                if ok { lastBGRA = pixelsSource }
            }
            if !ok {
                Log.write("rfb", "ошибка записи в сокет — закрываю сессию")
                markClosed(ctx, fd)
                return
            }
        }
    }

    /// Пометить соединение закрытым и выбить второй поток из recv/send.
    private func markClosed(_ ctx: ClientCtx, _ fd: Int32) {
        ctx.cond.lock()
        ctx.closed = true
        ctx.cond.signal()
        ctx.cond.unlock()
        shutdown(fd, SHUT_RDWR)
    }

    /// Привести буфер к размеру клиента: лишнее обрезаем, недостающее — чёрным.
    /// Масштабирования нет намеренно — оно ломает соответствие координат.
    private static func fit(_ src: [UInt8], from: (Int, Int),
                            to: (Int, Int)) -> [UInt8] {
        let (sw, sh) = from, (dw, dh) = to
        guard dw > 0, dh > 0 else { return src }
        var out = [UInt8](repeating: 0, count: dw * dh * 4)
        let copyW = min(sw, dw) * 4, rows = min(sh, dh)
        guard copyW > 0, rows > 0 else { return out }
        src.withUnsafeBufferPointer { s in
            out.withUnsafeMutableBufferPointer { d in
                guard let sb = s.baseAddress, let db = d.baseAddress else { return }
                for y in 0..<rows {
                    memcpy(db + y * dw * 4, sb + y * sw * 4, copyW)
                }
            }
        }
        return out
    }

    /// DesktopSize-псевдокодировка (−223): смена размера framebuffer клиента.
    private func sendDesktopSize(_ fd: Int32, w: Int, h: Int) -> Bool {
        var m = [UInt8]()
        m.append(0)                          // FramebufferUpdate
        m.append(0)                          // padding
        m += beU16(1)                        // 1 прямоугольник
        m += beU16(0)                        // x
        m += beU16(0)                        // y
        m += beU16(UInt16(w))
        m += beU16(UInt16(h))
        m += beU32(UInt32(bitPattern: -223)) // encoding = DesktopSize
        return writeAll(fd, m)               // данных у прямоугольника нет
    }

    // MARK: — RFB кадр (RAW)

    private func sendFramebufferRaw(_ fd: Int32, _ bgra: [UInt8], _ w: Int,
                                    _ h: Int, _ pf: PixelFormat) -> Bool {
        let pixels = pf.encode(bgra, width: w, height: h)
        var hdr = [UInt8]()
        hdr.append(0)              // message-type: FramebufferUpdate
        hdr.append(0)              // padding
        hdr += beU16(1)            // одно прямоугольник
        hdr += beU16(0)            // x
        hdr += beU16(0)            // y
        hdr += beU16(UInt16(w))
        hdr += beU16(UInt16(h))
        hdr += beU32(0)            // encoding = Raw
        if !writeAll(fd, hdr) { return false }
        return writeAll(fd, pixels)
    }

    // 1×1 полностью прозрачный курсор через Cursor-псевдокодировку (−239) —
    // клиент прячет свой локальный курсор (0×0 RealVNC игнорирует).
    private func sendTransparentCursor(_ fd: Int32, _ pf: PixelFormat) -> Bool {
        var m = [UInt8]()
        m.append(0)                          // FramebufferUpdate
        m.append(0)                          // padding
        m += beU16(1)                        // 1 прямоугольник
        m += beU16(0)                        // hotspot x
        m += beU16(0)                        // hotspot y
        m += beU16(1)                        // width = 1
        m += beU16(1)                        // height = 1
        m += beU32(UInt32(bitPattern: -239)) // encoding = Cursor
        m += [UInt8](repeating: 0, count: pf.bytesPerPixel)  // 1 пиксель
        m.append(0)                          // маска: 1 байт, бит=0 → прозрачно
        return writeAll(fd, m)
    }

    private func sendEmptyUpdate(_ fd: Int32) -> Bool {
        var hdr = [UInt8]()
        hdr.append(0)      // FramebufferUpdate
        hdr.append(0)      // padding
        hdr += beU16(0)    // 0 прямоугольников
        return writeAll(fd, hdr)
    }

    private func sendFramebufferZlib(_ fd: Int32, _ bgra: [UInt8], _ w: Int,
                                     _ h: Int, _ pf: PixelFormat,
                                     _ deflater: Deflater) -> Bool {
        let pixels = pf.encode(bgra, width: w, height: h)
        let comp = deflater.compress(pixels)
        var hdr = [UInt8]()
        hdr.append(0)              // FramebufferUpdate
        hdr.append(0)              // padding
        hdr += beU16(1)            // одно прямоугольник
        hdr += beU16(0)            // x
        hdr += beU16(0)            // y
        hdr += beU16(UInt16(w))
        hdr += beU16(UInt16(h))
        hdr += beU32(6)            // encoding = zlib
        hdr += beU32(UInt32(comp.count))  // длина сжатых данных
        if !writeAll(fd, hdr) { return false }
        return writeAll(fd, comp)
    }

    private func pixelFormat() -> [UInt8] {
        // 32bpp, depth 24, LE, truecolor, BGRA (redShift16, greenShift8, blueShift0)
        var p = [UInt8]()
        p.append(32)   // bits-per-pixel
        p.append(24)   // depth
        p.append(0)    // big-endian-flag = 0
        p.append(1)    // true-colour-flag = 1
        p += beU16(255) // red-max
        p += beU16(255) // green-max
        p += beU16(255) // blue-max
        p.append(16)   // red-shift
        p.append(8)    // green-shift
        p.append(0)    // blue-shift
        p += [0, 0, 0] // padding
        return p
    }

    // MARK: — мост к async-захвату

    /// Потокобезопасная ячейка: при таймауте задача может дописать результат
    /// позже, поэтому обычная захваченная переменная тут — гонка.
    private final class FrameBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Frame?
        func set(_ f: Frame?) { lock.lock(); value = f; lock.unlock() }
        func get() -> Frame? { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Мост к async-захвату. С таймаутом: ScreenCaptureKit изредка не
    /// возвращает управление (например, когда дисплей под ним исчезает), и
    /// без таймаута поток сессии залипал навсегда.
    private func grabSync(timeout: Double = 4) -> Frame? {
        let sem = DispatchSemaphore(value: 0)
        let box = FrameBox()
        let cap = capturer
        Task {
            box.set(await cap.grab())
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            Log.writeIfChanged("capture",
                               "захват не ответил за \(Int(timeout)) c — пропускаю кадр")
            return nil
        }
        return box.get()
    }

    // MARK: — сокет-утилиты

    private func readN(_ fd: Int32, _ n: Int) -> [UInt8]? {
        if n == 0 { return [] }
        var buf = [UInt8](repeating: 0, count: n)
        var got = 0
        while got < n {
            let r = buf.withUnsafeMutableBytes { p in
                recv(fd, p.baseAddress!.advanced(by: got), n - got, 0)
            }
            if r <= 0 {
                // Разделяем «клиент закрыл» и «молча пропал» (таймаут по
                // SO_RCVTIMEO) — второй случай и был вчерашним зависанием.
                let e = errno
                Log.write("rfb", r == 0 ? "клиент закрыл соединение"
                    : (e == EAGAIN || e == EWOULDBLOCK
                        ? "таймаут чтения — клиент пропал молча"
                        : "ошибка recv errno=\(e)"))
                return nil
            }
            got += r
        }
        return buf
    }

    private func writeAll(_ fd: Int32, _ data: [UInt8]) -> Bool {
        var sent = 0
        let n = data.count
        return data.withUnsafeBytes { p -> Bool in
            while sent < n {
                let r = send(fd, p.baseAddress!.advanced(by: sent), n - sent, 0)
                if r <= 0 { return false }
                sent += r
            }
            return true
        }
    }

    private func beU16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xff)] }
    private func beU32(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff),
         UInt8(v >> 8 & 0xff), UInt8(v & 0xff)]
    }
}
