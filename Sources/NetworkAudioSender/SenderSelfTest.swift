import Foundation
import AppKit
import SwiftUI

/// `NetworkAudioSender --selftest --to <host[:port]> [--to …] [--seconds N] [--bits 16|24]`
/// `                   [--name <stream>] [--only-pid <pid>] [--tone] [--tone-channels N]`
/// `                   [--rename-after S --rename-to <name>] [--keep] [--mute-mac] [--broadcast]`
/// `                   [--insert <name> [--mix 0…1] [--bypass]] [--offer]`
///
/// `--offer` offers the stream to Grabbers on the network (VBAN stage 3) and prints who
/// subscribes, so the handshake can be tested with a Grabber on this Mac and no targets. It asks
/// before a new Grabber listens, as the app does: `--allow-after S` allows every request once it
/// has waited S seconds, `--decline` declines each one, and `--no-ask` lets anyone listen.
///
/// Drives the real `SenderState` — the same capture, transmitter and target code the window
/// uses — with the run loop turning, and prints once a second what is being captured and sent.
///
/// **`--only-pid` is how this is tested without touching what the user is playing.** It taps
/// that one process, muted, instead of everything on the Mac: play a tone with `afplay`, pass
/// its PID, and the tone goes to the network and nowhere else. Without it the capture is the
/// real thing — every app but the Grabber and this one.
///
/// Runs against a throwaway preferences suite, so a test leaves no targets or settings behind.
enum SenderSelfTest {
    @MainActor
    static func run(arguments: [String]) {
        setvbuf(stdout, nil, _IONBF, 0)
        let app = NSApplication.shared
        // A regular, frontmost app, not an accessory: macOS only puts up the audio-recording
        // permission prompt for an app the user can see, and until that is answered a capture
        // delivers nothing at all.
        app.setActivationPolicy(.regular)
        app.finishLaunching()
        app.activate(ignoringOtherApps: true)

        let suite = "app.networkaudiosender.selftest"
        // `--keep` leaves this run's settings for the next, which is the only way to test what
        // is remembered. Still the throwaway suite, never the real app's.
        let keep = arguments.contains("--keep")
        if !keep { UserDefaults.standard.removePersistentDomain(forName: suite) }
        nonisolated(unsafe) let state = SenderState(defaults: UserDefaults(suiteName: suite) ?? .standard)
        let seconds = value("--seconds", arguments).flatMap(Double.init) ?? 10
        if let name = value("--name", arguments) { state.streamName = name }
        if value("--bits", arguments) == "24" { state.dataType = .int24 }
        if arguments.contains("--mute-mac") { state.muteThisMac = true }
        // `--source system | apps:<bundle id>[,<bundle id>…] | input:<device name>`.
        if let text = value("--source", arguments) {
            if text.hasPrefix("input:") {
                let wanted = String(text.dropFirst(6))
                if let device = InputDeviceCapture.inputDevices().first(where: { $0.name.localizedCaseInsensitiveContains(wanted) }) {
                    state.sendSource = .input(uid: device.uid, name: device.name)
                } else { print("Source    : no input device matching \"\(wanted)\"") }
            } else {
                state.sendSource = SendSource(stored: text)
            }
            print("Source    : \(state.sourceDescription)")
        }
        if let pid = value("--only-pid", arguments).flatMap(Int32.init) {
            state.systemCapture?.onlyProcess = pid
        }
        // Before any target: adding one starts the capture unless the tone is already running.
        if arguments.contains("--tone") {
            state.startTestTone(channels: value("--tone-channels", arguments).flatMap(Int.init) ?? 2)
        }
        // Rename the stream part-way through, as a user editing the name does.
        let renameAfter = value("--rename-after", arguments).flatMap(Double.init)
        let renameTo = value("--rename-to", arguments) ?? "Renamed"
        var renamed = false
        state.start()
        let allowAfter = value("--allow-after", arguments).flatMap(Double.init)
        let declineAll = arguments.contains("--decline")
        var askedAt: [String: Date] = [:]
        if arguments.contains("--offer") {
            state.onOfferLog = { print("Offer     : \($0)") }
            if arguments.contains("--no-ask") { state.askFirst = false }
            // Test only: announce on no network (an interface that does not exist), as across
            // two locations, where beacons never arrive.
            if arguments.contains("--no-beacons") { state.offerInterfaces = ["none0"] }
            state.offering = true
            print("Offer     : offering on port \(state.offerPort) to every local network")
        }
        // A Remote link, as in the Grabber's self-test.
        if arguments.contains("--make-remote-code") {
            state.start()
            state.makeRemoteCode()
            let until = Date().addingTimeInterval(4)
            while state.makingRemoteCode, Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
            print("Remote    : " + (state.remoteCode.map { "this end's code \($0.text) (port \($0.port))" }
                                    ?? (state.remoteCodeError ?? "no code")))
        }
        if let code = value("--remote-link", arguments) {
            print("Remote    : " + (state.linkRemote(code) ?? "linked \(code)"))
        }
        // Test only: this end's code for 127.0.0.1, with its real secret, written to a
        // file for the other end's test — the encrypted link tried on one Mac, without STUN.
        if let path = value("--local-code-file", arguments) {
            let code = RemoteCode(role: .sending, address: "127.0.0.1", port: UInt16(state.offerPort), secret: state.remoteSecret)
            try? code.text.write(toFile: path, atomically: true, encoding: .utf8)
            print("Remote    : wrote this end's local code (port \(state.offerPort))")
        }
        // Test only: link whatever code appears in this file (the other end's, written by a test).
        if let path = value("--remote-link-file", arguments) {
            var last = ""
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                MainActor.assumeIsolated {
                    guard let text = try? String(contentsOfFile: path, encoding: .utf8)
                            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text != last else { return }
                    let old = Set(last.split(separator: "\n").map(String.init))
                    last = text
                    for line in text.split(separator: "\n").map(String.init) where !old.contains(line) {
                        print("Remote    : " + (state.linkRemote(line) ?? "linked a code from the file"))
                    }
                }
            }
        }

