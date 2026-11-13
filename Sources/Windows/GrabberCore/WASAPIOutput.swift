import Foundation
import WinSDK
import NetworkAudioEngine
import NAGWASAPI
import WindowsInserts

/// The Grabber's monitor bus on Windows: the engine's
/// `MonitorOutput` over **WASAPI render** on the default playback device. The Mac's is
/// `AudioOutput`; this follows it — the mix, the monitor controls, the loudness taken on the
/// summed bus before them, the meters after them — without the inserts, which are the Mac's.
///
/// **Shared mode, never exclusive.** Exclusive mode skips the device's effects, Windows Sonic and
/// Dolby Atmos for Headphones among them, and takes the device from every other app.
///
/// **Pacing** is the Sender's loopback problem seen from the other end, and solved the other way
/// round: there the PC's clock has to pace what goes on the wire, here the *device's* clock paces
/// what is played. WASAPI's event mode wakes this thread each time the device has room — once per
/// engine period, 10 ms on nearly every device — so nothing sleeps on Windows' coarse timer, and
/// the receivers' own drift correction (`StreamReceiver.render`) keeps their buffers on target
/// against the device clock, as they do against Core Audio's on the Mac.
///
/// **Channel order.** The engine's 7.1 is `L R C LFE Lss Rss Lrs Rrs` (`Downmix.swift`); Windows'
/// 7.1 surround is `FL FR FC LFE BL BR SL SR`. So on the way out engine channels 4–5 (the sides)
/// go to 6–7, and 6–7 (the rears) go to 4–5. 5.1 and 4.0 need nothing: Windows calls their
/// surrounds "back", which is where the engine's go.
public final class WASAPIOutput: MonitorOutput {
    public var onStatusChange: (() -> Void)?
    public var onError: ((String) -> Void)?

    public init() {}
    deinit { stop(); bars.deallocate(); planar.deallocate(); busPointers.deallocate() }

    // MARK: - What the device is

    public private(set) var running = false
    public private(set) var deviceName = "—"
    public private(set) var deviceUID = ""
    public private(set) var deviceRate: Double = 48000
    /// The device's own shared-mode mix width, as set in Windows' Sound settings.
    public private(set) var mixChannels = 2
    /// The widest bus worth offering. Shared mode with AUTOCONVERTPCM takes any layout and Windows
    /// mixes it to the device — and with Windows Sonic or Dolby Atmos for Headphones on, it places a
    /// 7.1 stream around a stereo pair of headphones. So 7.1 is offered whatever the device is, and
    /// more only when the device itself is wider.
    public var deviceChannels: Int { max(8, mixChannels) }
    public private(set) var busChannels = 2
    public var requestedBusChannels = 2
    /// The endpoint buffer, in frames: one period being played while the next is written.
    public private(set) var deviceBufferFrames: UInt32 = 0
    public private(set) var renderBlockFrames = 0
    /// The width the stream was opened at, which is the bus unless the device refused it.
    public private(set) var openedChannels = 2

    // MARK: - The chosen device (as the Mac's Settings → Output)

    /// A device chosen by ID, or nil to follow Windows' default. Set with `setPreferredDevice`.
    public private(set) var chosenDeviceID: String?
    /// Its name when chosen, for saying so while it is unplugged.
    public private(set) var chosenDeviceName = ""
    /// The chosen device is not connected and the default stands in.
    public private(set) var usingFallback = false
    /// The render thread's copy of the choice, read when it opens a device.
    private let choiceLock = NSLock()
    private var renderChoice: String?

    /// Plays on `id` from now on (nil: the system default), reopening if playing.
    public func setPreferredDevice(id: String?, name: String) {
        chosenDeviceID = id
        chosenDeviceName = name
        choiceLock.lock(); renderChoice = id; choiceLock.unlock()
        if running || thread != nil { if let error = start() { onError?(error) } }
    }

