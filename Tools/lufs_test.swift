// Checks the loudness meter against closed-form answers. Run it after touching
// `Sources/NetworkAudioGrabber/Audio/Loudness.swift`:
//
//     mkdir -p /tmp/lufs && cp Tools/lufs_test.swift /tmp/lufs/main.swift
//     swiftc -O Sources/NetworkAudioGrabber/Audio/Loudness.swift /tmp/lufs/main.swift -o /tmp/lufs/run
//     /tmp/lufs/run
//
// (The copy to `main.swift` is needed because Swift only allows top-level statements in a file
// with that name.) It covers four things the implementation could get wrong quietly:
//
//   * the K-weighting itself, by comparing a sine's reading to `−0.691 + 20·log10(A·|H(f)|)`
//     at 48, 44.1 and 96 kHz — the derived coefficients are only correct if this holds off 48;
//   * both gates, against corrections worked out by hand for tone-then-silence and
//     tone-then-15-LU-quieter, including the 400 ms blocks that straddle the transition and
//     which BS.1770 does count;
//   * that reset really clears the histogram and the ring;
//   * that the answer does not depend on the render block size it is fed in.
//
// The expected figures are derived, not recorded from a previous run, so this catches a
// regression rather than blessing one.

import Foundation

// Magnitude of the two-stage K-weighting at `f`, taken from the same derivation the meter uses.
func kGainDB(f: Double, rate: Double) -> Double {
    func mag(_ b0: Double, _ b1: Double, _ b2: Double, _ a1: Double, _ a2: Double) -> Double {
        let w = 2 * Double.pi * f / rate
        let (c1, s1) = (cos(w), sin(w)), (c2, s2) = (cos(2*w), sin(2*w))
        let nr = b0 + b1*c1 + b2*c2, ni = -(b1*s1 + b2*s2)
        let dr = 1 + a1*c1 + a2*c2,  di = -(a1*s1 + a2*s2)
        return sqrt((nr*nr + ni*ni) / (dr*dr + di*di))
    }
    let f0 = 1681.974450955533, G = 3.999843853973347, Q = 0.7071752369554196
    let K = tan(.pi * f0 / rate), Vh = pow(10, G/20), Vb = pow(Vh, 0.4996667741545416)
    let a0 = 1 + K/Q + K*K
    let m1 = mag((Vh + Vb*K/Q + K*K)/a0, 2*(K*K - Vh)/a0, (Vh - Vb*K/Q + K*K)/a0,
                 2*(K*K - 1)/a0, (1 - K/Q + K*K)/a0)
    let f1 = 38.13547087602444, Q1 = 0.5003270373238773
    let K1 = tan(.pi * f1 / rate), d = 1 + K1/Q1 + K1*K1
    let m2 = mag(1, -2, 1, 2*(K1*K1 - 1)/d, (1 - K1/Q1 + K1*K1)/d)
    return 20 * log10(m1 * m2)
}

func feed(_ m: LoudnessMeter, rate: Double, seconds: Double,
          amplitude: Double, freq: Double = 1000, chunk: Int = 512) {
    var phase = 0.0
    let step = 2 * Double.pi * freq / rate
    var left = [Float](repeating: 0, count: chunk)
    var right = [Float](repeating: 0, count: chunk)
    var remaining = Int(rate * seconds)
    while remaining > 0 {
        let n = min(chunk, remaining)
        for i in 0..<n {
            let v = Float(amplitude * sin(phase))
            left[i] = v; right[i] = v
            phase += step
        }
        left.withUnsafeBufferPointer { lp in
            right.withUnsafeBufferPointer { rp in
                m.process(left: lp.baseAddress!, right: rp.baseAddress!, frames: n, stereo: true)
            }
        }
        remaining -= n
    }
}

func f(_ v: Double) -> String { v.isFinite ? String(format: "%.2f", v) : "-inf" }

var failures = 0
func check(_ label: String, _ got: Double, _ want: Double, tol: Double = 0.1) {
    let ok = abs(got - want) <= tol
    if !ok { failures += 1 }
    print("  \(ok ? "PASS" : "FAIL")  \(label): got \(f(got)) LUFS, want \(f(want)) ±\(tol)")
}

for rate in [48000.0, 44100.0, 96000.0] {
    print("=== \(Int(rate)) Hz ===")
    let k = kGainDB(f: 1000, rate: rate)
    // Stereo identical sine, amplitude 0.1: z = A^2 * |H|^2 summed over two channels.
    let predicted = -0.691 + 20 * log10(0.1) + k
    print(String(format: "  K-weighting at 1 kHz: %+.3f dB   closed form: %.2f LUFS", k, predicted))

    let m = LoudnessMeter()
    m.configure(rate: rate)
    m.windowSeconds = 10
    feed(m, rate: rate, seconds: 10, amplitude: 0.1)
    check("integrated", m.integrated, predicted)
    check("short-term", m.shortTerm, predicted)
    check("momentary",  m.momentary,  predicted)
    check("window 10 s", m.windowed,  predicted)
}

print("=== gating: 5 s tone then 5 s silence (48 kHz) ===")
let g = LoudnessMeter()
g.configure(rate: 48000)
g.windowSeconds = 600
let toneLoudness = -0.691 + 20 * log10(0.1) + kGainDB(f: 1000, rate: 48000)
feed(g, rate: 48000, seconds: 5, amplitude: 0.1)
feed(g, rate: 48000, seconds: 5, amplitude: 0)
// The silence is below the -70 LUFS absolute gate, so it must not drag the integrated figure
// down; the ungated short-term figure over the last 3 s must, however, read silence.
// 47 blocks sit wholly in the tone; the 3 blocks straddling the edge are part tone, part
// silence, and BS.1770 counts them. 10*log10(48.5/50) = −0.132 LU, so that is the answer.
check("integrated ignores the silence", g.integrated, toneLoudness - 0.1323, tol: 0.05)
print("  short-term after 3 s of silence: \(f(g.shortTerm)) LUFS (want very low)")
if g.shortTerm > -100 { failures += 1; print("  FAIL  short-term should have collapsed") } else { print("  PASS  short-term collapsed") }

print("=== relative gate: 5 s loud then 5 s 15 LU quieter ===")
let r = LoudnessMeter()
r.configure(rate: 48000)
feed(r, rate: 48000, seconds: 5, amplitude: 0.1)
feed(r, rate: 48000, seconds: 5, amplitude: 0.1 * pow(10, -15.0/20))
// The quiet half sits more than 10 LU below the ungated mean, so the relative gate drops it
// and the integrated figure stays on the loud half.
// Same three straddling blocks, this time carrying a little of the quiet half: −0.128 LU.
check("integrated keeps only the loud half", r.integrated, toneLoudness - 0.1281, tol: 0.05)

print("=== reset ===")
let s = LoudnessMeter()
s.configure(rate: 48000)
feed(s, rate: 48000, seconds: 4, amplitude: 0.5)
let before = s.integrated
s.reset()
feed(s, rate: 48000, seconds: 4, amplitude: 0.1)
print("  before reset: \(f(before)) LUFS")
check("after reset", s.integrated, toneLoudness)

print("=== chunk size independence (48 kHz, 4 s tone) ===")
for chunk in [64, 512, 4096] {
    let c = LoudnessMeter()
    c.configure(rate: 48000)
    feed(c, rate: 48000, seconds: 4, amplitude: 0.1, chunk: chunk)
    check("chunk \(chunk)", c.integrated, toneLoudness)
}

print("")
print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
