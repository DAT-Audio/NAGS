import Foundation

/// A bounds-checked cursor over an untrusted packet. Every read says whether the
/// bytes were there, so a parser built on it cannot read past the end of a datagram however the
/// datagram lies about its own lengths. **New protocol parsers use this**, and are added to
/// `--fuzzcheck`.
public struct ByteReader {
    private let base: UnsafePointer<UInt8>
    public let count: Int
    public private(set) var offset = 0

    public init(_ base: UnsafePointer<UInt8>, count: Int) {
        self.base = base
        self.count = max(0, count)
    }

    public var remaining: Int { count - offset }

    public mutating func u8() -> UInt8? {
        guard remaining >= 1 else { return nil }
        defer { offset += 1 }
        return base[offset]
    }

    public mutating func u16be() -> UInt16? {
        guard remaining >= 2 else { return nil }
        defer { offset += 2 }
        return UInt16(base[offset]) << 8 | UInt16(base[offset + 1])
    }

    public mutating func u16le() -> UInt16? {
        guard remaining >= 2 else { return nil }
        defer { offset += 2 }
        return UInt16(base[offset]) | UInt16(base[offset + 1]) << 8
    }

    public mutating func u32be() -> UInt32? {
        guard let hi = u16be(), let lo = u16be() else { return nil }
        return UInt32(hi) << 16 | UInt32(lo)
    }

    public mutating func u32le() -> UInt32? {
        guard let lo = u16le(), let hi = u16le() else { return nil }
        return UInt32(hi) << 16 | UInt32(lo)
    }

    /// The next `n` bytes, in place, or nil if they are not all there.
    public mutating func bytes(_ n: Int) -> UnsafeBufferPointer<UInt8>? {
        guard n >= 0, remaining >= n else { return nil }
        defer { offset += n }
        return UnsafeBufferPointer(start: base + offset, count: n)
    }

    public mutating func skip(_ n: Int) -> Bool { bytes(n) != nil }

    /// Everything not yet read.
    public mutating func rest() -> UnsafeBufferPointer<UInt8> { bytes(remaining)! }
}
