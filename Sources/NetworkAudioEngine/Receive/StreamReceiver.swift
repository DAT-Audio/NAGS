import Foundation
import NetworkAudioAtomics

/// Everything a received stream does once its packets are decoded to float, whatever carried
/// them: the ring buffer, the drift-controlled playout, the fold-down taps, gain and mute, the
/// meters and the arrival figures.
///
/// A transport subclasses this and supplies only `start`/`stop`, the packet parse and the
/// decode into `scratch`, then hands each packet over with `deliver(frames:)`. `RTPReceiver` is
/// the AES67 one. Sender and receiver clocks are never locked on any transport this app
/// receives, so the drift control here is common to all of them.
open class StreamReceiver {
    public let stream: StreamDescription
    public let ring: RingBuffer

    /// Playout target in frames — how much audio we try to keep buffered.
    public private(set) var targetFrames: Int

    // Consumer-side drift control (audio thread only).
    private var smoothedFill: Double
    public private(set) var ratio: Double = 1.0
    private var primed = false

    // Statistics (plain counters; read for display only).
    public private(set) var packetsReceived: UInt64 = 0
    public private(set) var packetsLost: UInt64 = 0
    public private(set) var underruns: UInt64 = 0
    public private(set) var lastPacketAt: CFAbsoluteTime = 0
    public private(set) var signalPeak: Float = 0

    /// Per-input-channel peaks, measured on the network thread as packets are decoded, so they
    /// are independent of the fold-down and refresh at packet rate rather than callback rate.
    /// Written by one thread and read by the UI; a torn float would cost one wrong meter frame,
    /// which is not worth a lock in the receive path.
    /// Written by the network thread, read by the meters (`SharedFloats`).
    private let channelPeaks: SharedFloats
    private let peakDecay: Float

    // Per-stream monitoring controls (set from the UI).
    public var gain: Float = 1.0
    public var muted: Bool = false
    public private(set) var mixMode: MixMode = .pair(0)

    /// Channel indices being soloed within this stream. Empty is the normal case.
    public private(set) var soloedChannels: Set<Int> = []

    /// Mix taps are double-buffered: the UI fills the slot the audio thread is not reading and
    /// then flips `activeTapSlot`. A 32-bit aligned store is atomic on Apple silicon, so the
    /// render block always sees a complete, self-consistent tap list without taking a lock.
    private let tapSlots: [UnsafeMutablePointer<MixTap>]
    private var tapCounts: [Int] = [0, 0]
    private var activeTapSlot: Int32 = 0

    /// Where a subclass decodes one packet, interleaved, before `deliver(frames:)`.
    public let scratch: UnsafeMutablePointer<Float>
    public let maxPacketFrames = 4096

    public init(stream: StreamDescription, latencyMs: Double) {
        self.stream = stream
        let target = max(stream.framesPerPacket * 2,
                         Int(latencyMs * Double(stream.sampleRate) / 1000.0))
        targetFrames = target
        smoothedFill = Double(target)
        // One second of headroom, at least eight times the playout target.
        let capacity = max(stream.sampleRate, target * 8)
        ring = RingBuffer(channels: stream.channels, capacityFrames: capacity)
        scratch = .allocate(capacity: maxPacketFrames * stream.channels)
        channelPeaks = SharedFloats(count: stream.channels)
        // ~200 ms fall time, applied once per packet.
        let dt = Double(stream.framesPerPacket) / Double(stream.sampleRate)
        peakDecay = Float(exp(-dt / 0.2))
        tapSlots = [.allocate(capacity: stream.channels), .allocate(capacity: stream.channels)]
        setMix(.pair(0), includeLFE: false, trimDB: -3)
    }

    deinit {
        scratch.deallocate()
        tapSlots.forEach { $0.deallocate() }
    }

    /// Starts receiving. Returns an error message on failure. Supplied by each transport.
    open func start(interfaceAddress: String) -> String? { nil }

    open func stop() {}

    /// Rebuilds the channel fold-down. Safe to call while audio is running.
    /// How wide the monitor bus is. Set by `AudioOutput` when the bus changes; the taps are
    /// rebuilt after it, because a pass-through means nothing without it.
    public var busChannels = 2

