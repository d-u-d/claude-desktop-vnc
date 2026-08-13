// Захват картинки для RFB в сырой BGRA-буфер.
//
// Два режима. Основной — захват ЦЕЛИКОМ виртуального дисплея: его геометрия
// (origin, размер, масштаб) не меняется всю сессию, поэтому координаты мыши
// сходятся точно. Захват окна оставлен фолбэком на случай, когда виртуалки
// нет: размер окна Claude плавает прямо во время сессии (в логах было
// 1024x737 → 1048x737 → 601x401), и координаты из-за этого уезжали.
//
// Класс намеренно НЕ актор: SCScreenshotManager изредка не возвращает
// управление, а изоляция актора выстраивала все захваты в одну очередь — одно
// зависание вешало и текущую сессию, и все новые подключения. Здесь замком
// защищён только кэш источника, сам захват идёт параллельно.
import Cocoa
import ScreenCaptureKit
import CoreGraphics

struct Frame {
    let width: Int
    let height: Int
    let bgra: [UInt8]   // width*height*4, порядок байт B,G,R,A (little-endian пиксель 0xAARRGGBB)
    let originX: CGFloat // левый край источника в глобальных точках экрана
    let originY: CGFloat // верхний край источника в глобальных точках экрана
    let scale: CGFloat   // пикселей кадра на одну глобальную точку экрана
}

final class WindowCapturer: @unchecked Sendable {
    private let targetApp: String

    // Кэш перечисления: полный обход SCShareableContent стоит 100–300 мс на
    // вызов, поэтому источник/фильтр/размеры переиспользуем и пересоздаём не
    // чаще раза в ~2 секунды (или при ошибке захвата по кэшу).
    private struct Cached {
        let filter: SCContentFilter
        let win: SCWindow?           // режим окна
        let display: CGRect?         // режим дисплея: его bounds в точках
        let w: Int, h: Int           // размеры кадра в пикселях
    }

    private let lock = NSLock()
    private var targetDisplay: CGDirectDisplayID?   // nil — режим окна
    private var cache: Cached?
    private var lastEnumeration: CFAbsoluteTime = 0
    private static let refreshInterval: CFAbsoluteTime = 2.0

    init(app: String) { self.targetApp = app }

    /// Переключить источник: дисплей (виртуалка) или окно Claude (nil).
    func setDisplay(_ id: CGDirectDisplayID?) {
        lock.lock()
        guard id != targetDisplay else { lock.unlock(); return }
        targetDisplay = id
        cache = nil
        lastEnumeration = 0
        lock.unlock()
        Log.write("capture", "источник: "
            + (id.map { "дисплей id=\($0)" } ?? "окно \(targetApp)"))
    }

    /// Снять текущий кадр. Возвращает nil, если источника нет или нет прав.
    func grab() async -> Frame? {
        // Свежий кэш — снимаем кадр без перечисления.
        if let c = freshCache() {
            if let frame = await capture(c) { return frame }
            invalidate()   // окно закрыто, дисплей исчез — пересоберём источник
        }
        guard let c = await enumerateSource() else { return nil }
        store(c)
        return await capture(c)
    }

    // MARK: — кэш источника

    private func freshCache() -> Cached? {
        lock.lock(); defer { lock.unlock() }
        guard let c = cache,
              CFAbsoluteTimeGetCurrent() - lastEnumeration < Self.refreshInterval
        else { return nil }
        return c
    }

    private func store(_ c: Cached) {
        lock.lock()
        cache = c
        lastEnumeration = CFAbsoluteTimeGetCurrent()
        lock.unlock()
    }

    private func invalidate() {
        lock.lock(); cache = nil; lastEnumeration = 0; lock.unlock()
    }

    private func currentDisplay() -> CGDirectDisplayID? {
        lock.lock(); defer { lock.unlock() }
        return targetDisplay
    }

    // MARK: — сборка источника

