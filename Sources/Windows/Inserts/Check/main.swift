import Foundation
import WinSDK
import WindowsInserts

// nag-vst3-check: the VST3 inserts against real installed plug-ins, with no audio
// device and nothing on the network. Scans, loads at each width, runs a synthetic sine through
// the chain and checks bypass, the aligned dry leg and Δ, saves and restores, and opens an editor.
//   nag-vst3-check [--rescan] [--no-editor] [--widths-all] [plug-in name…]

let arguments = Array(CommandLine.arguments.dropFirst())
let rescan = arguments.contains("--rescan")
let showEditor = !arguments.contains("--no-editor")
let allWidths = arguments.contains("--widths-all")
let named = arguments.filter { !$0.hasPrefix("--") }
var failures = 0

func check(_ ok: Bool, _ what: String) {
    print("  \(ok ? "PASS" : "FAIL")  \(what)")
    if !ok { failures += 1 }
}

func db(_ v: Float) -> String { v > 1e-9 ? String(format: "%.1f dBFS", 20 * log10(v)) : "−∞ dBFS" }

// `--describe <module>`: describe one module in this process, loading it, for diagnosing a module
// the scanner child gave up on.
if let i = arguments.firstIndex(of: "--describe"), i + 1 < arguments.count {
    print(VST3Catalog.describeInProcess(arguments[i + 1]))
    exit(0)
}

// VST3 editors are Win32 and some use OLE (drag and drop): an STA, as the app's UI thread is.
_ = OleInitialize(nil)

// MARK: - Scan

print("== Scan")
let catalog = VST3Catalog()
print("folder: %CommonProgramFiles%\\VST3   cache: %LOCALAPPDATA%\\Network Audio Grabber\\\(catalog.cacheURL.lastPathComponent)")
print("scanner child: \(catalog.scannerCommand != nil ? "nag-vst3-scan.exe (beside this exe)" : "none — moduleinfo.json only")")
var started = Date()
catalog.scan(force: rescan)
print(String(format: "scan%@: %.2f s, %d effects", rescan ? " (forced)" : "", Date().timeIntervalSince(started), catalog.plugins.count))
for p in catalog.plugins {
    print("  \(p.vendor) — \(p.name)   [\(p.subcategories.joined(separator: "|"))]  \(p.classID)")
}
for problem in catalog.problems {
    print("  problem: \(URL(fileURLWithPath: problem.path).lastPathComponent): \(problem.reason)")
}
started = Date()
catalog.scan()
print(String(format: "again, from the cache: %.3f s, %d effects", Date().timeIntervalSince(started), catalog.plugins.count))

/// By class name ("Pro-Q 4") or by module ("FabFilter Pro-Q 4", the bundle's name).
func find(_ name: String) -> VST3PluginInfo? {
    catalog.plugins.first { $0.name == name }
        ?? catalog.plugins.first { URL(fileURLWithPath: $0.path).deletingPathExtension().lastPathComponent == name }
}

// MARK: - Widths

print("\n== Widths at 48 kHz (accepted with engine→VST3 channel map, or refused)")
let widthNames = allWidths ? catalog.plugins.map(\.name)
    : (named.isEmpty ? ["FabFilter Pro-Q 4", "FabFilter Pro-L 2", "FabFilter Pro-R 2", "FabFilter Saturn 2",
                        "Kleverb", "Wwise RoomVerb", "Youlean Loudness Meter 2"] : named)
for name in widthNames {
    guard let info = find(name) else { print("  \(name): not installed"); continue }
    switch VST3Plugin.load(info) {
    case .failure(let error): print("  \(name): failed to load — \(error)")
    case .success(let plugin):
        var row: [String] = []
        for width in [2, 4, 6, 8] {
            switch plugin.configure(sampleRate: 48000, maxFrames: 4096, channels: width) {
            case .accepted(let map):
                row.append("\(width) ch ok 0x\(String(plugin.arrangement, radix: 16)) \(map)")
            case .refused: row.append("\(width) ch REFUSED")
            case .failed: row.append("\(width) ch ERROR")
            }
        }
        print("  \(name): " + row.joined(separator: " | "))
        plugin.unload()
    }
}