    /// The order this stream's channels are assumed to arrive in. Nothing in the protocol says,
    /// so it is an assumption per stream — see `ChannelOrder`.
    public private(set) var channelOrder: ChannelOrder = .smpte

    public final func setMix(_ mode: MixMode, includeLFE: Bool, trimDB: Double,
                      order: ChannelOrder = .smpte, soloed: Set<Int> = []) {
        mixMode = mode
        channelOrder = order
        soloedChannels = soloed
        let taps = Downmix.taps(channels: stream.channels, busChannels: busChannels, mode: mode,
                                order: order, includeLFE: includeLFE, trimDB: trimDB,
                                soloed: soloed)
        let target = Int(1 - activeTapSlot)
        let count = min(taps.count, stream.channels)
        for i in 0..<count { tapSlots[target][i] = taps[i] }
        tapCounts[target] = count
        activeTapSlot = Int32(target)
    }

    public var isReceiving: Bool { CFAbsoluteTimeGetCurrent() - lastPacketAt < receivingWindow }

    /// How long without audio before a stream counts as not receiving. A second for the LAN
    /// transports; longer for a buffered stream, which pauses its own reading while its buffer is
    /// full.
    public var receivingWindow: CFAbsoluteTime = 1.0
    /// Whether a pause over a second counts as a gap (a dropout). Not for a buffered stream,
    /// whose pauses are its own flow control; its reconnects say when it really dropped.
    public var countsArrivalGaps = true

    /// Packet arrival jitter, in milliseconds: RFC 3550's smoothed interarrival jitter and the
    /// worst single deviation from the stream's packet time. This is the number that says whether
    /// the buffer a stream needs is the network's fault or ours.
    public private(set) var jitterMs: Double = 0
    public private(set) var worstJitterMs: Double = 0
    /// Pauses of over a second between packets, and the latest one's length. A pause is not
    /// jitter in the network's sense — the sender stopped, or its capture was rebuilt — but it
    /// lands in `worstJitterMs` all the same, so the log says when one happened.
    public private(set) var gaps = 0
    public private(set) var lastGapMs: Double = 0
    private var lastArrival: CFAbsoluteTime = 0

    // MARK: Arrival test
    //
    // For "Test the connection": how far each packet lands from a steady clock over the test —
    // the spread a buffer has to cover — and how many go missing. Only listens; costs a flag
    // check per packet when no test runs.
    private var testing: UInt32 = 0
    private let testLock = NSLock()
    private var testStart: CFAbsoluteTime = 0
    private var testFrames = 0
    private var testOffsets: [Double] = []
    private var testLostAtStart: UInt64 = 0
    private var testPacketsAtStart: UInt64 = 0

    public struct ArrivalTest {
        /// Milliseconds: how far packets landed from a steady clock (99.5 % of them, and all).
        public let spreadMs: Double
        public let worstMs: Double
        public let packets: UInt64
        public let lost: UInt64
        public let packetMs: Double
    }

    public func beginArrivalTest() {
        testLock.lock()
        testOffsets.removeAll(keepingCapacity: true)
        testOffsets.reserveCapacity(12_000)
        testStart = 0
        testFrames = 0
        testLostAtStart = packetsLost
        testPacketsAtStart = packetsReceived
        testLock.unlock()
        nag_store32(&testing, 1)
    }

    public func endArrivalTest() -> ArrivalTest? {
        nag_store32(&testing, 0)
        testLock.lock(); defer { testLock.unlock() }
        guard testOffsets.count > 20 else { return nil }
        // Offsets against the steady clock, less their slow trend (the two clocks' drift),
        // measured from the earliest: what the buffer must absorb.
        let n = Double(testOffsets.count)
        let xs = (0..<testOffsets.count).map(Double.init)
        let mx = xs.reduce(0, +) / n, my = testOffsets.reduce(0, +) / n
        let sxy = zip(xs, testOffsets).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
        let sxx = xs.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
        let slope = sxx > 0 ? sxy / sxx : 0
        let detrended = zip(xs, testOffsets).map { $1 - slope * ($0 - mx) }.sorted()
        let low = detrended.first ?? 0
        let p995 = detrended[min(detrended.count - 1, Int(Double(detrended.count) * 0.995))]
        return ArrivalTest(spreadMs: (p995 - low) * 1000, worstMs: ((detrended.last ?? 0) - low) * 1000,
                           packets: packetsReceived - testPacketsAtStart, lost: packetsLost - testLostAtStart,
                           packetMs: Double(stream.framesPerPacket) / Double(stream.sampleRate) * 1000)
    }

