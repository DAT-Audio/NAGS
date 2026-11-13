import Foundation
import WinSDK
import NetworkAudioEngine

/// Windows' Grabber: the shared engine's `GrabberEngine`
/// over WASAPI render. The Mac's equivalent is `AppState`, which adds its windows, inserts, the
/// Send, internet radio and the Bonjour browsers; this adds what Windows can answer today and
/// nothing else.
///
/// What it finds and plays is the engine's: SAP (AES67), RAVENNA and Dante labelling over
/// Windows' own mDNS, VBAN with the Sender handshake, Scream, and plain RTP when switched on.
/// **Not here yet:** internet radio, which the Mac decodes with macOS itself.
///
/// Nothing plays until asked for, and a Sender that asks its own user before this Grabber may
/// listen shows as asking or declined — as on the Mac. Nothing is accepted silently.
public final class WindowsGrabber: GrabberEngine {
    public let wasapi: WASAPIOutput
    /// Dante devices over mDNS, kept for their TXT records (`nag-grab --dante-txt`).
    let danteBrowser: WindowsDanteBrowser
    /// Each Dante device's TXT records: device → service type → key → value.
    public func danteTXTRecords() -> [String: [String: [String: String]]] { danteBrowser.txtRecords() }
    public static let version = "0.16.2"

    public init(defaults: UserDefaults, logFile: URL?) {
        let output = WASAPIOutput()
        wasapi = output
        // The chosen output device (as the Mac's Settings → Output), applied before the engine starts.
        if let id = defaults.string(forKey: "outputDeviceID") {
            output.setPreferredDevice(id: id, name: defaults.string(forKey: "outputDeviceChosenName") ?? "")
        }
        GrabberEngine.computerName = { WindowsGrabber.pcName() }
        // RAVENNA and Dante over Windows' own mDNS (`WindowsBonjour.swift`), with the Mac's
        // defaults: RAVENNA and Dante on (the shared default in
        // `GrabberEngine`; a choice already saved is kept). `--test` turns both off.
        let dante = WindowsDanteBrowser()
        danteBrowser = dante
        super.init(defaults: defaults, output: output, hostMode: false, logFile: logFile,
                   ravenna: WindowsRavennaBrowser(), dante: dante)
    }

    public override func appVersion() -> String { "\(Self.version) for Windows" }

    /// Keeps Windows from sleeping while a stream plays, as App Nap is kept off on the Mac. The
    /// display may still sleep; only the system is held awake.
    public override func setBusy(_ busy: Bool) {
        guard busy != isBusy else { return }
        isBusy = busy
        let continuous: UInt32 = 0x8000_0000           // ES_CONTINUOUS
        let system: UInt32 = 0x0000_0001               // ES_SYSTEM_REQUIRED
        _ = SetThreadExecutionState(EXECUTION_STATE(busy ? continuous | system : continuous))
    }
    private var isBusy = false

    /// This PC's name, for the default name the Grabber gives Senders.
    static func pcName() -> String {
        var size: DWORD = 256
        var buffer = [WCHAR](repeating: 0, count: Int(size))
        guard GetComputerNameW(&buffer, &size) else { return "" }
        return String(decoding: buffer.prefix(Int(size)), as: UTF16.self)
    }

    // MARK: - Output device

    /// Plays on a chosen device whatever Windows' own default is, or on the default (nil).
    public func chooseOutputDevice(_ device: WASAPIOutput.RenderDevice?) {
        defaults.set(device?.id, forKey: "outputDeviceID")
        defaults.set(device?.name ?? "", forKey: "outputDeviceChosenName")
        wasapi.setPreferredDevice(id: device?.id, name: device?.name ?? "")
        append(log: device.map { "Output: \($0.name), whatever Windows' own output setting." }
                    ?? "Output: the system default (\(WASAPIOutput.defaultDeviceName() ?? "none")), following Windows' setting.")
        refreshOutputStatus()
    }

    /// Takes a stream added from pasted SDP off the list (as the Mac's does). Nothing announces
    /// it, so nothing brings it back.
    public func removeManualStream(_ id: String) {
        guard let stream = streams.first(where: { $0.id == id })?.description, stream.source == .manual else { return }
        unsubscribe(id, reason: "it was removed")
        streams.removeAll { $0.id == id }
        lastSeenAt[id] = nil
        health[id] = nil
        openStreamIDs.remove(id)
        append(log: "Removed “\(stream.name)”.")
    }

    // MARK: - For the fronts

    /// The streams as listed: what is playing first, as the Mac's compact window puts its
    /// Listening section first, then the rest in the engine's order.
    public var listed: [DiscoveredStream] {
        let visible = visibleStreams
        return visible.filter { isSubscribed($0.id) } + visible.filter { !isSubscribed($0.id) }
    }

    /// A row's status in words, as the Mac's row shows it.
    public func statusText(_ id: String) -> String {
        if let approval = vbanApprovals[id] { return approval == .waiting ? "Asking…" : "Declined" }
        if let failure = joinFailures[id] { return "Failed: \(failure)" }
        guard isSubscribed(id) else {
            if autoStopNote(id) != nil { return "Auto-stopped" }
            return ""
        }
        return isReceiving(id) ? "Receiving" : "Waiting for audio"
    }
}
