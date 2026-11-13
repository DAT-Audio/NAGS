import SwiftUI
import AppKit
import AudioToolbox
import CoreAudioKit
import AudioToolbox.AUCocoaUIView
import NetworkAudioAtomics

/// The Audio Units, maker "DAT Audio":
///
/// - **Grabber** (instrument) and **Grabber (effect)**: the whole Grabber — discovery, every
///   protocol, the list, trims, fold-down, mute and solo, loudness, the meters, themes — without
///   the inserts (the host's own slots do that), the output device (the host pulls the mix) or
///   Send. The effect is there for hosts that load only effects.
/// - **Sender** (effect): the Grabber's Send, sending the track it sits on — never the Mac.
///
/// **The same sources as the apps**, so a change to one is a change to both. The C++ wrapper
/// (`Sources/NetworkAudioGrabberAU`, on Apple's AudioUnitSDK) talks to this through the C
/// functions below.
///
/// **Every plugin is its own**: each Grabber plugin has its own engine — its streams, its
/// mix, its level — and each Sender its own stream. Discovery shares the ports it needs (see
/// `VBANListener` and `ScreamListener`; the multicast sockets share by design). Each has a
/// settings suite of its own while open, started from the last one closed, and its copy in the
/// DAW project when saved.
public enum PluginBridge {
    static let bundleID = "app.networkaudiograbber.au"
    /// What a new Grabber plugin starts from — the last one's settings — and where its log lives.
    static let suiteName = "app.networkaudiograbber.au"
    /// What a new Sender starts from: the last one's receivers and settings.
    static let sendTemplate = "app.networkaudiograbber.au.send"
    /// A private property (in the range Apple leaves to plugins) giving a plugin's handle, so
    /// its window finds its own engine.
    static let handleProperty: AudioUnitPropertyID = 64_000

    /// A plugin's own settings suite: named with this process, so one left behind by a host that
    /// crashed can be told from one still open in another DAW (`sweepInstanceFiles`).
    static func instanceSuite(_ template: String) -> String {
        "\(template).p\(getpid()).i\(UUID().uuidString)"
    }

    // MARK: Grabber plugins — "DAT Audio: Grabber" and "Grabber (effect)"

    final class ReceiverInstance {
        /// Made at once, for the render thread to hold from the start; driven by `state`.
        let output: AudioOutput
        let suite = PluginBridge.instanceSuite(PluginBridge.suiteName)
        /// The engine, made on the main thread.
        var state: AppState?
        var pendingProject: [String: Any]?
        var pendingFormat: (Double, Int)?
        /// The latency the host is told, in seconds (bits of a Double), and how to tell it that
        /// it changed.
        var latencyBits: UInt64 = 0
        var notifyContext: UnsafeMutableRawPointer?
        var notify: (@convention(c) (UnsafeMutableRawPointer?) -> Void)?
        /// Watches for that, until the engine starts.
        var waiting: Timer?
        init() { output = AudioOutput() }
    }
    nonisolated(unsafe) static var receivers: [Int32: ReceiverInstance] = [:]

    // MARK: Senders — "DAT Audio: Sender"

    /// One Sender plugin: its own stream, named after its track when the host says.
    final class SenderInstance {
        /// The track, handed from the render thread to this Sender's send thread.
        let feed = HostAudioFeed()
        let suite = PluginBridge.instanceSuite(PluginBridge.sendTemplate)
        /// The host's name for the track (`kAudioUnitProperty_ContextName`), if it gives one.
        var trackName: String?
        var number = 1
        /// Made on the main thread; replaced when a project's copy is opened.
        var slot: SenderSlot?
        /// Waiting for the send to exist.
        var pendingProject: [String: Any]?
    }
    nonisolated(unsafe) static var senders: [Int32: SenderInstance] = [:]

    /// The last project copy made of each plugin, for a host that asks off the main thread.
    nonisolated(unsafe) static var savedCopies: [Int32: Data] = [:]

    nonisolated(unsafe) static var nextHandle: Int32 = 1
    static let lock = NSLock()

