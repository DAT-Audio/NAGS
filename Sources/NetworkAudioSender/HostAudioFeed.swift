import Foundation
import AudioToolbox
import NetworkAudioAtomics

/// The Audio Unit's Send source: **the track's audio**, never
/// the system's — capturing the Mac inside a DAW would send the DAW's own output back round.
///
/// The host's render thread must not lock, allocate or touch a socket, so it only copies the
/// track into a single-producer, single-consumer ring (`write`). A send thread drains the ring
/// every few milliseconds and hands the audio to the Sender's usual chain — meters, then the
/// network — exactly as the system capture does (`onAudio`).
///
/// Costs nothing until used: `write` returns at once while nothing is being sent, and the send
/// thread's timer only exists while something is.
public final class HostAudioFeed: TrackAudioSource, @unchecked Sendable {
    /// Interleaved samples; a power of two, about 0.7 s of 8 channels at 48 kHz.
    private static let capacity = 1 << 18
    private let ring: UnsafeMutablePointer<Float>
    /// Samples written and read, ever (wrapping); the difference is what waits in the ring.
    private var written: UInt64 = 0
    private var read: UInt64 = 0
    /// 1 while sending: the render thread copies only then.
    private var active: UInt32 = 0
    private var rate: UInt32 = 48000
    private var channels: UInt32 = 2
    /// 1: the track carries on to the plugin's output. 0 only while sending with "Pass the track
    /// through while sending" off. Read by the render thread.
    private var pass: UInt32 = 1
    public var passesTrack: Bool { nag_load32(&pass) == 1 }
    public func setPasses(_ on: Bool) { nag_store32(&pass, on ? 1 : 0) }
    /// Frames dropped because the send thread fell behind, for the log.
    private(set) var overruns: UInt64 = 0

    /// Chunks for the chain, at most VBAN's 256 frames of the widest the ring carries.
    private let chunk: UnsafeMutablePointer<Float>
    private static let chunkFrames = 256
    private static let maxChannels = 8
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "Track send", qos: .userInteractive)

    /// Samples (interleaved), frames, channels, rate: on the send thread.
    public var onAudio: ((UnsafePointer<Float>, Int, Int, Int) -> Void)?

    public init() {
        ring = .allocate(capacity: Self.capacity)
        ring.initialize(repeating: 0, count: Self.capacity)
        chunk = .allocate(capacity: Self.chunkFrames * Self.maxChannels)
    }

    deinit {
        timer?.cancel()
        ring.deallocate()
        chunk.deallocate()
    }

    /// The format the host renders at; the render thread reads it, so it is set atomically.
    public func configure(rate: Double, channels: Int) {
        nag_store32(&self.rate, UInt32(max(0, rate)))
        nag_store32(&self.channels, UInt32(min(max(1, channels), Self.maxChannels)))
    }

    public var sampleRate: Int { Int(nag_load32(&rate)) }
    public var channelCount: Int { Int(nag_load32(&channels)) }

    // MARK: Render thread

    /// One buffer of the track, deinterleaved Float32 as the host gives it. Real-time safe.
    public func write(_ abl: UnsafePointer<AudioBufferList>, frames: Int) {
        guard nag_load32(&active) == 1, frames > 0 else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
        let n = min(buffers.count, channelCount)
        guard n > 0 else { return }
        let w = nag_load64(&written)
        let r = nag_load64(&read)
        nag_fence_acquire()
        let free = UInt64(Self.capacity) - (w &- r)
        let samples = frames * n
        guard UInt64(samples) <= free else { overruns &+= UInt64(frames); return }
        let mask = UInt64(Self.capacity - 1)
        for c in 0..<n {
            guard let data = buffers[c].mData?.assumingMemoryBound(to: Float.self) else { continue }
            for f in 0..<frames {
                ring[Int((w &+ UInt64(f * n + c)) & mask)] = data[f]
            }
        }
        nag_fence_release()
        nag_store64(&written, w &+ UInt64(samples))
    }

    // MARK: Main thread

    /// Starts or stops the send thread; the ring is emptied either way.
    public func setActive(_ on: Bool) {
        guard on != (timer != nil) else { return }
        if on {
            nag_store64(&read, nag_load64(&written))
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .milliseconds(1))
            t.setEventHandler { [weak self] in self?.drain() }
            t.resume()
            timer = t
            nag_store32(&active, 1)
        } else {
            nag_store32(&active, 0)
            timer?.cancel()
            timer = nil
        }
    }

    // MARK: Send thread

    private func drain() {
        let n = channelCount
        let rate = sampleRate
        let mask = UInt64(Self.capacity - 1)
        while true {
            let w = nag_load64(&written)
            nag_fence_acquire()
            let r = nag_load64(&read)
            let frames = min(Int((w &- r) / UInt64(n)), Self.chunkFrames)
            guard frames > 0 else { return }
            let samples = frames * n
            for i in 0..<samples { chunk[i] = ring[Int((r &+ UInt64(i)) & mask)] }
            nag_fence_release()
            nag_store64(&read, r &+ UInt64(samples))
            onAudio?(chunk, frames, n, rate)
        }
    }
}
