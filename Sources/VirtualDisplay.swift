// Управление виртуальным HiDPI-дисплеем iPadVNC через betterdisplaycli.
// Поднимается только на время VNC-сессии (иначе висит в раскладке экранов и
// «ловит» курсор при переходе между мониторами).
// Все вызовы cli — с таймаутом и проверкой результата: однажды виртуалка
// «зависла» из-за молчаливо повисшего betterdisplaycli.
//
// Опознаём виртуалку по НАСТОЯЩЕМУ displayID из `get --identifiers`, а не по
// размеру 1024×768: проверка по размеру врала, если дисплей поднимался с иным
// разрешением — тогда disconnect() рапортовал успех, ничего не погасив.
import Foundation
import CoreGraphics

final class VirtualDisplay {
    private let cli = "/opt/homebrew/bin/betterdisplaycli"
    private let name = "iPadVNC"

    // Размер виртуалки в точках. Не 1024×768: у окна Claude минимальная ширина
    // 1048 точек, оно не влезало и теряло справа 24 точки вместе с полосой
    // прокрутки. 1152×864 — та же пропорция 4:3, окно влезает с запасом.
    private let wantW = 1152, wantH = 864

    /// Колбэк для сообщений об ошибках (подключает main.swift → статус в меню).
    var onStatus: ((String) -> Void)?

    /// Об отсутствии бинарника сообщаем один раз, а не на каждый вызов.
    private var reportedMissingCli = false

    /// Последний подтверждённый ID виртуалки — чтобы отдавать его без запуска
    /// процесса cli (меню и координаты спрашивают часто).
    private let idLock = NSLock()
    private var lastKnownID: CGDirectDisplayID?

    // MARK: — запуск cli

