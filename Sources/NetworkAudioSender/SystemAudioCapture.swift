import Foundation
import AppKit
import CoreAudio

/// Captures what this Mac is playing, through a CoreAudio **process tap** (macOS 14.2+): no
/// driver, no virtual device, nothing for the user to install. The first capture asks for the
/// system's audio-recording permission.
///
/// The shape, which is how Apple's own sample does it:
///
///     process tap (every process but these, on the output device's own channels — or mixed
///                  to stereo when asked)
///       → private aggregate device, clocked by the current output device
///       → IOProc on our own queue → `onAudio`
///
/// **Two apps are always left out of the capture: this one and the Grabber.** A Mac running both
/// would otherwise take the Grabber's playback — which is itself network audio — and send it
/// straight back out, a loop at network latency.
final class SystemAudioCapture: SystemAudioSource {
    static let grabberBundleID = "app.networkaudiograbber.monitor"

    /// Interleaved float frames, the channel count and the rate, on the capture queue.
    var onAudio: ((UnsafePointer<Float>, Int, Int, Int) -> Void)?
    /// Something about the capture changed — it started, stopped or failed. Main queue.
    var onStateChange: (() -> Void)?
    /// Why the capture is being rebuilt, for the log. While it is, nothing is sent.
    var onRestart: ((String) -> Void)?

    private(set) var running = false
    private(set) var sampleRate = 0
    private(set) var channels = 0
    private(set) var lastError: String?

    /// Silence the Mac's own output while capturing, so the audio goes only to the network.
    var muteLocal = false

    /// Mix everything to stereo instead of sending the output device's own channel count. Off
    /// by default: what goes out should be what the Mac is playing, and on a 5.1 or 7.1 output
    /// that is six or eight channels, which the Grabber folds down or passes through itself.
    var stereoOnly = false

    /// For the self-test: tap only this process, muted, instead of everything but two apps —
    /// so a test tone can be captured without capturing, or silencing, anything the user is
    /// playing.
    var onlyProcess: pid_t?

    /// **Chosen apps**: tap only these apps, by bundle
    /// identifier, instead of everything. An app captures once it has used audio; until one of
    /// them has, nothing is tapped and the Sender sends silence. Nil: every app (the default).
    var onlyApps: [String]?
    /// The apps' audio process objects the current tap was made with, to know when to rebuild.
    private var tappedApps: Set<AudioObjectID> = []

    private let queue = DispatchQueue(label: "Network Audio Sender capture", qos: .userInteractive)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var interleaved: UnsafeMutablePointer<Float>
    /// Input buffers ahead of the tap's in each callback. The aggregate carries the output
    /// device as its clock, and with it **that device's own inputs** — an interface's microphone
    /// channels arrive first and the tap's after them. Reading from the front took the interface's
    /// mic as "left" and the tapped stereo, interleaved, as "right".
    private var skipBuffers = 0
    private static let maxChannels = 64
    private let interleavedCapacity = 8192 * 16

    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var observers: [NSObjectProtocol] = []
    private var restartPending = false

    init() {
        interleaved = .allocate(capacity: interleavedCapacity)
    }

    deinit {
        stop()
        interleaved.deallocate()
    }

    // MARK: - Lifecycle

    /// Starts capturing. Returns an error message on failure.
    @discardableResult
    func start() -> String? {
        stopCapture()
        let error = startCapture()
        lastError = error
        running = error == nil
        if running { watchForChanges() }
        onStateChange?()
        return error
    }

    func stop() {
        unwatch()
        stopCapture()
        running = false
        onStateChange?()
    }

