import Foundation

/// Loudness measurement to **ITU-R BS.1770-4** / EBU R 128: K-weighting, 400 ms gating blocks
/// at 75 % overlap, the −70 LUFS absolute gate and the −10 LU relative gate.
///
/// Four readings come out of it:
///
/// | Reading | Window | Gated |
/// | --- | --- | --- |
/// | momentary | 400 ms | no |
/// | short-term (`LUFS-S`) | 3 s | no |
/// | window (`LUFS-W`) | user-set, 1…600 s | yes |
/// | integrated (`LUFS-I`) | since the last reset | yes |
///
/// Everything runs on the audio thread inside the render callback, so after `configure` it
/// allocates nothing and takes no locks: the callback writes the readings and the UI polls
/// them, which is the same arrangement the peak meters use.
///
/// **Where it measures matters.** This sits on the summed bus
/// before master level, DIM and MONO, and before the insert slots, so the figures describe the
/// programme rather than how loud you happen to be listening or how the room correction is set.
public final class LoudnessMeter {
    public init() {}


    /// One direct-form-I biquad, coefficients pre-normalised so `a0 == 1`.
    public struct Biquad {
        public var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    }

    /// Filter memory for one biquad on one channel.
    public struct BiquadState {
        public var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

        public mutating func process(_ x: Double, _ c: Biquad) -> Double {
            var y = c.b0 * x + c.b1 * x1 + c.b2 * x2 - c.a1 * y1 - c.a2 * y2
            // A K-weighted tail decays towards denormal, and denormals on the audio thread are
            // an order of magnitude slower to multiply. Flushing well below −300 dBFS costs one
            // compare and is inaudible by any measure.
            if abs(y) < 1e-20 { y = 0 }
            x2 = x1; x1 = x
            y2 = y1; y1 = y
            return y
        }

        public mutating func reset() { x1 = 0; x2 = 0; y1 = 0; y2 = 0 }
    }

    // MARK: - Geometry

    /// The gating block hop. A 400 ms block at 75 % overlap advances 100 ms at a time, so
    /// 100 ms is the natural unit to accumulate in.
    private static let subBlockSeconds = 0.1
    private static let momentarySubBlocks = 4       // 400 ms
    private static let shortTermSubBlocks = 30      // 3 s
    public static let maxWindowSeconds = 600
    private static let windowCapacity = maxWindowSeconds * 10

    /// `−0.691 dB` is the BS.1770 channel-weighting offset.
    private static let offset = -0.691

    /// The absolute gate, as energy rather than LUFS, so the gating loops need no logarithms.
    private static let absoluteGateZ = pow(10.0, (-70.0 - offset) / 10.0)

    // Integrated is unbounded in time, and the relative gate needs the whole distribution of
    // block loudnesses rather than a running mean — so bin them. 0.1 LU bins put the only
    // quantisation on the gate boundary itself, which is what ffmpeg's ebur128 does too.
    private static let binWidth = 0.1
    private static let binLow = -70.0
    private static let binCount = 801               // −70 … +10 LUFS

    // MARK: - Readings, written on the audio thread and polled by the UI

    public private(set) var momentary: Double = -.infinity
    public private(set) var shortTerm: Double = -.infinity
    public private(set) var windowed: Double = -.infinity
    public private(set) var integrated: Double = -.infinity

    /// How many complete 400 ms gating blocks have gone into the integrated reading. The UI
    /// uses it to grey the figure out until there is enough material to mean anything.
    public private(set) var blocksMeasured = 0

    /// Length of the user-set rolling window. Clamped; read on the audio thread.
    public var windowSeconds = 60 {
        didSet { windowSeconds = min(Self.maxWindowSeconds, max(1, windowSeconds)) }
    }

    // MARK: - State

    private var shelf = Biquad()
    private var highPass = Biquad()

    /// One K-weighting chain per bus channel, and the BS.1770 weight that channel carries.
    /// Sized in `configure`, which is the only place this allocates — the render callback runs
    /// over whatever is already here.
    private var shelfState: [BiquadState] = []
    private var highPassState: [BiquadState] = []
    private var weights: [Double] = []
    private var sumSquares: [Double] = []
    public private(set) var channels = 2

    /// The BS.1770-4 channel weights for a bus of this width.
    ///
    /// Left, right and centre count at unity; the surrounds are weighted **+1.5 dB** (a factor
    /// of 1.41 in power) because a sound arriving from behind is perceived louder than the same
    /// sound in front; and the **LFE is excluded entirely** — it is a band-limited effects
    /// channel, not programme.
    ///
    /// A width with no SMPTE layout — a 12- or 16-channel bus, say — has no standard weighting,
    /// and inventing one would be worse than saying so: every channel counts at unity, which
    /// measures what is coming out without claiming to be a compliant reading of a bed.
    public static func channelWeights(for channels: Int) -> [Double] {
        guard let layout = SMPTELayout.forChannelCount(channels) else {
            return [Double](repeating: 1, count: max(1, channels))
        }
        switch layout {
        case .mono, .stereo:
            return [Double](repeating: 1, count: channels)
        case .quad:                         // L R Ls Rs
            return [1, 1, 1.41, 1.41]
        case .surround51:                   // L R C LFE Ls Rs
            return [1, 1, 1, 0, 1.41, 1.41]
        case .surround71:                   // L R C LFE Lss Rss Lrs Rrs
            return [1, 1, 1, 0, 1.41, 1.41, 1.41, 1.41]
        }
    }

