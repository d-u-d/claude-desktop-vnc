// Диагностический лог в /tmp/winvnc.log. Нужен, чтобы разбирать «залипшие»
// сессии постфактум: кто и когда подключился, что вернул betterdisplaycli,
// какая была геометрия. Пишем построчно с меткой времени, потокобезопасно.
import Foundation

enum Log {
    private static let lock = NSLock()
    private static let path = "/tmp/winvnc.log"
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func write(_ tag: String, _ message: String) {
        let line = "\(fmt.string(from: Date())) [\(tag)] \(message)\n"
        lock.lock(); defer { lock.unlock() }
        guard let data = line.data(using: .utf8) else { return }
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile(); fh.write(data); try? fh.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }

    /// Пишем только если строка изменилась с прошлого раза (для геометрии,
    /// которая опрашивается постоянно, но меняется редко).
    private static var lastByTag = [String: String]()
    static func writeIfChanged(_ tag: String, _ message: String) {
        lock.lock()
        let changed = lastByTag[tag] != message
        if changed { lastByTag[tag] = message }
        lock.unlock()
        if changed { write(tag, message) }
    }

    /// Приложение резидентное, лог мог бы расти вечно. При старте: если файл
    /// перевалил за 256 КБ, откладываем его в .prev и начинаем с чистого.
    /// История прошлого запуска при этом сохраняется.
    static func trimIfBig() {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int, size > 256 * 1024 else { return }
        try? fm.removeItem(atPath: path + ".prev")
        try? fm.moveItem(atPath: path, toPath: path + ".prev")
    }

    /// Перехват фатальных сигналов. Обработчик сигнала обязан быть предельно
    /// простым, поэтому пишем сырым write(2) в отдельный файл, без Foundation,
    /// и сразу возвращаем сигналу поведение по умолчанию.
    static func installCrashHandlers() {
        let handler: @convention(c) (Int32) -> Void = { sig in
            let fd = open("/tmp/winvnc.crash", O_WRONLY | O_CREAT | O_APPEND, 0o644)
            if fd >= 0 {
                var name: String
                switch sig {
                case SIGSEGV: name = "SIGSEGV\n"
                case SIGBUS:  name = "SIGBUS\n"
                case SIGILL:  name = "SIGILL\n"
                case SIGABRT: name = "SIGABRT\n"
                case SIGTRAP: name = "SIGTRAP\n"
                case SIGPIPE: name = "SIGPIPE\n"
                default:      name = "сигнал\n"
                }
                name.withUTF8 { _ = Darwin.write(fd, $0.baseAddress, $0.count) }
                close(fd)
            }
            signal(sig, SIG_DFL)
            raise(sig)
        }
        for sig in [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGTRAP] {
            signal(sig, handler)
        }
        NSSetUncaughtExceptionHandler { ex in
            Log.write("crash", "исключение: \(ex.name.rawValue) — \(ex.reason ?? "")")
        }
    }
}