    /// Main-thread work, run now when already on it and otherwise queued — never waited for: a
    /// host that creates a plugin on another thread while its main thread waits would deadlock.
    static func onMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread { MainActor.assumeIsolated { body() } } else { DispatchQueue.main.async(execute: body) }
    }

    /// kind 0: a Grabber plugin (instrument or effect); 1: a Sender.
    static func open(kind: Int32) -> Int32 {
        // Before anything is made: an `AudioOutput` in host mode opens no device.
        AudioOutput.hostMode = true
        lock.lock()
        let handle = nextHandle
        nextHandle += 1
        if kind == 1 {
            let instance = SenderInstance()
            instance.number = senders.count + 1
            senders[handle] = instance
        } else {
            receivers[handle] = ReceiverInstance()
        }
        lock.unlock()
        onMain {
            sweepInstanceFiles()
            if kind == 1 { makeSend(handle) } else { makeState(handle) }
        }
        return handle
    }

    static func receiver(_ handle: Int32) -> ReceiverInstance? {
        lock.lock(); defer { lock.unlock() }
        return receivers[handle]
    }

    static func instance(_ handle: Int32) -> SenderInstance? {
        lock.lock(); defer { lock.unlock() }
        return senders[handle]
    }

    /// For the windows, which the host may ask for before the queued set-up has run. Opening
    /// the window starts the engine.
    static func receiverState(_ handle: Int32) -> AppState? {
        guard let r = receiver(handle) else { return nil }
        if r.state == nil { makeState(handle) }
        startEngine(r)
        return r.state
    }

    /// **A Grabber plugin starts listening only once it is used**: its window opens, a
    /// project hands it streams, or the host renders it. A DAW scanning its plugins creates each
    /// one to ask what it is — REAPER on opening, after new plugins — and that must not start
    /// discovery, join anything or take ports.
    static func startEngine(_ r: ReceiverInstance) {
        r.waiting?.invalidate()
        r.waiting = nil
        guard let s = r.state, !s.isStarted else { return }
        s.start()
        if let project = r.pendingProject {
            r.pendingProject = nil
            s.restoreProjectState(project)
        }
    }
    static func senderSlot(_ handle: Int32) -> SenderSlot? {
        guard let instance = instance(handle) else { return nil }
        if instance.slot == nil { makeSend(handle) }
        return instance.slot
    }

    /// What a Grabber plugin keeps for itself and does not hand on to the next new one: what it plays.
    static let receiverOwnKeys: Set<String> = ["listening"]

    /// Makes (or remakes, for a project's copy) one Grabber plugin's engine. Main thread.
    private static func makeState(_ handle: Int32) {
        guard let r = receiver(handle) else { return }
        // Made once; a project's copy opened later goes to the live engine (`restore`).
        guard r.state == nil else { return }
        seed(suite: r.suite, from: suiteName, except: receiverOwnKeys)
        // One Grabber plugin keeps the log file; the others keep theirs in memory.
        lock.lock()
        let keepsLog = !receivers.values.contains { $0 !== r && $0.state != nil }
        lock.unlock()
        let s = AppState(defaults: UserDefaults(suiteName: r.suite) ?? .standard, hostOutput: r.output,
                         keepsLog: keepsLog)
        // The host sizes its plugin windows itself; the layout follows the width (compact when
        // narrow, which is how it opens).
        s.viewMode = .full
        r.state = s
        if let (rate, channels) = r.pendingFormat { r.output.configureForHost(rate: rate, channels: channels) }
        s.onHostLatencyChange = { [weak r, weak s] in
            guard let r, let s else { return }
            let bits = s.hostLatencySeconds.bitPattern
            guard bits != nag_load64(&r.latencyBits) else { return }
            nag_store64(&r.latencyBits, bits)
            r.notify?(r.notifyContext)
        }
        nag_store64(&r.latencyBits, s.hostLatencySeconds.bitPattern)
        // The host may have asked before the engine existed, and been told 0 (REAPER).
        r.notify?(r.notifyContext)
        // Waits to be used (`startEngine`); a project's copy is a use.
        if r.pendingProject != nil {
            startEngine(r)
        } else {
            r.waiting = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak r] _ in
                guard let r else { return }
                if nag_load32(&r.output.hostRendered) == 1 { MainActor.assumeIsolated { startEngine(r) } }
            }
        }
    }

    /// Makes (or remakes, for a project's copy) one Sender's send. Main thread.
    private static func makeSend(_ handle: Int32) {
        guard let instance = instance(handle) else { return }
        // Made already, and no project's copy to open: nothing to do (the queued set-up after a
        // window asked first).
        if instance.slot != nil, instance.pendingProject == nil { return }
        // The old send stops first: stopping saves "sending nothing", which must not land on
        // top of the project's copy.
        if let old = instance.slot?.send { old.stopAll(); old.shutdown() }
        if let project = instance.pendingProject {
            instance.pendingProject = nil
            GrabberSend.load(project, into: instance.suite)
        } else if instance.slot == nil {
            GrabberSend.seed(suite: instance.suite, from: sendTemplate)
        }
        let s = GrabberSend(suiteName: instance.suite, hostFeed: instance.feed,
                            defaultName: instance.trackName ?? "DAW Track \(instance.number)")
        // The Grabber plugins' colour scheme, so the two look like one product.
        let theme = ThemeChoice.stored(in: UserDefaults(suiteName: suiteName) ?? .standard)
        s.applyTheme(enabled: theme.enabled, primary: theme.primaryHex, secondary: theme.secondaryHex)
        if let slot = instance.slot { slot.send = s } else { instance.slot = SenderSlot(send: s) }
        s.start()
    }

    /// Copies every key of `template` into an empty `suite`, less `except`.
    static func seed(suite: String, from template: String, except: Set<String>) {
        guard (UserDefaults.standard.persistentDomain(forName: suite) ?? [:]).isEmpty,
              let d = UserDefaults(suiteName: suite),
              let all = UserDefaults.standard.persistentDomain(forName: template) else { return }
        for (key, value) in all where !except.contains(key) { d.set(value, forKey: key) }
    }

    /// Keeps a closing plugin's settings as the next new one's starting point.
    static func writeBack(suite: String, to template: String, except: Set<String>) {
        guard let all = UserDefaults.standard.persistentDomain(forName: suite),
              let t = UserDefaults(suiteName: template) else { return }
        for (key, value) in all where !except.contains(key) { t.set(value, forKey: key) }
    }

    static func close(_ handle: Int32) {
        lock.lock()
        let receiver = receivers.removeValue(forKey: handle)
        let sender = senders.removeValue(forKey: handle)
        savedCopies[handle] = nil
        lock.unlock()
        onMain {
            // A Grabber plugin stops with its plugin, so nothing keeps receiving with no plugin open;
            // its settings are the next new one's starting point.
            if let receiver {
                receiver.notify = nil
                receiver.waiting?.invalidate()
                if let s = receiver.state {
                    s.unsubscribeAll(reason: "the plugin was closed")
                    s.shutdown()
                }
                writeBack(suite: receiver.suite, to: suiteName, except: receiverOwnKeys)
                UserDefaults.standard.removePersistentDomain(forName: receiver.suite)
            }
            // A Sender likewise; the project holds its copy.
            if let sender, let send = sender.slot?.send {
                send.writeBack(to: sendTemplate)
                send.stopAll()
                send.shutdown()
                UserDefaults.standard.removePersistentDomain(forName: sender.suite)
            }
            sweepInstanceFiles()
        }
    }

    /// Plugins' settings files that no open plugin owns: removed. macOS leaves a closed one's
    /// file behind empty; a host that crashed leaves one full, named with a process that no
    /// longer runs. One named with a live process — another DAW, open now — is left alone.
    static func sweepInstanceFiles() {
        guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return }
        let folder = library.appendingPathComponent("Preferences")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        let pattern = #"^app\.networkaudiograbber\.au(\.send)?\.(p(\d+)\.)?i[0-9A-F-]+\.plist$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        for name in names {
            let range = NSRange(name.startIndex..., in: name)
            guard let match = regex.firstMatch(in: name, range: range) else { continue }
            let url = folder.appendingPathComponent(name)
            let empty = (NSDictionary(contentsOf: url)?.count ?? 0) == 0
            var orphan = empty
            if !orphan {
                if let pidRange = Range(match.range(at: 3), in: name), let pid = Int32(name[pidRange]) {
                    orphan = kill(pid, 0) != 0 && errno == ESRCH
                } else {
                    orphan = true      // named before process ids were added: from an old build
                }
            }
            guard orphan else { continue }
            UserDefaults.standard.removePersistentDomain(forName: String(name.dropLast(".plist".count)))
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// The host named the track a Sender is on: its stream follows, unless renamed.
    static func trackNamed(_ handle: Int32, _ name: String) {
        onMain {
            guard let instance = instance(handle) else { return }
            instance.trackName = name
            instance.slot?.send.grabberRenamed(name)
        }
    }

    // MARK: A project's copy

    /// What the host saves in the project for this plugin. On the main thread it is made fresh;
    /// off it, the last one made is given, never waited for.
    static func save(_ handle: Int32) -> Data? {
        if Thread.isMainThread {
            let copy: [String: Any]? = MainActor.assumeIsolated {
                if let instance = instance(handle) { return instance.slot?.send.projectState() }
                return receiver(handle)?.state?.projectState()
            }
            guard let copy, let data = try? PropertyListSerialization.data(fromPropertyList: copy, format: .binary, options: 0)
            else { return nil }
            lock.lock(); savedCopies[handle] = data; lock.unlock()
            return data
        }
        lock.lock(); defer { lock.unlock() }
        return savedCopies[handle]
    }

    /// A project being opened hands back its copy.
    static func restore(_ handle: Int32, _ data: Data) {
        guard let copy = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { return }
        onMain {
            if let instance = instance(handle) {
                instance.pendingProject = copy
                makeSend(handle)
            } else if let r = receiver(handle) {
                if let s = r.state, s.isStarted { s.restoreProjectState(copy); return }
                r.pendingProject = copy
                if r.state == nil { makeState(handle) } else { startEngine(r) }
            }
        }
    }
}