    private func startCapture() -> String? {
        let description: CATapDescription
        if let pid = onlyProcess {
            guard let process = Self.processObject(pid) else {
                return "The test process is not playing audio yet."
            }
            description = CATapDescription(stereoMixdownOfProcesses: [process])
            description.muteBehavior = .muted
        } else if let apps = onlyApps {
            let objects = Self.processObjects(forApps: apps)
            tappedApps = Set(objects)
            guard !objects.isEmpty else {
                // None of them is playing yet: nothing to tap. Report the output's format so the
                // status reads as running; the watcher below builds the tap when one appears.
                sampleRate = Self.defaultOutput()?.rate ?? 48000
                channels = 2
                return nil
            }
            let outputUID = Self.defaultOutputUID() ?? ""
            if stereoOnly || outputUID.isEmpty {
                description = CATapDescription(stereoMixdownOfProcesses: objects)
            } else {
                description = CATapDescription(processes: objects, deviceUID: outputUID, stream: 0)
            }
            description.muteBehavior = muteLocal ? .mutedWhenTapped : .unmuted
        } else {
            // What is playing *to the output device*, on that device's own channels — unless
            // stereo is asked for, or the device cannot be named, when everything is mixed down.
            let outputUID = Self.defaultOutputUID() ?? ""
            if stereoOnly || outputUID.isEmpty {
                description = CATapDescription(stereoGlobalTapButExcludeProcesses: excludedProcesses())
            } else {
                description = CATapDescription(excludingProcesses: excludedProcesses(),
                                               deviceUID: outputUID, stream: 0)
            }
            if #available(macOS 26.0, *) {
                // By bundle identifier too, which also covers a Grabber launched after this tap
                // was made. Older systems rely on the relaunch watcher below instead.
                description.bundleIDs = [Self.grabberBundleID, Bundle.main.bundleIdentifier ?? ""]
                    .filter { !$0.isEmpty }
            }
            description.muteBehavior = muteLocal ? .mutedWhenTapped : .unmuted
        }
        description.name = "Network Audio Sender"
        description.uuid = UUID()
        description.isPrivate = true

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { return "Could not create the audio tap (\(Self.code(status)))." }
        tapID = tap

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = Self.address(kAudioTapPropertyFormat)
        status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
        guard status == noErr else { return "Could not read the tap's format (\(Self.code(status)))." }
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32 else {
            return "The tap delivers a format this app does not read."
        }
        sampleRate = Int(format.mSampleRate.rounded())
        channels = min(Self.maxChannels, Int(format.mChannelsPerFrame))

        // The aggregate is clocked by the output device, so the capture runs at the rate the
        // Mac is actually playing at.
        let outputUID = Self.defaultOutputUID() ?? ""
        var aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Network Audio Sender",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        skipBuffers = 0
        if !outputUID.isEmpty {
            aggregate[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            aggregate[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
            skipBuffers = Self.inputBufferCount(ofDefaultOutput: ())
        }
        var device = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
        guard status == noErr else {
            return "Could not create the capture device (\(Self.code(status)))."
        }
        aggregateID = device

        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, queue) {
            [weak self] _, input, _, _, _ in
            self?.receive(input)
        }
        guard status == noErr, let proc else {
            return "Could not attach to the capture device (\(Self.code(status)))."
        }
        procID = proc
        status = AudioDeviceStart(aggregateID, proc)
        guard status == noErr else { return "Could not start capturing (\(Self.code(status)))." }
        return nil
    }

    private func stopCapture() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: - Audio

    /// What the capture callback has seen, for the self-test: whether it is called at all, and
    /// with what — the first thing to know when a capture delivers nothing.
    private(set) var callbacks: UInt64 = 0
    private(set) var lastBufferCount = 0
    private(set) var lastBufferBytes = 0

