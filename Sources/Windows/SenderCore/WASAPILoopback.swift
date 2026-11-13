import Foundation
import WinSDK
import NetworkAudioEngine
import NAGWASAPI

/// What the Windows Sender copies, as the Mac Sender's `SendSource`, and stored the
/// same way under `"sendSource"`, so the two read each other's text:
/// - **system**: everything this PC plays, less this app's (or the Grabber's) own playback;
/// - **app**: one app's process tree. The Mac allows several; process loopback takes one process
///   tree per capture, so here it is one, stored as `"apps:<exe>"` (a Mac list keeps its first);
/// - **input**: one input device whole, at its own channel count, as `"input:<id>\u{1F}<name>"`.
public enum WindowsSendSource: Equatable {
    case system
    case app(exe: String, name: String)
    case input(id: String, name: String)

    /// Stored as text in the app's settings.
    public var stored: String {
        switch self {
        case .system: return "system"
        case .app(let exe, _): return "apps:" + exe
        case .input(let id, let name): return "input:" + id + "\u{1F}" + name
        }
    }

    public init(stored: String?) {
        guard let stored else { self = .system; return }
        if stored.hasPrefix("apps:") {
            let ids = stored.dropFirst(5).split(separator: ",").map(String.init)
            guard let exe = ids.first, !exe.isEmpty else { self = .system; return }
            self = .app(exe: exe, name: Self.plainName(exe))
        } else if stored.hasPrefix("input:") {
            let parts = stored.dropFirst(6).split(separator: "\u{1F}", maxSplits: 1).map(String.init)
            self = parts.count == 2 ? .input(id: parts[0], name: parts[1]) : .system
        } else {
            self = .system
        }
    }

    /// "player.exe" as "player": what an app is called before it has been seen running.
    public static func plainName(_ exe: String) -> String {
        exe.lowercased().hasSuffix(".exe") ? String(exe.dropLast(4)) : exe
    }

    public var isInput: Bool { if case .input = self { return true }; return false }
}

/// This PC's audio, captured: the engine's `SystemAudioSource`
/// over WASAPI. The Mac's equivalent is `SystemAudioCapture`, a Core Audio process tap, with
/// `InputDeviceCapture` beside it.
///
/// What it copies is `source`:
/// - **system** is a *process loopback* (Windows 10 2004 and later) of everything except one
///   process tree, `excludedProcessID`, which by default is this process: the Grabber plays its
///   own audio, and sending that back out would echo. Where process loopback is missing or
///   refused it falls back to the default playback device's plain loopback, which includes this
///   app, and says so through `onRestart`;
/// - **app** is a process loopback of that app's process tree alone. Until the app is running
///   this sends silence and looks for it once a second; when it quits, it waits again;
/// - **input** is an input device in shared mode, at its own channel count. `stereoOnly` does not
///   apply to it, as on the Mac.
///
/// All shared mode, so nothing about what the user hears changes and no other app is interrupted.
///
/// **Silence.** A Core Audio tap runs with the device and delivers silence while nothing plays;
/// WASAPI loopback delivers nothing at all. A VBAN receiver wants a steady stream, so when the
/// device has been quiet for a moment this makes the silence itself. `othersArePlaying()` then
/// means what it says on the Mac: audio that is not silence has arrived recently.
///
/// **Pacing**: what the device hands over and
/// what should go on the wire are not the same shape. WASAPI gives a chunk of about 10 ms at a
/// time, and `Thread.sleep` on Windows is granular to the system timer — asking for 2 ms gets 10,
/// asking for 10 gets 20 — so a loop built on it sent 20 ms of audio in one burst and then
/// nothing for 20 ms. The wire looked right on average and starved a receiver on every gap.
/// So: a **high-resolution waitable timer** ticks every 2 ms, the device's chunks go into a small
/// queue, and each tick sends only as many frames as the clock says are owed. The receiver sees a
/// steady trickle rather than a bursty average.
public final class WASAPILoopback: SystemAudioSource {
    public var onAudio: ((UnsafePointer<Float>, Int, Int, Int) -> Void)?
    public var onStateChange: (() -> Void)?
    public var onRestart: ((String) -> Void)?