// MARK: - C functions for the wrapper

@_cdecl("nag_au_open")
public func nag_au_open(_ kind: Int32) -> Int32 { PluginBridge.open(kind: kind) }

@_cdecl("nag_au_close")
public func nag_au_close(_ handle: Int32) { PluginBridge.close(handle) }

/// A Grabber plugin's output, for the wrapper to render from without looking anything up on the
/// render thread. Owned by the bridge until the plugin closes.
@_cdecl("nag_au_receiver_output")
public func nag_au_receiver_output(_ handle: Int32) -> UnsafeMutableRawPointer? {
    guard let r = PluginBridge.receiver(handle) else { return nil }
    return Unmanaged.passUnretained(r.output).toOpaque()
}

/// A Sender's feed, likewise.
@_cdecl("nag_au_sender_feed")
public func nag_au_sender_feed(_ handle: Int32) -> UnsafeMutableRawPointer? {
    guard let instance = PluginBridge.instance(handle) else { return nil }
    return Unmanaged.passUnretained(instance.feed).toOpaque()
}

/// The host's rate and output width, on initialise.
@_cdecl("nag_au_configure")
public func nag_au_configure(_ handle: Int32, _ kind: Int32, _ rate: Double, _ channels: Int32) {
    if kind == 1 {
        PluginBridge.instance(handle)?.feed.configure(rate: rate, channels: Int(channels))
        return
    }
    PluginBridge.onMain {
        guard let r = PluginBridge.receiver(handle) else { return }
        r.pendingFormat = (rate, Int(channels))
        r.output.configureForHost(rate: rate, channels: Int(channels))
    }
}