    private func receive(_ input: UnsafePointer<AudioBufferList>) {
        let all = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        callbacks &+= 1
        lastBufferCount = all.count
        // The tap's buffers are the ones after the output device's own inputs. If the count
        // ever disagrees, the tap is at least the last buffer.
        let start = all.count > skipBuffers ? skipBuffers : max(0, all.count - 1)
        let buffers = Array(all[start...])
        lastBufferBytes = Int(buffers.first?.mDataByteSize ?? 0)
        guard let first = buffers.first, let firstData = first.mData else { return }

        let frames: Int
        let channelCount: Int
        let samples: UnsafePointer<Float>
        if buffers.count == 1 {
            // Interleaved: use it where it lies, unless it is wider than is sent (more than 64
            // channels), when the first `maxChannels` are copied down into scratch.
            let width = max(1, Int(first.mNumberChannels))
            let data = firstData.assumingMemoryBound(to: Float.self)
            if width <= Self.maxChannels {
                channelCount = width
                frames = Int(first.mDataByteSize) / (4 * width)
                samples = UnsafePointer(data)
            } else {
                channelCount = Self.maxChannels
                frames = min(Int(first.mDataByteSize) / (4 * width), interleavedCapacity / channelCount)
                for f in 0..<frames {
                    for c in 0..<channelCount { interleaved[f * channelCount + c] = data[f * width + c] }
                }
                samples = UnsafePointer(interleaved)
            }
        } else {
            // One buffer per channel: interleave into scratch, the first `maxChannels` of them.
            channelCount = min(buffers.count, Self.maxChannels)
            frames = min(Int(first.mDataByteSize) / 4, interleavedCapacity / channelCount)
            for (c, buffer) in buffers.prefix(channelCount).enumerated() {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for f in 0..<frames { interleaved[f * channelCount + c] = data[f] }
            }
            samples = UnsafePointer(interleaved)
        }
        guard frames > 0 else { return }
        onAudio?(samples, frames, channelCount, sampleRate)
    }

    // MARK: - Following the system

