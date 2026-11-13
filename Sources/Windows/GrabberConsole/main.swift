import Foundation
import NetworkAudioEngine
import GrabberCore

// `nag-grab` — the Windows Grabber, without a window.
//
//   nag-grab [--list] [--play <name>]… [--seconds N] [--bus 2|4|6|8] [--volume V]
//            [--sender <ip[:port]>] [--scream] [--rtp] [--dante] [--no-ravenna] [--list-networks] [--keep]
//
// It listens for streams with the same engine the Mac Grabber runs and plays the ones named on
// the default playback device, in shared mode, through WASAPI.
//
// **It plays only what it is told.** Listening is passive: streams are listed as their
// announcements and packets arrive, and nothing is joined until `--play` names it. A Network
// Audio Sender that asks its own user first shows as "Asking…" until they allow it.

setvbuf(stdout, nil, _IONBF, 0)

let arguments = Array(CommandLine.arguments.dropFirst())

func flag(_ name: String) -> Bool { arguments.contains(name) }

func value(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}

func values(_ name: String) -> [String] {
    var found: [String] = []
    for (i, argument) in arguments.enumerated() where argument == name && i + 1 < arguments.count {
        found.append(arguments[i + 1])
    }
    return found
}

if flag("--help") || flag("-h") {
    print("""
    nag-grab — the Windows Grabber (no window)

      --list              list the streams found, then stop (after --seconds, default 5)
      --play <name>       play the stream with this name (or the start of it); may be given
                          more than once. "all" plays everything found.
      --seconds N         stop after N seconds (default: until Ctrl-C; 5 with --list)
      --bus 2|4|6|8       the output bus: stereo (default), 4.0, 5.1 or 7.1
      --volume V          the master volume, 0 to 1 (default 1). 0 plays silence while
                          everything is still received and measured — for testing with a
                          Sender on this same PC, whose capture would otherwise hear it
      --sender <ip[:port]>  ask a Network Audio Sender at this address for its stream
                          (for a VPN, or where its beacon cannot reach)
      --scream            listen for Scream too (UDP 4010, multicast; off by default)
      --rtp               list RTP streams that name no PTP clock (beta; off by default)
      --no-dante          do not browse for Dante devices (on by default, as on the Mac; it
                          labels their AES67 streams Dante)
      --dante-txt         with --list: also print what each Dante device publishes in its TXT
                          records (maker, model and the like) — to see what a RedNet unit says
      --no-ravenna        do not browse for RAVENNA sessions (on by default, as on the Mac)
      --list-networks     print this PC's networks and interfaces, then stop
      --keep              keep this run's settings for the next run
      --help              this

    VBAN (UDP 6980) and SAP announcements are listened for. Nothing is played or asked for
    until --play names it.
    """)
    exit(0)
}

if flag("--list-networks") {
    print("Interfaces this PC can receive on:")
    for i in Interfaces.receiveAddresses() {
        print("  \(i.name)  \(i.address)  \(i.kindLabel)"
              + (i.broadcast.map { "  broadcast \($0)" } ?? ""))
    }
    print("Networks:")
    for n in LocalNetworks.list() {
        print("  \(n.name)  \(n.address)/\(n.netmask)" + (n.broadcast.map { "  broadcast \($0)" } ?? ""))
    }
    exit(0)
}

// A settings file of its own, so a test leaves the window's alone.
let suite = "app.networkaudiograbber.naggrab"
if !flag("--keep") { UserDefaults.standard.removePersistentDomain(forName: suite) }
let defaults = UserDefaults(suiteName: suite) ?? .standard

let grabber = WindowsGrabber(defaults: defaults, logFile: nil)
if flag("--scream") { grabber.screamEnabled = true }
if flag("--rtp") { grabber.plainRTPEnabled = true }
if flag("--dante") || flag("--dante-txt") { grabber.danteEnabled = true }
if flag("--no-dante") { grabber.danteEnabled = false }
if flag("--no-ravenna") { grabber.ravennaEnabled = false }
if let volume = value("--volume").flatMap(Double.init) { grabber.masterVolume = max(0, min(1, volume)) }
grabber.start()
if let bus = value("--bus").flatMap(Int.init) { grabber.setBusWidth(bus) }
for sender in values("--sender") {
    if let error = grabber.addManualSender(sender) { print("--sender \(sender): \(error)") }
}

let wanted = values("--play")
let listOnly = flag("--list")
let stopAfter = value("--seconds").flatMap(Double.init) ?? (listOnly ? 5 : nil)
let started = Date()

print("nag-grab — the Windows Grabber \(WindowsGrabber.version)")
print("Output    : \(grabber.outputDeviceName), \(Int(grabber.outputRate)) Hz, device \(grabber.wasapi.mixChannels) ch, "
      + "bus \(grabber.busWidthLabel(grabber.busChannels))")
