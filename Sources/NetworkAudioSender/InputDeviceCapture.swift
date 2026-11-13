import Foundation
import AVFoundation
import CoreAudio

/// An input device as the Sender's source: a microphone, an
/// interface's inputs, or a virtual device such as BlackHole — taken whole, at its own channel
/// count and rate. No process tap and no aggregate: an IOProc on the device itself.
///
/// macOS asks for the **Microphone** permission the first time (any input device counts). Until
/// it is granted the capture says so rather than sending silence without a reason.
final class InputDeviceCapture: SystemAudioSource {
    var onAudio: ((UnsafePointer<Float>, Int, Int, Int) -> Void)?
    var onStateChange: (() -> Void)?
    var onRestart: ((String) -> Void)?

    private(set) var running = false
    private(set) var sampleRate = 0
    private(set) var channels = 0
    private(set) var lastError: String?
    /// Not used: an input is not this Mac's output, so there is nothing to silence.
    var muteLocal = false
    /// Not used: an input device is sent at its own channel count.
    var stereoOnly = false
    private(set) var callbacks: UInt64 = 0
    private(set) var lastBufferCount = 0
    private(set) var lastBufferBytes = 0

    let deviceUID: String
    private let queue = DispatchQueue(label: "Network Audio Sender input", qos: .userInteractive)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let interleaved: UnsafeMutablePointer<Float>
    private let capacity = 8192 * 64
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var restartPending = false
    /// Wanted running; may be waiting for the device to come back.
    private var wanted = false

    init(deviceUID: String) {
        self.deviceUID = deviceUID
        interleaved = .allocate(capacity: capacity)
    }

    deinit {
        stop()
        interleaved.deallocate()
    }

    @discardableResult
    func start() -> String? {
        wanted = true
        stopDevice()
        let error = startDevice()
        lastError = error
        running = error == nil
        watch()
        onStateChange?()
        return error
    }

    func stop() {
        wanted = false
        unwatch()
        stopDevice()
        running = false
        onStateChange?()
    }

    func othersArePlaying() -> Bool { running }

    private func startDevice() -> String? {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            // Ask, then try again once answered.
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                DispatchQueue.main.async { if self?.wanted == true { self?.start() } }
            }
            return "Waiting for permission to use the microphone and other inputs."
        default:
            return "Microphone access is off for this app. Turn it on in System Settings → Privacy & "
                + "Security → Microphone."
        }
        guard let device = Self.inputDevice(withUID: deviceUID) else {
            return "\(Self.lastKnownName[deviceUID] ?? "The input device") isn't connected."
        }
        deviceID = device
        let total = Self.inputChannelCount(of: device)
        guard total > 0 else { return "That device has no inputs." }
        channels = min(64, total)
        sampleRate = Int(Self.nominalRate(of: device).rounded())
        var proc: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue) { [weak self] _, input, _, _, _ in
            self?.receive(input)
        }
        guard status == noErr, let proc else { return "Could not attach to the input device (\(SystemAudioCapture.code(status)))." }
        procID = proc
        status = AudioDeviceStart(device, proc)
        guard status == noErr else { return "Could not start the input device (\(SystemAudioCapture.code(status)))." }
        return nil
    }

    private func stopDevice() {
        if deviceID != kAudioObjectUnknown, let procID {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
        }
        procID = nil
        deviceID = AudioObjectID(kAudioObjectUnknown)
    }

    /// Every input buffer, whatever its channel count, interleaved in order.
    private func receive(_ input: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        callbacks &+= 1
        lastBufferCount = buffers.count
        lastBufferBytes = Int(buffers.first?.mDataByteSize ?? 0)
        let total = min(channels, buffers.reduce(0) { $0 + Int($1.mNumberChannels) })
        guard total > 0, let first = buffers.first, first.mNumberChannels > 0 else { return }
        let frames = min(Int(first.mDataByteSize) / (4 * Int(first.mNumberChannels)), capacity / total)
        guard frames > 0 else { return }
        // Used where it lies only when every channel in it is sent: a single buffer wider than
        // `channels` (more than 64) is strided by its own width, so it is copied down below.
        if buffers.count == 1, Int(first.mNumberChannels) == total, let data = first.mData {
            onAudio?(UnsafePointer(data.assumingMemoryBound(to: Float.self)), frames, total, sampleRate)
            return
        }
        var c = 0
        for buffer in buffers {
            let n = Int(buffer.mNumberChannels)
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { c += n; continue }
            for k in 0..<n where c + k < total {
                for f in 0..<frames { interleaved[f * total + c + k] = data[f * n + k] }
            }
            c += n
        }
        onAudio?(UnsafePointer(interleaved), frames, total, sampleRate)
    }

    // MARK: - Following the device

    /// The device coming and going, and its rate changing: rebuilt a moment later.
    private func watch() {
        unwatch()
        listen(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, because: "devices changed")
        if deviceID != kAudioObjectUnknown {
            listen(deviceID, kAudioDevicePropertyNominalSampleRate, because: "the input's sample rate changed")
        }
    }

    private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, because reason: String) {
        var address = SystemAudioCapture.address(selector)
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
    }

    private func scheduleRestart(because reason: String) {
        guard wanted, !restartPending else { return }
        // Only when it matters: the device appeared, vanished, or this one changed rate.
        let present = Self.inputDevice(withUID: deviceUID) != nil
        if reason == "devices changed", present == running, running { return }
        restartPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.restartPending = false
            guard self.wanted else { return }
            let error = self.start()
            self.onRestart?(error.map { "Input rebuilt because \(reason): \($0)" }
                            ?? "Input rebuilt because \(reason).")
        }
    }

    // MARK: - Devices

    struct Device: Identifiable, Hashable {
        let uid: String, name: String, channels: Int
        var id: String { uid }
    }

    /// Names seen, for saying which device is missing.
    static var lastKnownName: [String: String] = [:]

    /// Every device with inputs, by name — not this app's own private capture devices.
    static func inputDevices() -> [Device] {
        var address = SystemAudioCapture.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        let devices = ids.compactMap { id -> Device? in
            let n = inputChannelCount(of: id)
            guard n > 0, let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName), !name.hasPrefix("Network Audio") else { return nil }
            return Device(uid: uid, name: name, channels: n)
        }
        for d in devices { lastKnownName[d.uid] = d.name }
        return devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func inputDevice(withUID uid: String) -> AudioObjectID? {
        var address = SystemAudioCapture.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return nil }
        return ids.first { string($0, kAudioDevicePropertyDeviceUID) == uid && inputChannelCount(of: $0) > 0 }
    }

    static func inputChannelCount(of device: AudioObjectID) -> Int {
        var config = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                mScope: kAudioObjectPropertyScopeInput,
                                                mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &config, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &config, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func nominalRate(of device: AudioObjectID) -> Double {
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = SystemAudioCapture.address(kAudioDevicePropertyNominalSampleRate)
        _ = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
        return rate
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = SystemAudioCapture.address(selector)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