    /// Запуск betterdisplaycli с таймаутом. Если процесс не завершился —
    /// terminate(), полсекунды на выход, затем SIGKILL. capture — собирать stdout.
    private func launch(_ args: [String], timeout: TimeInterval = 10,
                        capture: Bool) -> (ok: Bool, output: String?) {
        guard FileManager.default.isExecutableFile(atPath: cli) else {
            if !reportedMissingCli {
                reportedMissingCli = true
                onStatus?("нет betterdisplaycli — виртуалка недоступна")
                Log.write("vdisp", "не найден \(cli)")
            }
            return (false, nil)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = args
        let pipe = capture ? Pipe() : nil
        p.standardOutput = pipe as Any?
        p.standardError = nil
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch {
            Log.write("vdisp", "не удалось запустить cli \(args.joined(separator: " "))")
            return (false, nil)
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            // Завис (вчерашний сценарий): мягко, потом жёстко.
            p.terminate()
            usleep(500_000)
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            Log.write("vdisp", "ТАЙМАУТ cli: \(args.joined(separator: " "))")
            return (false, nil)
        }
        let ok = p.terminationStatus == 0
        var out: String?
        if let pipe = pipe {
            // Вывод cli маленький — читаем после выхода, буфер пайпа не переполнится.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            out = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (ok, out)
    }

    /// Команда без вывода: true — запустилась и exit-код 0.
    @discardableResult
    private func run(_ args: [String]) -> Bool {
        launch(args, capture: false).ok
    }

    /// Запрос с захватом stdout: trimmed-вывод или nil при любой ошибке.
    private func query(_ args: [String]) -> String? {
        let r = launch(args, capture: true)
        return r.ok ? r.output : nil
    }

    // MARK: — опознание дисплея

    private func activeIDs() -> Set<CGDirectDisplayID> {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count)
        return Set(ids.prefix(Int(count)))
    }

    /// Вытащить displayID из JSON `get --identifiers`. nil, если виртуалка
    /// отключена (UUID = UNKNOWN, displayID = 0) или разобрать не удалось.
    static func parseDisplayID(_ text: String) -> CGDirectDisplayID? {
        if let data = text.data(using: .utf8),
           let any = try? JSONSerialization.jsonObject(with: data),
           let obj = any as? [String: Any] {
            if let uuid = obj["UUID"] as? String,
               uuid.uppercased() == "UNKNOWN" { return nil }
            if let s = obj["displayID"] as? String, let v = UInt32(s), v != 0 {
                return v
            }
            if let n = obj["displayID"] as? NSNumber, n.uint32Value != 0 {
                return n.uint32Value
            }
            return nil
        }
        // Фолбэк без JSON: ищем "displayID" : "27"
        guard let r = text.range(of: "\"displayID\"") else { return nil }
        let tail = text[r.upperBound...]
        let digits = tail.drop { !$0.isNumber }.prefix { $0.isNumber }
        guard let v = UInt32(digits), v != 0 else { return nil }
        return v
    }

    /// Один опрос cli. answered — cli вообще ответил (иначе он мёртв/завис).
    private func probe() -> (answered: Bool, id: CGDirectDisplayID?) {
        guard let out = query(["get", "--name=\(name)", "--identifiers"]) else {
            return (false, nil)
        }
        guard let id = Self.parseDisplayID(out), activeIDs().contains(id) else {
            return (true, nil)   // cli знает про экран, но в системе его нет
        }
        return (true, id)
    }

    private func remember(_ id: CGDirectDisplayID?) {
        idLock.lock(); lastKnownID = id; idLock.unlock()
    }

    /// ID виртуального дисплея (запускает cli). nil — виртуалки нет.
    func displayID() -> CGDirectDisplayID? {
        let r = probe()
        remember(r.id)
        return r.id
    }

    /// То же из кэша, без запуска процесса — можно звать часто (меню, кадры).
    func cachedDisplayID() -> CGDirectDisplayID? {
        idLock.lock(); let id = lastKnownID; idLock.unlock()
        guard let id = id, activeIDs().contains(id) else { return nil }
        return id
    }

    /// Границы виртуального дисплея в глобальных точках.
    func bounds() -> CGRect? {
        if let id = cachedDisplayID() { return CGDisplayBounds(id) }
        if let id = displayID() { return CGDisplayBounds(id) }
        return nil
    }

    /// Запасная проверка по размеру — только когда cli не отвечает вовсе.
    /// Знаем оба размера: текущий и прежний (мало ли, экран поднялся старым).
    private func legacyPresent() -> Bool {
        for id in activeIDs() {
            let b = CGDisplayBounds(id)
            let w = Int(b.width), h = Int(b.height)
            if (w == wantW && h == wantH) || (w == 1024 && h == 768) { return true }
        }
        return false
    }

    /// Виртуалка подключена по данным betterdisplaycli?
    /// nil — cli не ответил (нет бинарника / завис / непонятный вывод).
    func isConnected() -> Bool? {
        guard let out = query(["get", "--name=\(name)", "--connected"])?
            .lowercased() else { return nil }
        if out.contains("off") { return false }   // сначала off: «on» — подстрока
        if out.contains("on") { return true }
        return nil
    }

    /// Виртуалка активна в системе?
    func present() -> Bool {
        let r = probe()
        remember(r.id)
        if r.answered { return r.id != nil }
        return legacyPresent()   // cli молчит — судим по размеру, как раньше
    }

    // MARK: — connect / disconnect

    /// Поднять виртуалку и дождаться появления. Идемпотентно.
    /// До 3 попыток, в каждой ожидание до ~6 c. false — не поднялась.
    func connect() -> Bool {
        if let id = displayID() {
            Log.write("vdisp", "уже поднята id=\(id) bounds=\(CGDisplayBounds(id))")
            return true
        }
        for attempt in 1...3 {
            let on = run(["set", "--name=\(name)", "--connected=on"])
            // Первая попытка — обычное дело, в лог идут только повторы.
            if attempt > 1 {
                Log.write("vdisp", "поднимаю, попытка \(attempt): on=\(on)")
            }
            for _ in 0..<12 {                          // до ~6 c на попытку
                usleep(500_000)
                if let id = displayID() {
                    applyResolution(id)
                    Log.write("vdisp",
                              "поднялась id=\(id) bounds=\(CGDisplayBounds(id))")
                    return true
                }
            }
        }
        onStatus?("виртуалка не поднялась")
        Log.write("vdisp", "ПРОВАЛ: виртуалка не поднялась")
        return false
    }

    /// Выставить нужное разрешение. Команду шлём ТОЛЬКО после того, как экран
    /// реально появился: раньше она уходила сразу за `connected=on`, экран ещё
    /// не существовал, и betterdisplaycli возвращал ошибку (в логах res=false).
    private func applyResolution(_ id: CGDirectDisplayID) {
        let b = CGDisplayBounds(id)
        if Int(b.width) == wantW && Int(b.height) == wantH { return }
        _ = run(["set", "--name=\(name)", "--resolution=\(wantW)x\(wantH)"])
        for _ in 0..<8 {                               // до ~2 c на применение
            usleep(250_000)
            let cur = CGDisplayBounds(id)
            if Int(cur.width) == wantW && Int(cur.height) == wantH { return }
        }
        Log.write("vdisp", "разрешение осталось "
            + "\(Int(CGDisplayBounds(id).width))x\(Int(CGDisplayBounds(id).height))")
    }

    /// Погасить виртуалку и убедиться, что она исчезла.
    /// До 4 попыток, в каждой ожидание до ~3 c. false — не гаснет.
    @discardableResult
    func disconnect() -> Bool {
        for attempt in 1...4 {
            let off = run(["set", "--name=\(name)", "--connected=off"])
            if attempt > 1 {   // первая попытка — норма, пишем только повторы
                Log.write("vdisp", "гашу, попытка \(attempt): off=\(off)")
            }
            for _ in 0..<6 {                           // до ~3 c на попытку
                let r = probe()
                if r.answered {
                    if r.id == nil {
                        remember(nil)
                        Log.write("vdisp", "погасла")
                        return true
                    }
                } else if !legacyPresent() {
                    remember(nil)
                    Log.write("vdisp", "cli молчит, по размеру виртуалки нет")
                    return true
                }
                usleep(500_000)
            }
        }
        onStatus?("виртуалка не гаснет!")
        Log.write("vdisp", "ПРОВАЛ: виртуалка не гаснет")
        return false
    }
}