/// One buffer of a Grabber plugin's mix into the host's deinterleaved Float32 buffers. The render
/// thread.
@_cdecl("nag_au_render")
public func nag_au_render(_ output: UnsafeMutableRawPointer, _ abl: UnsafeMutablePointer<AudioBufferList>, _ frames: UInt32) {
    Unmanaged<AudioOutput>.fromOpaque(output)._withUnsafeGuaranteedRef { $0.renderForHost(abl, frames: Int(frames)) }
}

/// A Grabber plugin's latency, in seconds: its streams' buffer.
@_cdecl("nag_au_latency")
public func nag_au_latency(_ handle: Int32) -> Double {
    guard let r = PluginBridge.receiver(handle) else { return 0 }
    return Double(bitPattern: nag_load64(&r.latencyBits))
}

/// How the wrapper hears that a Grabber plugin's latency changed (it then tells the host).
@_cdecl("nag_au_on_latency")
public func nag_au_on_latency(_ handle: Int32, _ context: UnsafeMutableRawPointer?,
                              _ notify: (@convention(c) (UnsafeMutableRawPointer?) -> Void)?) {
    PluginBridge.onMain {
        guard let r = PluginBridge.receiver(handle) else { return }
        r.notifyContext = context
        r.notify = notify
        // Registered after the engine was made: tell the host the real figure now.
        if r.state != nil { notify?(context) }
    }
}

