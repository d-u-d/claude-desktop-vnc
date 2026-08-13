// Формат пикселей RFB и конвертация нашего BGRA-кадра в формат, запрошенный
// клиентом (SetPixelFormat). Поддерживаем truecolor 8/16/32 bpp с любыми
// масками и порядком байт.
import Foundation

struct PixelFormat {
    var bpp: Int = 32
    var depth: Int = 24
    var bigEndian: Bool = false
    var trueColor: Bool = true
    var rMax: Int = 255, gMax: Int = 255, bMax: Int = 255
    var rShift: Int = 16, gShift: Int = 8, bShift: Int = 0

    static let defaultBGRA = PixelFormat()

    /// 16 байт pixel-format из SetPixelFormat -> структура.
    static func parse(_ p: [UInt8]) -> PixelFormat {
        var f = PixelFormat()
        f.bpp = Int(p[0]); f.depth = Int(p[1])
        f.bigEndian = p[2] != 0; f.trueColor = p[3] != 0
        f.rMax = Int(p[4]) << 8 | Int(p[5])
        f.gMax = Int(p[6]) << 8 | Int(p[7])
        f.bMax = Int(p[8]) << 8 | Int(p[9])
        f.rShift = Int(p[10]); f.gShift = Int(p[11]); f.bShift = Int(p[12])
        return f
    }

    var bytesPerPixel: Int { bpp / 8 }

    /// Конвертировать BGRA-кадр (B,G,R,A на пиксель) в этот формат.
    func encode(_ bgra: [UInt8], width: Int, height: Int) -> [UInt8] {
        let bpp8 = bytesPerPixel
        let n = width * height
        var out = [UInt8](repeating: 0, count: n * bpp8)
        // Быстрый путь для нашего дефолта (32bpp BGRA LE) — байты уже готовы
        if bpp == 32 && !bigEndian && rShift == 16 && gShift == 8 && bShift == 0
            && rMax == 255 && gMax == 255 && bMax == 255 {
            return bgra
        }
        bgra.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                var si = 0, di = 0
                for _ in 0..<n {
                    let b = Int(src[si]); let g = Int(src[si+1]); let r = Int(src[si+2])
                    let rr = (r * rMax) / 255
                    let gg = (g * gMax) / 255
                    let bb = (b * bMax) / 255
                    let v = UInt32((rr << rShift) | (gg << gShift) | (bb << bShift))
                    if bigEndian {
                        for k in 0..<bpp8 {
                            dst[di + k] = UInt8((v >> (8 * (bpp8 - 1 - k))) & 0xff)
                        }
                    } else {
                        for k in 0..<bpp8 {
                            dst[di + k] = UInt8((v >> (8 * k)) & 0xff)
                        }
                    }
                    si += 4; di += bpp8
                }
            }
        }
        return out
    }
}
