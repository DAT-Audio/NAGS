import Foundation
import NetworkAudioEngine
import SenderCore

// `nag-send` — the Windows Sender, without a window.
//
//   nag-send --to <ip[:port]> [--to …] [--findable] [--name <stream>] [--seconds N]
//            [--bits 16|24] [--mute-local] [--allow-all] [--list-networks] [--keep]
//            [--source system|app:<exe>|input:<name or id>] [--list-sources] [--include-self]
//
// It captures this PC's own audio with WASAPI and sends it as VBAN, using the same engine the
// Mac Sender runs, so a Mac Grabber hears it as it would hear a Mac. What it captures is the
// source: everything this PC plays less a running Grabber's playback, one app, or
// one input device.
//
// **It sends only where it is told.** With no `--to` and no `--findable` it captures, prints what
// it would send, and puts nothing on the network at all.

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
    nag-send — the Windows Sender (no window yet)

      --to <ip[:port]>   send to this address; may be given more than once
      --findable         offer the stream so Grabbers on this network can find it
      --allow-all        let any Grabber listen without being asked (with --findable)
      --name <stream>    the stream's name, as listeners see it (default "PC Audio")
      --bits 16|24       what is sent (default 24)
      --stereo           fold to two channels instead of sending the device's own count
                         (an 8-channel device at 48 kHz 16-bit is about 6.1 Mbit/s; two is 1.5)
      --seconds N        stop after N seconds (default: until Ctrl-C)
      --mute-local       ask to silence this PC's output: not available, see the note printed
      --source <what>    what to capture (default system):
                           system           everything this PC plays, less a running
                                            Grabber's playback (or this app's, with none)
                           app:<exe>        one app's audio, e.g. app:player.exe; silence
                                            until it runs
                           input:<name|id>  one input device, at its own channel count
                                            (--stereo does not apply to it)
      --list-sources     print the input devices and the apps with audio, then stop
      --include-self     with the system source, leave nothing out (the old loopback)
      --test-tone        test aid: play a quiet 1 kHz tone from this process and print how
                         loud 1 kHz is in the capture; leaves out this process, not a Grabber
      --list-networks    print this PC's networks and interfaces, then stop
      --keep             keep this run's settings for the next run
      --help             this

    With neither --to nor --findable, nothing is put on the network.
    """)
    exit(0)
}

// A settings file of its own, so a test leaves the real app's — when there is one — alone.
let suite = "app.networkaudiosender.nagsend"
if !flag("--keep") { UserDefaults.standard.removePersistentDomain(forName: suite) }
let defaults = UserDefaults(suiteName: suite) ?? .standard

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

if flag("--list-sources") {
    print("Process loopback (system less one app, or one app): "
          + (WASAPILoopback.processLoopbackAvailable ? "available" : "not available on this Windows"))
    print("Input devices (--source input:<name or id>):")
    let inputs = WASAPILoopback.inputDevices()
    if inputs.isEmpty { print("  (none connected)") }
    for device in inputs { print("  \(device.name)  \(device.channels) ch  \(device.id)") }
    print("Apps with audio on the default playback device (--source app:<exe>):")
    let apps = WASAPILoopback.audioApps()
    if apps.isEmpty { print("  (none)") }
    for app in apps {
        print("  \(app.exe)  \"\(app.name)\"  pid \(app.pid)" + (app.playing ? "  playing" : ""))
    }
    if let grabber = WASAPILoopback.grabberProcessID() { print("A Grabber is running: pid \(grabber)") }
    exit(0)
}

// What to capture. Read before the sender exists, so its first capture opens on it.
var source = WindowsSendSource.system
if let text = value("--source") {
    if text == "system" {
        source = .system
    } else if text.hasPrefix("app:") {
        let exe = String(text.dropFirst(4))
        source = .app(exe: exe, name: WindowsSendSource.plainName(exe))
    } else if text.hasPrefix("input:") {
        let wanted = String(text.dropFirst(6))
        let inputs = WASAPILoopback.inputDevices()
        guard let device = inputs.first(where: { $0.id == wanted })
                ?? inputs.first(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame })
                ?? inputs.first(where: { $0.name.localizedCaseInsensitiveContains(wanted) }) else {
            print("No input device matches \"\(wanted)\". These are connected:")
            for device in inputs { print("  \(device.name)  \(device.id)") }
            exit(2)
        }
        source = .input(id: device.id, name: device.name)
    } else {
        print("--source takes system, app:<exe> or input:<name or id>")
        exit(2)
    }
}

// The capture `WindowsSender` makes, reached as it is made. `nag-send` plays nothing itself, so
// the system source leaves out a running Grabber's playback rather than its own — unless the
// tone test is on, which is about this process's own playback.
var capture: WASAPILoopback?
WASAPILoopback.onCreate = { made in
    capture = made
    made.source = source
    if flag("--include-self") {
        made.excludedProcessID = nil
    } else if !flag("--test-tone") {
        made.excludeRunningGrabber = true
    }
}

let sender = WindowsSender(defaults: defaults, name: value("--name") ?? "PC Audio")

// The tone test: play 1 kHz from this process, and measure 1 kHz in what is captured.
let toneMeter = ToneMeter(frequency: 1000)
let tonePlayer = TestTonePlayer()
if flag("--test-tone"), let capture {
    let engineFeed = capture.onAudio
    capture.onAudio = { samples, frames, channels, rate in
        toneMeter.feed(samples, frames: frames, channels: channels, rate: rate)
        engineFeed?(samples, frames, channels, rate)
    }
    tonePlayer.start(frequency: 1000, level: 0.1)             // −20 dBFS
}
if let name = value("--name") { sender.streamName = name }
if value("--bits") == "24" { sender.dataType = .int24 }
if value("--bits") == "16" { sender.dataType = .int16 }
if flag("--stereo") { sender.stereoOnly = true }
if flag("--mute-local") { sender.muteThisMac = true }

// Where it goes. Nothing is sent anywhere that was not asked for here.
var targets: [SendTarget] = []
for text in values("--to") {
    let parts = text.split(separator: ":", maxSplits: 1)
    let host = String(parts[0])
    let port = parts.count > 1 ? Int(parts[1]) ?? VBAN.port : VBAN.port
    targets.append(SendTarget(host: host, port: port))
}
sender.targets = targets

if flag("--findable") {
    if flag("--allow-all") { sender.askFirst = false }
    sender.offering = true
}

sender.start()
for target in sender.targets { sender.toggleSending(target.id) }

print("nag-send — the Windows Sender")
print("Stream    : \(VBAN.wireName(sender.streamName))  \(sender.dataType == .int24 ? "24-bit" : "16-bit")")
if targets.isEmpty && !flag("--findable") {
    print("Sending   : nowhere — no --to and no --findable, so nothing goes on the network.")
} else {
    print("Sending   : " + (targets.isEmpty ? "(offered only)"
                            : targets.map(\.address).joined(separator: ", ")))
}
if flag("--findable") {
    print("Findable  : yes, on UDP \(sender.offerPort)"
          + (flag("--allow-all") ? " — anyone may listen" : " — each Grabber is asked for"))
}
if flag("--mute-local") { print("Note      : \(WASAPILoopback.muteNotice)") }
switch source {
case .system:
    let leftOut: String
    if flag("--include-self") { leftOut = "nothing left out" }
    else if flag("--test-tone") { leftOut = "this process left out" }
    else if let grabber = WASAPILoopback.grabberProcessID() { leftOut = "the Grabber (pid \(grabber)) left out" }
    else { leftOut = "no Grabber running, so this process left out" }
    print("Source    : this PC's audio, \(leftOut)")
case .app(let exe, _):
    print("Source    : one app, \(exe)")
case .input(_, let name):
    print("Source    : input device \(name)")
}
if flag("--test-tone") { print("Test tone : 1 kHz at −20 dBFS from this process") }

let started = Date()
let stopAfter = value("--seconds").flatMap(Double.init)
var lastPackets: UInt64 = 0
var announcedCapture = false
var lastDeviceFrames: UInt64 = 0

func db(_ v: Float) -> String { v > 1e-6 ? String(format: "%5.1f", 20 * log10(v)) : "   −∞" }

let ticker = Timer(timeInterval: 1, repeats: true) { timer in
    // Any Grabber that asked to listen, when the run said anyone may.
    if flag("--allow-all") { for request in sender.requests { sender.allow(request) } }

    let status: String
    switch sender.captureStatus {
    case .idle:
        status = "idle         "
    case .failed(let message):
        status = "FAILED: \(message)"
    case .running(let rate, let channels):
        status = "capturing \(rate / 1000) kHz \(channels) ch"
        if !announcedCapture {
            announcedCapture = true
            print("Capturing : \(sender.captureDevice)")
        }
    }
    let packets = sender.packetsSent
    let listening = sender.listeners.map { "\($0.name ?? "?")@\($0.ip)" }
    let tone = flag("--test-tone") ? "   1 kHz " + db(Float(toneMeter.take())) : ""
    // Frames the device itself gave this second: 0 while it gives nothing and silence is made.
    let deviceFrames = capture?.deviceFrames ?? 0
    let fromDevice = String(format: "   device %6llu fr/s", deviceFrames &- lastDeviceFrames)
    lastDeviceFrames = deviceFrames
    print(String(format: "%4.0f s  %@   L %@  R %@ dBFS%@%@   %4llu packets/s   errors %llu%@",
                 Date().timeIntervalSince(started), status,
                 db(sender.level(0)), db(sender.level(1)), tone, fromDevice,
                 packets &- lastPackets, sender.sendErrors,
                 listening.isEmpty ? "" : "   listening: " + listening.joined(separator: ", ")))
    lastPackets = packets

    guard let stopAfter, Date().timeIntervalSince(started) >= stopAfter else { return }
    timer.invalidate()
    finish()
}
RunLoop.main.add(ticker, forMode: .default)

func finish() -> Never {
    tonePlayer.stop()
    let packets = sender.packetsSent
    print("Sent      : \(packets) packets, \(sender.sendErrors) send errors")
    print("Unreachable: \(sender.unreachableTargets.count) of \(sender.sending.count) targets")
    sender.shutdown()
    print("--- log ---")
    for entry in sender.activity.entries {
        print("  \(entry.kind.label)  \(entry.text)")
    }
    exit(sender.sendErrors > 0 ? 1 : 0)
}

// Ctrl-C stops it the same way, so the log and the figures are printed either way.
signal(SIGINT) { _ in finish() }

RunLoop.main.run()