    public private(set) var running = false
    public private(set) var sampleRate = 0
    public private(set) var lastError: String?

    /// What is *delivered*: two when `stereoOnly` folds a wider source, else the source's own
    /// count.
    public var channels: Int { foldsToStereo ? 2 : captureChannels }

    /// The width the source itself opened at, before any fold.
    public private(set) var captureChannels = 0

    /// Not available here. WASAPI loopback is a copy of the mix on its way out; there is no
    /// equivalent of the Mac tap's "muted when tapped", and the only thing Windows offers — the
    /// endpoint's volume — would change what the user hears from every app. `nag-send` says so
    /// once rather than failing quietly.
    public var muteLocal = false { didSet { if muteLocal { onRestart?(Self.muteNotice) } } }
    public static let muteNotice =
        "Muting this PC's own output is not available with WASAPI loopback: the capture is a copy "
        + "of what the device plays, so silencing it would silence the capture too."

    /// Fold what is sent to stereo, rather than send the device's own channel count. Not for an
    /// input, which is always sent whole.
    public var stereoOnly = false

    public private(set) var callbacks: UInt64 = 0
    public private(set) var lastBufferCount = 0
    public private(set) var lastBufferBytes = 0
    /// Frames the source itself has handed over since starting, as against the silence made here
    /// while it hands over nothing — which tells a quiet input from one that is not delivering.
    public private(set) var deviceFrames: UInt64 = 0

    /// What is being copied, for the status line: the playback device for the system, the app's
    /// name for an app, the input's name for an input.
    public private(set) var deviceName = ""

    /// What to copy. Changing it while running restarts the capture on the new source; the
    /// capture thread reads it when it opens.
    public var source: WindowsSendSource {
        get { lock.withLock { _source } }
        set {
            let changed = lock.withLock { () -> Bool in
                guard newValue != _source else { return false }
                _source = newValue
                return true
            }
            if changed { restartRequested = true }
        }
    }
    private var _source: WindowsSendSource

    /// The process tree the system source leaves out. This process by default, which is right
    /// for the Grabber's Send: the Grabber plays its own audio. `nil` leaves nothing out, which is
    /// the plain device loopback of before. Read at each open; changing it restarts the capture.
    public var excludedProcessID: UInt32? {
        get { lock.withLock { _excluded } }
        set {
            let changed = lock.withLock { () -> Bool in
                guard newValue != _excluded else { return false }
                _excluded = newValue
                return true
            }
            if changed, case .system = source { restartRequested = true }
        }
    }
    private var _excluded: UInt32? = nag_wasapi_own_pid()

    /// For a Sender that is not the Grabber (`nag-sender`, `nag-send`): leave out a running
    /// Grabber's playback rather than `excludedProcessID`'s, looked for at each open and every two
    /// seconds after, so a Grabber started or quit while sending is followed. With no Grabber
    /// running, `excludedProcessID` is left out as usual.
    public var excludeRunningGrabber = false {
        didSet { if excludeRunningGrabber != oldValue, case .system = source { restartRequested = true } }
    }

    /// Called with each new capture as it is made, before anything uses it. The engine's owner
    /// (`WindowsSender`) keeps its capture to itself, so this is how a front end reaches it to set
    /// the source and the exclusion.
    nonisolated(unsafe) public static var onCreate: ((WASAPILoopback) -> Void)?

    private let lock = NSLock()

    public init(source: WindowsSendSource = .system) {
        _source = source
        Self.onCreate?(self)
    }
    deinit { stop() }

