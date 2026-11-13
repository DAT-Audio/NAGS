/// What `SendEngine` sends, and what may shape it on the way:
/// each platform gives its own. The Mac's are `SystemAudioCapture` (a process tap),
/// `HostAudioFeed` (a DAW track, in the Sender plugin) and `InsertProcessor` (Audio Units).
/// Windows: WASAPI loopback, excluding the Grabber's own output, for the system source.

/// This machine's own audio output, captured.
public protocol SystemAudioSource: AnyObject {
    /// Interleaved float frames, channel count and rate, on the capture's own queue.
    var onAudio: ((UnsafePointer<Float>, Int, Int, Int) -> Void)? { get set }
    /// It started, stopped or failed. Main queue.
    var onStateChange: (() -> Void)? { get set }
    /// Why it is being rebuilt, for the log.
    var onRestart: ((String) -> Void)? { get set }
    var running: Bool { get }
    var sampleRate: Int { get }
    var channels: Int { get }
    var lastError: String? { get }
    /// Silence this machine's own output while capturing.
    var muteLocal: Bool { get set }
    /// Mix to stereo rather than send the output's own channel count.
    var stereoOnly: Bool { get set }
    /// Buffers delivered since starting — none at all, with something playing, is what a
    /// missing recording permission looks like.
    var callbacks: UInt64 { get }
    var lastBufferCount: Int { get }
    var lastBufferBytes: Int { get }
    @discardableResult func start() -> String?
    func stop()
    /// Whether some other app is playing audio now.
    func othersArePlaying() -> Bool
}

/// A DAW track, handed over by a plugin.
public protocol TrackAudioSource: AnyObject {
    var onAudio: ((UnsafePointer<Float>, Int, Int, Int) -> Void)? { get set }
    var sampleRate: Int { get }
    var channelCount: Int { get }
    func setActive(_ on: Bool)
    /// The track carries on to its output while sent (true), or is silenced in the host.
    func setPasses(_ on: Bool)
}

/// Effects applied to what is sent (the inserts). Returns the samples to send.
public protocol SendProcessor: AnyObject {
    func process(_ samples: UnsafePointer<Float>, frames: Int, channels: Int,
                 sampleRate: Int) -> UnsafePointer<Float>
}
