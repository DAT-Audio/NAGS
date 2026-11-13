import Foundation

/// Somewhere to send this Mac's audio.
///
/// **Every target is remembered**; a favourite is pinned to the top of the list. Whether a
/// target was *sending* is remembered too, but only acted on if "Resume sending when opened" is
/// on — off by default, because an app that starts transmitting what the Mac is playing just by
/// being opened is one nobody should have to discover by accident.
public struct SendTarget: Identifiable, Codable, Equatable {
    public var id = UUID()
    public var host: String
    public var port: Int = VBAN.port
    public var favourite = false
    /// Send to the broadcast address of the network this host is on, instead of to the host —
    /// every receiver on that network hears it.
    public var broadcast = false
    /// Send silence, so the receiver keeps listing the stream.
    public var muted = false
    /// A name for it, chosen by the user ("Studio PC"). Only ever shown on this Mac; nothing is sent.
    /// Optional, so targets saved before names existed still decode.
    public var name: String?
    /// A broadcast made by **Broadcast on this network**: the interface and the
    /// network it was started on (`NetworkIdentity`), and whether it comes back on at launch —
    /// only on that same network. Optional, so older targets still decode.
    public var interface: String?
    public var networkSignature: String?
    public var keepOn: Bool?

    /// Where it goes: the host, with the port only when it is not VBAN's.
    public var address: String { port == VBAN.port ? host : "\(host):\(port)" }
    /// What the list shows: the name if there is one, otherwise the address.
    public var label: String { name ?? address }

    public init(id: UUID = UUID(), host: String, port: Int = VBAN.port, favourite: Bool = false,
                broadcast: Bool = false, muted: Bool = false, name: String? = nil) {
        self.id = id; self.host = host; self.port = port; self.favourite = favourite
        self.broadcast = broadcast; self.muted = muted; self.name = name
    }
}

/// Levels of what is **sent** — after the inserts, so a plugin that changes the level shows it —
/// for the meters. Written on the capture queue, read on the main thread: each channel's level
/// and the time it was set only mean something together, so they go under a `SeqLock`.
/// (They were Swift arrays read while being written, which the language does not promise holds.)
public final class SendMeter {
    private static let maxChannels = 64
    /// The Grabber's bar release (`AudioOutput.barReleaseTau`), so a level falls the same way
    /// on both ends of a stream.
    private static let fallTau = 0.22
    private let value: UnsafeMutablePointer<Float> = {
        let p = UnsafeMutablePointer<Float>.allocate(capacity: SendMeter.maxChannels)
        p.initialize(repeating: 0, count: SendMeter.maxChannels)
        return p
    }()
    private let at: UnsafeMutablePointer<CFAbsoluteTime> = {
        let p = UnsafeMutablePointer<CFAbsoluteTime>.allocate(capacity: SendMeter.maxChannels)
        p.initialize(repeating: 0, count: SendMeter.maxChannels)
        return p
    }()
    private let lock = SeqLock()

    public init() {}
    deinit { value.deallocate(); at.deallocate() }

    public func measure(_ s: UnsafePointer<Float>, frames: Int, channels: Int) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.write {
            for c in 0..<min(Self.maxChannels, channels) {
                var peak: Float = 0
                var i = c
                while i < frames * channels {
                    peak = max(peak, abs(s[i]))
                    i += channels
                }
                if peak >= decayed(c, now: now) {
                    value[c] = peak
                    at[c] = now
                }
            }
        }
    }

    /// 0…1, falling smoothly between buffers and reading empty once nothing arrives.
    public func level(_ c: Int, now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> Float {
        guard c >= 0, c < Self.maxChannels else { return 0 }
        return lock.read { decayed(c, now: now) }
    }

    private func decayed(_ c: Int, now: CFAbsoluteTime) -> Float {
        guard at[c] > 0 else { return 0 }
        let elapsed = now - at[c]
        guard elapsed < Self.fallTau * 8 else { return 0 }
        return value[c] * Float(exp(-max(0, elapsed) / Self.fallTau))
    }
}

/// What the capture is doing, for the window to say.
public enum CaptureStatus: Equatable {
    case idle
    case running(rate: Int, channels: Int)
    case failed(String)
}
