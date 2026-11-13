import Foundation

/// Single-producer / single-consumer interleaved float ring buffer.
///
/// The network thread writes whole packets; the audio render thread reads with a *fractional*
/// step so the caller can gently resample to absorb the drift between the sender's PTP clock
/// and this Mac's audio clock. Only the write counter is shared, and it is guarded by an
/// `AudioLock` (`os_unfair_lock` on the Mac) held for a couple of instructions (it donates priority, so the audio
/// thread cannot be inverted by the network thread).
public final class RingBuffer {
    public let channels: Int
    public let capacityFrames: Int

    private let storage: UnsafeMutablePointer<Float>
    private let lock = AudioLock()
    private var writeFrames: Int64 = 0      // shared, lock-guarded
    private var writeCursor: Int = 0        // producer-only
    private var readFrames: Double = 0      // consumer-only (absolute, fractional)

    public init(channels: Int, capacityFrames: Int) {
        self.channels = max(1, channels)
        self.capacityFrames = capacityFrames
        storage = .allocate(capacity: capacityFrames * self.channels)
        storage.initialize(repeating: 0, count: capacityFrames * self.channels)
    }

    deinit {
        storage.deallocate()
        lock.free()
    }

    private var totalWritten: Int64 {
        lock.acquire()
        let v = writeFrames
        lock.release()
        return v
    }

    // MARK: - Producer

    public func write(_ src: UnsafePointer<Float>, frames: Int) {
        guard frames > 0, frames <= capacityFrames else { return }
        let first = min(frames, capacityFrames - writeCursor)
        storage.advanced(by: writeCursor * channels)
            .update(from: src, count: first * channels)
        if first < frames {
            storage.update(from: src.advanced(by: first * channels), count: (frames - first) * channels)
        }
        writeCursor = (writeCursor + frames) % capacityFrames
        lock.acquire()
        writeFrames += Int64(frames)
        lock.release()
    }

    public func writeSilence(frames: Int) {
        guard frames > 0, frames <= capacityFrames else { return }
        var remaining = frames
        while remaining > 0 {
            let chunk = min(remaining, capacityFrames - writeCursor)
            storage.advanced(by: writeCursor * channels)
                .update(repeating: 0, count: chunk * channels)
            writeCursor = (writeCursor + chunk) % capacityFrames
            remaining -= chunk
        }
        lock.acquire()
        writeFrames += Int64(frames)
        lock.release()
    }

    // MARK: - Consumer

    /// Frames buffered and not yet consumed.
    public var availableFrames: Double { Double(totalWritten) - readFrames }

    /// Drops everything buffered except `keepFrames`, used to prime or recover the buffer.
    public func resync(keepFrames: Int) {
        readFrames = max(0, Double(totalWritten) - Double(keepFrames))
    }

    /// Reads `frames` output frames, advancing by `ratio` input frames per output frame, and
    /// **adds** the result into the stereo destination through the supplied mix taps.
    /// Returns false (writing nothing) when there is not enough buffered audio.
    @discardableResult
    /// Resamples this stream's ring into the monitor bus and sums it there.
    ///
    /// `buses` is one pointer per bus channel, already zeroed by the caller, and every stream
    /// adds into them. Stereo is simply the two-channel case: the taps a fold-down builds target
    /// bus channels 0 and 1 and nothing here knows the difference.
    ///
    /// Peak is taken **per bus channel after summing the taps**, not per tap, so two source
    /// channels folding into the same side report the level they actually make together.
    public func mix(into buses: UnsafePointer<UnsafeMutablePointer<Float>>,
             busCount: Int,
             frames: Int,
             ratio: Double,
             taps: UnsafePointer<MixTap>,
             tapCount: Int,
             gain: Float,
             peak: inout Float) -> Bool {
        let needed = Double(frames) * ratio + 2
        guard availableFrames >= needed, tapCount > 0, busCount > 0 else { return false }

        var pos = readFrames
        let cap = Double(capacityFrames)
        var localPeak: Float = 0

        // Stack scratch for one frame's worth of bus sums — no allocation, so this stays safe
        // on the audio thread. It is what lets the peak be taken after summing rather than
        // during it.
        withUnsafeTemporaryAllocation(of: Float.self, capacity: busCount) { acc in
            for i in 0..<frames {
                let wrapped = pos.truncatingRemainder(dividingBy: cap)
                let i0 = Int(wrapped)
                let frac = Float(wrapped - Double(i0))
                let b0 = i0 * channels
                let b1 = ((i0 + 1) % capacityFrames) * channels

                for b in 0..<busCount { acc[b] = 0 }
                for t in 0..<tapCount {
                    let tap = taps[t]
                    let c = Int(tap.channel)
                    let s0 = storage[b0 + c]
                    let sample = s0 + (storage[b1 + c] - s0) * frac
                    // Bounds-checked because a tap set can outlive the bus width it was built
                    // for: the UI fills the inactive slot and the audio thread picks it up a
                    // callback later, and the device can change underneath both.
                    let a = Int(tap.destA)
                    if a >= 0, a < busCount { acc[a] += sample * tap.gainA }
                    let b = Int(tap.destB)
                    if b >= 0, b < busCount { acc[b] += sample * tap.gainB }
                }
                for b in 0..<busCount {
                    let value = acc[b]
                    buses[b][i] += value * gain
                    localPeak = max(localPeak, abs(value))
                }

                pos += ratio
            }
        }
        readFrames = pos
        peak = localPeak
        return true
    }
}