    /// Rebuilds the capture when anything under it changes: the output device, its sample
    /// rate, sleep and wake, and — before macOS 26, where exclusion is by process — the Grabber
    /// starting, since a process can only be excluded once it exists.
    private func watchForChanges() {
        unwatch()
        listen(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
               because: "the output device changed")
        if aggregateID != kAudioObjectUnknown {
            listen(aggregateID, kAudioDevicePropertyNominalSampleRate, because: "the sample rate changed")
        }
        // Chosen apps: rebuild when one of them starts (or stops) having audio.
        if onlyApps != nil {
            var address = Self.address(kAudioHardwarePropertyProcessObjectList)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self, let apps = self.onlyApps else { return }
                if Set(Self.processObjects(forApps: apps)) != self.tappedApps {
                    self.scheduleRestart(because: "a chosen app started or stopped")
                }
            }
            let system = AudioObjectID(kAudioObjectSystemObject)
            if AudioObjectAddPropertyListenerBlock(system, &address, DispatchQueue.main, block) == noErr {
                listeners.append((system, address, block))
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            self?.scheduleRestart(because: "the Mac woke")
        })
        observers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                            object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == Self.grabberBundleID else { return }
            // Its process object appears once it opens its audio engine, a moment after launch.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self?.scheduleRestart(because: "Network Audio Grabber opened, and is left out of the capture")
            }
        })
    }

    private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, because reason: String) {
        var address = Self.address(selector)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleRestart(because: reason) }
        if AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block) == noErr {
            listeners.append((object, address, block))
        }
    }

    private func unwatch() {
        for (object, address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, DispatchQueue.main, block)
        }
        listeners.removeAll()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
    }

    /// One change often raises several signals, and the hardware is not settled the instant the
    /// first arrives — so restarts are coalesced and made a moment later.
    private func scheduleRestart(because reason: String) {
        guard running, !restartPending else { return }
        restartPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.restartPending = false
            guard self.running else { return }
            let began = CFAbsoluteTimeGetCurrent()
            let error = self.start()
            let ms = (CFAbsoluteTimeGetCurrent() - began) * 1000
            self.onRestart?(error.map { "Capture rebuilt because \(reason), and it failed: \($0)" }
                ?? String(format: "Capture rebuilt because %@ (%.0f ms, plus 400 ms to let it settle). "
                          + "Nothing is sent meanwhile.", reason, ms))
        }
    }

    // MARK: - HAL helpers

    private func excludedProcesses() -> [AudioObjectID] {
        var pids = [getpid()]
        pids += NSRunningApplication.runningApplications(withBundleIdentifier: Self.grabberBundleID)
            .map(\.processIdentifier)
        return pids.compactMap(Self.processObject)
    }

    /// Whether any app this tap would capture is playing audio right now: every process with
    /// output running, less this app and the Grabber, which the tap leaves out. Silence while
    /// nothing plays is normal; silence while something does is what a missing recording
    /// permission looks like, and only then is it worth saying so.
    func othersArePlaying() -> Bool {
        if let apps = onlyApps {
            // Only the chosen apps count: silence while they are quiet is normal.
            var running = Self.address(kAudioProcessPropertyIsRunningOutput)
            return Self.processObjects(forApps: apps).contains { object in
                var value: UInt32 = 0
                var size = UInt32(MemoryLayout<UInt32>.size)
                return AudioObjectGetPropertyData(object, &running, 0, nil, &size, &value) == noErr && value != 0
            }
        }
        let excluded = Set(excludedProcesses())
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return false }
        var running = Self.address(kAudioProcessPropertyIsRunningOutput)
        return objects.contains { object in
            guard !excluded.contains(object) else { return false }
            var value: UInt32 = 0
            var valueSize = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(object, &running, 0, nil, &valueSize, &value) == noErr && value != 0
        }
    }

    /// The audio process objects of the running apps with these bundle identifiers — and of their
    /// helper processes, which is where a browser's sound actually plays from.
    static func processObjects(forApps bundleIDs: [String]) -> [AudioObjectID] {
        let wanted = Set(bundleIDs)
        var address = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        var bundleAddress = Self.address(kAudioProcessPropertyBundleID)
        return objects.filter { object in
            var id: Unmanaged<CFString>?
            var idSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(object, &bundleAddress, 0, nil, &idSize, &id) == noErr,
                  let bundle = id?.takeRetainedValue() as String? else { return false }
            // A helper's identifier extends its app's: com.example.Browser.helper (Renderer).
            return wanted.contains(bundle) || wanted.contains { bundle.hasPrefix($0 + ".") }
        }
    }

    /// Bundle identifiers of the processes playing sound right now.
    static func playingBundleIDs() -> [String] {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        var running = Self.address(kAudioProcessPropertyIsRunningOutput)
        var bundleAddress = Self.address(kAudioProcessPropertyBundleID)
        return objects.compactMap { object in
            var value: UInt32 = 0
            var valueSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(object, &running, 0, nil, &valueSize, &value) == noErr, value != 0 else { return nil }
            var id: Unmanaged<CFString>?
            var idSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(object, &bundleAddress, 0, nil, &idSize, &id) == noErr else { return nil }
            return id?.takeRetainedValue() as String?
        }
    }

    /// The audio process object for a PID, which exists once that process has used audio.
    static func processObject(_ pid: pid_t) -> AudioObjectID? {
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid,
                                                &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    /// How many input buffers the default output device contributes to an aggregate — its
    /// input streams, which an interface with a microphone has and built-in speakers do not.
    static func inputBufferCount(ofDefaultOutput _: Void) -> Int {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         0, nil, &size, &device) == noErr else { return 0 }
        var config = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                mScope: kAudioObjectPropertyScopeInput,
                                                mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyDataSize(device, &config, 0, nil, &size) == noErr,
              size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &config, 0, nil, &size, raw) == noErr else { return 0 }
        return Int(raw.assumingMemoryBound(to: AudioBufferList.self).pointee.mNumberBuffers)
    }

    /// The Mac's output device — what the capture taps — by name, and the rate it runs at, for
    /// the header. Nil if there is none.
    static func defaultOutput() -> (name: String, rate: Int)? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address = Self.address(kAudioObjectPropertyName)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr,
              let name else { return nil }
        var rate: Float64 = 0
        size = UInt32(MemoryLayout<Float64>.size)
        address = Self.address(kAudioDevicePropertyNominalSampleRate)
        _ = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
        return (name.takeRetainedValue() as String, Int(rate.rounded()))
    }

    static func defaultOutputUID() -> String? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         0, nil, &size, &device) == noErr else { return nil }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address = Self.address(kAudioDevicePropertyDeviceUID)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr,
              let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// A HAL status as its four-character code where it has one — what Apple's documentation
    /// and forums quote — else the number.
    static func code(_ status: OSStatus) -> String {
        let bytes = withUnsafeBytes(of: status.bigEndian) { Array($0) }
        let printable = bytes.allSatisfy { (0x20...0x7E).contains($0) }
        return printable ? "'" + String(decoding: bytes, as: UTF8.self) + "'" : "\(status)"
    }
}
