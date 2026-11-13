import Foundation
import WinSDK
import NAGVST3

/// Why a plug-in did not load, in words for the log.
public struct VST3Error: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// One VST3 effect instance: NAGVST3's C handle, with Swift around it.
///
/// Everything here is for the UI thread — the thread VST3 says loading, configuring, state and
/// editors belong to. The audio thread never touches this object, only `handle`, through
/// `VST3InsertChain`, which also makes sure nothing here deactivates the plug-in under it.
public final class VST3Plugin: @unchecked Sendable {
    public let info: VST3PluginInfo
    /// The C instance. Valid until `unload`.
    public let handle: OpaquePointer
    public private(set) var isUnloaded = false

    private init(info: VST3PluginInfo, handle: OpaquePointer) {
        self.info = info
        self.handle = handle
    }

    deinit { unload() }

    /// Loads, creates and initialises the plug-in, not yet active (`configure` does that).
    public static func load(_ info: VST3PluginInfo) -> Result<VST3Plugin, VST3Error> {
        var error = [CChar](repeating: 0, count: 512)
        guard let handle = nag_vst3_load(info.path, info.classID, &error, Int32(error.count)) else {
            return .failure(VST3Error(String(cString: error)))
        }
        return .success(VST3Plugin(info: info, handle: handle))
    }

    /// Releases the plug-in. A plug-in that has faulted is left alone instead (see
    /// `nag_vst3_has_failed`). Never while the audio thread may be processing it.
    public func unload() {
        guard !isUnloaded else { return }
        isUnloaded = true
        nag_vst3_unload(handle)
    }

    /// What `configure` came to.
    public enum Configuration: Equatable, Sendable {
        /// Running. `channelMap[e]` is the VST3 channel the engine's channel `e` goes to.
        case accepted(channelMap: [Int])
        /// Will not take the width; left inactive, and not to be processed at all.
        case refused
        case failed
    }

    /// Negotiates `channels` (2, 4, 6, 8) and activates for real-time 32-bit processing.
    public func configure(sampleRate: Double, maxFrames: Int, channels: Int) -> Configuration {
        guard !isUnloaded else { return .failed }
        var map = [Int32](repeating: 0, count: max(1, channels))
        let status = nag_vst3_configure(handle, sampleRate, Int32(maxFrames), Int32(channels), &map)
        return Self.configuration(status, map: map, channels: channels)
    }

    /// Deactivates and reactivates with the same configuration: what a latency or I/O change
    /// asks of a host.
    public func restart(channels: Int) -> Configuration {
        guard !isUnloaded else { return .failed }
        var map = [Int32](repeating: 0, count: max(1, channels))
        return Self.configuration(nag_vst3_restart(handle, &map), map: map, channels: channels)
    }

    private static func configuration(_ status: Int32, map: [Int32], channels: Int) -> Configuration {
        switch status {
        case Int32(NAG_VST3_OK): return .accepted(channelMap: map.prefix(channels).map { Int($0) })
        case Int32(NAG_VST3_REFUSED): return .refused
        default: return .failed
        }
    }

    /// VST3's speaker-arrangement bit mask in use, 0 when not running.
    public var arrangement: UInt64 { isUnloaded ? 0 : nag_vst3_arrangement(handle) }

    /// The latency the plug-in reports, in samples at the configured rate.
    public var latencySamples: Int { isUnloaded ? 0 : Int(nag_vst3_latency(handle)) }

    /// Whether it faulted inside `process` and has been taken out for good.
    public var hasFailed: Bool { nag_vst3_has_failed(handle) != 0 }

    /// `restartComponent` flags since the last call: 1 reload, 2 I/O, 4 parameter values, 8 latency.
    public func takeRestartFlags() -> UInt32 { isUnloaded ? 0 : nag_vst3_take_restart_flags(handle) }

    /// The plug-in's own bypass parameter, if it has one.
    public func setBypass(_ bypassed: Bool) {
        guard !isUnloaded else { return }
        nag_vst3_set_bypass(handle, bypassed ? 1 : 0)
    }

    /// The plug-in's settings, component and controller together (see `nag_vst3_get_state`).
    public var state: Data? {
        guard !isUnloaded, !hasFailed else { return nil }
        var bytes: UnsafeMutablePointer<UInt8>?
        var size: Int64 = 0
        guard nag_vst3_get_state(handle, &bytes, &size) == 0, let bytes else { return nil }
        defer { nag_vst3_free(bytes) }
        return Data(bytes: bytes, count: Int(size))
    }

    @discardableResult
    public func setState(_ data: Data) -> Bool {
        guard !isUnloaded, !hasFailed else { return false }
        return data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
            return nag_vst3_set_state(handle, base, Int64(raw.count)) == 0
        }
    }

    // MARK: - Editor

    public var hasEditor: Bool { !isUnloaded && nag_vst3_has_editor(handle) != 0 }
    public var editorWindow: HWND? {
        isUnloaded ? nil : nag_vst3_editor_window(handle).map { HWND($0.assumingMemoryBound(to: HWND__.self)) }
    }

    /// What the C callback reaches: a box of its own rather than the plug-in, so a close that
    /// happens while the plug-in is being deinitialised never takes a reference to it.
    private final class EditorCallback {
        var onClosed: (() -> Void)?
    }
    private let editorCallback = EditorCallback()

    /// Opens the editor in its own window owned by `parent`, or brings it to the front.
    /// `onClosed` is called when the window closes, however it closed.
    @discardableResult
    public func openEditor(parent: HWND?, title: String, onClosed: (() -> Void)? = nil) -> Bool {
        guard !isUnloaded else { return false }
        if editorWindow == nil { editorCallback.onClosed = onClosed }
        let context = Unmanaged.passUnretained(editorCallback).toOpaque()
        let result = nag_vst3_open_editor(handle, parent.map { UnsafeMutableRawPointer($0) }, title,
                                          { context in
                                              guard let context else { return }
                                              let box = Unmanaged<EditorCallback>.fromOpaque(context).takeUnretainedValue()
                                              let closed = box.onClosed
                                              box.onClosed = nil
                                              closed?()
                                          }, context)
        return result == 0
    }

    public func closeEditor() {
        guard !isUnloaded else { return }
        nag_vst3_close_editor(handle)
    }
}
