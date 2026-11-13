import Foundation
import AppKit

/// What the Sender sends.
/// One kind at a time:
/// - **system**: everything this Mac plays, as before — the default;
/// - **apps**: only the chosen apps (by bundle identifier), through the same process tap;
/// - **input**: one input device whole, at its own channel count — a microphone, an interface's
///   inputs, BlackHole.
public enum SendSource: Equatable {
    case system
    case apps([String])
    case input(uid: String, name: String)

    /// Stored as text in each app's settings.
    var stored: String {
        switch self {
        case .system: return "system"
        case .apps(let ids): return "apps:" + ids.joined(separator: ",")
        case .input(let uid, let name): return "input:" + uid + "\u{1F}" + name
        }
    }

    init(stored: String?) {
        guard let stored else { self = .system; return }
        if stored.hasPrefix("apps:") {
            let ids = stored.dropFirst(5).split(separator: ",").map(String.init)
            self = ids.isEmpty ? .system : .apps(ids)
        } else if stored.hasPrefix("input:") {
            let parts = stored.dropFirst(6).split(separator: "\u{1F}", maxSplits: 1).map(String.init)
            self = parts.count == 2 ? .input(uid: parts[0], name: parts[1]) : .system
        } else {
            self = .system
        }
    }

    var isInput: Bool { if case .input = self { return true }; return false }
}

/// The capture the engine holds, for the life of the app: passes everything through to whichever
/// real capture the source needs, and swaps it when the source changes. The shared engine keeps
/// one `SystemAudioSource` and never knows (it is also the Windows build's).
final class SwitchableCapture: SystemAudioSource {
    private(set) var inner: SystemAudioSource

    var source: SendSource {
        didSet { if source != oldValue { swap() } }
    }

    init(source: SendSource) {
        self.source = source
        inner = Self.make(for: source)
    }

    private static func make(for source: SendSource) -> SystemAudioSource {
        switch source {
        case .system:
            return SystemAudioCapture()
        case .apps(let ids):
            let capture = SystemAudioCapture()
            capture.onlyApps = ids
            return capture
        case .input(let uid, let name):
            InputDeviceCapture.lastKnownName[uid] = name
            return InputDeviceCapture(deviceUID: uid)
        }
    }

    private func swap() {
        let wasRunning = inner.running
        inner.stop()
        let next = Self.make(for: source)
        next.onAudio = onAudio
        next.onStateChange = onStateChange
        next.onRestart = onRestart
        next.muteLocal = muteLocal
        next.stereoOnly = stereoOnly
        inner = next
        if wasRunning { inner.start() } else { onStateChange?() }
    }

    var onAudio: ((UnsafePointer<Float>, Int, Int, Int) -> Void)? {
        didSet { inner.onAudio = onAudio }
    }
    var onStateChange: (() -> Void)? {
        didSet { inner.onStateChange = onStateChange }
    }
    var onRestart: ((String) -> Void)? {
        didSet { inner.onRestart = onRestart }
    }
    var muteLocal = false { didSet { inner.muteLocal = muteLocal } }
    var stereoOnly = false { didSet { inner.stereoOnly = stereoOnly } }

    var running: Bool { inner.running }
    var sampleRate: Int { inner.sampleRate }
    var channels: Int { inner.channels }
    var lastError: String? { inner.lastError }
    var callbacks: UInt64 { inner.callbacks }
    var lastBufferCount: Int { inner.lastBufferCount }
    var lastBufferBytes: Int { inner.lastBufferBytes }
    @discardableResult func start() -> String? { inner.start() }
    func stop() { inner.stop() }
    func othersArePlaying() -> Bool { inner.othersArePlaying() }
}

/// A running app, for the Chosen apps list.
struct RunningAudioApp: Identifiable, Hashable {
    let bundleID: String
    let name: String
    let icon: NSImage?
    /// Making sound right now.
    let playing: Bool
    var id: String { bundleID }

    /// Regular apps running now, less this one and the Grabber (which the Sender never sends),
    /// playing ones first.
    static func list() -> [RunningAudioApp] {
        let own = Bundle.main.bundleIdentifier ?? ""
        let playingIDs = Set(SystemAudioCapture.playingBundleIDs())
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> RunningAudioApp? in
                guard let id = app.bundleIdentifier, id != own, id != SystemAudioCapture.grabberBundleID,
                      id != "app.networkaudiosender.send" else { return nil }
                let playing = playingIDs.contains { $0 == id || $0.hasPrefix(id + ".") }
                return RunningAudioApp(bundleID: id, name: app.localizedName ?? id, icon: app.icon, playing: playing)
            }
            .sorted { ($0.playing ? 0 : 1, $0.name.lowercased()) < ($1.playing ? 0 : 1, $1.name.lowercased()) }
    }

    /// A chosen app's name when it is not running, from its bundle if installed.
    static func name(of bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }
}