        for (i, arg) in arguments.enumerated() where arg == "--to" && i + 1 < arguments.count {
            let parts = arguments[i + 1].split(separator: ":")
            state.draftHost = String(parts[0])
            state.draftPort = parts.count > 1 ? String(parts[1]) : String(VBAN.port)
            if !state.addDraft() { print("Target    : \(state.draftError ?? "refused")") }
        }
        if arguments.contains("--broadcast") {
            for t in state.targets { state.toggleBroadcast(t.id) }
        }
        for t in state.targets {
            print("Target    : \(t.name.map { "\($0) (\(t.address))" } ?? t.address) → \(state.destination(of: t) ?? "no broadcast address")"
                + (state.isSending(t.id) ? "  sending" : "  not sending") + (t.favourite ? "  ★" : ""))
        }

        // Inserts, once the scan has something to choose from: `--insert <name>` into slot 1,
        // then `--mix 0…1` and `--bypass` on it. (No `--delta`: the Sender has no Δ, since there
        // is nothing on this Mac to hear the difference against.)
        let insertName = value("--insert", arguments)
        let insertMix = value("--mix", arguments).flatMap(Double.init)
        var insertDone = insertName == nil

        let started = Date()
        var lastPackets: UInt64 = 0
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            MainActor.assumeIsolated {
                if !insertDone, let insertName, !state.availablePlugins.isEmpty {
                    insertDone = true
                    print("Insert 1  : " + (state.loadPlugin(named: insertName, slot: 0)
                                              ? insertName : "nothing matching \"\(insertName)\""))
                    if let insertMix { state.setSlotMix(0, insertMix) }
                    if arguments.contains("--bypass") { state.toggleBypass(slot: 0) }
                }
                let packets = state.packetsSent
                let status: String
                switch state.captureStatus {
                case .idle: status = "idle"
                case .failed(let message): status = "FAILED: \(message)"
                case .running(let rate, let channels): status = "capturing \(rate) Hz \(channels) ch"
                }
                func db(_ v: Float) -> String { v > 1e-6 ? String(format: "%.1f", 20 * log10(v)) : "−∞" }
                for r in state.requests {
                    let since = askedAt[r.id] ?? Date()
                    askedAt[r.id] = since
                    if declineAll { print("Offer     : declining \(r.name ?? r.ip)"); state.decline(r) }
                    else if let allowAfter, Date().timeIntervalSince(since) >= allowAfter {
                        print("Offer     : allowing \(r.name ?? r.ip) after \(Int(allowAfter)) s"); state.allow(r)
                    }
                }
                let listening = state.listeners.map { "\($0.name ?? "?")@\($0.ip):\($0.port)" }
                print(String(format: "%4.0f s  %@   L %@  R %@ dBFS   %llu packets/s   errors %llu   %@%@",
                             Date().timeIntervalSince(started), status,
                             db(state.level(0)), db(state.level(1)),
                             packets &- lastPackets, state.sendErrors, state.captureDebug,
                             listening.isEmpty ? "" : "   listening: " + listening.joined(separator: ", ")))
                lastPackets = packets
                if let renameAfter, !renamed, Date().timeIntervalSince(started) >= renameAfter {
                    renamed = true
                    print("Renamed   : \(state.streamName) → \(renameTo)")
                    state.streamName = renameTo
                }
                guard Date().timeIntervalSince(started) >= seconds else { return }
                timer.invalidate()
                print("Inserts   : \(state.insertSummary)")
                for i in 0..<3 { if let f = state.slotFailure(i) { print("Insert \(i + 1)  : FAILED: \(f)") } }
                print("Sent      : \(packets) packets, \(state.sendErrors) send errors")
                print("Unreachable: \(state.unreachableTargets.count) of \(state.sending.count) targets")
                state.shutdown()
                print("--- log ---")
                state.activity.entries.forEach {
                    print("\(ActivityLogView.time($0.date))  \($0.kind.label.padding(toLength: 7, withPad: " ", startingAt: 0))  \($0.text)")
                }
                if keep { UserDefaults(suiteName: suite)?.synchronize() }
                else { UserDefaults.standard.removePersistentDomain(forName: suite) }
                exit(0)
            }
        }
        app.run()
    }

    private static func value(_ flag: String, _ arguments: [String]) -> String? {
        guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }
}