    /// What the default playback device is called and runs at, without opening a capture — so the
    /// window can say what it would copy before anything is being sent. Asked of Windows at most
    /// once a second: the window repaints thirty times a second and this is a COM round trip.
    public static func defaultDevice() -> (name: String, rate: Int, channels: Int)? {
        let now = Date()
        if let cached = cachedDefault, now.timeIntervalSince(cachedDefaultAt) < 1 { return cached }
        var name = [CChar](repeating: 0, count: 256)
        var rate: Int32 = 0
        var channels: Int32 = 0
        cachedDefaultAt = now
        guard nag_wasapi_default_device(&name, 256, &rate, &channels) == 0 else {
            cachedDefault = nil
            return nil
        }
        cachedDefault = (String(cString: name), Int(rate), Int(channels))
        return cachedDefault
    }
    nonisolated(unsafe) private static var cachedDefault: (name: String, rate: Int, channels: Int)?
    nonisolated(unsafe) private static var cachedDefaultAt = Date.distantPast

    // MARK: - Lists for a Source menu

    /// The input devices connected now, for the Source menu. Each is sent at its own width.
    public static func inputDevices() -> [(id: String, name: String, channels: Int)] {
        let max = 64, record = 512
        var ids = [CChar](repeating: 0, count: max * record)
        var names = [CChar](repeating: 0, count: max * record)
        var widths = [Int32](repeating: 0, count: max)
        let count = Int(nag_wasapi_input_devices(&ids, &names, &widths, Int32(record), Int32(max)))
        return (0..<count).map { i in
            (text(ids, i * record), text(names, i * record), Int(widths[i]))
        }
    }

    /// The apps with audio on the default playback device now, playing ones first, less this
    /// process and the project's own apps (which the Sender never sends, as on the Mac). `exe` is
    /// what `.app` and `"apps:"` store.
    public static func audioApps() -> [(exe: String, name: String, pid: UInt32, playing: Bool)] {
        let max = 128, record = 260
        var pids = [UInt32](repeating: 0, count: max)
        var exes = [CChar](repeating: 0, count: max * record)
        var names = [CChar](repeating: 0, count: max * record)
        var active = [Int32](repeating: 0, count: max)
        let count = Int(nag_wasapi_audio_apps(&pids, &exes, &names, &active, Int32(record), Int32(max)))
        return (0..<count)
            .map { i in (text(exes, i * record), text(names, i * record), pids[i], active[i] != 0) }
            .filter { !ownApps.contains($0.exe.lowercased()) }
            .sorted { ($0.playing ? 0 : 1, $0.name.lowercased()) < ($1.playing ? 0 : 1, $1.name.lowercased()) }
    }

    /// The project's own executables, never offered as an app to send.
    public static let ownApps: Set<String> = ["nag-grabber.exe", "nag-grab.exe", "nag-sender.exe", "nag-send.exe"]

    /// A running Grabber (`nag-grabber.exe`, else `nag-grab.exe`), for `nag-sender` to leave out.
    public static func grabberProcessID() -> UInt32? {
        for exe in ["nag-grabber.exe", "nag-grab.exe"] {
            let pid = nag_wasapi_find_process(exe)
            if pid != 0 { return pid }
        }
        return nil
    }

    /// Whether this Windows offers process loopback at all (Windows 10 2004 or later).
    public static var processLoopbackAvailable: Bool { nag_wasapi_process_loopback_available() != 0 }