    private func recordArrival(_ arrival: CFAbsoluteTime, frames: Int) {
        testLock.lock()
        if testStart == 0 { testStart = arrival }
        let expected = testStart + Double(testFrames) / Double(stream.sampleRate)
        testOffsets.append(arrival - expected)
        testFrames += frames
        testLock.unlock()
    }

    /// Lowest buffer fill seen since priming, in frames. What headroom was *actually* used.
    public private(set) var minBufferFrames: Double = .infinity

    /// Fraction of the target the fill may wander either side before the rate is corrected.
    /// Set by a receiver whose arrival is bursty by nature (`WebStreamReceiver`).
    public var driftDeadband: Double = 0

    /// The playout target actually in force, in frames. Differs from the user's latency setting
    /// whenever the render block forces it higher, which is the thing worth seeing.
    public private(set) var playoutTargetFrames: Double = 0

    public final func setLatency(ms: Double) {
        let target = max(stream.framesPerPacket * 2, Int(ms * Double(stream.sampleRate) / 1000.0))
        targetFrames = min(target, ring.capacityFrames / 4)
        primed = false
    }

    // MARK: - Network thread

    /// Counts lost packets and, when the gap is short enough to be worth it, pads the ring with
    /// silence so channel alignment and timing survive the loss.
    public final func recordLoss(packets: Int, silenceFrames: Int) {
        packetsLost += UInt64(packets)
        if silenceFrames > 0 { ring.writeSilence(frames: silenceFrames) }
    }

    /// Takes one packet already decoded into `scratch`: meters it, buffers it, and updates the
    /// arrival figures.
    public final func deliver(frames: Int) {
        measureChannelPeaks(frames: frames)
        ring.write(scratch, frames: frames)
        packetsReceived += 1
        let arrival = CFAbsoluteTimeGetCurrent()
        lastPacketAt = arrival
        if nag_load32(&testing) == 1 { recordArrival(arrival, frames: frames) }
        if lastArrival > 0 {
            let gap = (arrival - lastArrival) * 1000
            let expected = Double(frames) / Double(stream.sampleRate) * 1000
            let deviation = abs(gap - expected)
            jitterMs += (deviation - jitterMs) / 16      // RFC 3550's 1/16 gain
            if deviation > worstJitterMs { worstJitterMs = deviation }
            if gap > 1000, countsArrivalGaps { gaps += 1; lastGapMs = gap }
        }
        lastArrival = arrival
    }

    /// Peak per channel over this packet, decayed towards zero so the meters fall smoothly.
    private func measureChannelPeaks(frames: Int) {
        let channels = stream.channels
        for c in 0..<channels {
            var peak: Float = 0
            var i = c
            while i < frames * channels {
                peak = max(peak, abs(scratch[i]))
                i += channels
            }
            channelPeaks[c] = max(peak, channelPeaks[c] * peakDecay)
        }
    }

    /// Level of one input channel, 0…1. Zero while no packets are arriving, so a dead stream
    /// reads empty rather than frozen at its last value.
    public final func channelPeak(_ index: Int) -> Float {
        guard index >= 0, index < stream.channels, isReceiving else { return 0 }
        return channelPeaks[index]
    }

    // MARK: - Audio thread