/// `NetworkAudioSender --render <folder>`: the window as images, for the docs and for review.
/// Synthetic throughout — made-up targets from the documentation address ranges, fixed meter
/// levels, nothing captured and nothing sent.
enum SenderRender {
    /// Tall enough for the sample's listeners, request and targets without scrolling, which is
    /// the height the real window grows to for them (`WindowFloor`). At 560 the content's floor
    /// overflowed the frame and the header and status bar were cut off.
    static let size = CGSize(width: 480, height: 760)

    @MainActor
    static func run(arguments: [String]) {
        let outDir = arguments.firstIndex(of: "--render").flatMap {
            $0 + 1 < arguments.count ? arguments[$0 + 1] : nil
        } ?? NSTemporaryDirectory()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()

        let suite = "app.networkaudiosender.preview"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        // Tall, so the window's floor can be read off it: where the content ends with nothing
        // listed, which is the height the window needs before it has to scroll.
        let empty = SenderState(defaults: UserDefaults(suiteName: suite) ?? .standard)
        empty.previewOutput = ("Studio Monitors", 48000)
        empty.previewNetworks = []
        empty.previewAddresses = ["192.0.2.30"]
        empty.previewLevels = [0, 0]
        empty.setPreviewInserts([nil, nil, nil])
        capture(AnyView(SenderView().environment(empty)), size: CGSize(width: size.width, height: 1200),
                appearance: NSAppearance(named: .aqua), to: "\(outDir)/sender-empty-tall.png")
        // The quick-start guide's first Sender picture: as a new user opens it.
        capture(AnyView(SenderView().environment(empty)), size: CGSize(width: size.width, height: 340),
                appearance: NSAppearance(named: .darkAqua), to: "\(outDir)/guide-s1-fresh.png")
        UserDefaults.standard.removePersistentDomain(forName: suite)

        let state = SenderState(defaults: UserDefaults(suiteName: suite) ?? .standard)
        // As the Grabber's harness: the app's own colours, not the rendering Mac's accent.
        state.applyTheme(ThemePreset.harness)
        state.streamName = "Edit Suite Mac"
        // Made-up device and networks for the header, never this Mac's own.
        state.previewOutput = ("Studio Monitors", 48000)
        state.previewNetworks = [LocalNetwork(name: "en0", address: "192.0.2.30", netmask: "255.255.255.0", broadcast: "192.0.2.255"),
                                 LocalNetwork(name: "en5", address: "203.0.113.30", netmask: "255.255.255.0", broadcast: "203.0.113.255")]
        state.targets = [
            SendTarget(host: "192.0.2.20", favourite: true, name: "Studio PC"),
            SendTarget(host: "192.0.2.31", favourite: true, muted: true),
            SendTarget(host: "198.51.100.7"),
        ]
        state.previewLevels = [0.42, 0.30]
        state.setPreviewInserts([
            PluginInfo(name: "AUGraphicEQ", manufacturer: "Apple", type: 0, subType: 0,
                       manufacturerCode: 0, hasCustomView: true),
            nil, nil])
        // Marked as sending without starting anything: the preview shows the state, the
        // harness never captures or transmits.
        state.setPreviewSending([state.targets[0].id, state.targets[1].id])
        // Documentation addresses only; the second one reported the name its target shows.
        state.previewAddresses = ["192.0.2.30", "203.0.113.30"]
        state.setPreviewListeners([
            .init(ip: "192.0.2.40", port: 6980, name: "Control Room", cookie: [], lastSeen: 0),
            .init(ip: "198.51.100.7", port: 6980, name: "Edit Bay Grabber", cookie: [], lastSeen: 0),
        ], reported: ["192.0.2.40": "Control Room", "198.51.100.7": "Edit Bay Grabber"],
           requests: [.init(ip: "192.0.2.41", port: 6980, name: "Booth Mac", cookie: [], lastSeen: 0)])

        // `--render <dir> --matrix`: every colour scheme in both appearances, at the narrowest
        // width, the usual size and a large one.
        if arguments.contains("--matrix") {
            let themes: [(String, ThemePreset?)] = [("default", nil)]
                + ThemePreset.all.map { ($0.name.lowercased().replacingOccurrences(of: " & ", with: "-")
                                            .replacingOccurrences(of: " ", with: "-"), $0) }
            for (name, preset) in themes {
                if let preset { state.applyTheme(preset) }
                else { state.theme = ThemeChoice(enabled: false, primaryHex: state.theme.primaryHex,
                                                 secondaryHex: state.theme.secondaryHex) }
                for (look, appearance) in [("dark", NSAppearance(named: .darkAqua)), ("light", NSAppearance(named: .aqua))] {
                    for (tag, sz) in [("narrow", CGSize(width: 460, height: 760)), ("mid", size),
                                      ("big", CGSize(width: 720, height: 1000))] {
                        capture(AnyView(SenderView().environment(state)), size: sz, appearance: appearance,
                                to: "\(outDir)/\(name)-\(look)-sender-\(tag).png")
                    }
                }
            }
            UserDefaults.standard.removePersistentDomain(forName: suite)
            print("Wrote the Sender matrix to \(outDir)")
            exit(0)
        }

        capture(AnyView(SenderView().environment(state)), size: CGSize(width: size.width, height: 1200),
                appearance: NSAppearance(named: .aqua), to: "\(outDir)/sender-full-tall.png")
        // Broadcast on this network: the real sheet, on the harness's networks.
        for (name, appearance) in [("light", NSAppearance(named: .aqua)), ("dark", NSAppearance(named: .darkAqua))] {
            capture(AnyView(BroadcastSheet().environment(state)), size: CGSize(width: 400, height: 380),
                    appearance: appearance, to: "\(outDir)/sender-broadcast-sheet-\(name).png")
        }
        // …and with every network already broadcast to: it says so, Start greyed.
        state.previewBroadcasting = Set(state.broadcastNetworks.map(\.name))
        capture(AnyView(BroadcastSheet().environment(state)), size: CGSize(width: 400, height: 400),
                appearance: NSAppearance(named: .darkAqua), to: "\(outDir)/sender-broadcast-sheet-already-dark.png")
        state.previewBroadcasting = nil
        // Settings → Grabbers with one denied this session, which can be allowed after all.
        state.setPreviewDenied([VBANOffer.Subscriber(ip: "192.0.2.77", port: 6980, name: "Edit Suite",
                                                     cookie: [], lastSeen: 0)])
        capture(AnyView(Form { SendSettingsSections() }.formStyle(.grouped).environment(state)),
                size: CGSize(width: 460, height: 900), appearance: NSAppearance(named: .darkAqua),
                to: "\(outDir)/sender-settings-denied-dark.png")
        state.setPreviewDenied([])
        // The connection guide's Somewhere else, with a made-up code.
        state.setPreviewRemoteCode(RemoteCode(role: .sending, address: "203.0.113.30", port: 6981))
        state.setPreviewRemoteLinks(["203.0.113.60:6980"])
        for (name, appearance) in [("light", NSAppearance(named: .aqua)), ("dark", NSAppearance(named: .darkAqua))] {
            capture(AnyView(ConnectToGrabber(somewhereElse: true).environment(state)),
                    size: CGSize(width: 420, height: 900), appearance: appearance,
                    to: "\(outDir)/sender-connect-remote-\(name).png")
        }
        for (name, appearance) in [("sender-light", NSAppearance(named: .aqua)),
                                   ("sender-dark", NSAppearance(named: .darkAqua))] {
            capture(state, appearance: appearance, to: "\(outDir)/\(name).png")
        }
        state.applyTheme(ThemePreset.all[1])
        capture(state, appearance: NSAppearance(named: .darkAqua), to: "\(outDir)/sender-theme.png")
        // The Chosen apps sheet, with whatever apps are running here — rendered only
        // to the scratch folder, never into the docs (it lists this Mac's own apps).
        capture(AnyView(ChosenAppsSheet().environment(state)), size: CGSize(width: 360, height: 470),
                appearance: NSAppearance(named: .darkAqua), to: "\(outDir)/sender-chosen-apps.png")
        state.applyTheme(ThemePreset.reaperDefault)
        capture(state, appearance: NSAppearance(named: .darkAqua), to: "\(outDir)/sender-reaper-default.png")
        state.showSettings = true
        capture(AnyView(SenderView().environment(state)), size: CGSize(width: size.width, height: 1900),
                appearance: NSAppearance(named: .darkAqua), to: "\(outDir)/sender-settings-reaper-default.png")
        state.showSettings = false
        state.applyTheme(ThemePreset.all[1])
        state.showSettings = true
        capture(state, appearance: NSAppearance(named: .aqua), to: "\(outDir)/sender-settings.png")
        state.allowPreview(["192.0.2.40": "Control Room"])
        capture(AnyView(SenderView().environment(state)), size: CGSize(width: size.width, height: 1900),
                appearance: NSAppearance(named: .aqua), to: "\(outDir)/sender-settings-tall.png")
        // The log, with made-up entries on documentation addresses.
        for (kind, text) in [(ActivityLog.Kind.note, "Opened Network Audio Sender."),
                             (.request, "Offering “Edit Suite Mac” to Grabbers on this network (VBAN), asking before a new one listens."),
                             (.request, "Booth Mac at 192.0.2.41 asks to listen. Waiting for Allow or Deny."),
                             (.done, "Allowed Control Room at 192.0.2.40 — by you. It is remembered."),
                             (.done, "Control Room at 192.0.2.40 is listening (VBAN, unicast)."),
                             (.done, "Capturing this Mac's audio: 48 kHz, 2 ch."),
                             (.request, "Sending to Studio PC at 192.0.2.20 (VBAN)."),
                             (.warning, "Timed out: a Grabber stopped checking in for 15 s and was dropped."),
                             (.stopped, "Stopped sending to 198.51.100.7 — you stopped it.")] {
            state.activity.add(kind, text)
        }
        state.settingsShowsLog = true
        capture(state, appearance: NSAppearance(named: .aqua), to: "\(outDir)/sender-log.png")
        state.settingsShowsLog = false
        state.showSettings = false
        capture(AnyView(ConnectToGrabber().environment(state)), size: CGSize(width: 420, height: 640),
                appearance: NSAppearance(named: .aqua), to: "\(outDir)/sender-connect.png")
        capture(AnyView(ConnectToGrabber().environment(state)), size: CGSize(width: 420, height: 980),
                appearance: NSAppearance(named: .darkAqua), to: "\(outDir)/guide-s4-connect.png")
        UserDefaults.standard.removePersistentDomain(forName: suite)
        print("Wrote sender-light, sender-dark, sender-theme, sender-settings and sender-connect to \(outDir)")
        exit(0)
    }

    @MainActor
    private static func capture(_ state: SenderState, appearance: NSAppearance?, to path: String) {
        capture(AnyView(SenderView().environment(state)), size: size, appearance: appearance, to: path)
    }

    @MainActor
    private static func capture(_ view: AnyView, size: CGSize, appearance: NSAppearance?, to path: String) {
        let window = ActiveLookingWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        window.orderFrontRegardless()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        window.displayIfNeeded()
        if let png = WindowShot.png(of: window) {      // at the window's point size, whatever the screens
            try? png.write(to: URL(fileURLWithPath: path))
        }
        window.orderOut(nil)
    }
}
