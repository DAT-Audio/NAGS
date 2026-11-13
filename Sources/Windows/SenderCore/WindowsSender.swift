import Foundation
import NetworkAudioEngine

/// Windows' Sender: the shared engine's `SendEngine` with this
/// PC's audio under it. The Mac's equivalent is `SenderState`, which adds its window, its inserts
/// and its hooks into macOS; this adds the two hooks Windows can answer and nothing else, because
/// `nag-send` has no window and no inserts.
///
/// Everything a listener hears — the wire format, the targets, who may listen, auto-stop — is the
/// engine's, the same code the Mac Sender runs, so a stream from here and a stream from a Mac are
/// the same stream (`docs/PROTOCOL.md`).
public final class WindowsSender: SendEngine {
    private let loopback: WASAPILoopback

    /// `onDemand`: as the Mac Grabber's Send — no tick, no offer and no capture until something is
    /// sent or offered, and all of it stops again when nothing is.
    /// `processor`: the inserts, if the front has them (the Sender app's VST3 chain). `logFile`:
    /// where the log is kept between runs; nil keeps it in memory (the console, a test).
    public init(defaults: UserDefaults, name: String?, onDemand: Bool = false, processor: SendProcessor? = nil,
                logFile: URL? = nil) {
        let capture = WASAPILoopback()
        loopback = capture
        // 24-bit unless chosen otherwise: what receivers expect for
        // monitoring. Written before the engine reads it; a choice already made is kept.
        if defaults.object(forKey: "dataType") == nil {
            defaults.set(Int(VBAN.DataType.int24.rawValue), forKey: "dataType")
        }
        super.init(defaults: defaults, onDemand: onDemand, hostFeed: nil, defaultName: name,
                   capture: capture, processor: processor, logFile: logFile)
    }

    /// The capture itself, for choosing its source and what it leaves out.
    public var windowsCapture: WASAPILoopback { loopback }

    /// The playback device being copied, for the status line.
    public var captureDevice: String { loopback.deviceName }

    // MARK: Hooks into Windows

    /// How the engine's log names this machine: "Capturing this PC's audio", not "this Mac's".
    public override var thisMachine: String { "this PC" }

    /// What the beacon says this PC is playing out of. The rate is the capture's, which is the
    /// device's own mix rate.
    public override func outputDevice() -> (name: String, rate: Int)? {
        // While capturing, what is actually being copied; before that, what would be.
        if !loopback.deviceName.isEmpty { return (loopback.deviceName, loopback.sampleRate) }
        guard let device = WASAPILoopback.defaultDevice() else { return nil }
        return (device.name, device.rate)
    }

    /// Which network a kept broadcast was made for, so it does not come back on a different one.
    /// The Mac asks `NetworkIdentity`; here the interface and its broadcast address are enough to
    /// tell one network from another, which is all the engine compares.
    public override func networkSignature(interface: String, broadcast: String?) -> String {
        "\(interface)|\(broadcast ?? "-")"
    }
}