    /// Called from the render block. Mixes this stream into the stereo bus.
    public final func render(into buses: UnsafePointer<UnsafeMutablePointer<Float>>, busCount: Int,
                      frames: Int, outputRate: Double) {
        let available = ring.availableFrames
        let nominal = Double(stream.sampleRate) / outputRate

        // The playout target is the requested latency, but never less than one render block
        // plus a couple of packets of slack — otherwise a device with a large buffer size
        // would underrun on every callback no matter how healthy the network is.
        let target = min(Double(ring.capacityFrames / 4),
                         max(Double(targetFrames),
                             Double(frames) * nominal + Double(stream.framesPerPacket) * 2))

        playoutTargetFrames = target

        // Prime on first render, and recover from gross buffer errors, by dropping to target.
        if !primed || available > target * 4 || available < 0 {
            guard available >= target else { return }
            ring.resync(keepFrames: Int(target))
            smoothedFill = target
            primed = true
            minBufferFrames = .infinity
        }
        if available < minBufferFrames { minBufferFrames = available }

        // Slow proportional control: pull the fill back to target with at most ±0.25 % of
        // rate change, which is well below audibility for monitoring and covers any real
        // PTP-vs-CoreAudio drift (typically under 100 ppm).
        smoothedFill += (available - smoothedFill) * 0.002
        // A buffered stream's fill swings by design — it arrives in bursts, a decoded frame of
        // audio at a time — so within its dead band it plays at exactly its own rate, and only
        // a real drift beyond it is corrected. Zero for the clocked transports, as before.
        var error = smoothedFill - target
        let band = driftDeadband * target
        error = abs(error) <= band ? 0 : error - (error > 0 ? band : -band)
        let rateCorrection = error / target * 0.05
        ratio = nominal * min(max(1.0 + rateCorrection, 0.9975), 1.0025)

        // Muted streams are still consumed, otherwise the buffer runs away while muted.
        var peak: Float = 0
        let slot = Int(activeTapSlot)
        let ok = ring.mix(into: buses, busCount: busCount, frames: frames, ratio: ratio,
                          taps: tapSlots[slot], tapCount: tapCounts[slot],
                          gain: muted ? 0 : gain, peak: &peak)
        if ok {
            signalPeak = max(peak, signalPeak * 0.88)
        } else {
            underruns += 1
            primed = false
        }
    }

    // MARK: - Little-endian PCM

    /// Little-endian PCM — integers or floats — into `scratch`. VBAN and Scream both send it;
    /// AES67's big-endian formats are `RTPReceiver`'s. `count` is samples, all channels.
    public final func decodeLittleEndian(_ src: UnsafePointer<UInt8>, count: Int) {
        let dst = scratch
        switch stream.encoding {
        case .PCM16:
            let scale = Float(1.0 / 32768.0)
            for i in 0..<count {
                let b = src + i * 2
                dst[i] = Float(Int16(bitPattern: UInt16(b[0]) | UInt16(b[1]) << 8)) * scale
            }
        case .PCM24:
            let scale = Float(1.0 / 8388608.0)
            for i in 0..<count {
                let b = src + i * 3
                var v = Int32(b[0]) | Int32(b[1]) << 8 | Int32(b[2]) << 16
                if v & 0x800000 != 0 { v -= 0x1000000 }                  // sign-extend 24-bit
                dst[i] = Float(v) * scale
            }
        case .PCM32:
            let scale = Float(1.0 / 2147483648.0)
            for i in 0..<count {
                dst[i] = Float(Int32(bitPattern: word32(src + i * 4))) * scale
            }
        case .F32:
            for i in 0..<count {
                dst[i] = finite(Float(bitPattern: word32(src + i * 4)))
            }
        case .F64:
            for i in 0..<count {
                let b = src + i * 8
                let u = UInt64(word32(b)) | UInt64(word32(b + 4)) << 32
                dst[i] = finite(Float(Double(bitPattern: u)))
            }
        case .L16, .L24, .L32:
            break                                                     // AES67's, big-endian
        }
    }

    private func word32(_ b: UnsafePointer<UInt8>) -> UInt32 {
        UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
    }

    /// A float stream can carry NaN or infinity, by accident or on purpose, and one of either
    /// in the bus would poison the loudness measurement and every meter downstream.
    private func finite(_ v: Float) -> Float { v.isFinite ? v : 0 }
}
