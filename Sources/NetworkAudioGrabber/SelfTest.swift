import Foundation
import AppKit
import CoreAudio

/// `NetworkAudioGrabber --selftest [--only <text>] [--insert <name>] [--insert2 <name>] [--mix 0…1]`
/// `             [--silent | --master 0…1] [--bypass] [--delta 1] [--solo 7,8]`
/// `             [--mixmode pair:6] [--bus N] [--keep] [--seconds N] [--vban] [--stopafter N] [--flipto <device>]`
/// `             [--vban-sender <ip[:port]>] [--autostop <minutes>]`
///
/// `--silent` pulls the master level to zero. Loudness is measured ahead of it, so this joins
/// real streams and checks the readings without putting anything out of the audio device —
/// which is also a live demonstration that the monitor level cannot move a loudness figure.
///
/// Drives the real `AppState` — the same discovery, subscription, insert and audio-engine code
/// the window uses — with the run loop turning, then prints the app's own activity log and the
/// output level. This is how the plugin chain gets verified: `--probe` runs its own bare loop,
/// and Audio Unit scanning and instantiation both need a live run loop.
enum SelfTest {
    @MainActor
    static func run(arguments: [String]) {
        setvbuf(stdout, nil, _IONBF, 0)
        let seconds = value(for: "--seconds", in: arguments).flatMap(Double.init) ?? 20
        let only = value(for: "--only", in: arguments)
        let insertName = value(for: "--insert", in: arguments)
        // A third slot exists now, and a chain is only proven by filling the last one.
        let insert3Name = value(for: "--insert3", in: arguments)
        // Both slots, because the two-slot case is the one that exercises a chained insert:
        // slot 1's summing mixer becomes the node that fans out into slot 2.
        let insert2Name = value(for: "--insert2", in: arguments)
        let mix = value(for: "--mix", in: arguments).flatMap(Double.init)

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()

        // A throwaway preferences suite, for the same reason the render harness uses one: this
        // loads a plugin into insert 1 and joins streams, and `shutdown()` persists both — so
        // on the real domain a diagnostic run would quietly change the app's settings.
        let suite = "app.networkaudiograbber.selftest"
        // `--keep` leaves this run's preferences in the throwaway suite instead of wiping them,
        // which is the only way to test anything that is *remembered* — a per-stream mix mode,
        // a per-device bus width — since that needs two runs to see. Still the throwaway suite,
        // so the real app's settings are untouched either way.
        let keepDefaults = arguments.contains("--keep")
        // The run before the exit-time wipe below; `defer` is no use here because `exit` does
        // not unwind.
        if !keepDefaults { UserDefaults.standard.removePersistentDomain(forName: suite) }

        // Safe despite the @Sendable Timer closure below: every touch is inside
        // MainActor.assumeIsolated, and this harness is single-threaded by construction.
        nonisolated(unsafe) let state = AppState(defaults: UserDefaults(suiteName: suite) ?? .standard)
        if let name = value(for: "--iface", in: arguments) { state.selectedInterface = name }
        // `--autostop N`: auto-stop after N minutes without audio, to watch it stop a stream.
        if let minutes = value(for: "--autostop", in: arguments).flatMap(Int.init) {
            state.autoStopStreams = true
            state.autoStopStreamsMinutes = minutes
        }
        // `--master` is how the *post*-insert peak meter gets checked without making a noise:
        // 0.001 puts a −12 dBFS tone at −72 dBFS, which the meter reads and nobody hears. That
        // is the only way to prove audio survives the parallel insert wiring, since the
        // loudness readings are taken upstream of it.
        let latency = value(for: "--latency", in: arguments).flatMap(Double.init)
        let deviceBuffer = value(for: "--devicebuffer", in: arguments).flatMap(UInt32.init)
        let silent = arguments.contains("--silent")
        let master = value(for: "--master", in: arguments).flatMap(Double.init)
        // Before `start()`, so the engine is built against the new block size.
        if let deviceBuffer { _ = state.setOutputBufferFrames(deviceBuffer) }
        if let latency { state.latencyMs = min(80, max(5, latency)); state.vbanLatencyMs = min(80, max(5, latency)) }
        if let master { state.masterVolume = min(1, max(0, master)) }
        else if silent { state.masterVolume = 0 }
        let bypass = arguments.contains("--bypass")
        // 1-based, like --insert2. `--delta 1 --insert <transparent plugin> --master 0.001`
        // is the null test: a plugin that changes nothing must subtract to silence, and a
        // residual means either the inversion or the delay compensation is wrong.
        let delta = value(for: "--delta", in: arguments).flatMap(Int.init)
        // Width of the monitor bus, for exercising multichannel output without a rig:
        // any device with more than two outputs will do.
        let busWidth = value(for: "--bus", in: arguments).flatMap(Int.init)
        let mute = arguments.contains("--mute")
        // Mute part-way through, to see what an already-running loudness measurement does.
        let muteAfter = value(for: "--muteafter", in: arguments).flatMap(Double.init)
        var muteApplied = false
        // "Stop all" part-way through, to see the master meters fall to zero and then stop
        // redrawing, rather than freeze where the stop caught them.
        // Switch the system's default output to a named device part-way through and back again,
        // reporting where the engine actually renders after each change. **Changes a
        // system-wide setting** for a few seconds; the original default is always put back.
        let flipTo = value(for: "--flipto", in: arguments)
        var flipStep = 0
        var flipAt = Date.distantFuture
        var flipOriginal = AudioDeviceID(0)
        var flipCalls: UInt64 = 0
        let stopAfter = value(for: "--stopafter", in: arguments).flatMap(Double.init)
        var stoppedAt: Date?
        var metersIdleLogged = false
        // 1-based on the command line, like everything else the user sees.
        let solo = Set((value(for: "--solo", in: arguments) ?? "")
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .map { $0 - 1 }
            .filter { $0 >= 0 })
        let mixMode = value(for: "--mixmode", in: arguments)
        // On by default in the app, but off here unless asked for, so a self-test
        // never binds VBAN's port by surprise (pair with `Tools/vban_sender.py`). Set before
        // `start()` so the first discovery opens the port.
        state.vbanEnabled = arguments.contains("--vban")
        if arguments.contains("--scream") { state.screamEnabled = true }
        // The beta receivers are off by default; a test of them switches them on.
        if arguments.contains("--plain-rtp") { state.plainRTPEnabled = true }
        if arguments.contains("--web") { state.webStreamsEnabled = true }
        // A Network Audio Sender by address, as Settings → Discovery adds one.
        if let sender = value(for: "--vban-sender", in: arguments) {
            print("Sender    : " + (state.addManualSender(sender) ?? "asking \(sender)"))
        }
        // `--output-device <name>`: play on that device rather than the system default,
        // as Settings → Output chooses one. The run's own preferences, so the app's are untouched.
        if let name = value(for: "--output-device", in: arguments) {
            if let option = state.outputDeviceOptions.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) {
                state.chooseOutputDevice(option)
                print("Output    : chose \(option.name) (\(option.channels) ch)")
            } else {
                print("Output    : no output device matching \"\(name)\"")
            }
        }
        // `--output-device-missing`: a chosen device that is not connected, as if unplugged.
        if arguments.contains("--output-device-missing") {
            state.chooseOutputDevice(.init(uid: "selftest-unplugged-device", name: "Unplugged Test Device", channels: 2))
        }
        state.start()
        // A Remote link: `--make-remote-code` asks the address server from the VBAN
        // socket and prints this end's code; `--remote-link <code>` links the sending end's.
        // `--connection-test`: treat every stream as remote, and run the 30 s test on the first
        // one playing (the test tone on lo0, say), printing what it suggests.
        if arguments.contains("--connection-test") {
            RemoteAddresses.testEverythingRemote = true
            Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { _ in
                MainActor.assumeIsolated {
                    guard let first = state.playingRemoteStreams.first else { print("Test      : nothing playing"); return }
                    state.testConnection(first.id)
                    Timer.scheduledTimer(withTimeInterval: AppState.connectionTestSeconds + 1, repeats: false) { _ in
                        MainActor.assumeIsolated {
                            switch state.connectionTest {
                            case .done(let r):
                                print(String(format: "Test      : “%@” spread %.1f ms, worst %.1f ms, lost %.2f %%, suggested %.0f ms",
                                             r.streamName, r.spreadMs, r.worstMs, r.lostPercent, r.suggestedMs))
                            case .failed(let why): print("Test      : failed — \(why)")
                            default: print("Test      : still running")
                            }
                        }
                    }
                }
            }
        }
        if arguments.contains("--make-remote-code") {
            state.makeRemoteCode()
            let until = Date().addingTimeInterval(4)
            while state.makingRemoteCode, Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
            print("Remote    : " + (state.remoteCode.map { "this end's code \($0.text) (port \($0.port))" }
                                    ?? (state.remoteCodeError ?? "no code")))
        }
        if arguments.contains("--print-vban-port") {
            print("VBANPORT  : \(state.vbanListenPort)")
            fflush(stdout)
        }
        if let code = value(for: "--remote-link", in: arguments) {
            print("Remote    : " + (state.linkRemote(code) ?? "linked \(code)"))
        }
        // Test only, as in the Sender's: this end's code for 127.0.0.1 with its real
        // secret, to a file; and the other end's, linked as soon as it appears in its file.
        if let path = value(for: "--local-code-file", in: arguments) {
            let code = RemoteCode(role: .receiving, address: "127.0.0.1", port: UInt16(state.vbanListenPort), secret: state.remoteSecret)
            try? code.text.write(toFile: path, atomically: true, encoding: .utf8)
            print("Remote    : wrote this end's local code (port \(state.vbanListenPort))")
        }
        if let path = value(for: "--remote-link-file", in: arguments) {
            var linked = false
            Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { t in
                MainActor.assumeIsolated {
                    guard !linked, let text = try? String(contentsOfFile: path, encoding: .utf8)
                            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
                    linked = true
                    t.invalidate()
                    print("Remote    : " + (state.linkRemote(text) ?? "linked the code from the file"))
                }
            }
        }
        // An internet stream by its address: probed, listed, then joinable with --only.
        if let web = value(for: "--web", in: arguments) {
            state.addWebStream(web) { error in
                print("Web       : " + (error ?? "added " + (state.streams.last { $0.description.source == .web }?.description.formatSummary ?? "")))
            }
        }
        if let busWidth { state.setBusWidth(busWidth) }
        print("Interface : \(state.selectedInterface) (\(state.interfaceAddress))")
        if silent || master != nil {
            print(String(format: "Master    : %.4g (loudness is measured ahead of it)",
                         state.masterVolume))
        }
        if state.vbanEnabled {
            // What Settings → Discovery tells a user to point a sender at, read from this Mac.
            print("VBAN      : " + (state.vbanError ?? state.vbanSharingNote ?? "listening on UDP \(VBAN.port); send to "
                + state.vbanAddresses.map { a in
                    "\(a.address) (\(a.kindLabel)" + (a.broadcast.map { ", broadcast \($0)" } ?? "") + ")"
                }.joined(separator: ", ")))
        }
        print("Output    : \(state.outputDeviceName) @ \(Int(state.outputRate)) Hz"
            + "   device \(state.outputChannels) ch   bus \(state.busChannels) ch")