// MARK: - Signal

/// Planar buses as the WASAPI side has them, with a sine on each channel (a different frequency
/// per channel, −6 dBFS), and the whole input and output kept for comparison.
final class Bus {
    let channels: Int
    let planes: UnsafeMutablePointer<Float>
    let pointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    let capacity = 8192
    var phase = 0
    var input: [[Float]]
    var output: [[Float]]

    init(channels: Int) {
        self.channels = channels
        planes = .allocate(capacity: channels * capacity)
        pointers = .allocate(capacity: channels)
        for c in 0..<channels { pointers[c] = planes + c * capacity }
        input = Array(repeating: [], count: channels)
        output = Array(repeating: [], count: channels)
    }

    func reset() {
        input = Array(repeating: [], count: channels)
        output = Array(repeating: [], count: channels)
    }

    func run(_ chain: VST3InsertChain, frames total: Int, block: Int = 480) {
        var done = 0
        while done < total {
            let n = min(block, total - done)
            for c in 0..<channels {
                let f = 440.0 * pow(1.25, Double(c))
                for i in 0..<n {
                    pointers[c][i] = Float(0.5 * sin(2 * Double.pi * f * Double(phase + i) / 48000))
                }
                input[c].append(contentsOf: UnsafeBufferPointer(start: pointers[c], count: n))
            }
            chain.process(buses: pointers, channels: channels, frames: n)
            for c in 0..<channels { output[c].append(contentsOf: UnsafeBufferPointer(start: pointers[c], count: n)) }
            phase += n
            done += n
        }
    }

    /// Largest |output − input delayed by `delay`|, after `skip` frames.
    func difference(delay: Int, skip: Int) -> Float {
        var worst: Float = 0
        for c in 0..<channels {
            for i in max(skip, delay)..<output[c].count { worst = max(worst, abs(output[c][i] - input[c][i - delay])) }
        }
        return worst
    }

    func peak(skip: Int) -> Float {
        var worst: Float = 0
        for c in 0..<channels { for i in skip..<output[c].count { worst = max(worst, abs(output[c][i])) } }
        return worst
    }
}

/// The chain's checks for one plug-in at one width.
func exercise(_ chain: VST3InsertChain, slot: Int, channels: Int) {
    let bus = Bus(channels: channels)
    let name = chain.info(slot)?.name ?? "?"
    guard chain.isLive(slot) else {
        print("  \(name) at \(channels) ch: \(chain.isRefused(slot) ? "refused — held out of circuit" : "not live: \(chain.failure(slot) ?? "?")")")
        // A refused slot must leave the bus exactly as it was.
        bus.run(chain, frames: 4800)
        check(bus.difference(delay: 0, skip: 0) == 0, "refused slot passes the bus untouched")
        return
    }
    let latency = chain.slots[slot].latencyFrames
    print(String(format: "  %@ at %d ch: live, latency %d samples (%.2f ms), map %@", name, channels, latency,
                 chain.latencyMs(slot), "\(chain.slots[slot].channelMap)"))
    let settle = latency + 9600

    chain.setBypass(slot: slot, false)
    chain.setMix(slot: slot, 1)
    bus.reset()
    bus.run(chain, frames: 48000)
    let inLevel = chain.level(slot: slot, output: false), outLevel = chain.level(slot: slot, output: true)
    print("    100 % wet: in \(db(inLevel)), out \(db(outLevel)); |wet − input delayed by latency| = \(db(bus.difference(delay: latency, skip: settle)))")

    bus.reset()
    bus.run(chain, frames: 12000, block: 6000)    // longer than the chain's 4096: done in pieces
    check(bus.output[0].count == 12000, "6000-frame blocks (over the 4096 maximum) are processed in pieces")

    chain.setBypass(slot: slot, true)
    bus.reset()
    bus.run(chain, frames: 9600)
    check(bus.difference(delay: 0, skip: 480) == 0, "bypass gives back the input exactly (hard bypass: no delay, as on the Mac)")
    chain.setBypass(slot: slot, false)

    chain.setMix(slot: slot, 0)
    bus.reset()
    bus.run(chain, frames: 9600)
    check(bus.difference(delay: latency, skip: latency + 960) == 0,
          "0 % wet gives back the input exactly, delayed by the latency (\(latency) samples)")

    chain.setMix(slot: slot, 0.5)
    bus.reset()
    bus.run(chain, frames: 24000)
    let blend = bus.difference(delay: latency, skip: settle)
    print("    50 % wet: |output − input delayed| = \(db(blend)) (no comb filter when the dry leg is aligned)")

    chain.setMix(slot: slot, 1)
    let compensation = chain.setDelta(slot: slot, true)
    bus.reset()
    bus.run(chain, frames: 48000)
    let residue = bus.peak(skip: settle)
    print("    Δ on, compensation \(compensation.map(String.init) ?? "refused") samples: residue \(db(residue))")
    check(compensation == latency && residue < 0.001, "Δ at 100 % wet with a neutral plug-in is near silence (< −60 dBFS)")
    chain.setDelta(slot: slot, false)
    chain.setBypass(slot: slot, true)
    check(chain.setDelta(slot: slot, true) == nil, "Δ is refused while bypassed")
    chain.setBypass(slot: slot, false)
    print("    summary: " + chain.summary.joined(separator: " → "))
}