    private var subBlockFrames = 4800
    private var framesThisSubBlock = 0

    /// Per-sub-block weighted mean square (`zL + zR`), most recent last. Only the last 30 are
    /// needed, for the momentary and short-term windows.
    private var subBlocks = [Double](repeating: 0, count: shortTermSubBlocks)
    private var subBlockIndex = 0
    private var subBlockCount = 0

    /// Per-gating-block weighted mean square, for the user-set rolling window.
    private var window = [Double](repeating: 0, count: windowCapacity)
    private var windowIndex = 0
    private var windowCount = 0

    private var binEnergy = [Double](repeating: 0, count: binCount)
    private var binPopulation = [Int](repeating: 0, count: binCount)
    private var histogramEnergy = 0.0
    private var histogramCount = 0

    /// Set from the main thread, honoured by the audio thread on its next callback.
    private var resetPending = false

    // MARK: - Setup

    /// Recomputes the K-weighting for `rate` and clears everything. Called whenever the engine
    /// is rebuilt, because the output device's rate can change under us.
    public func configure(rate: Double, channels: Int = 2) {
        let rate = max(8000, rate)
        self.channels = max(1, channels)
        weights = Self.channelWeights(for: self.channels)
        shelfState = Array(repeating: BiquadState(), count: self.channels)
        highPassState = Array(repeating: BiquadState(), count: self.channels)
        sumSquares = [Double](repeating: 0, count: self.channels)
        subBlockFrames = max(1, Int((rate * Self.subBlockSeconds).rounded()))

        // Stage 1 — the high-frequency shelf that stands in for the acoustic effect of a head.
        // Coefficients are derived rather than copied from the spec's 48 kHz table so the
        // weighting is still correct when the output device is running at 44.1 or 96 kHz.
        let shelfF0 = 1681.974450955533
        let shelfGain = 3.999843853973347
        let shelfQ = 0.7071752369554196
        let k = tan(Double.pi * shelfF0 / rate)
        let vh = pow(10, shelfGain / 20)
        let vb = pow(vh, 0.4996667741545416)
        let a0 = 1 + k / shelfQ + k * k
        shelf = Biquad(b0: (vh + vb * k / shelfQ + k * k) / a0,
                       b1: 2 * (k * k - vh) / a0,
                       b2: (vh - vb * k / shelfQ + k * k) / a0,
                       a1: 2 * (k * k - 1) / a0,
                       a2: (1 - k / shelfQ + k * k) / a0)

        // Stage 2 — the RLB high-pass.
        let hpF0 = 38.13547087602444
        let hpQ = 0.5003270373238773
        let k1 = tan(Double.pi * hpF0 / rate)
        let d = 1 + k1 / hpQ + k1 * k1
        highPass = Biquad(b0: 1, b1: -2, b2: 1,
                          a1: 2 * (k1 * k1 - 1) / d,
                          a2: (1 - k1 / hpQ + k1 * k1) / d)

        clear()
    }

    /// Starts the measurement again from nothing. Safe to call from the main thread.
    public func reset() { resetPending = true }

    private func clear() {
        for i in shelfState.indices { shelfState[i].reset(); highPassState[i].reset() }
        framesThisSubBlock = 0
        for i in sumSquares.indices { sumSquares[i] = 0 }
        for i in subBlocks.indices { subBlocks[i] = 0 }
        subBlockIndex = 0; subBlockCount = 0
        for i in window.indices { window[i] = 0 }
        windowIndex = 0; windowCount = 0
        for i in binEnergy.indices { binEnergy[i] = 0; binPopulation[i] = 0 }
        histogramEnergy = 0; histogramCount = 0
        blocksMeasured = 0
        momentary = -.infinity
        shortTerm = -.infinity
        windowed = -.infinity
        integrated = -.infinity
        resetPending = false
    }

    // MARK: - Audio thread

    /// Feeds one render block. `stereo` is false when the output device is mono and both
    /// pointers are the same buffer — measuring that signal twice would read 3 LU hot.
    /// Measures one callback's worth of the monitor bus.
    ///
    /// `buses` is one pointer per bus channel. A channel whose BS.1770 weight is zero — the
    /// LFE — is skipped outright rather than filtered and multiplied by nothing.
    public func process(buses: UnsafePointer<UnsafeMutablePointer<Float>>,
                 channels busCount: Int,
                 frames: Int) {
        if resetPending { clear() }
        // Never run past what `configure` sized: the device can change underneath a callback.
        let count = min(busCount, channels)
        guard count > 0 else { return }

        for i in 0..<frames {
            for c in 0..<count where weights[c] > 0 {
                let filtered = highPassState[c].process(
                    shelfState[c].process(Double(buses[c][i]), shelf), highPass)
                sumSquares[c] += filtered * filtered
            }

            framesThisSubBlock += 1
            if framesThisSubBlock >= subBlockFrames { closeSubBlock() }
        }
    }

