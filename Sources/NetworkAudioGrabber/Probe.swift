import Foundation
import CoreWLAN

/// Headless diagnostics:
/// `NetworkAudioGrabber --probe [--iface en5] [--seconds 20] [--listen] [--only <text>] [--play] [--dante]`.
///
/// `--play` routes the joined streams to the default output device through the same audio
/// engine the app uses, so the whole chain can be checked from a terminal.
///
/// Exercises exactly the same discovery, RTP decode and resampling code as the app, but
/// prints to the terminal instead of playing, so a silent stream can be diagnosed without
/// guessing at CoreAudio.
enum Probe {
    static func run(arguments: [String]) {
        // Unbuffered, so progress still streams when the output is piped into grep or a file.
        setvbuf(stdout, nil, _IONBF, 0)
        let seconds = value(for: "--seconds", in: arguments).flatMap(Double.init) ?? 15
        let listen = arguments.contains("--listen")
        // Without --only, --listen subscribes to everything it finds, which can pull a lot of
        // multicast onto the link. --only narrows it to sessions whose name contains the text.
        let only = value(for: "--only", in: arguments)
        let play = arguments.contains("--play")
        let wantDante = arguments.contains("--dante")

        Interfaces.wifiNames = Set(CWWiFiClient.shared().interfaceNames() ?? [])   // as the app does
        SAPListener.inflate = SAPInflate.inflate
        let all = Interfaces.listIPv4()
        guard !all.isEmpty else {
            print("No usable IPv4 interface found.")
            exit(1)
        }
        let requested = value(for: "--iface", in: arguments)
        let iface = all.first(where: { $0.name == requested || $0.address == requested })
            // Accept any literal IPv4 too, so lo0 or a filtered interface can still be probed.
            ?? requested.flatMap { r in r.contains(".") ? NetInterface(name: r, address: r, kind: .wired) : nil }
            ?? all[0]

        print("Interface : \(iface.display)")
        let scope = only.map { "  (subscribing to names containing \"\($0)\")" }
            ?? "  (subscribing to every stream found)"
        print("Duration  : \(Int(seconds))s\(listen ? scope : "")")
        print("")

        var found: [String: StreamDescription] = [:]
        var receivers: [String: RTPReceiver] = [:]
        let lock = NSLock()
        var player: AudioOutput?

        let handle: (String, DiscoverySource) -> Void = { sdp, source in
            guard let desc = SDPParser.parse(sdp, source: source) else { return }
            lock.lock()
            let isNew = found[desc.id] == nil
            found[desc.id] = desc
            lock.unlock()
            guard isNew else { return }
            print("FOUND  \(desc.name)")
            print("       \(desc.groupAddress):\(desc.port)  \(desc.formatSummary)  via \(source.rawValue)")
            if let ptp = desc.ptpRef { print("       clock \(ptp)") }

            let wanted = only.map { desc.name.localizedCaseInsensitiveContains($0) } ?? true
            if listen && wanted {
                let r = RTPReceiver(stream: desc, latencyMs: 15)
                // Fold 5.1/7.1 down the same way the app does; everything else stays on ch 1/2.
                if let layout = SMPTELayout.forChannelCount(desc.channels),
                   layout == .surround51 || layout == .surround71 {
                    r.setMix(.downmix, includeLFE: false, trimDB: -3)
                }
                if let err = r.start(interfaceAddress: iface.address) {
                    print("       JOIN FAILED: \(err)")
                } else {
                    lock.lock(); receivers[desc.id] = r; lock.unlock()
                    lock.lock(); let all = Array(receivers.values); lock.unlock()
                    player?.setReceivers(all)
                    print("       joined")
                }
            }
        }

        var danteBrowser: DanteBrowser?
        if wantDante {
            let browser = DanteBrowser()
            // Keyed on name+address so both the initial sighting and the resolved address
            // are reported once each, which distinguishes a browse failure from a resolve one.
            var announced = Set<String>()
            browser.onDevicesChanged = { devices in
                for d in devices {
                    let key = "\(d.name)|\(d.address ?? "-")"
                    guard announced.insert(key).inserted else { continue }
                    print("DANTE  \(d.name)  \(d.address ?? "resolving…")  \(d.channelNames.count) tx ch")
                }
            }
            browser.onError = { print("Dante: \($0)") }
            browser.start()
            danteBrowser = browser
        }

        if play {
            let out = AudioOutput()
            if let err = out.start() {
                print("Audio: \(err)")
            } else {
                print("Output    : \(out.deviceName) @ \(Int(out.deviceRate)) Hz")
            }
            player = out
        }
        print("")

        let sap = SAPListener()
        sap.onAnnouncement = { sdp, deletion in
            if deletion { print("DELETED announcement") } else { handle(sdp, .sap) }
        }
        sap.onError = { print("SAP: \($0)") }
        sap.start(interfaceAddress: iface.address)

        let ravenna = RavennaBrowser()
        ravenna.onSDP = { handle($0, .ravenna) }
        ravenna.onError = { print("mDNS: \($0)") }
        ravenna.start()

        // Pull audio at 48 kHz in 1024-frame blocks, exactly as the render callback would,
        // and report level and dominant frequency so a decoded tone is verifiable.
        let block = 1024
        let left = UnsafeMutablePointer<Float>.allocate(capacity: block)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: block)
        defer { left.deallocate(); right.deallocate() }


