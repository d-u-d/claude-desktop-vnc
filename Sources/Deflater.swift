// Постоянный zlib-поток на соединение для RFB-кодирования zlib (тип 6).
// Каждый кадр деффлейтится с Z_SYNC_FLUSH — состояние потока сохраняется,
// клиент декодирует единым инфлейт-потоком.
import Foundation

final class Deflater {
    private var strm = z_stream()
    private var ready = false

    init(level: Int32 = 6) {
        let r = deflateInit2_(&strm, level, Z_DEFLATED, 15, 8, Z_DEFAULT_STRATEGY,
                              zlibVersion(), Int32(MemoryLayout<z_stream>.size))
        ready = (r == Z_OK)
    }

    deinit { if ready { deflateEnd(&strm) } }

    /// Сжать блок, поток продолжается (Z_SYNC_FLUSH). Пусто, если инициализация не удалась.
    func compress(_ input: [UInt8]) -> [UInt8] {
        guard ready, !input.isEmpty else { return [] }
        var output = [UInt8]()
        let chunk = 1 << 16
        var buf = [UInt8](repeating: 0, count: chunk)
        input.withUnsafeBufferPointer { inp in
            strm.next_in = UnsafeMutablePointer(mutating: inp.baseAddress)
            strm.avail_in = uInt(input.count)
            repeat {
                buf.withUnsafeMutableBufferPointer { outp in
                    strm.next_out = outp.baseAddress
                    strm.avail_out = uInt(chunk)
                    _ = deflate(&strm, Z_SYNC_FLUSH)
                    let produced = chunk - Int(strm.avail_out)
                    if produced > 0 {
                        output.append(contentsOf: UnsafeBufferPointer(
                            start: outp.baseAddress, count: produced))
                    }
                }
            } while strm.avail_out == 0
        }
        return output
    }
}
