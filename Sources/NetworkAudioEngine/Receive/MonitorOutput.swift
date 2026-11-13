/// What `GrabberEngine` needs from the platform: somewhere to
/// play the streams, and the Bonjour browsers. The Mac's are `AudioOutput` (AVAudioEngine and
/// Core Audio), `RavennaBrowser` and `DanteBrowser` (Network framework). Windows: WASAPI for
/// the output, and the DNS-SD API (`DnsServiceBrowse`) for the browsers.

/// The monitor bus: every playing stream mixed to the output device, with the monitor
/// controls, the meters and the loudness measurement. Inserts are the platform's own business.
public protocol MonitorOutput: AnyObject {
    /// Called when the device or the engine changed underneath (main queue).
    var onStatusChange: (() -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }

    @discardableResult func start() -> String?
    func stop()
    var running: Bool { get }
    /// The receivers to mix, replacing the last list.
    func setReceivers(_ list: [StreamReceiver])

    var masterGain: Float { get set }
    var dimmed: Bool { get set }
    var monoFold: Bool { get set }
    var safetyLimiter: Bool { get set }

    /// The bus width: what was asked for, and what the device could take.
    var busChannels: Int { get }
    var requestedBusChannels: Int { get }
    /// Sets the width; returns what was applied.
    func setBusChannels(_ channels: Int) -> Int

    var deviceName: String { get }
    var deviceUID: String { get }
    var deviceRate: Double { get }
    var deviceChannels: Int { get }
    var deviceSampleRates: [Double] { get }
    func setDeviceSampleRate(_ rate: Double) -> Bool
    var deviceBufferFrames: UInt32 { get }
    func setDeviceBufferFrames(_ frames: UInt32) -> Bool
    var renderBlockFrames: Int { get }

    /// Meters: each channel's envelope, the held peak, the highest since a reset, and the clip.
    func peak(_ channel: Int) -> Float
    var peakL: Float { get }
    var peakR: Float { get }
    var peakHold: Float { get }
    var peakMax: Float { get }
    func clearPeakMax()
    var clipped: Bool { get }
    func clearClip()
    /// How often the metering tap fires, and its block, for the self-test.
    var tapFrames: Int { get }
    var tapHz: Double { get }
    var loudness: LoudnessMeter { get }
    /// The audio graph, for the self-test.
    var graphSummary: String { get }
}

/// A browser that finds streams and hands over their SDP (RAVENNA).
public protocol StreamBrowser: AnyObject {
    var onSDP: ((String) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    func start()
    func stop()
}

/// A stream browser that also says when a stream it found has left: with the SDP it
/// last gave, so the engine can take it off the list at once rather than after `staleAfter`.
/// Optional, so a platform's browser can adopt it when it can tell.
public protocol LeavingStreamBrowser: StreamBrowser {
    var onGone: ((String) -> Void)? { get set }
}

/// A browser that finds devices (Dante), to label their streams.
public protocol DeviceBrowser: AnyObject {
    var onDevicesChanged: (([DanteDevice]) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    func start()
    func stop()
}

/// A Dante device seen on the network.
public struct DanteDevice: Identifiable, Hashable {
    public var name: String
    public var address: String?          // nil until Bonjour resolution completes
    public var channelNames: [String] = []
    public var id: String { name }
    public init(name: String, address: String? = nil, channelNames: [String] = []) {
        self.name = name; self.address = address; self.channelNames = channelNames
    }
}