        let deadline = Date().addingTimeInterval(seconds)
        var nextReport = Date().addingTimeInterval(1)
        var accum: [String: (rms: Double, crossings: Int, blocks: Int)] = [:]

        while Date() < deadline {
            lock.lock()
            let active = receivers
            lock.unlock()

            if play || active.isEmpty {
                // Run the main queue rather than sleeping: plugin instantiation and Bonjour
                // resolution both call back on it.
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            } else {
                for (id, r) in active {
                    left.update(repeating: 0, count: block)
                    right.update(repeating: 0, count: block)
                    // The probe measures a stereo fold, which is all its RMS and zero-crossing
                    // figures need; the bus pointers are just left and right side by side.
                    let buses = [left, right]
                    buses.withUnsafeBufferPointer { pointers in
                        guard let base = pointers.baseAddress else { return }
                        r.render(into: base, busCount: 2, frames: block, outputRate: 48000)
                    }

                    var sum = 0.0
                    var crossings = 0
                    var previous: Float = 0
                    for i in 0..<block {
                        let v = left[i]
                        sum += Double(v * v)
                        if (previous < 0 && v >= 0) || (previous > 0 && v <= 0) { crossings += 1 }
                        previous = v
                    }
                    var entry = accum[id] ?? (0, 0, 0)
                    entry.rms += (sum / Double(block)).squareRoot()
                    entry.crossings += crossings
                    entry.blocks += 1
                    accum[id] = entry
                }
                // 1024 frames at 48 kHz ≈ 21.3 ms of audio.
                Thread.sleep(forTimeInterval: Double(block) / 48000.0)
            }

            if Date() >= nextReport {
                nextReport = Date().addingTimeInterval(1)
                lock.lock()
                let snapshot = receivers
                lock.unlock()
                if let player {
                    let peak = max(player.peakL, player.peakR)
                    let db = peak > 1e-6
                        ? String(format: "%.1f dBFS", 20 * log10(Double(peak)))
                        : "silent"
                    print("  [output \(player.deviceName) @ \(Int(player.deviceRate)) Hz, peak \(db)]")
                }
                for (id, r) in snapshot.sorted(by: { $0.key < $1.key }) {
                    let a = accum[id] ?? (0, 0, 0)
                    let blocks = max(1, a.blocks)
                    let rms = a.rms / Double(blocks)
                    let db = rms > 1e-9 ? 20 * log10(rms) : -140
                    let hz = Double(a.crossings) / 2.0 / (Double(blocks) * Double(block) / 48000.0)
                    let bufMs = r.ring.availableFrames / Double(r.stream.sampleRate) * 1000
                    print(String(format:
                        "  %-22@ pkts %-8llu lost %-5llu under %-4llu buf %5.1f ms  ratio %.6f  level %6.1f dBFS  ~%5.0f Hz",
                        r.stream.name as NSString, r.packetsReceived, r.packetsLost, r.underruns,
                        bufMs, r.ratio, db, hz))
                    accum[id] = (0, 0, 0)
                }
            }
        }

        lock.lock()
        let final = receivers
        receivers.removeAll()
        lock.unlock()
        danteBrowser?.stop()
        player?.setReceivers([])
        player?.stop()
        final.values.forEach { $0.stop() }
        sap.stop()
        ravenna.stop()

        print("")
        print("\(found.count) stream(s) discovered.")
        exit(0)
    }

    private static func value(for flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}