print("Graph     : \(grabber.audioGraphSummary)")
print("Listening : VBAN on UDP \(grabber.vbanListenPort), SAP" + (grabber.ravennaEnabled ? ", RAVENNA" : "")
      + (grabber.danteEnabled ? ", Dante" : "") + (grabber.screamEnabled ? ", Scream" : "")
      + (wanted.isEmpty ? "   (nothing will play: no --play)" : "   playing: " + wanted.joined(separator: ", ")))

func matches(_ stream: DiscoveredStream, _ name: String) -> Bool {
    if name.lowercased() == "all" { return true }
    let have = stream.description.name.lowercased()
    return have == name.lowercased() || have.hasPrefix(name.lowercased()) || stream.id == name
}

var known: Set<String> = []
var asked: Set<String> = []

func line(_ s: DiscoveredStream) -> String {
    let d = s.description
    return "\(d.source.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0)) \(d.name)  "
        + "\(d.formatSummary)  from \(d.originAddress)"
}

let ticker = Timer(timeInterval: 1, repeats: true) { timer in
    let elapsed = Date().timeIntervalSince(started)
    // New streams, as they are found.
    for s in grabber.streams where !known.contains(s.id) {
        known.insert(s.id)
        print(String(format: "%4.0f s  found   ", elapsed) + line(s))
    }
    // Join what was asked for, once each, as it appears.
    if !listOnly {
        for s in grabber.streams where !asked.contains(s.id) && wanted.contains(where: { matches(s, $0) }) {
            asked.insert(s.id)
            grabber.toggle(s.description)
            print(String(format: "%4.0f s  play    ", elapsed) + s.description.name)
        }
        for id in grabber.subscribed.sorted() {
            let name = grabber.streams.first { $0.id == id }?.description.name ?? id
            let h = grabber.health[id] ?? StreamHealth()
            let f = grabber.figures(id) ?? StreamFigures()
            print(String(format: "%4.0f s  %@  %@  packets %llu  lost %llu  underruns %llu  buffer %.1f ms  "
                         + "jitter %.2f ms  drift %+.0f ppm  peak %@",
                         elapsed, name, grabber.statusText(id).padding(toLength: 17, withPad: " ", startingAt: 0),
                         f.packets, h.lost, h.underruns, f.bufferMs, f.jitterMs, f.driftPPM, db(f.peak)))
        }
        if !grabber.subscribed.isEmpty {
            let peaks = (0..<grabber.busChannels).map { db(grabber.outputPeak($0)) }
            print("         out  " + zip(grabber.busChannelLabels, peaks).map { "\($0) \($1)" }.joined(separator: "  "))
        }
    }
    guard let stopAfter, elapsed >= stopAfter else { return }
    timer.invalidate()
    finish()
}
RunLoop.main.add(ticker, forMode: .default)

func db(_ v: Float) -> String { v > 1e-6 ? String(format: "%5.1f", 20 * log10(v)) : "   −∞" }

func finish() -> Never {
    print("--- streams ---")
    for s in grabber.streams { print("  " + line(s)) }
    if grabber.streams.isEmpty { print("  (none found)") }
    if flag("--dante-txt") {
        print("--- Dante devices' TXT records ---")
        let records = grabber.danteTXTRecords()
        for device in records.keys.sorted() {
            print("  \(device)")
            for (type, txt) in records[device]!.sorted(by: { $0.key < $1.key }) {
                print("    \(type): " + (txt.isEmpty ? "(none)" : txt.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "  ")))
            }
        }
        if records.isEmpty { print("  (no Dante devices found)") }
    }
    if !grabber.subscribed.isEmpty {
        print("--- played ---")
        for id in grabber.subscribed.sorted() {
            let h = grabber.health[id] ?? StreamHealth()
            let f = grabber.figures(id) ?? StreamFigures()
            print(String(format: "  %@: packets %llu, lost %llu, underruns %llu, buffer %.1f ms (lowest %.1f ms)",
                         grabber.streams.first { $0.id == id }?.description.name ?? id,
                         f.packets, h.lost, h.underruns, f.bufferMs, f.minBufferMs))
        }
        print("Latency   : " + grabber.latencyBudget.replacingOccurrences(of: "\n", with: "\n            "))
        print("Meter tap : \(grabber.meterTapSummary)")
    }
    grabber.shutdown()
    print("--- log ---")
    for entry in grabber.activity.entries { print("  \(entry.kind.label)  \(entry.text)") }
    exit(0)
}

// Ctrl-C stops it the same way, so the figures and the log are printed either way.
signal(SIGINT) { _ in finish() }

RunLoop.main.run()