/// A Sender's input, for its send. The render thread; returns at once while nothing is sent.
@_cdecl("nag_au_send_input")
public func nag_au_send_input(_ feed: UnsafeMutableRawPointer, _ abl: UnsafePointer<AudioBufferList>, _ frames: UInt32) {
    Unmanaged<HostAudioFeed>.fromOpaque(feed)._withUnsafeGuaranteedRef { $0.write(abl, frames: Int(frames)) }
}

/// Whether a Sender's track carries on to its output. The render thread.
@_cdecl("nag_au_pass_through")
public func nag_au_pass_through(_ feed: UnsafeMutableRawPointer) -> Int32 {
    Unmanaged<HostAudioFeed>.fromOpaque(feed)._withUnsafeGuaranteedRef { $0.passesTrack ? 1 : 0 }
}

/// The project's copy of a plugin, +1 retained, or nil.
@_cdecl("nag_au_save")
public func nag_au_save(_ handle: Int32) -> Unmanaged<CFData>? {
    guard let data = PluginBridge.save(handle) else { return nil }
    return Unmanaged.passRetained(data as CFData)
}

@_cdecl("nag_au_restore")
public func nag_au_restore(_ handle: Int32, _ data: CFData) {
    PluginBridge.restore(handle, data as Data)
}

/// The host's name for a Sender's track.
@_cdecl("nag_au_track_name")
public func nag_au_track_name(_ handle: Int32, _ name: CFString) {
    PluginBridge.trackNamed(handle, name as String)
}

// MARK: - The plugins' windows

/// The plugin's handle, from the wrapper's private property.
private func pluginHandle(_ audioUnit: AudioUnit) -> Int32? {
    var handle: Int32 = 0
    var size = UInt32(MemoryLayout<Int32>.size)
    guard AudioUnitGetProperty(audioUnit, PluginBridge.handleProperty, kAudioUnitScope_Global, 0,
                               &handle, &size) == noErr else { return nil }
    return handle
}

/// The Grabber plugin's window (`kAudioUnitProperty_CocoaUI`): the Grabber's own window in host mode —
/// compact when it opens, the full layout when widened — without Send, which is the Sender's.
@objc(NAGReceiverViewFactory)
public final class NAGReceiverViewFactory: NSObject, AUCocoaUIBase {
    public func interfaceVersion() -> UInt32 { 0 }

    public func uiView(forAudioUnit audioUnit: AudioUnit, with preferredSize: NSSize) -> NSView? {
        // Hosts ask for the view on the main thread.
        var view: NSView?
        MainActor.assumeIsolated {
            guard let handle = pluginHandle(audioUnit), let state = PluginBridge.receiverState(handle) else { return }
            let host = NSHostingView(rootView: ContentView().environment(state))
            // Opens compact, whatever the host suggests: REAPER offered
            // a small window that cut off the full layout.
            _ = preferredSize
            // The host decides the size; the view does not impose a minimum of its own on it.
            host.sizingOptions = []
            host.frame = NSRect(origin: .zero, size: NSSize(width: CompactView.pluginOpenWidth, height: 660))
            host.autoresizingMask = [.width, .height]
            view = host
        }
        return view
    }
}

/// The Sender's window: its send controls, compact.
@objc(NAGSenderViewFactory)
public final class NAGSenderViewFactory: NSObject, AUCocoaUIBase {
    public func interfaceVersion() -> UInt32 { 0 }

    public func uiView(forAudioUnit audioUnit: AudioUnit, with preferredSize: NSSize) -> NSView? {
        var view: NSView?
        MainActor.assumeIsolated {
            guard let handle = pluginHandle(audioUnit), let slot = PluginBridge.senderSlot(handle) else { return }
            let host = NSHostingView(rootView: SenderPluginView(slot: slot))
            _ = preferredSize
            host.sizingOptions = []
            host.frame = NSRect(origin: .zero, size: NSSize(width: CompactView.pluginOpenWidth, height: 560))
            host.autoresizingMask = [.width, .height]
            view = host
        }
        return view
    }
}
