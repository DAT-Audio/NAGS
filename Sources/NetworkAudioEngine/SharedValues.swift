import Foundation
@_exported import NetworkAudioAtomics

/// Floats written on one thread and read on another — a meter's peaks — made once, never
/// resized, each read and written whole (`NetworkAudioAtomics`). For a value on its own; values
/// that must be read together go under a `SeqLock`.
public final class SharedFloats: @unchecked Sendable {
    private let bits: UnsafeMutablePointer<UInt32>
    public let count: Int

    public init(count: Int) {
        self.count = count
        bits = .allocate(capacity: max(1, count))
        bits.initialize(repeating: 0, count: max(1, count))
    }
    deinit { bits.deallocate() }

    @inline(__always) public subscript(_ i: Int) -> Float {
        get { Float(bitPattern: nag_load32(bits + i)) }
        set { nag_store32(bits + i, newValue.bitPattern) }
    }
}

/// A sequence lock: one writer, any number of readers, nobody waits for the writer — which is
/// the audio thread, and must never wait. The writer bumps the counter to odd, writes, bumps it
/// to even; a reader that saw it odd, or saw it change while it read, reads again. For values
/// that only mean something together, such as an envelope's level, target and time.
public final class SeqLock: @unchecked Sendable {
    private let sequence: UnsafeMutablePointer<UInt32>

    public init() {
        sequence = .allocate(capacity: 1)
        sequence.initialize(to: 0)
    }
    deinit { sequence.deallocate() }

    /// Writer only. Never nested.
    @inline(__always) public func write(_ body: () -> Void) {
        let s = nag_load32(sequence)
        nag_store32(sequence, s &+ 1)
        nag_fence_release()
        body()
        nag_store32_release(sequence, s &+ 2)
    }

    /// Readers. A handful of retries at most — a write is a few stores long — and after that the
    /// read stands, which costs one odd meter frame, never a stall on the main thread.
    @inline(__always) public func read<T>(_ body: () -> T) -> T {
        for _ in 0..<8 {
            let before = nag_load32_acquire(sequence)
            guard before & 1 == 0 else { continue }
            let value = body()
            nag_fence_acquire()
            if nag_load32(sequence) == before { return value }
        }
        return body()
    }
}