    private static func text(_ buffer: [CChar], _ offset: Int) -> String {
        buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress! + offset) }
    }

    // MARK: - Starting and stopping

    private var thread: Thread?
    private var wanted = false
    private var restartRequested = false
    private let ready = DispatchSemaphore(value: 0)
    private var openError: String?

    /// Opens the device on the capture thread — COM objects belong to the thread that made them —
    /// and waits for it, so a failure is reported here rather than later and elsewhere.
    @discardableResult
    public func start() -> String? {
        guard !running else { return nil }
        wanted = true
        openError = nil
        fellBackNoted = false
        let t = Thread { [weak self] in self?.captureLoop() }
        t.name = "WASAPI capture"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
        // Opening a device is quick; process loopback's activation can take a little longer, and
        // five seconds is still a long wait for one that is going to work.
        if ready.wait(timeout: .now() + 5) == .timedOut {
            wanted = false
            lastError = "the audio source did not open in time"
            onStateChange?()
            return lastError
        }
        if let openError {
            wanted = false
            thread = nil
            lastError = openError
            onStateChange?()
            return openError
        }
        lastError = nil
        // No `onStateChange` here: the capture thread has already sent one, and two would be
        // logged as two starts.
        return nil
    }

    public func stop() {
        wanted = false
        thread = nil
        running = false
    }

    /// Whether anything is playing into the source. Silence while nothing plays is normal; silence
    /// while something does is what a device that stopped feeding the loopback looks like.
    public func othersArePlaying() -> Bool {
        monotonic() - lastRealAudio < 0.5
    }

    /// When audio that was not silence last arrived. Process loopback hands over silent packets
    /// while its processes are quiet, so "something arrived" no longer means "something plays".
    private var lastRealAudio: Double = 0
    /// Whether the fall back to plain loopback has been said this start, so a device change does
    /// not say it again.
    private var fellBackNoted = false
    private var foldsToStereo: Bool { stereoOnly && !openedSource.isInput && captureChannels > 2 }
    /// The source the capture thread last opened, as against `source`, which may have just changed.
    private var openedSource: WindowsSendSource = .system

    // MARK: - The capture thread

    /// How often the loop wakes. Short enough that a VBAN packet (about 1.9 ms of 48 kHz audio
    /// at eight channels) goes out close to when it is due, long enough not to spin.
    private static let tickMilliseconds = 2
    /// How long the device may give nothing before this makes the silence itself. Comfortably
    /// more than a tick, so an ordinary late chunk is not mistaken for quiet.
    private static let quietAfter: Double = 0.05
    /// The most audio allowed to sit in the queue before it is drained faster than real time.
    /// The device's clock and this PC's are not the same clock, and without this the slack would
    /// grow all day on a device that runs fast.
    private static let maxHeldSeconds: Double = 0.04

    /// How one run of the capture ended.
    private enum Ending { case failedToOpen, lost, again }

    /// Opens the source, runs until it is lost, changed or the Sender stops, and opens it again —
    /// a loop, not a call back into itself, so a long run of device changes cannot pile up on the
    /// stack. Only the first open reports its error to `start()`.
    private func captureLoop() {
        var first = true
        while wanted {
            let ending = runOnce(reportOpenFailure: first)
            first = false
            guard wanted else { break }
            switch ending {
            case .again: continue
            case .lost: Thread.sleep(forTimeInterval: 0.3)
            case .failedToOpen: Thread.sleep(forTimeInterval: 1)
            }
        }
    }

    /// What one run opened: a capture handle, or none while waiting for an app to start.
    private struct Opened {
        var handle: OpaquePointer?
        var rate: Int
        var channels: Int
        var name: String
        /// The process the include or exclude is about, to notice it quit or change.
        var targetPID: UInt32 = 0
    }

    /// Opens what `source` says. Returns nil with the reason when it cannot.
    private func open(_ source: WindowsSendSource) -> (Opened?, String?) {
        var rate: Int32 = 0
        var width: Int32 = 0
        var errorText = [CChar](repeating: 0, count: 256)

        func deviceName(_ handle: OpaquePointer) -> String {
            var name = [CChar](repeating: 0, count: 256)
            return nag_wasapi_device_name(handle, &name, 256) == 0 ? String(cString: name) : ""
        }

        switch source {
        case .system:
            let (excluded, grabberMode) = lock.withLock { (_excluded, excludeRunningGrabber) }
            let target = (grabberMode ? Self.grabberProcessID() : nil) ?? excluded
            if let target {
                if Self.processLoopbackAvailable,
                   let handle = nag_wasapi_open_source(NAG_SOURCE_PROCESS_EXCLUDE, nil, target, 0,
                                                       &rate, &width, &errorText, 256) {
                    return (Opened(handle: handle, rate: Int(rate), channels: Int(width),
                                   name: deviceName(handle), targetPID: target), nil)
                }
                if !fellBackNoted {
                    fellBackNoted = true
                    let why = Self.processLoopbackAvailable
                        ? "process loopback was refused (\(String(cString: errorText)))"
                        : "this Windows has no process loopback (it needs Windows 10 2004 or later)"
                    note("\(why); capturing everything this PC plays instead, this app's own audio included")
                }
            }
            guard let handle = nag_wasapi_open(&rate, &width, &errorText, 256) else {
                return (nil, "could not open the playback device: \(String(cString: errorText))")
            }
            return (Opened(handle: handle, rate: Int(rate), channels: Int(width), name: deviceName(handle)), nil)

        case .app(let exe, let name):
            guard Self.processLoopbackAvailable else {
                return (nil, "capturing one app needs Windows 10 2004 or later")
            }
            let label = Self.audioApps().first { $0.exe.caseInsensitiveCompare(exe) == .orderedSame }?.name ?? name
            let pid = nag_wasapi_find_process(exe)
            guard pid != 0 else {
                // Not running: silence at the rate and width it will have, until it is.
                let device = Self.defaultDevice()
                return (Opened(handle: nil, rate: device?.rate ?? 48000,
                               channels: Self.processWidth(device?.channels ?? 2),
                               name: label + " (not running)"), nil)
            }
            guard let handle = nag_wasapi_open_source(NAG_SOURCE_PROCESS_INCLUDE, nil, pid, 0,
                                                      &rate, &width, &errorText, 256) else {
                return (nil, "could not capture \(label): \(String(cString: errorText))")
            }
            return (Opened(handle: handle, rate: Int(rate), channels: Int(width), name: label, targetPID: pid), nil)

        case .input(let id, let name):
            guard let handle = nag_wasapi_open_source(NAG_SOURCE_INPUT, id, 0, 0,
                                                      &rate, &width, &errorText, 256) else {
                return (nil, "could not open \(name): \(String(cString: errorText))")
            }
            let real = deviceName(handle)
            return (Opened(handle: handle, rate: Int(rate), channels: Int(width),
                           name: real.isEmpty ? name : real), nil)
        }
    }

    /// The width a process loopback opens at for a device of `channels`: its own, as the C side
    /// asks first. Kept in one place so an app's silence while it is not running has the width
    /// its capture will have.
    private static func processWidth(_ channels: Int) -> Int { (1...8).contains(channels) ? channels : 2 }

    /// One source, from opening to losing or leaving it.
    private func runOnce(reportOpenFailure: Bool) -> Ending {
        restartRequested = false
        let source = self.source
        let (openedOrNil, failure) = open(source)
        guard let opened = openedOrNil else {
            let text = failure ?? "the audio source would not open"
            if reportOpenFailure { openError = text; ready.signal() } else { note(text) }
            return .failedToOpen
        }
        let capture = opened.handle
        defer { if let capture { nag_wasapi_close(capture) } }

        if let capture, nag_wasapi_start(capture) != 0 {
            let text = "the audio source would not start"
            if reportOpenFailure { openError = text; ready.signal() } else { note(text) }
            return .failedToOpen
        }

        openedSource = source
        deviceName = opened.name
        sampleRate = opened.rate
        captureChannels = opened.channels
        let channels = captureChannels
        running = true
        lastRealAudio = 0
        if reportOpenFailure { ready.signal() }
        onStateChange?()

        let tick = HighResolutionTick(milliseconds: Self.tickMilliseconds)
        let maxHeld = Int(Double(sampleRate) * Self.maxHeldSeconds)
        // Room for a quarter second, so a scheduling hiccup loses nothing the device kept.
        let capacity = max(maxHeld * 4, sampleRate / 4)
        var queue = [Float](repeating: 0, count: capacity * channels)
        var held = 0                                   // frames waiting in `queue`
        var scratch = [Float](repeating: 0, count: capacity * channels)
        var silence = [Float](repeating: 0, count: capacity * channels)

        var owed = 0.0                                 // frames the clock says are due
        var lastWake = monotonic()
        var lastDeviceAudio = 0.0                      // when the device last gave anything
        var lastCheck = lastWake
        var checks = 0
        var ending = Ending.lost

        while wanted {
            if restartRequested { ending = .again; break }
            tick.wait()
            let now = monotonic()
            owed += (now - lastWake) * Double(sampleRate)
            lastWake = now
            // A long stall — the machine slept, or this thread was starved — is not made up for
            // by flooding the network with a second of audio all at once.
            owed = min(owed, Double(sampleRate) * 0.1)

            // What the device has ready. Nothing is the usual answer while nothing is playing.
            var got = 0
            if let capture {
                got = scratch.withUnsafeMutableBufferPointer {
                    Int(nag_wasapi_read(capture, $0.baseAddress, Int32(capacity - held)))
                }
                if got < 0 {
                    note("the audio source stopped; opening it again")
                    break
                }
            }
            if got > 0 {
                lastDeviceAudio = now
                deviceFrames &+= UInt64(got)
                let audible = scratch.withUnsafeBufferPointer { s in
                    s.prefix(got * channels).contains { $0 != 0 }
                }
                if audible { lastRealAudio = now }
                queue.withUnsafeMutableBufferPointer { q in
                    scratch.withUnsafeBufferPointer { s in
                        q.baseAddress!.advanced(by: held * channels)
                            .update(from: s.baseAddress!, count: got * channels)
                    }
                }
                held += got
            }

            // What to send this tick: what the clock owes, and any backlog above the slack
            // allowance, so a device running fast does not build a delay that never comes down.
            var send = min(Int(owed), held)
            if held - send > maxHeld { send = held - maxHeld }
            if send > 0 {
                queue.withUnsafeBufferPointer { deliver($0.baseAddress!, frames: send) }
                owed = max(0, owed - Double(send))
                held -= send
                if held > 0 {
                    queue.withUnsafeMutableBufferPointer { q in
                        let base = q.baseAddress!
                        base.update(from: base.advanced(by: send * channels), count: held * channels)
                    }
                }
            } else if held == 0, now - lastDeviceAudio > Self.quietAfter, Int(owed) > 0 {
                // Quiet: make the silence, so the stream carries on at the device's own rate.
                let frames = min(Int(owed), capacity)
                silence.withUnsafeBufferPointer { deliver($0.baseAddress!, frames: frames) }
                owed -= Double(frames)
            }

            // What may have changed under the source. Each question costs a COM round trip or a
            // process walk, so once a second rather than every tick.
            if now - lastCheck > 1 {
                lastCheck = now
                checks += 1
                if let reason = changed(source, opened, capture, every2s: checks % 2 == 0) {
                    if !reason.isEmpty { note(reason) }
                    ending = .again
                    break
                }
            }
        }

        running = false
        onStateChange?()
        return ending
    }

    /// Whether the source should be opened again: the reason for the log ("" to reopen without
    /// one), or nil to carry on.
    private func changed(_ source: WindowsSendSource, _ opened: Opened, _ capture: OpaquePointer?,
                         every2s: Bool) -> String? {
        switch source {
        case .system:
            if let capture, nag_wasapi_default_changed(capture) != 0 {
                return "the default playback device changed; following it"
            }
            // A Grabber being left out started or quit. Only in that mode: the exclusion a front
            // end chose is its own to change.
            if opened.targetPID != 0, lock.withLock({ excludeRunningGrabber }) {
                if let capture, nag_wasapi_target_exited(capture) != 0 {
                    return "the Grabber quit; leaving out this app's own playback instead"
                }
                if every2s, let grabber = Self.grabberProcessID(), grabber != opened.targetPID {
                    return "a Grabber is running; leaving out its playback"
                }
            }
        case .app(let exe, _):
            if capture == nil {
                if nag_wasapi_find_process(exe) != 0 { return "\(exe) started; capturing it" }
            } else if let capture, nag_wasapi_target_exited(capture) != 0 {
                return "\(opened.name) quit; sending silence until it starts again"
            }
        case .input:
            break
        }
        return nil
    }

    private func note(_ text: String) {
        onRestart?(text)
    }

    /// One block on its way to the engine: folded to stereo first if that was asked for.
    private func deliver(_ samples: UnsafePointer<Float>, frames: Int) {
        callbacks &+= 1
        lastBufferCount = frames
        guard let onAudio else { return }
        if foldsToStereo {
            let folded = fold(samples, frames: frames)
            lastBufferBytes = frames * 2 * MemoryLayout<Float>.size
            folded.withUnsafeBufferPointer { onAudio($0.baseAddress!, frames, 2, sampleRate) }
        } else {
            lastBufferBytes = frames * captureChannels * MemoryLayout<Float>.size
            onAudio(samples, frames, captureChannels, sampleRate)
        }
    }

    private var foldBuffer: [Float] = []

    /// Many channels to two. Windows lays its channels out in the WAVE order — L R C LFE then the
    /// surrounds — so the centre and the surrounds go to both sides at the usual −3 dB, and the
    /// LFE is left out, as a fold-down should leave it. Anything that is not a WAVE layout is
    /// averaged instead, which is at least never wrong by much.
    private func fold(_ samples: UnsafePointer<Float>, frames: Int) -> [Float] {
        let channels = captureChannels
        if foldBuffer.count < frames * 2 { foldBuffer = [Float](repeating: 0, count: frames * 2) }
        let attenuation: Float = 0.7071
        let waveLayout = channels == 6 || channels == 8
        for f in 0..<frames {
            let row = samples + f * channels
            var left: Float = 0
            var right: Float = 0
            if waveLayout {
                left = row[0] + attenuation * row[2]
                right = row[1] + attenuation * row[2]
                for c in 4..<channels {                        // the surrounds; 3 is the LFE
                    let side = attenuation * row[c]
                    if (c - 4) % 2 == 0 { left += side } else { right += side }
                }
            } else {
                var sum: Float = 0
                for c in 0..<channels { sum += row[c] }
                left = sum / Float(channels)
                right = left
            }
            foldBuffer[f * 2] = max(-1, min(1, left))
            foldBuffer[f * 2 + 1] = max(-1, min(1, right))
        }
        return foldBuffer
    }
}