    /// Полное перечисление и сборка фильтра. Замок здесь НЕ держим: под await
    /// его удерживать нельзя, да и незачем — худшее следствие гонки в том, что
    /// два кадра перечислят окна дважды.
    private func enumerateSource() async -> Cached? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            return makeDisplayEntry(content) ?? makeWindowEntry(content)
        } catch {
            Log.writeIfChanged("capture", "SCShareableContent: \(error)")
            return nil
        }
    }

    /// Источник — целиком виртуальный дисплей. nil, если он не задан/исчез
    /// (тогда сработает фолбэк на окно).
    private func makeDisplayEntry(_ content: SCShareableContent) -> Cached? {
        guard let id = currentDisplay(),
              let disp = content.displays.first(where: { $0.displayID == id })
        else { return nil }
        let b = CGDisplayBounds(id)
        guard b.width > 0, b.height > 0 else { return nil }
        let filter = SCContentFilter(display: disp, excludingWindows: [])
        let pps = filter.pointPixelScale
        let w = Int((b.width * CGFloat(pps)).rounded())
        let h = Int((b.height * CGFloat(pps)).rounded())
        guard w > 0, h > 0 else { return nil }
        return Cached(filter: filter, win: nil, display: b, w: w, h: h)
    }

    /// Фолбэк: самое крупное окно Claude.
    private func makeWindowEntry(_ content: SCShareableContent) -> Cached? {
        let cands = content.windows.filter {
            $0.owningApplication?.applicationName == targetApp
            && $0.frame.width > 200 && $0.frame.height > 200
        }
        guard let win = cands.max(by: {
            $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
        }), win.frame.width > 0 else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: win)
        let pps = filter.pointPixelScale
        let w = Int(filter.contentRect.width * CGFloat(pps))
        let h = Int(filter.contentRect.height * CGFloat(pps))
        guard w > 0, h > 0 else { return nil }
        return Cached(filter: filter, win: win, display: nil, w: w, h: h)
    }

    // MARK: — сам захват

    /// Снять кадр по готовому источнику. nil — захват не удался.
    private func capture(_ c: Cached) async -> Frame? {
        let cfg = SCStreamConfiguration()
        cfg.width = c.w
        cfg.height = c.h
        cfg.showsCursor = true   // реальный курсор в кадре — точно виден куда клик
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        let started = CFAbsoluteTimeGetCurrent()
        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: c.filter, configuration: cfg)
            let spent = CFAbsoluteTimeGetCurrent() - started
            if spent > 1.5 {   // подозрительно долго — пригодится при разборе
                Log.write("capture", String(format: "кадр снят за %.1f c", spent))
            }
            // Масштаб — из фактических размеров: пиксели кадра к глобальным
            // точкам источника. Так «пиксель кадра → точка экрана» сходится
            // независимо от странностей contentRect/pointPixelScale.
            let pointsWide = c.display?.width ?? c.win?.frame.width ?? 0
            guard pointsWide > 0, image.width > 0 else { return nil }
            let origin = c.display?.origin ?? c.win?.frame.origin ?? .zero
            let scale = CGFloat(image.width) / pointsWide
            return Self.toBGRA(image, originX: origin.x, originY: origin.y,
                               scale: scale)
        } catch {
            Log.writeIfChanged("capture", "captureImage: \(error)")
            return nil
        }
    }


    /// CGImage -> плотный BGRA-буфер (снимаем возможный row padding).
    static func toBGRA(_ image: CGImage, originX: CGFloat,
                       originY: CGFloat, scale: CGFloat) -> Frame? {
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        // BGRA в памяти = alpha-first + little-endian
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        let ok: Bool = buf.withUnsafeMutableBytes { ptr in
            guard let ctx = CGContext(
                data: ptr.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: cs, bitmapInfo: info) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? Frame(width: w, height: h, bgra: buf,
                          originX: originX, originY: originY, scale: scale) : nil
    }
}
