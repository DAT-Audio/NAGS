import Foundation
import NetworkAudioEngine
import SenderCore

/// What a Send captures, in words and as a menu (the Mac's `SourceMenu`): system audio — all apps
/// but the Grabber — one app, or one input device whole. Kept under the Mac's own key,
/// `"sendSource"`, in the Send's settings.
enum SendSourceText {
    static func source(_ s: WindowsSender) -> WindowsSendSource { s.windowsCapture.source }

    static func short(_ s: WindowsSender) -> String {
        switch source(s) {
        case .system: return "System audio"
        case .app(_, let name): return name
        case .input(_, let name): return name
        }
    }

    static func glyph(_ s: WindowsSender) -> String {
        switch source(s) {
        case .system: return "\u{E7F5}"
        case .app: return "\u{E737}"
        case .input: return "\u{E720}"
        }
    }

    static func isInput(_ s: WindowsSender) -> Bool { source(s).isInput }

    static func tooltip(_ s: WindowsSender, excludesOwnPlayback: Bool, app: String) -> String {
        switch source(s) {
        case .system:
            let left = excludesOwnPlayback ? "this Grabber" : "Network Audio Grabber"
            return "Sending everything this PC plays (except \(left)), on \(s.outputDevice()?.name ?? "the playback device"). "
                + "Click to send one app or an input device instead."
        case .app(_, let name):
            return "Sending only \(name). While it is not running, receivers hear silence and stay connected. Click to change."
        case .input(_, let name):
            return "Sending \(name), at its own channel count. Click to change."
        }
    }

    static func menu(_ s: WindowsSender) -> [DrawnWindow.MenuEntry] {
        let current = source(s)
        func choose(_ new: WindowsSendSource) {
            s.windowsCapture.source = new
            s.defaults.set(new.stored, forKey: "sendSource")
            s.note(.note, "Source: " + {
                switch new {
                case .system: return "system audio — all apps."
                case .app(_, let name): return "\(name) only."
                case .input(_, let name): return "\(name), whole."
                }
            }())
        }
        var entries: [DrawnWindow.MenuEntry] = [
            .item("System audio output — all apps", checked: current == .system) { choose(.system) },
            .separator,
            .heading("One app"),
        ]
        let apps = WASAPILoopback.audioApps()
        if apps.isEmpty, case .app = current {} else if apps.isEmpty { entries.append(.heading("    No app is playing sound")) }
        var listed = Set<String>()
        for a in apps where !listed.contains(a.exe.lowercased()) {
            listed.insert(a.exe.lowercased())
            let new = WindowsSendSource.app(exe: a.exe, name: a.name)
            entries.append(.item("\(a.name)" + (a.playing ? "  ·  playing" : ""), checked: current == new) { choose(new) })
        }
        if case .app(let exe, let name) = current, !listed.contains(exe.lowercased()) {
            entries.append(.item("\(name)  ·  not running", checked: true) {})
        }
        entries.append(.separator)
        entries.append(.heading("An input device, whole"))
        let inputs = WASAPILoopback.inputDevices()
        if inputs.isEmpty { entries.append(.heading("    No input devices")) }
        for d in inputs {
            let new = WindowsSendSource.input(id: d.id, name: d.name)
            entries.append(.item("\(d.name)  ·  \(d.channels) ch", checked: current == new) { choose(new) })
        }
        return entries
    }
}

/// Points a Send's capture at its saved source and what "System audio" leaves out: the Sender app
/// leaves out a running Grabber (or else itself); the Grabber's Send its own playback, which is
/// the capture's default.
func configureSenderCapture(_ sender: WindowsSender, forSenderApp: Bool) {
    sender.windowsCapture.source = WindowsSendSource(stored: sender.defaults.string(forKey: "sendSource"))
    if forSenderApp { sender.windowsCapture.excludeRunningGrabber = true }
}
