import Foundation
import Compression

/// The Mac's zlib for compressed SAP announcements (`SAPListener.inflate`: the
/// listener is in the engine, which has no Compression framework).
enum SAPInflate {
    /// SAP compression is zlib; Compression's ZLIB algorithm wants a raw deflate stream,
    /// so drop the 2-byte zlib header when it is present.
    static func inflate(_ data: [UInt8]) -> [UInt8]? {
        var input = data
        if input.count > 2, input[0] & 0x0F == 8 { input.removeFirst(2) }
        let capacity = 256 * 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { dst.deallocate() }
        let written = input.withUnsafeBufferPointer { src -> Int in
            guard let base = src.baseAddress else { return 0 }
            return compression_decode_buffer(dst, capacity, base, src.count, nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else { return nil }
        return Array(UnsafeBufferPointer(start: dst, count: written))
    }
}
