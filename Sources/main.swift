// WinVNC — резидентное приложение в строке меню.
// Отдаёт окно Claude по RFB (VNC). Этап B: RAW-кодирование, только картинка.
import Cocoa
import ApplicationServices

let kTargetApp = "Claude"
let kPort: UInt16 = 5901
/// Сколько секунд тишины от клиентов считаем признаком зависшей сессии.
/// Меньше периода бездействия обычного клиента быть не должно: живой VNC-клиент
/// шлёт FramebufferUpdateRequest постоянно, так что 45 c тишины — это авария.
let kStaleSeconds: Double = 45

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let capturer = WindowCapturer(app: kTargetApp)
    let resizer = WindowResizer()
    let virtualDisplay = VirtualDisplay()
    var server: RFBServer?
    var status = "старт…"
    private let connLock = NSLock()
    private var clientCount = 0
    private var restoreWork: DispatchWorkItem?
    private var watchdog: DispatchSourceTimer?

    func applicationDidFinishLaunching(_ n: Notification) {
        AppDelegate.shared = self
        Log.installCrashHandlers()
        Log.trimIfBig()
        Log.write("session", "старт приложения")
        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "display",
                                accessibilityDescription: "WinVNC")
            btn.image?.isTemplate = true
        }
        // Запрос Accessibility (нужно для ввода) — добавляет приложение в список
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        // Ошибки виртуалки — в статус меню (колбэки приходят с фоновых потоков)
        virtualDisplay.onStatus = { [weak self] s in
            DispatchQueue.main.async { self?.status = s; self?.refreshMenu() }
        }
        // Ресайзер сам виртуалку не ищет — берёт её границы у VirtualDisplay
        // (тот знает точный displayID из betterdisplaycli).
        resizer.virtualBounds = { [weak self] in self?.virtualDisplay.bounds() }
        // На старте: погасить виртуалку (чтобы за столом не мешала), затем
        // спасти окно, если прошлый сеанс его ужал/оставил на виртуалке.
        DispatchQueue.global().async {
            self.virtualDisplay.disconnect()
            usleep(500_000)
            self.resizer.ensureSaneSize()
        }
        // Сторож: раз в 15 c гасит виртуалку, зависшую без клиентов, и спасает
        // окно (страховка от сценария «клиент отвалился, а дисплей остался»).
        let wd = DispatchSource.makeTimerSource(queue: .global())
        wd.schedule(deadline: .now() + 15, repeating: 15)
        wd.setEventHandler { [weak self] in self?.watchdogTick() }
        wd.resume()
        watchdog = wd
        refreshMenu()
        let srv = RFBServer(port: kPort, capturer: capturer)
        srv.onStatus = { [weak self] s in
            DispatchQueue.main.async { self?.status = s; self?.refreshMenu() }
        }
        srv.onConnect = { [weak self] in self?.clientConnected() }
        srv.onDisconnect = { [weak self] in self?.clientDisconnected() }
        srv.start()
        server = srv
    }

    private func clientConnected() {
        connLock.lock()
        clientCount += 1
        let n = clientCount
        let first = n == 1
        restoreWork?.cancel(); restoreWork = nil   // отменить отложенный возврат/гашение
        connLock.unlock()
        Log.write("session", "клиент подключился, всего клиентов \(n)")
        if first {
            let ok = virtualDisplay.connect()      // поднять виртуалку на первого
            let id = ok ? virtualDisplay.displayID() : nil
            Log.write("session", "виртуалка: connect=\(ok), displayID=" +
                (id.map { String($0) } ?? "нет"))
            if let id = id {
                // Захват — весь виртуальный дисплей (окно там развёрнуто во весь)
                capturer.setDisplay(id)
            } else {
                // Фолбэк: снимаем окно; maximizeForClient() тоже сфолбэчится
                capturer.setDisplay(nil)
                DispatchQueue.main.async {
                    self.status = "виртуалка не поднялась — работаю на физическом"
                    self.refreshMenu()
                }
            }
        }
        resizer.waitUntilStable()                  // доиграть любой возврат
        resizer.maximizeForClient()                // сохранить «дом» + перенести на виртуалку
        resizer.waitUntilStable()                  // дождаться конца анимации ресайза
    }

    private func clientDisconnected() {
        connLock.lock()
        clientCount = max(0, clientCount - 1)
        let left = clientCount
        let none = left == 0
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            Log.write("session", "отложенный возврат: пошёл")
            // Сначала захват обратно на окно — виртуалка сейчас исчезнет.
            // Синхронно: через Task переключение могло опоздать за гашением.
            self.capturer.setDisplay(nil)
            self.resizer.restore()                 // окно назад на физический монитор
            Log.write("session", "restore выполнен")
            let off = self.virtualDisplay.disconnect()   // затем погасить виртуалку
            Log.write("session", "disconnect=\(off)")
            // не погасла: onStatus уже сообщил, сторож дожмёт через ≤15 c
        }
        if none { restoreWork = work }
        connLock.unlock()
        Log.write("session", "клиент отключился, осталось \(left)")
        // Только если через 3 c никто не переподключился (фон: restore делает main.sync).
        if none {
            Log.write("session", "запускаю отложенный возврат через 3 c")
            DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: work)
        }
    }

    /// Сторож (фоновая очередь): клиентов нет, а виртуалка есть — гасим.
    /// Заодно спасаем окно, залипшее в координатах уже исчезнувшей виртуалки.
    ///
    /// Счётчику clientCount одному верить нельзя: если поток сессии завис при
    /// закрытии сокета, onDisconnect не придёт и счётчик навсегда останется >0
    /// (реальный случай: «клиент закрыл соединение» и дальше тишина в логе).
    /// Поэтому «клиент жив» = счётчик >0 И была недавняя активность сессий.
    private func watchdogTick() {
        connLock.lock()
        let count = clientCount
        connLock.unlock()
        // Оба вызова дешёвые (чтение под своим локом, без запуска процессов).
        let live = server?.liveSessions() ?? 0
        let silence = server?.secondsSinceActivity() ?? .infinity
        // Спокойное состояние в лог не пишем: сторож подаёт голос, только
        // когда действительно вмешивается.
        if count > 0 && silence < kStaleSeconds { return }
        if count > 0 {
            // Счётчик говорит «клиенты есть», а сообщений от них давно нет.
            // Перепроверяем активность: между двумя замерами мог подключиться
            // новый клиент (его рукопожатие сразу обновляет метку активности).
            let silenceNow = server?.secondsSinceActivity() ?? .infinity
            guard silenceNow >= kStaleSeconds else {
                Log.write("watchdog", "активность появилась во время проверки — отбой")
                return
            }
            Log.write("watchdog", "зависшая сессия: clientCount=\(count), " +
                "liveSessions=\(live), тишина \(Self.secs(silenceNow)) c — " +
                "обнуляю счётчик и убираюсь принудительно")
            connLock.lock()
            clientCount = 0
            connLock.unlock()
            // Зависший поток может очнуться и позже позвать clientDisconnected():
            // там max(0, clientCount - 1), так что в минус счётчик не уйдёт,
            // а повторная уборка (restore/disconnect) идемпотентна.
            DispatchQueue.main.async {
                self.status = "сторож: зависшая сессия — убираюсь"
                self.refreshMenu()
            }
            // Всё строго вне connLock: restore() делает DispatchQueue.main.sync.
            capturer.setDisplay(nil)
            resizer.restore()
            let off = virtualDisplay.disconnect()
            Log.write("watchdog", "аварийная уборка: restore выполнен, disconnect=\(off)")
            resizer.rescueIfOffscreen()
            return
        }
        // Опрос состояния небыстрый (isConnected дёргает cli) — за это время
        // клиент мог подключиться, поэтому после опроса перепроверяем счётчик.
        let hanging = virtualDisplay.present() || virtualDisplay.isConnected() == true
        if hanging {
            connLock.lock()
            let stillNone = clientCount == 0
            connLock.unlock()
            guard stillNone else {
                Log.write("watchdog", "клиент подключился во время опроса — отбой")
                return
            }
            Log.write("watchdog", "гашу зависшую виртуалку")
            DispatchQueue.main.async {
                self.status = "сторож: гашу зависшую виртуалку"; self.refreshMenu()
            }
            // Вне connLock: restore() делает main.sync, под локом был бы риск
            // застрять и заблокировать clientConnected/Disconnected.
            // Если клиент подключится прямо сейчас — не страшно: connect() у него
            // идемпотентен и поднимет виртуалку заново; повторный connect() отсюда
            // не делаем.
            capturer.setDisplay(nil)
            resizer.restore()
            let off = virtualDisplay.disconnect()
            Log.write("watchdog", "restore выполнен, disconnect=\(off)")
        }
        // Даже без виртуалки: окно могло остаться в её бывших координатах
        // (вчерашний сценарий — висело в (-1024,-65), почти не видно).
        // Опрос выше небыстрый — ещё раз убеждаемся, что клиента нет, чтобы не
        // дёргать окно под руками у только что подключившегося.
        connLock.lock()
        let idle = clientCount == 0
        connLock.unlock()
        if idle { resizer.rescueIfOffscreen() }
    }

    /// Секунды для лога и меню: «∞», если активности не было вообще.
    private static func secs(_ s: Double) -> String {
        guard s.isFinite, s < 86_400 else { return "∞" }
        return String(format: "%.0f", max(0, s))
    }

    func applicationWillTerminate(_ n: Notification) {
        // resizer.restore() здесь НЕ зовём: он делает DispatchQueue.main.sync,
        // а applicationWillTerminate уже выполняется на main — дедлок до kill.
        // Окно спасёт ensureSaneSize() при следующем старте, а вот зависшая
        // виртуалка сама не пропадёт — гасим её синхронно перед выходом.
        Log.write("session", "выход из приложения")
        virtualDisplay.disconnect()
    }

    func refreshMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "WinVNC :\(kPort) — \(status)",
                                action: nil, keyEquivalent: ""))
        // Живые сессии и тишина — дешёвые чтения, main-поток не блокируют
        // (в отличие от isConnected(), который дёргает betterdisplaycli).
        let live = server?.liveSessions() ?? 0
        let silence = server?.secondsSinceActivity() ?? .infinity
        let clients = live > 0
            ? "клиентов: \(live) (тишина \(Self.secs(silence)) c)"
            : "клиентов: 0"
        menu.addItem(NSMenuItem(title: clients, action: nil, keyEquivalent: ""))
        let ax = AXIsProcessTrusted() ? "🟢 есть" : "🔴 нет"
        menu.addItem(NSMenuItem(title: "Ввод (Accessibility): \(ax)",
                                action: nil, keyEquivalent: ""))
        // Именно cachedDisplayID: меню строится на main, запускать тут cli нельзя.
        let vd = virtualDisplay.cachedDisplayID().map { "id=\($0)" } ?? "нет"
        menu.addItem(NSMenuItem(title: "Виртуалка: \(vd)",
                                action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Выход", action: #selector(quit),
                                keyEquivalent: "q"))
        for item in menu.items { item.target = self }
        statusItem.menu = menu
    }

    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