// MARK: - A clock to send by

private let performanceFrequency: Double = {
    var f = LARGE_INTEGER()
    QueryPerformanceFrequency(&f)
    return f.QuadPart == 0 ? 1 : Double(f.QuadPart)
}()

/// Seconds from a clock that only ever goes forwards, unlike `Date`, which the user or a time
/// server can move while audio is being sent.
private func monotonic() -> Double {
    var now = LARGE_INTEGER()
    QueryPerformanceCounter(&now)
    return Double(now.QuadPart) / performanceFrequency
}

/// A steady tick of a few milliseconds.
///
/// `Thread.sleep` cannot do this on Windows: it is granular to the system timer, which is 15.6 ms
/// unless something has asked for better, so a 2 ms sleep takes about 10. A waitable timer made
/// with `CREATE_WAITABLE_TIMER_HIGH_RESOLUTION` keeps to about 2.5 ms without `timeBeginPeriod`,
/// which would raise the timer resolution for the whole machine and cost battery everywhere else.
/// Windows 10 1803 and later; on anything older this falls back to sleeping, which sends in
/// bursts but still sends.
private final class HighResolutionTick {
    private let handle: HANDLE?
    private let fallback: TimeInterval

    init(milliseconds: Int) {
        fallback = Double(milliseconds) / 1000
        let allAccess: DWORD = 0x1F0003          // TIMER_ALL_ACCESS, which WinSDK does not export
        let made = CreateWaitableTimerExW(nil, nil,
                                          DWORD(CREATE_WAITABLE_TIMER_HIGH_RESOLUTION), allAccess)
        if let made {
            var due = LARGE_INTEGER()
            due.QuadPart = LONGLONG(-10_000 * milliseconds)   // relative, in 100 ns units
            if SetWaitableTimer(made, &due, LONG(milliseconds), nil, nil, false) {
                handle = made
            } else {
                CloseHandle(made)
                handle = nil
            }
        } else {
            handle = nil
        }
    }

    deinit { if let handle { CloseHandle(handle) } }

    func wait() {
        if let handle {
            WaitForSingleObject(handle, INFINITE)
        } else {
            Thread.sleep(forTimeInterval: fallback)
        }
    }
}
