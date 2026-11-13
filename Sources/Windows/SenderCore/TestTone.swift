import Foundation
import NAGWASAPI

/// A test aid for the system source's exclusion (`nag-send --test-tone`): a quiet
/// sine played through WASAPI render from inside this process, so a capture that leaves this
/// process out can be shown not to hear it, and one that does not, to hear it.
public final class TestTonePlayer {
    private var wanted = false
    private var thread: Thread?

    public init() {}
    deinit { stop() }

    /// Plays `frequency` at `level` (linear peak) on the default playback device until `stop()`.
    public func start(frequency: Double = 1000, level: Float = 0.1) {
        guard !wanted else { return }
        wanted = true
        let t = Thread { [weak self] in self?.play(frequency: frequency, level: level) }
        t.name = "test tone"
        thread = t
        t.start()
    }

    public func stop() {
        wanted = false
        thread = nil
    }

    private func play(frequency: Double, level: Float) {
        var rate: Int32 = 0, deviceChannels: Int32 = 0, opened: Int32 = 0, bufferFrames: Int32 = 0
        var name = [CChar](repeating: 0, count: 256)
        var id = [CChar](repeating: 0, count: 256)
        var error = [CChar](repeating: 0, count: 256)
        guard let render = nag_render_open(2, &rate, &deviceChannels, &opened, &bufferFrames,
                                           &name, 256, &id, 256, &error, 256) else {
            print("Test tone : could not open the playback device: \(String(cString: error))")
            return
        }
        defer { nag_render_close(render) }
        guard nag_render_start(render) == 0 else { return }
        let step = 2 * Double.pi * frequency / Double(rate)
        let width = Int(opened)
        var phase = 0.0
        while wanted {
            let room = Int(nag_render_wait(render, 100))
            if room < 0 { break }
            if room == 0 { continue }
            guard let buffer = nag_render_buffer(render, Int32(room)) else { break }
            for f in 0..<room {
                let sample = level * Float(sin(phase))
                phase += step
                if phase > 2 * Double.pi { phase -= 2 * Double.pi }
                for c in 0..<width { buffer[f * width + c] = c < 2 ? sample : 0 }
            }
            if nag_render_release(render, Int32(room)) != 0 { break }
        }
    }
}

/// How loud one frequency is in what is captured: a Goertzel filter over 100 ms windows of the
/// first channel, keeping the loudest window since last asked. Fed on the capture's thread.
public final class ToneMeter {
    private let frequency: Double
    private let lock = NSLock()
    private var rate = 0
    private var window = 0
    private var count = 0
    private var s1 = 0.0, s2 = 0.0, coefficient = 0.0
    private var loudest = 0.0

    public init(frequency: Double = 1000) { self.frequency = frequency }

    public func feed(_ samples: UnsafePointer<Float>, frames: Int, channels: Int, rate: Int) {
        lock.lock(); defer { lock.unlock() }
        if rate != self.rate {
            self.rate = rate
            window = rate / 10
            coefficient = 2 * cos(2 * Double.pi * frequency / Double(rate))
            count = 0; s1 = 0; s2 = 0
        }
        for f in 0..<frames {
            let s0 = Double(samples[f * channels]) + coefficient * s1 - s2
            s2 = s1; s1 = s0
            count += 1
            if count == window {
                let power = s1 * s1 + s2 * s2 - coefficient * s1 * s2
                let amplitude = 2 * sqrt(max(0, power)) / Double(window)
                loudest = max(loudest, amplitude)
                count = 0; s1 = 0; s2 = 0
            }
        }
    }

    /// The loudest window's amplitude (linear peak) since the last call.
    public func take() -> Double {
        lock.lock(); defer { lock.unlock() }
        let value = loudest
        loudest = 0
        return value
    }
}