// MARK: - The chain

print("\n== Chain at 48 kHz")
let chain = VST3InsertChain()
let firstChoice = named.first.flatMap(find) ?? find("FabFilter Pro-Q 4") ?? catalog.plugins.first
let latentChoice = find("FabFilter Pro-L 2")

if let info = firstChoice {
    chain.configure(sampleRate: 48000, channels: 2)
    if let problem = chain.load(slot: 0, info: info) { print("  \(problem)") }
    exercise(chain, slot: 0, channels: 2)
    for width in [6, 8] {
        chain.configure(sampleRate: 48000, channels: width)
        exercise(chain, slot: 0, channels: width)
    }
    chain.configure(sampleRate: 48000, channels: 2)
}

if let info = latentChoice {
    // A plug-in with latency, in another slot, so the aligned dry leg is exercised for real.
    chain.unload(slot: 0)
    chain.configure(sampleRate: 48000, channels: 2)
    if let problem = chain.load(slot: 1, info: info) { print("  \(problem)") }
    exercise(chain, slot: 1, channels: 2)
}

if let stereoOnly = find("FabFilter Saturn 2") {
    // A stereo-only plug-in on a 5.1 bus: refused, held out, the bus untouched.
    // Slot 1 (still loaded) is bypassed meanwhile, so the bus untouched is the refused slot's doing.
    chain.configure(sampleRate: 48000, channels: 6)
    chain.setBypass(slot: 1, true)
    chain.load(slot: 2, info: stereoOnly)
    exercise(chain, slot: 2, channels: 6)
    chain.setBypass(slot: 1, false)
    print("    summary: " + chain.summary.joined(separator: " → "))
    chain.unload(slot: 2)
    chain.configure(sampleRate: 48000, channels: 2)
}

// MARK: - State