    /// One playback device, as Windows lists it.
    public struct RenderDevice: Equatable {
        public let id: String
        public let name: String
        public let channels: Int
    }

    /// Every connected playback device.
    public static func renderDevices() -> [RenderDevice] {
        let record = 512, max = 32
        var ids = [CChar](repeating: 0, count: record * max)
        var names = [CChar](repeating: 0, count: record * max)
        var channels = [Int32](repeating: 0, count: max)
        let n = Int(nag_render_devices(&ids, &names, &channels, Int32(record), Int32(max)))
        return (0..<n).map { i in
            let id = ids.withUnsafeBufferPointer { String(cString: $0.baseAddress! + i * record) }
            let name = names.withUnsafeBufferPointer { String(cString: $0.baseAddress! + i * record) }
            return RenderDevice(id: id, name: name, channels: Int(channels[i]))
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The system default's name, for "System default — …".
    public static func defaultDeviceName() -> String? {
        var name = [CChar](repeating: 0, count: 256)
        var rate: Int32 = 0, channels: Int32 = 0
        guard nag_wasapi_default_device(&name, 256, &rate, &channels) == 0 else { return nil }
        return String(cString: name)
    }

    public var deviceSampleRates: [Double] { [deviceRate] }
    /// The rate is the device's shared-mode mix rate, set in Windows' Sound settings: one app does
    /// not change it for all the others.
    public func setDeviceSampleRate(_ rate: Double) -> Bool { false }
    /// Shared mode's period is Windows' to choose, not an app's.
    public func setDeviceBufferFrames(_ frames: UInt32) -> Bool { false }

    // MARK: - Monitor controls (read on the audio thread; a stale read costs one block)

    public var masterGain: Float = 1
    public var dimmed = false
    public var monoFold = false
    public var safetyLimiter = false
    /// −20 dB, the conventional dim amount on a monitor controller, as on the Mac.
    public static let dimGain: Float = 0.1

    public let loudness = LoudnessMeter()

    /// The three VST3 inserts (as the Mac's `InsertChain`): after the loudness
    /// measurement, before the monitor level, DIM, MONO and the limiter. Configured on the main
    /// thread whenever the device or the bus changes; processed on the render thread.
    public let inserts = VST3InsertChain()

    /// Tells the inserts the rate and width now playing. Main thread.
    private func configureInserts() {
        inserts.configure(sampleRate: deviceRate, channels: busChannels, maxFrames: Self.maxFrames)
    }

    // MARK: - Receivers

    private var receivers: [StreamReceiver] = []
    /// Guards `receivers`. The audio thread only ever *tries* it: if the list is mid-update it
    /// plays one block of silence rather than wait.
    private let receiverLock: UnsafeMutablePointer<SRWLOCK> = {
        let p = UnsafeMutablePointer<SRWLOCK>.allocate(capacity: 1)
        p.initialize(to: SRWLOCK())
        InitializeSRWLock(p)
        return p
    }()

    public func setReceivers(_ list: [StreamReceiver]) {
        for receiver in list { receiver.busChannels = busChannels }
        AcquireSRWLockExclusive(receiverLock)
        receivers = list
        ReleaseSRWLockExclusive(receiverLock)
    }

    private func currentReceivers() -> [StreamReceiver] {
        AcquireSRWLockExclusive(receiverLock)
        defer { ReleaseSRWLockExclusive(receiverLock) }
        return receivers
    }

    // MARK: - Starting and stopping

    private var thread: Thread?
    private var wanted = false
    private var reopen = false
    private let opened = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private var openError: String?

    /// Opens the device on the render thread — COM objects belong to the thread that made them —
    /// and waits for it, so a failure is reported here, as the Mac's `start` reports it.
    @discardableResult
    public func start() -> String? {
        stop()
        let width = plannedWidth()
        busChannels = width
        wanted = true
        openError = nil
        let t = Thread { [weak self] in self?.renderLoop(width: width) }
        t.name = "WASAPI render"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
        if opened.wait(timeout: .now() + 3) == .timedOut {
            return "The playback device did not open in time."
        }
        if let openError {
            wanted = false
            _ = finished.wait(timeout: .now() + 1)
            thread = nil
            return "Could not play on the default playback device: \(openError)."
        }
        for receiver in currentReceivers() { receiver.busChannels = busChannels }
        configureInserts()
        onStatusChange?()
        return nil
    }

    public func stop() {
        guard thread != nil else { return }
        wanted = false
        _ = finished.wait(timeout: .now() + 2)
        thread = nil
        running = false
    }

    /// The bus width to open at: what was asked for, clamped to what the device offers.
    private func plannedWidth() -> Int {
        var name = [CChar](repeating: 0, count: 256)
        var rate: Int32 = 0
        var channels: Int32 = 0
        if nag_wasapi_default_device(&name, 256, &rate, &channels) == 0, channels > 0 {
            mixChannels = Int(channels)
        }
        return max(2, min(requestedBusChannels, max(2, deviceChannels)))
    }

    @discardableResult
    public func setBusChannels(_ channels: Int) -> Int {
        requestedBusChannels = max(2, channels)
        let wanted = max(2, min(requestedBusChannels, max(2, deviceChannels)))
        guard running else { return wanted }
        guard wanted != busChannels else { return busChannels }
        if let error = start() { onError?(error) }
        return busChannels
    }

    // MARK: - The render thread

    /// The longest block rendered at once. A 20 ms buffer at 192 kHz is 3840 frames.
    private static let maxFrames = 4096
    private static let maxChannels = 64
    /// The bus, one plane per channel, made once: the audio thread must not allocate.
    private let planar = UnsafeMutablePointer<Float>.allocate(capacity: WASAPIOutput.maxFrames * WASAPIOutput.maxChannels)
    private let busPointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: WASAPIOutput.maxChannels)
    /// Where each bus channel goes in the device's interleaved buffer.
    private var outputSlot = [Int](repeating: 0, count: WASAPIOutput.maxChannels)
    private var limiterGain: Float = 1

    /// Opens the device, plays until it is lost or stopped, and opens it again if it was lost —
    /// following the default device when the user changes it in Windows.
    private func renderLoop(width: Int) {
        var first = true
        var width = width
        while wanted {
            let ok = runOnce(width: width, reportOpen: first)
            if first && !ok { break }                     // `start` reports it
            first = false
            guard wanted else { break }
            Thread.sleep(forTimeInterval: ok ? 0.3 : 1)
            // The width for whatever is the default device now. Worked out here without touching
            // anything the main thread reads; `runOnce` hands the result over.
            let offered = Self.defaultDeviceChannels() ?? 2
            width = max(2, min(requestedBusChannels, max(8, offered)))
        }
        running = false
        finished.signal()
    }

    /// The default playback device's channel count, or nil if Windows will not say.
    private static func defaultDeviceChannels() -> Int? {
        var name = [CChar](repeating: 0, count: 256)
        var rate: Int32 = 0
        var channels: Int32 = 0
        guard nag_wasapi_default_device(&name, 256, &rate, &channels) == 0, channels > 0 else { return nil }
        return Int(channels)
    }

    /// The rate the render thread mixes at. Its own copy, so it never reads `deviceRate` while the
    /// main thread is being handed a new one.
    private var renderRate: Double = 48000

    private func runOnce(width: Int, reportOpen: Bool) -> Bool {
        var rate: Int32 = 0, mixChannels: Int32 = 0, openedWidth: Int32 = 0, buffer: Int32 = 0
        var name = [CChar](repeating: 0, count: 256)
        var id = [CChar](repeating: 0, count: 256)
        var error = [CChar](repeating: 0, count: 256)
        choiceLock.lock(); let choice = renderChoice; choiceLock.unlock()
        var fellBack: Int32 = 0
        let openedDevice: OpaquePointer? = choice.map { w in
            w.withCString { nag_render_open_device($0, &fellBack, Int32(width), &rate, &mixChannels, &openedWidth, &buffer,
                                                   &name, 256, &id, 256, &error, 256) }
        } ?? nag_render_open_device(nil, &fellBack, Int32(width), &rate, &mixChannels, &openedWidth, &buffer,
                                    &name, 256, &id, 256, &error, 256)
        guard let device = openedDevice else {
            let text = String(cString: error)
            if reportOpen { openError = text; opened.signal() } else { report("Playback device: \(text)") }
            return false
        }
        defer { nag_render_close(device) }

        let channels = min(Int(openedWidth), Self.maxChannels)
        renderRate = Double(rate)
        loudness.configure(rate: renderRate, channels: channels)
        resetMeters(channels: channels)
        for c in 0..<Self.maxChannels {
            outputSlot[c] = c
            busPointers[c] = planar + c * Self.maxFrames
        }
        if channels == 8 { outputSlot[4] = 6; outputSlot[5] = 7; outputSlot[6] = 4; outputSlot[7] = 5 }

        // What the rest of the app reads, handed over in one go: directly on the first open, while
        // `start` waits on `opened` and reads nothing; on the main queue after a device change,
        // when the main thread may be reading at any moment.
        let deviceName = String(cString: name), deviceUID = String(cString: id)
        let publish = { [self] in
            self.deviceName = deviceName
            self.deviceUID = deviceUID
            self.deviceRate = Double(rate)
            self.mixChannels = Int(mixChannels)
            self.openedChannels = Int(openedWidth)
            self.busChannels = channels
            self.deviceBufferFrames = UInt32(buffer)
            self.usingFallback = fellBack != 0
        }

        guard nag_render_start(device) == 0 else {
            if reportOpen { openError = "the playback device would not start"; opened.signal() }
            else { report("The playback device would not start.") }
            return false
        }
        running = true
        if reportOpen {
            publish()
            opened.signal()
        } else {
            for receiver in currentReceivers() { receiver.busChannels = channels }
            DispatchQueue.main.async { [weak self] in
                publish()
                self?.configureInserts()
                self?.onStatusChange?()
            }
        }

        var lastDeviceCheck = CFAbsoluteTimeGetCurrent()
        while wanted {
            let room = Int(nag_render_wait(device, 200))
            if room < 0 {
                report("The playback device stopped; opening it again.")
                break
            }
            if room > 0 {
                let frames = min(room, Self.maxFrames)
                guard let out = nag_render_buffer(device, Int32(frames)) else {
                    report("The playback device stopped; opening it again.")
                    break
                }
                renderBlock(into: out, frames: frames, channels: channels)
                if nag_render_release(device, Int32(frames)) != 0 {
                    report("The playback device stopped; opening it again.")
                    break
                }
            }
            // Following the default: follow it when it changes. On a chosen device that was not
            // there: go back to it when it is. A COM round trip, so once a second.
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastDeviceCheck > 1 {
                lastDeviceCheck = now
                if let choice {
                    if fellBack != 0, choice.withCString({ nag_render_device_active(device, $0) }) != 0 {
                        report("The chosen playback device is back; playing on it again.")
                        break
                    }
                    if fellBack != 0, nag_render_default_changed(device) != 0 { break }
                } else if nag_render_default_changed(device) != 0 {
                    report("The default playback device changed; following it.")
                    break
                }
            }
        }
        running = false
        DispatchQueue.main.async { [weak self] in self?.onStatusChange?() }
        return true
    }

    private func report(_ text: String) {
        onError?(text)
    }

    /// Render callbacks so far: a counter that stops climbing means the device stopped asking.
    public private(set) var renderCalls: UInt64 = 0

    /// One block: the receivers mixed, loudness measured, the monitor controls, the meters, then
    /// interleaved into the device's buffer in Windows' channel order. Allocates nothing.
    private func renderBlock(into out: UnsafeMutablePointer<Float>, frames: Int, channels: Int) {
        renderCalls &+= 1
        renderBlockFrames = frames
        for c in 0..<channels { busPointers[c].update(repeating: 0, count: frames) }

        var active = false
        if TryAcquireSRWLockExclusive(receiverLock) != 0 {
            for receiver in receivers {
                receiver.render(into: busPointers, busCount: channels, frames: frames, outputRate: renderRate)
            }
            active = !receivers.isEmpty
            ReleaseSRWLockExclusive(receiverLock)
        }

        // Loudness on the summed bus, before master level, DIM and MONO, as on the Mac.
        if active { loudness.process(buses: busPointers, channels: channels, frames: frames) }

        // The inserts, in place, every block — a reverb's tail rings on after the last stream
        // stops, as it does on the Mac. A no-op with nothing live, and a pass-through for a block
        // it cannot take (mid-swap, or before a new width is configured).
        inserts.process(buses: busPointers, channels: channels, frames: frames)

        let gain = masterGain * (dimmed ? Self.dimGain : 1)
        let lfe = SMPTELayout.forChannelCount(channels)?.lfeIndex
        if monoFold, channels > 1 {
            let folded = lfe == nil ? channels : channels - 1
            let scale = folded > 0 ? 1 / Float(folded) : 0
            for i in 0..<frames {
                var sum: Float = 0
                for b in 0..<channels where b != lfe { sum += busPointers[b][i] }
                let mono = sum * scale * gain
                for b in 0..<channels where b != lfe { busPointers[b][i] = mono }
                if let lfe { busPointers[lfe][i] *= gain }
            }
        } else if gain != 1 {
            for b in 0..<channels {
                let plane = busPointers[b]
                for i in 0..<frames { plane[i] *= gain }
            }
        }

        if safetyLimiter { limit(frames: frames, channels: channels) }

        meter(frames: frames, channels: channels)

        for i in 0..<frames {
            let row = out + i * channels
            for c in 0..<channels { row[outputSlot[c]] = busPointers[c][i] }
        }
    }

    /// The safety limiter: a peak limiter just under full scale, instant attack, 100 ms release.
    /// The Mac uses Apple's limiter unit here; this is the plain version of the same promise —
    /// nothing reaches the device above −0.2 dBFS.
    private func limit(frames: Int, channels: Int) {
        let ceiling: Float = 0.977
        let release = Float(1 - exp(-1 / (0.1 * renderRate)))
        for i in 0..<frames {
            var peak: Float = 0
            for c in 0..<channels { peak = max(peak, abs(busPointers[c][i])) }
            let needed: Float = peak * limiterGain > ceiling ? ceiling / peak : 1
            if needed < limiterGain { limiterGain = needed } else { limiterGain += (1 - limiterGain) * release }
            if limiterGain < 1 { for c in 0..<channels { busPointers[c][i] *= limiterGain } }
        }
    }

    // MARK: - Metering (as the Mac's `AudioOutput`)

    /// A one-pole envelope evaluated continuously from its last update, so it can be sampled at
    /// any frame rate.
    private struct Follower {
        var from: Float = 0, target: Float = 0
        var at: CFAbsoluteTime = 0
        var tau: Double = 0.3

        mutating func update(to measured: Float, now: CFAbsoluteTime, attack: Double, release: Double) {
            let current = value(at: now)
            from = current
            target = measured
            tau = measured > current ? attack : release
            at = now
        }

        func value(at now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> Float {
            guard at > 0 else { return 0 }
            let elapsed = now - at
            guard elapsed > 0 else { return from }
            guard elapsed < tau * 8 else { return target }
            return target + (from - target) * Float(exp(-elapsed / tau))
        }
    }

    private let bars: UnsafeMutablePointer<Follower> = {
        let p = UnsafeMutablePointer<Follower>.allocate(capacity: WASAPIOutput.maxChannels)
        p.initialize(repeating: Follower(), count: WASAPIOutput.maxChannels)
        return p
    }()
    private var barCount = 2
    private var holdValue: Float = 0
    private var holdSetAt: CFAbsoluteTime = 0
    private let meterLock = SeqLock()
    /// [0] the clip latch, [1] the maximum.
    private let latches = SharedFloats(count: 2)

    private static let barAttackTau = 0.025
    private static let barReleaseTau = 0.22
    private static let holdSeconds = 1.5
    private static let holdFallTau = 1.20

    public private(set) var tapFrames = 0
    public private(set) var tapHz: Double = 0
    private var tapCallbacks = 0
    private var tapWindowStart: CFAbsoluteTime = 0

    private func resetMeters(channels: Int) {
        meterLock.write {
            for i in 0..<Self.maxChannels { bars[i] = Follower() }
            barCount = min(channels, Self.maxChannels)
        }
    }

    public func peak(_ channel: Int) -> Float {
        guard channel >= 0, channel < barCount else { return 0 }
        return meterLock.read { bars[channel] }.value()
    }
    public var peakL: Float { peak(0) }
    public var peakR: Float { peak(barCount > 1 ? 1 : 0) }
    public var peakHold: Float { meterLock.read { heldPeak() } }
    public var peakMax: Float { latches[1] }
    public var clipped: Bool { latches[0] > 0 }
    public func clearPeakMax() { latches[1] = 0 }
    public func clearClip() { latches[0] = 0; latches[1] = 0 }

    private func heldPeak(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> Float {
        guard holdValue > 0, holdSetAt > 0 else { return 0 }
        let elapsed = now - (holdSetAt + Self.holdSeconds)
        guard elapsed > 0 else { return holdValue }
        guard elapsed < Self.holdFallTau * 8 else { return 0 }
        return holdValue * Float(exp(-elapsed / Self.holdFallTau))
    }

    /// Peaks of one block, after everything, so the bars show what reaches the device.
    private func meter(frames: Int, channels: Int) {
        let now = CFAbsoluteTimeGetCurrent()
        var instant: Float = 0
        meterLock.write {
            let counted = min(channels, barCount)
            for c in 0..<counted {
                var peak: Float = 0
                let plane = busPointers[c]
                for i in 0..<frames { peak = max(peak, abs(plane[i])) }
                bars[c].update(to: peak, now: now, attack: Self.barAttackTau, release: Self.barReleaseTau)
                instant = max(instant, peak)
            }
            tapFrames = frames
            tapCallbacks += 1
            if tapWindowStart == 0 { tapWindowStart = now }
            if now - tapWindowStart >= 1 {
                tapHz = Double(tapCallbacks) / (now - tapWindowStart)
                tapCallbacks = 0
                tapWindowStart = now
            }
            if instant > heldPeak(now: now) {
                holdValue = instant
                holdSetAt = now
            }
        }
        if instant > latches[1] { latches[1] = instant }
        if instant >= 0.999 { latches[0] = 1 }
    }

    // MARK: - Diagnostics

    public var graphSummary: String {
        guard running else { return "not running" }
        let layout = SMPTELayout.forChannelCount(openedChannels)?.rawValue ?? "\(openedChannels) ch direct"
        let chain = inserts.summary.joined(separator: " → ")
        return "source" + (chain.isEmpty ? "" : " → " + chain) + " → monitor controls" + (safetyLimiter ? " → limiter" : "")
            + " → WASAPI shared (\(openedChannels) ch float, \(layout)"
            + (openedChannels == 8 ? ", sides/rears reordered" : "")
            + ") → device mix (\(mixChannels) ch, \(Int(deviceRate)) Hz)"
    }
}