    private func closeSubBlock() {
        let n = Double(subBlockFrames)
        // z = Σ G_i · (mean square of channel i), the BS.1770 weighted sum. On a stereo bus
        // both weights are 1 and this is the two mean squares added, exactly as before.
        var z = 0.0
        for c in 0..<channels {
            z += weights[c] * sumSquares[c] / n
            sumSquares[c] = 0
        }
        framesThisSubBlock = 0

        subBlocks[subBlockIndex] = z
        subBlockIndex = (subBlockIndex + 1) % Self.shortTermSubBlocks
        subBlockCount += 1

        momentary = Self.loudness(meanOfRecentSubBlocks(Self.momentarySubBlocks))
        shortTerm = Self.loudness(meanOfRecentSubBlocks(Self.shortTermSubBlocks))

        // A gating block is only complete once four sub-blocks have gone by.
        guard subBlockCount >= Self.momentarySubBlocks else { return }
        let blockZ = meanOfRecentSubBlocks(Self.momentarySubBlocks)
        blocksMeasured += 1

        window[windowIndex] = blockZ
        windowIndex = (windowIndex + 1) % Self.windowCapacity
        if windowCount < Self.windowCapacity { windowCount += 1 }

        // The absolute gate is applied on the way in, so the histogram only ever holds blocks
        // that survive it and the relative gate can be taken straight off the totals.
        if blockZ > Self.absoluteGateZ {
            let index = Self.bin(for: Self.loudness(blockZ))
            binEnergy[index] += blockZ
            binPopulation[index] += 1
            histogramEnergy += blockZ
            histogramCount += 1
        }

        windowed = gatedWindowLoudness()
        integrated = gatedHistogramLoudness()
    }

    /// Mean of the most recent `count` sub-blocks, or of everything so far if fewer have
    /// arrived — which keeps the momentary and short-term figures sensible from the first
    /// tenth of a second rather than reading −∞ for three seconds.
    private func meanOfRecentSubBlocks(_ count: Int) -> Double {
        let available = min(count, min(subBlockCount, Self.shortTermSubBlocks))
        guard available > 0 else { return 0 }
        var sum = 0.0
        var index = subBlockIndex
        for _ in 0..<available {
            index = (index - 1 + Self.shortTermSubBlocks) % Self.shortTermSubBlocks
            sum += subBlocks[index]
        }
        return sum / Double(available)
    }

    /// BS.1770 gating over the rolling window: drop everything below −70 LUFS, take the mean,
    /// then drop everything more than 10 LU below that mean and take the mean again.
    ///
    /// Both passes compare energies rather than loudnesses — `l > Γ` is `z > meanZ / 10` once
    /// the relative gate is written out — so a 6000-block window costs no logarithms.
    private func gatedWindowLoudness() -> Double {
        let wanted = min(windowSeconds * 10, windowCount)
        guard wanted > 0 else { return -.infinity }

        var sum = 0.0
        var kept = 0
        var index = windowIndex
        for _ in 0..<wanted {
            index = (index - 1 + Self.windowCapacity) % Self.windowCapacity
            let z = window[index]
            if z > Self.absoluteGateZ { sum += z; kept += 1 }
        }
        guard kept > 0 else { return -.infinity }

        let relativeGateZ = (sum / Double(kept)) / 10.0
        var gatedSum = 0.0
        var gatedKept = 0
        index = windowIndex
        for _ in 0..<wanted {
            index = (index - 1 + Self.windowCapacity) % Self.windowCapacity
            let z = window[index]
            if z > Self.absoluteGateZ && z > relativeGateZ { gatedSum += z; gatedKept += 1 }
        }
        guard gatedKept > 0 else { return -.infinity }
        return Self.loudness(gatedSum / Double(gatedKept))
    }

    private func gatedHistogramLoudness() -> Double {
        guard histogramCount > 0 else { return -.infinity }
        let relativeGate = Self.loudness(histogramEnergy / Double(histogramCount)) - 10
        // Keep bins whose lower edge sits at or above the gate.
        let first = max(0, Int(((relativeGate - Self.binLow) / Self.binWidth).rounded(.up)))
        guard first < Self.binCount else { return -.infinity }

        var sum = 0.0
        var kept = 0
        for i in first..<Self.binCount {
            sum += binEnergy[i]
            kept += binPopulation[i]
        }
        guard kept > 0 else { return -.infinity }
        return Self.loudness(sum / Double(kept))
    }

    // MARK: - Conversions

    private static func loudness(_ z: Double) -> Double {
        z > 0 ? offset + 10 * log10(z) : -.infinity
    }

    private static func bin(for loudness: Double) -> Int {
        let index = Int(((loudness - binLow) / binWidth).rounded(.down))
        return min(binCount - 1, max(0, index))
    }
}