print("\n== State")
if let info = firstChoice {
    chain.load(slot: 0, info: info)
    chain.setMix(slot: 0, 0.7)
    chain.setBypass(slot: 2, false)
    let before = chain.slots[0].plugin?.state
    print("  \(info.name): state blob \(before?.count ?? 0) bytes")
    let suite = "nag-vst3-check"
    let defaults = UserDefaults(suiteName: suite)!
    chain.save(to: defaults)
    let restored = VST3InsertChain()
    restored.configure(sampleRate: 48000, channels: 2)
    let problems = restored.restore(from: defaults, catalog: catalog)
    for p in problems { print("  \(p)") }
    let after = restored.slots[0].plugin?.state
    check(restored.info(0)?.id == info.id && restored.isLive(0), "slot 0 restored with the same plug-in, live")
    check(restored.info(1)?.id == latentChoice?.id, "slot 1 restored")
    check(abs(restored.mix(0) - 0.7) < 1e-9 && !restored.isBypassed(0), "mix and bypass restored")
    /// The blob's two parts: "NAG3", version, then component and controller state with lengths.
    func parts(_ blob: Data?) -> (component: Data, controller: Data)? {
        guard let blob, blob.count >= 24 else { return nil }
        let b = [UInt8](blob)
        func u64(_ at: Int) -> Int { (0..<8).reduce(0) { $0 | Int(b[at + $1]) << (8 * $1) } }
        let n = u64(8)
        return (Data(b[16..<(16 + n)]), Data(b[(24 + n)...]))
    }
    let p0 = parts(before), p1 = parts(after)
    print("  saved: component \(p0?.component.count ?? 0) + controller \(p0?.controller.count ?? 0) bytes; "
          + "restored: component \(p1?.component.count ?? 0) + controller \(p1?.controller.count ?? 0) bytes")
    check(p0 != nil && p0?.component == p1?.component, "component state (the sound) identical after save → restore")
    // The controller's part may carry the plug-in's own UI housekeeping; what matters is that a
    // second round trip changes nothing more.
    let third = VST3InsertChain()
    third.configure(sampleRate: 48000, channels: 2)
    third.load(slot: 0, info: info, state: after)
    let p2 = parts(third.slots[0].plugin?.state)
    print("  second round: component \(p2?.component.count ?? 0) + controller \(p2?.controller.count ?? 0) bytes")
    check(p2?.component == p0?.component, "component state identical after a second round trip")
    third.unload(slot: 0)
    // The other restored slot, whole blob.
    if let latent = latentChoice {
        let saved = (defaults.dictionary(forKey: "\(VST3InsertChain.defaultsPrefix)1")?["state"] as? String)
            .flatMap { Data(base64Encoded: $0) }
        let back = restored.slots[1].plugin?.state
        print("  \(latent.name): saved \(saved?.count ?? 0) bytes, restored \(back?.count ?? 0) bytes")
        check(saved != nil && parts(saved)?.component == parts(back)?.component, "\(latent.name) component state identical after save → restore")
    }
    defaults.removePersistentDomain(forName: suite)
    restored.unload(slot: 0)
    restored.unload(slot: 1)
}

// MARK: - Editor

if showEditor, firstChoice != nil, chain.hasEditor(slot: 0) {
    print("\n== Editor")
    var closed = false
    chain.onEditorClosed = { _ in closed = true }
    let opened = chain.openEditor(slot: 0, parent: nil)
    check(opened, "editor opened in its own window")
    if let window = chain.slots[0].plugin?.editorWindow {
        var r = RECT()
        GetClientRect(window, &r)
        var title = [WCHAR](repeating: 0, count: 256)
        let n = GetWindowTextW(window, &title, 256)
        print("  window \"\(String(decoding: title.prefix(Int(n)), as: UTF16.self))\", client \(r.right - r.left) × \(r.bottom - r.top)")
    }
    // Three seconds of message loop, as the app's UI thread would run.
    let until = Date().addingTimeInterval(3)
    var message = MSG()
    while Date() < until {
        while PeekMessageW(&message, nil, 0, 0, UINT(PM_REMOVE)) {
            TranslateMessage(&message)
            DispatchMessageW(&message)
        }
        chain.poll()
        Sleep(10)
    }
    chain.closeEditor(slot: 0)
    check(closed && chain.slots[0].plugin?.editorWindow == nil, "editor closed cleanly, close callback called")
}

chain.unload(slot: 0)
chain.unload(slot: 1)
print("\n" + (failures == 0 ? "All passed." : "\(failures) check(s) failed."))
exit(failures == 0 ? 0 : 1)