        var subscribed = false
        var insertDone = insertName == nil && insert2Name == nil && insert3Name == nil
        let deadline = Date().addingTimeInterval(seconds)

        // A real AppKit run loop, not `RunLoop.run(until:)`: only `NSApplication.run()` drains
        // the main dispatch queue, and both the Audio Unit scan and `AVAudioUnit.instantiate`
        // publish their results there.
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            MainActor.assumeIsolated {
                if !insertDone, !state.availablePlugins.isEmpty {
                    insertDone = true
                    for (slot, wanted) in [(0, insertName), (1, insert2Name),
                                           (2, insert3Name)] {
                        guard let wanted else { continue }
                        if let match = state.availablePlugins.first(where: {
                            $0.name.localizedCaseInsensitiveContains(wanted)
                        }) {
                            print("Insert \(slot + 1)  : \(match.display)")
                            state.setPlugin(slot: slot, to: match)
                            if let mix { state.setSlotMix(slot, mix) }
                            if bypass { state.toggleBypass(slot: slot) }
                        } else {
                            print("Insert \(slot + 1)  : nothing matching \"\(wanted)\" among "
                                + "\(state.availablePlugins.count) AUs")
                        }
                    }
                }

                // After the insert is wired, not when it is chosen: instantiation is
                // asynchronous, so this retries until the node is in the graph.
                if let delta, state.deltaSlot != delta - 1, state.slotLive.indices.contains(delta - 1) {
                    state.setDelta(slot: delta - 1, true)
                }

                if !subscribed, let only,
                   let target = state.streams.first(where: {
                       $0.description.name.localizedCaseInsensitiveContains(only)
                   }) {
                    subscribed = true
                    state.toggle(target.description)
                    if let mixMode, let mode = parseMixMode(mixMode) {
                        state.setMixMode(target.id, mode)
                    }
                    for channel in solo { state.toggleChannelSolo(target.id, channel) }
                    if mute { state.toggleMute(target.id) }
                }

                if let muteAfter, !muteApplied, subscribed,
                   Date() >= deadline.addingTimeInterval(-(seconds - muteAfter)),
                   let target = state.streams.first(where: { state.isSubscribed($0.id) }) {
                    muteApplied = true
                    state.toggleMute(target.id)
                    print(String(format: "  muted at %.0f s: I was %@",
                                 muteAfter, state.readouts.integrated.value))
                }

                if let flipTo, subscribed {
                    func report(_ what: String) {
                        let d = state.outputDiagnostic
                        let pulled = d.renderCalls &- flipCalls
                        flipCalls = d.renderCalls
                        // Any real device calls back tens of times a second; a handful in three
                        // seconds is an engine that has stopped pulling audio.
                        let ok = d.engineDevice == d.defaultDevice && pulled > 50
                        print("  \(what): default \(d.defaultDevice), engine renders to "
                            + "\(d.engineDevice) (\(d.engineRunning ? "running" : "STOPPED")), "
                            + "\(pulled) callbacks in 3 s, \(d.restarts) restart(s) so far  "
                            + (ok ? "OK" : "FAIL"))
                    }
                    if flipStep == 0 {
                        flipStep = 1; flipAt = Date().addingTimeInterval(3)
                        flipCalls = state.outputDiagnostic.renderCalls
                    } else if Date() >= flipAt {
                        flipAt = Date().addingTimeInterval(3)
                        switch flipStep {
                        case 1:
                            report("before")
                            flipOriginal = CoreAudioDevice.defaultOutputID
                            if let target = CoreAudioDevice.outputDevices.first(where: {
                                CoreAudioDevice.name(of: $0).localizedCaseInsensitiveContains(flipTo)
                            }), target != flipOriginal {
                                CoreAudioDevice.setDefaultOutput(target)
                                flipStep = 2
                            } else {
                                print("  flip: no other output device matching \"\(flipTo)\"")
                                flipStep = 9
                            }
                        case 2:
                            report("after switching to it")
                            CoreAudioDevice.setDefaultOutput(flipOriginal)
                            flipStep = 3
                        case 3:
                            report("after switching back")
                            flipStep = 9
                        default:
                            break
                        }
                    }
                }

                if let stopAfter, stoppedAt == nil, subscribed,
                   Date() >= deadline.addingTimeInterval(-(seconds - stopAfter)) {
                    stoppedAt = Date()
                    print(String(format: "  stop all at %.0f s: output peak %.3g, hold %.3g",
                                 stopAfter, state.outputPeakL, state.outputPeakHold))
                    state.unsubscribeAll()
                }
                if let stoppedAt, !metersIdleLogged, !state.metersActive {
                    metersIdleLogged = true
                    print(String(format: "  meters idle %.1f s after the stop: output peak %.3g, hold %.3g",
                                 Date().timeIntervalSince(stoppedAt), state.outputPeakL,
                                 state.outputPeakHold))
                }

                guard Date() >= deadline else { return }
                if flipStep == 2 || flipStep == 3, flipOriginal != 0 {
                    CoreAudioDevice.setDefaultOutput(flipOriginal)      // never leave it switched
                }
                if stoppedAt != nil, !metersIdleLogged {
                    print(String(format: "  meters STILL running at the end: output peak %.3g, hold %.3g",
                                 state.outputPeakL, state.outputPeakHold))
                }
                timer.invalidate()
                report(state)
                state.shutdown()
                if keepDefaults {
                    // `exit` runs no `defer` and gives cfprefsd no chance to flush on its own.
                    UserDefaults(suiteName: suite)?.synchronize()
                } else {
                    UserDefaults.standard.removePersistentDomain(forName: suite)
                }
                exit(0)
            }
        }
        app.run()
    }

    /// `pair:6`, `mono:2` or `downmix`, all 0-based to match `MixMode` itself.
    private static func parseMixMode(_ text: String) -> MixMode? { MixMode(token: text) }

    @MainActor
    private static func report(_ state: AppState) {
        let peak = max(state.outputPeakL, state.outputPeakR)
        let db = peak > 1e-6 ? String(format: "%.1f dBFS", 20 * log10(Double(peak))) : "silent"
        print("")
        print("Discovered: \(state.streams.count)   listening: \(state.subscribed.count)   "
            + "Audio Units: \(state.availablePlugins.count)")
        for slot in 0..<state.slotInfo.count {
            print("Insert \(slot + 1)  : \(state.slotInfo[slot]?.name ?? "empty")"
                + (state.slotBypassed[slot] ? " (bypassed)" : "")
                + (state.slotFailure[slot].map { " (FAILED: \($0))" } ?? "")
                + String(format: "  mix %.0f %% wet", state.slotMix[slot] * 100))
        }
        print("Engine    : \(state.audioGraphSummary)")
        print("Device    : \(state.outputDeviceName)"
            + (state.outputDeviceUID == nil ? " (system default)" : state.outputFallback ? " (chosen device missing: system default)" : " (chosen)"))
        print("Meter tap : \(state.meterTapSummary)")
        print("Latency   : \(state.latencyBudget)")
        print("Output pk : \(db)   max readout \(state.readouts.outputMax) dBFS")

        // Per-channel, at any width: on a wide bus it says whether pass-through reached the
        // outputs it claims to, and on a stereo one it shows the left/right balance a fold
        // produced — which is how a channel-order mistake announces itself.
        do {
            let labels = state.busChannelLabels
            let peaks = (0..<state.busChannels).map { channel -> String in
                let level = state.outputPeak(channel)
                let text = level > 0.00002
                    ? String(format: "%.0f", 20 * log10(Double(level))) : "−∞"
                return "\(labels[channel]) \(text)"
            }
            print("Bus peaks : " + peaks.joined(separator: "  ") + "   (dBFS)")
        }
        print("Loudness  : " + [("S", state.loudnessShortTerm),
                                ("W", state.loudnessWindowed),
                                ("I", state.loudnessIntegrated)]
            .map { name, value in
                value.isFinite ? String(format: "%@ %.1f LUFS", name, value) : "\(name) −∞"
            }
            .joined(separator: "   ")
            + "   (\(state.loudnessBlocks) blocks, \(state.lufsWindowSeconds) s window)")
        for stream in state.streams where state.isSubscribed(stream.id) {
            let solo = state.soloedChannels(stream.id).sorted().map { String($0 + 1) }
            print("  mix       : "
                + Downmix.label(for: state.mixMode(for: stream.id),
                                channels: stream.description.channels)
                + (solo.isEmpty ? "" : "   solo ch \(solo.joined(separator: ","))"))
            let peaks = (0..<stream.description.channels)
                .map { state.channelPeak(stream.id, $0) }
            print(String(format: "  input peaks: max %.3f across %d channels   muted: %@",
                         peaks.max() ?? 0, peaks.count,
                         state.isMuted(stream.id) ? "yes" : "no"))
            if let f = state.figures(stream.id) {
                let h = state.health[stream.id] ?? StreamHealth()
                print(String(format: "  %@  pkts %llu  lost %llu  under %llu  buf %.0f ms  "
                                   + "drift %+.0f ppm  peak %.3f  jitter %.2f ms  worst %.2f ms",
                             stream.description.name, f.packets, h.lost, h.underruns,
                             f.bufferMs, f.driftPPM, f.peak, f.jitterMs, f.worstJitterMs))
            }
            if stream.description.source == .web {
                print("  now playing: \(state.nowPlaying[stream.id] ?? "—")")
            }
        }
        print("")
        print("--- app log ---")
        state.activity.entries.suffix(300).forEach {
            print("\(ActivityLogView.time($0.date))  \($0.kind.label.padding(toLength: 7, withPad: " ", startingAt: 0))  \($0.text)")
        }
    }

    private static func value(for flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}
