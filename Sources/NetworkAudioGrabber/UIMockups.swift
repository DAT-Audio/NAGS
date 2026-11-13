import SwiftUI
import AppKit

/// `NetworkAudioGrabber --mockup-ui <folder>` draws **proposals** from the UI review for
/// comparison before any real change: the Grabber's full window, its compact window
/// and the Sender, each as the current layout refined and as alternatives borrowed from familiar
/// apps. Static views with made-up names and documentation addresses; wired to nothing.
///
/// The current layouts are not redrawn here — the render harness's own shots are copied beside
/// these so each option sits next to what it would replace.
enum UIMockups {
    @MainActor
    static func run(arguments: [String]) {
        let outDir = arguments.firstIndex(of: "--mockup-ui").flatMap {
            $0 + 1 < arguments.count ? arguments[$0 + 1] : nil
        } ?? NSTemporaryDirectory()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let dark = NSAppearance(named: .darkAqua)
        let shots: [(String, AnyView, CGSize)] = [
            ("grabber-R-refined", AnyView(Captioned(GrabberRefined(), title: "R · The current layout, refined",
                note: "Flat rows, protocol as text, sentence-case headings over their columns, amber only for state, 10 pt minimum. Right panel: no Inputs section, LUFS once, level in dB, EBU M/S/I with the target.")), CGSize(width: 1204, height: 740)),
            ("grabber-T-table", AnyView(Captioned(GrabberTable(), title: "T · Native table and inspector — from Activity Monitor, Finder, Logic's inspector",
                note: "A sortable table, one row per stream, the selected stream's detail in the inspector on the right. Output and loudness in a fixed block under it.")), CGSize(width: 1204, height: 740)),
            ("grabber-M-mixer", AnyView(Captioned(GrabberMixer(), title: "M · Mixer strips — from RME TotalMix, Logic's mixer, Voicemeeter",
                note: "Each playing stream is a channel strip; the master strip is pinned right; streams found but not playing are in a browser on the left.")), CGSize(width: 1204, height: 740)),
            ("grabber-S-sidebar", AnyView(Captioned(GrabberSidebar(), title: "S · Source sidebar and transport bar — from Dante Controller, Music, Mail",
                note: "Protocols become places in a sidebar instead of coloured chips; the monitor output is a slim bar along the bottom; inserts and loudness open in an inspector.")), CGSize(width: 1204, height: 740)),
            ("compact-R-refined", AnyView(Captioned(CompactRefined(), title: "R · Compact, refined", note: "Same layout; flat rows, sentence case, amber only for state.", width: 372)), CGSize(width: 372, height: 700)),
            ("compact-P-popover", AnyView(Captioned(CompactPopover(), title: "P · Menu-bar popover — from SoundSource, Loopback", note: "Always one click away in the menu bar; the icon shows state only, never a live meter.", width: 420)), CGSize(width: 420, height: 640)),
            ("compact-B-strip", AnyView(Captioned(CompactStrip(), title: "B · Monitor strip — from Logic's control bar, Audio Hijack's floating meters", note: "A short floating bar to sit above a DAW: output, loudness, level, DIM/MONO, and a menu of what is playing.", width: 760)), CGSize(width: 760, height: 190)),
            ("sender-R-refined", AnyView(Captioned(SenderRefined(), title: "R · Sender, refined", note: "One Receivers list for targets and listeners (how each receives in its own column); flat rows; sentence case.", width: 480)), CGSize(width: 480, height: 760)),
            ("sender-G-form", AnyView(Captioned(SenderForm(), title: "G · Grouped form — from System Settings → Sound", note: "Native grouped form: This Mac, Receivers, Inserts. Nothing custom-drawn but the meter.", width: 480)), CGSize(width: 480, height: 920)),
            ("sender-H-chain", AnyView(Captioned(SenderChain(), title: "H · Signal chain — from Audio Hijack", note: "Source → inserts → receivers, left to right, so 'inserts reach the receiver only' is visible rather than a footnote.", width: 760)), CGSize(width: 760, height: 480)),
            ("sender-X-menubar", AnyView(Captioned(SenderMenuBar(), title: "X · Menu-bar extra — from Loopback, SoundSource", note: "The Sender is set-and-forget: send on or off, the stream, who receives, and Allow/Deny, from the menu bar.", width: 420)), CGSize(width: 420, height: 600)),
        ]
        for (name, view, size) in shots {
            capture(view, size: size, appearance: dark, to: "\(outDir)/\(name).png")
        }
        print("Wrote \(shots.map(\.0).joined(separator: ", ")) to \(outDir)")
        exit(0)
    }

    @MainActor
    private static func capture(_ view: AnyView, size: CGSize, appearance: NSAppearance?, to path: String) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        window.orderFrontRegardless()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        window.displayIfNeeded()
        if let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                            [.boundsIgnoreFraming, .bestResolution]),
           let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
        window.orderOut(nil)
    }
}

// MARK: - Shared pieces

private let amber = Color(red: 0.94, green: 0.63, blue: 0.16)
private let panel = Color(nsColor: .windowBackgroundColor)
private let secondaryText = Color.secondary

/// Title and one line of explanation above each mockup.
private struct Captioned<Content: View>: View {
    let content: Content
    let title: String
    let note: String
    var width: CGFloat = 1204

    init(_ content: Content, title: String, note: String, width: CGFloat = 1204) {
        self.content = content; self.title = title; self.note = note; self.width = width
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .underPageBackgroundColor))
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(panel)
        }
    }
}

private struct Stream: Identifiable {
    let id = UUID()
    let name: String
    let source: String
    let channels: Int
    var playing = false
    var level: Double = 0
    var status: String = ""
    var warn = false
    var mute = false
    var solo = false
    var bus = "Ch 1/2"
}

private let sample: [Stream] = [
    Stream(name: "Dub Stage 7.1", source: "RAVENNA", channels: 8),
    Stream(name: "Edit Bay 3 Monitor", source: "SAP", channels: 6),
    Stream(name: "Edit Suite Mac", source: "VBAN", channels: 2, status: "Asking…"),
    Stream(name: "Laptop VBAN", source: "VBAN", channels: 2),
    Stream(name: "Live Room 1–8", source: "RAVENNA", channels: 8, playing: true, level: 0.72, status: "OK", solo: true),
    Stream(name: "Ref Mix (manual)", source: "Manual", channels: 2),
    Stream(name: "Scream from 192.0.2.50", source: "Scream", channels: 2),
    Stream(name: "Stagebox-1 TX 1–2", source: "Dante", channels: 2, playing: true, level: 0, status: "No packets", warn: true),
    Stream(name: "Studio A 5.1 Bed", source: "RAVENNA", channels: 6, playing: true, level: 0.55, status: "OK", mute: true),
]

/// A horizontal level bar: green to yellow to red by position, drawn once.
private struct HBar: View {
    let level: Double
    var height: CGFloat = 6
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.primary.opacity(0.10))
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(LinearGradient(colors: [.green, .green, .yellow, .red], startPoint: .leading, endPoint: .trailing))
                    .frame(width: g.size.width)
                    .mask(alignment: .leading) { Rectangle().frame(width: g.size.width * level) }
            }
        }
        .frame(height: height)
    }
}

private struct VBar: View {
    let level: Double
    var width: CGFloat = 8
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.primary.opacity(0.10))
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(LinearGradient(colors: [.green, .green, .yellow, .red], startPoint: .bottom, endPoint: .top))
                    .frame(height: g.size.height)
                    .mask(alignment: .bottom) { Rectangle().frame(height: g.size.height * level) }
            }
        }
        .frame(width: width)
    }
}

/// A slider drawn as a track and a knob; a picture of one, not a control.
private struct FakeSlider: View {
    let value: Double
    var fill: Color = Color.primary.opacity(0.45)
    var body: some View {
        GeometryReader { g in
            // The track inset by half the knob, so the knob stays inside the slider's frame.
            let w = max(0, g.size.width - 13)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.15)).frame(width: w, height: 3).offset(x: 6.5)
                Capsule().fill(fill).frame(width: w * value, height: 3).offset(x: 6.5)
                Circle().fill(Color.white).frame(width: 13, height: 13)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
                    .offset(x: w * value)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 14)
    }
}

/// Mute and solo in the mixer convention: grey off, red mute, yellow solo.
private struct MS: View {
    let mute: Bool, solo: Bool
    var body: some View {
        HStack(spacing: 3) {
            key("M", on: mute, colour: .red)
            key("S", on: solo, colour: .yellow)
        }
    }
    private func key(_ t: String, on: Bool, colour: Color) -> some View {
        Text(t).font(.system(size: 10, weight: .semibold))
            .frame(width: 20, height: 18)
            .background(RoundedRectangle(cornerRadius: 4).fill(on ? colour : Color.primary.opacity(0.10)))
            .foregroundStyle(on ? (t == "M" ? Color.white : Color.black) : Color.secondary)
    }
}

/// A status in words with a shape as well as a colour — never colour alone.
private struct Status: View {
    let text: String, warn: Bool
    var body: some View {
        if text.isEmpty { Color.clear.frame(width: 1) } else {
            Label(text, systemImage: warn ? "exclamationmark.triangle.fill" : (text == "OK" ? "checkmark.circle" : "hourglass"))
                .labelStyle(.titleAndIcon)
                .font(.system(size: 11))
                .foregroundStyle(warn ? Color.orange : Color.secondary)
        }
    }
}

/// The toolbar row, refined: honest menus with chevrons, words where words help.
private struct RefinedToolbar: View {
    var compact = false
    var body: some View {
        HStack(spacing: 12) {
            AppEmblem(.grabber, size: 22, caption: .beside)
            Divider().frame(height: 18)
            menu("Ethernet (en5)")
            menu("Headphones · 48 kHz", symbol: "headphones")
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                Text("Filter").font(.system(size: 12)).foregroundStyle(.tertiary)
                Spacer()
            }
            .frame(width: 160).padding(.horizontal, 7).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            Picker("", selection: .constant(0)) { Text("All").tag(0); Text("Playing").tag(1) }
                .pickerStyle(.segmented).labelsHidden().frame(width: 130)
            Image(systemName: "plus").font(.system(size: 13)).foregroundStyle(.secondary)
            Image(systemName: "sidebar.trailing").font(.system(size: 13)).foregroundStyle(.secondary)
            Image(systemName: "gearshape").font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }
    private func menu(_ t: String, symbol: String? = nil) -> some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(.secondary) }
            Text(t).font(.system(size: 12))
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Grabber R: the current layout, refined

private struct GrabberRefined: View {
    // Fixed widths shared by the header and every row, so each title sits over its column.
    enum W { static let play: CGFloat = 22, bus: CGFloat = 78, level: CGFloat = 70, trim: CGFloat = 110,
                    ms: CGFloat = 48, source: CGFloat = 120, status: CGFloat = 104 }

    var body: some View {
        VStack(spacing: 0) {
            RefinedToolbar()
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    header
                    Divider()
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(sample) { row($0); Divider().opacity(0.5) }
                        }
                    }
                    Divider()
                    HStack {
                        Text("3 playing of 9").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Connect to a Sender over VBAN…") {}.controlSize(.small)
                        Button("Stop all") {}.controlSize(.small)
                    }
                    .padding(.horizontal, 12).frame(height: 34)
                }
                Divider()
                RefinedPanel().frame(width: 320)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 14)
            Color.clear.frame(width: W.play)
            Text("Stream").frame(maxWidth: .infinity, alignment: .leading)
            Text("Bus").frame(width: W.bus, alignment: .leading)
            Text("Level").frame(width: W.level, alignment: .leading)
            Text("Trim").frame(width: W.trim, alignment: .leading)
            Text("M / S").frame(width: W.ms, alignment: .leading)
            Text("Source").frame(width: W.source, alignment: .leading)
            Text("Status").frame(width: W.status, alignment: .leading)
        }
        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        .padding(.horizontal, 12).frame(height: 26)
    }

    private func row(_ s: Stream) -> some View {
        HStack(spacing: 8) {
            Image(systemName: s.name.hasPrefix("Live") ? "star.fill" : "star")
                .font(.system(size: 10)).foregroundStyle(s.name.hasPrefix("Live") ? amber : Color.secondary.opacity(0.5))
                .frame(width: 14)
            Image(systemName: s.playing ? "stop.circle.fill" : "play.circle")
                .font(.system(size: 17)).foregroundStyle(s.playing ? Color.primary : Color.secondary)
                .frame(width: W.play)
            Text(s.name).font(.system(size: 13, weight: s.playing ? .medium : .regular))
                .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if s.playing {
                    HStack(spacing: 2) { Text(s.bus); Image(systemName: "chevron.down").font(.system(size: 7)) }
                        .font(.system(size: 11))
                } else { Text("") }
            }.frame(width: W.bus, alignment: .leading)
            Group { if s.playing { HBar(level: s.level) } else { Color.clear } }.frame(width: W.level)
            Group { if s.playing { HStack { FakeSlider(value: 0.62); Text("0.0 dB").font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary) } } else { Color.clear } }
                .frame(width: W.trim)
            Group { if s.playing { MS(mute: s.mute, solo: s.solo) } else { Color.clear } }.frame(width: W.ms, alignment: .leading)
            Text("\(s.source) · \(s.channels) ch").font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(width: W.source, alignment: .leading)
            Status(text: s.status, warn: s.warn).frame(width: W.status, alignment: .leading)
        }
        .padding(.horizontal, 12).frame(height: 32)
        .background(s.name.hasPrefix("Live") ? Color.primary.opacity(0.06) : Color.clear)
    }
}

/// The right panel, slimmed: no Inputs (the list has them), output with a dB scale, loudness once.
private struct RefinedPanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            section("Inserts") {
                VStack(spacing: 6) {
                    insert("1", "SoundID Reference", bypass: false)
                    HStack {
                        Image(systemName: "plus.circle").foregroundStyle(.secondary)
                        Text("Add insert").font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer()
                    }.padding(.horizontal, 8)
                }
            }
            section("Output") {
                HStack(alignment: .bottom, spacing: 14) {
                    HStack(spacing: 4) { VBar(level: 0.74, width: 10); VBar(level: 0.70, width: 10) }
                        .frame(height: 150)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(["0", "−6", "−12", "−24", "−48"], id: \.self) {
                            Text($0).font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }.frame(height: 150).padding(.leading, -8)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Peak −3.3 dBFS").font(.system(size: 13)).monospacedDigit()
                        HStack(spacing: 6) {
                            Image(systemName: "speaker.wave.2").foregroundStyle(.secondary)
                            FakeSlider(value: 0.9)
                        }
                        Text("Level −1.0 dB").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                        HStack(spacing: 6) {
                            Button("Dim") {}.controlSize(.small)
                            Button("Mono") {}.controlSize(.small)
                        }
                    }
                }
            }
            section("Loudness · target −23 LUFS") {
                VStack(spacing: 6) {
                    reading("Momentary", "−20.4", "+2.6")
                    reading("Short-term", "−21.2", "+1.8")
                    reading("Integrated", "−22.8", "+0.2")
                }
            }
            Spacer()
        }
        .padding(14)
    }

    private func section<C: View>(_ t: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            c()
        }
    }

    private func insert(_ n: String, _ name: String, bypass: Bool) -> some View {
        HStack(spacing: 8) {
            Text(n).font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 3) { Text(name); Image(systemName: "chevron.down").font(.system(size: 7)) }.font(.system(size: 12))
            Spacer()
            Button("Bypass") {}.controlSize(.small)
            Image(systemName: "slider.horizontal.3").foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
    }

    private func reading(_ label: String, _ value: String, _ delta: String) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).frame(width: 84, alignment: .leading)
            Text(value).font(.system(size: 15, weight: .medium)).monospacedDigit()
            Text("LUFS").font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer()
            Text(delta).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

// MARK: - Grabber T: native table and inspector

private struct GrabberTable: View {
    var body: some View {
        VStack(spacing: 0) {
            RefinedToolbar()
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    Table(sample) {
                        TableColumn("") { s in
                            Image(systemName: s.playing ? "stop.circle.fill" : "play.circle").foregroundStyle(s.playing ? Color.primary : Color.secondary)
                        }.width(22)
                        TableColumn("Name") { s in Text(s.name) }.width(min: 150, ideal: 190)
                        TableColumn("Source") { s in Text(s.source).foregroundStyle(.secondary) }.width(68)
                        TableColumn("Ch") { s in Text("\(s.channels)").monospacedDigit().foregroundStyle(.secondary) }.width(28)
                        TableColumn("Level") { s in if s.playing { HBar(level: s.level) } }.width(70)
                        TableColumn("M/S") { s in if s.playing { MS(mute: s.mute, solo: s.solo) } }.width(50)
                        TableColumn("Status") { s in Status(text: s.status, warn: s.warn) }.width(100)
                        TableColumn("Jitter") { s in Text(s.playing && !s.warn ? "0.12 ms" : "").monospacedDigit().foregroundStyle(.secondary) }.width(60)
                    }
                    Divider()
                    HStack {
                        Text("3 playing of 9").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Stop all") {}.controlSize(.small)
                    }
                    .padding(.horizontal, 12).frame(height: 30)
                }
                Divider()
                inspector.frame(width: 340)
            }
        }
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Live Room 1–8").font(.system(size: 15, weight: .semibold))
                    Text("RAVENNA · 8 ch · 48 kHz · L24 · 1 ms").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                HStack(alignment: .bottom, spacing: 5) {
                    ForEach(Array(["L", "R", "C", "LFE", "Ls", "Rs", "Lrs", "Rrs"].enumerated()), id: \.0) { i, c in
                        VStack(spacing: 3) {
                            VBar(level: [0.5, 0.52, 0.3, 0.2, 0.4, 0.42, 0.7, 0.72][i], width: 12).frame(height: 90)
                            Text(c).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }
                HStack(spacing: 8) {
                    LabeledContent("Bus") { Text("Ch 1/2 ⌄") }
                    Spacer()
                    MS(mute: false, solo: true)
                }.font(.system(size: 12))
                LabeledContent("Trim") { HStack { FakeSlider(value: 0.62).frame(width: 140); Text("0.0 dB").monospacedDigit() } }.font(.system(size: 12))
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow { stat("Jitter", "0.12 ms"); stat("Worst", "0.9 ms") }
                    GridRow { stat("Buffer", "15 ms"); stat("Low water", "12 ms") }
                    GridRow { stat("Drift", "+18 ppm"); stat("Lost", "0") }
                    GridRow { stat("Underruns", "0"); stat("Last underrun", "—") }
                }
                stat("Clock", "PTP · 00-00-5E-EF-10-00-00-02 : 0")
                Divider()
                Text("Output").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    HStack(spacing: 3) { VBar(level: 0.74, width: 8); VBar(level: 0.7, width: 8) }.frame(height: 60)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Peak −3.3 dBFS · −22.8 LUFS integrated").font(.system(size: 12)).monospacedDigit()
                        FakeSlider(value: 0.9).frame(width: 160)
                        HStack { Button("Dim") {}.controlSize(.small); Button("Mono") {}.controlSize(.small) }
                    }
                }
            }
            .padding(14)
        }
    }

    private func stat(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(k).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(v).font(.system(size: 12)).monospacedDigit()
        }
    }
}

// MARK: - Grabber M: mixer strips

private struct GrabberMixer: View {
    var body: some View {
        VStack(spacing: 0) {
            RefinedToolbar()
            Divider()
            HStack(spacing: 0) {
                browser.frame(width: 230)
                Divider()
                HStack(alignment: .top, spacing: 8) {
                    ForEach(sample.filter(\.playing)) { strip($0, master: false) }
                    Spacer()
                    Divider()
                    strip(Stream(name: "Master", source: "Headphones", channels: 2, playing: true, level: 0.74), master: true)
                }
                .padding(10)
            }
        }
    }

    private var browser: some View {
        List {
            Section("Found on the network") {
                ForEach(sample.filter { !$0.playing }) { s in
                    HStack {
                        Image(systemName: "play.circle").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(s.name).font(.system(size: 12))
                            Text("\(s.source) · \(s.channels) ch").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func strip(_ s: Stream, master: Bool) -> some View {
        VStack(spacing: 8) {
            Text(s.name).font(.system(size: 11, weight: .semibold)).lineLimit(2).multilineTextAlignment(.center)
                .frame(height: 30)
            Text(master ? "Headphones · 48 kHz" : "\(s.source) · \(s.channels) ch").font(.system(size: 10)).foregroundStyle(.secondary)
            if !master { Text("Ch 1/2 ⌄").font(.system(size: 11)) }
            HStack(alignment: .bottom, spacing: 6) {
                HStack(spacing: 2) { VBar(level: s.level, width: 7); VBar(level: s.level * 0.95, width: 7) }
                VStack(spacing: 0) {
                    Spacer()
                    RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.15)).frame(width: 4)
                        .overlay(alignment: .center) {
                            RoundedRectangle(cornerRadius: 3).fill(Color.white).frame(width: 22, height: 12)
                                .shadow(color: .black.opacity(0.4), radius: 1)
                                .offset(y: -30)
                        }
                    Spacer()
                }
            }
            .frame(height: 300)
            Text(master ? "−1.0 dB" : "0.0 dB").font(.system(size: 11)).monospacedDigit()
            if master {
                VStack(spacing: 4) {
                    Button("Dim") {}.controlSize(.small)
                    Button("Mono") {}.controlSize(.small)
                    Text("−22.8 LUFS-I").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                }
            } else {
                MS(mute: s.mute, solo: s.solo)
                Status(text: s.status, warn: s.warn).font(.system(size: 10))
            }
            Spacer()
        }
        .padding(8)
        .frame(width: master ? 120 : 110)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
    }
}

// MARK: - Grabber S: source sidebar and transport bar

private struct GrabberSidebar: View {
    var body: some View {
        VStack(spacing: 0) {
            RefinedToolbar()
            Divider()
            HStack(spacing: 0) {
                List {
                    Section("Library") {
                        side("Playing", "play.circle", 3, selected: true)
                        side("Favourites", "star", 1)
                        side("All streams", "list.bullet", 9)
                    }
                    Section("Sources") {
                        side("RAVENNA & AES67", "dot.radiowaves.left.and.right", 3)
                        side("SAP", "megaphone", 1)
                        side("Dante", "point.3.connected.trianglepath.dotted", 1)
                        side("VBAN", "arrow.left.arrow.right", 2)
                        side("Scream", "desktopcomputer", 1)
                        side("Added by hand", "hand.point.up.left", 1)
                    }
                }
                .listStyle(.sidebar)
                .frame(width: 210)
                Divider()
                VStack(spacing: 0) {
                    HStack {
                        Text("Playing").font(.system(size: 15, weight: .semibold))
                        Spacer()
                        Button("Stop all") {}.controlSize(.small)
                    }.padding(.horizontal, 14).frame(height: 40)
                    Divider()
                    VStack(spacing: 0) {
                        ForEach(sample.filter(\.playing)) { s in
                            HStack(spacing: 10) {
                                Image(systemName: "stop.circle.fill").font(.system(size: 17))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(s.name).font(.system(size: 13, weight: .medium))
                                    Text("\(s.source) · \(s.channels) ch · Ch 1/2").font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                HBar(level: s.level).frame(width: 110)
                                FakeSlider(value: 0.62).frame(width: 110)
                                MS(mute: s.mute, solo: s.solo)
                                Status(text: s.status, warn: s.warn).frame(width: 100, alignment: .leading)
                            }
                            .padding(.horizontal, 14).frame(height: 48)
                            Divider().opacity(0.5)
                        }
                        Spacer()
                    }
                }
            }
            Divider()
            // The monitor output, as Music's transport bar.
            HStack(spacing: 14) {
                HStack(spacing: 3) { VStack(spacing: 3) { HBar(level: 0.74, height: 5); HBar(level: 0.7, height: 5) } }.frame(width: 220)
                Text("Peak −3.3 dBFS").font(.system(size: 12)).monospacedDigit()
                Text("−22.8 LUFS-I").font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "speaker.wave.2").foregroundStyle(.secondary)
                FakeSlider(value: 0.9).frame(width: 150)
                Button("Dim") {}.controlSize(.small)
                Button("Mono") {}.controlSize(.small)
                HStack(spacing: 3) { Image(systemName: "headphones"); Text("Headphones ⌄") }.font(.system(size: 12))
                Image(systemName: "sidebar.trailing").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).frame(height: 52)
        }
    }

    private func side(_ t: String, _ symbol: String, _ n: Int, selected: Bool = false) -> some View {
        HStack {
            Label(t, systemImage: symbol)
            Spacer()
            Text("\(n)").foregroundStyle(.secondary).monospacedDigit()
        }
        .font(.system(size: 12))
        .listRowBackground(selected ? RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.10)) : nil)
    }
}

// MARK: - Compact R: refined

private struct CompactRefined: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                AppEmblem(.grabber, size: 18, caption: .beside)
                Text("en5 ⌄").font(.system(size: 11))
                Text("Headphones · 48 kHz ⌄").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 11)).foregroundStyle(.secondary)
                Image(systemName: "gearshape").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).frame(height: 40)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("−3.3").font(.system(size: 28, weight: .light)).monospacedDigit()
                        Text("Peak, dBFS").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("−22.8").font(.system(size: 28, weight: .light)).monospacedDigit()
                        Text("Integrated, LUFS · target −23").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                VStack(spacing: 4) {
                    HStack { Text("L").font(.system(size: 10)).foregroundStyle(.secondary); HBar(level: 0.74, height: 7) }
                    HStack { Text("R").font(.system(size: 10)).foregroundStyle(.secondary); HBar(level: 0.70, height: 7) }
                }
                HStack(spacing: 6) {
                    Image(systemName: "speaker.wave.2").foregroundStyle(.secondary)
                    FakeSlider(value: 0.9)
                    Text("−1.0 dB").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                }
                HStack { Button("Dim") {}.controlSize(.small); Button("Mono") {}.controlSize(.small) }
            }
            .padding(12)
            Divider()
            disclosure("Loudness", detail: "S −21.2 · M −20.4", open: false)
            Divider()
            disclosure("Inserts", detail: "SoundID Reference", open: false)
            Divider()
            disclosure("Playing", detail: "3", open: true)
            VStack(spacing: 0) {
                ForEach(sample.filter(\.playing)) { s in
                    HStack(spacing: 8) {
                        Image(systemName: "stop.circle.fill").font(.system(size: 15))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(s.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            HBar(level: s.level, height: 4).frame(width: 90)
                        }
                        Spacer()
                        Status(text: s.status == "OK" ? "" : s.status, warn: s.warn)
                        MS(mute: s.mute, solo: s.solo)
                    }
                    .padding(.horizontal, 12).frame(height: 44)
                    Divider().opacity(0.5)
                }
                HStack { Text("6 more on the network").font(.system(size: 11)).foregroundStyle(.secondary); Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.secondary); Spacer() }
                    .padding(12)
            }
            Spacer()
        }
    }

    private func disclosure(_ t: String, detail: String, open: Bool) -> some View {
        HStack {
            Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            Text(t).font(.system(size: 12, weight: .semibold))
            Spacer()
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).frame(height: 30)
    }
}

// MARK: - Compact P: menu-bar popover

private struct CompactPopover: View {
    var body: some View {
        VStack(spacing: 0) {
            // A slice of menu bar, for context.
            HStack(spacing: 14) {
                Spacer()
                Image(systemName: "wifi"); Image(systemName: "battery.75")
                AppEmblem(.grabber, size: 15, caption: .none).opacity(1.6)
                Text("12:00").font(.system(size: 12))
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12).frame(height: 24)
            .background(Color.primary.opacity(0.08))
            HStack { Spacer(); CompactRefined().frame(width: 340, height: 520)
                .background(RoundedRectangle(cornerRadius: 12).fill(panel))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.18)))
                .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
                .padding(.trailing, 20).padding(.top, 6) }
            Spacer()
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

// MARK: - Compact B: monitor strip

private struct CompactStrip: View {
    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 14) {
                AppEmblem(.grabber, size: 16, caption: .none)
                VStack(spacing: 4) { HBar(level: 0.74, height: 6); HBar(level: 0.7, height: 6) }.frame(width: 190)
                VStack(alignment: .leading, spacing: 0) {
                    Text("−3.3 dBFS").font(.system(size: 12)).monospacedDigit()
                    Text("−22.8 LUFS-I").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                }
                Image(systemName: "speaker.wave.2").foregroundStyle(.secondary)
                FakeSlider(value: 0.9).frame(width: 110)
                Button("Dim") {}.controlSize(.small)
                Button("Mono") {}.controlSize(.small)
                HStack(spacing: 3) { Text("3 playing"); Image(systemName: "chevron.down").font(.system(size: 8)) }.font(.system(size: 12))
            }
            .padding(.horizontal, 14).frame(height: 56)
            .background(RoundedRectangle(cornerRadius: 10).fill(panel))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.18)))
            .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
            .padding(.horizontal, 16)
            Spacer()
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

// MARK: - Sender pieces

private struct Receiver: Identifiable {
    let id = UUID()
    let name: String, address: String, how: String
    var muted = false, asking = false
}

private let receivers: [Receiver] = [
    Receiver(name: "Booth Mac", address: "192.0.2.41", how: "Asking", asking: true),
    Receiver(name: "Control Room", address: "192.0.2.40", how: "Listening"),
    Receiver(name: "Edit Bay Grabber", address: "198.51.100.7", how: "Listening and sent to"),
    Receiver(name: "Studio PC", address: "192.0.2.20", how: "Sent to"),
    Receiver(name: "192.0.2.31", address: "192.0.2.31", how: "Sent to", muted: true),
]

private struct SenderHeader: View {
    var body: some View {
        HStack {
            AppEmblem(.sender, size: 22, caption: .beside)
            Spacer()
            Image(systemName: "gearshape").font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).frame(height: 44)
    }
}

private struct ReceiverRow: View {
    let r: Receiver
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: r.asking ? "hand.raised" : (r.how.hasPrefix("Listening") ? "headphones" : "arrow.up.right"))
                .foregroundStyle(r.asking ? Color.orange : Color.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(r.name).font(.system(size: 12, weight: .medium))
                Text(r.address).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            Spacer()
            if r.asking {
                Button("Deny") {}.controlSize(.small)
                Button("Allow") {}.controlSize(.small)
            } else {
                Text(r.how).font(.system(size: 11)).foregroundStyle(.secondary)
                Text("M").font(.system(size: 10, weight: .semibold)).frame(width: 20, height: 18)
                    .background(RoundedRectangle(cornerRadius: 4).fill(r.muted ? Color.red : Color.primary.opacity(0.10)))
                    .foregroundStyle(r.muted ? Color.white : Color.secondary)
                Image(systemName: "xmark").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).frame(height: 38)
    }
}

// MARK: - Sender R: refined

private struct SenderRefined: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SenderHeader()
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("This Mac").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        TextField("", text: .constant("Edit Suite Mac")).textFieldStyle(.roundedBorder).frame(width: 170)
                        VStack(spacing: 3) { HBar(level: 0.8, height: 6); HBar(level: 0.74, height: 6) }
                    }
                    Text("16-bit · 48 kHz · stereo").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Receivers").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Toggle("Offer to Grabbers", isOn: .constant(true)).toggleStyle(.switch).controlSize(.mini)
                            .font(.system(size: 11))
                    }
                    VStack(spacing: 0) {
                        ForEach(receivers) { ReceiverRow(r: $0); Divider().opacity(0.5) }
                        HStack {
                            TextField("", text: .constant(""), prompt: Text("Add a receiver by address")).textFieldStyle(.roundedBorder)
                            Button("Add") {}.controlSize(.small)
                        }.padding(8)
                    }
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                    Button("Connect to a Grabber over VBAN…") {}.controlSize(.small)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Inserts — heard at the receivers, not on this Mac").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    HStack {
                        Text("1").foregroundStyle(.secondary)
                        Text("AUGraphicEQ ⌄")
                        Spacer()
                        Button("Bypass") {}.controlSize(.small)
                    }.font(.system(size: 12)).padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                    HStack { Image(systemName: "plus.circle"); Text("Add insert") }.font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            Spacer()
            Divider()
            HStack {
                Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.green)
                Text("Sending to 4 receivers · 1 536 kbit/s").font(.system(size: 11))
                Spacer()
                Button("Stop all") {}.controlSize(.small)
            }.padding(.horizontal, 14).frame(height: 34)
        }
    }
}

// MARK: - Sender G: grouped form

private struct SenderForm: View {
    var body: some View {
        VStack(spacing: 0) {
            SenderHeader()
            Divider()
            Form {
                Section("This Mac") {
                    LabeledContent("Stream name") { Text("Edit Suite Mac") }
                    LabeledContent("Level") { VStack(spacing: 3) { HBar(level: 0.8, height: 5); HBar(level: 0.74, height: 5) }.frame(width: 200) }
                    LabeledContent("Format") { Text("16-bit · 48 kHz · stereo").foregroundStyle(.secondary) }
                }
                Section("Receivers") {
                    Toggle("Offer to Grabbers on this network", isOn: .constant(true))
                    ForEach(receivers) { ReceiverRow(r: $0).padding(.horizontal, -10) }
                    LabeledContent("Add by address") { Text("192.0.2.x").foregroundStyle(.tertiary) }
                }
                Section("Inserts") {
                    LabeledContent("1") { Text("AUGraphicEQ") }
                    LabeledContent("2") { Text("Empty").foregroundStyle(.secondary) }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Text("Sending to 4 receivers").font(.system(size: 11))
                Spacer()
                Button("Stop all") {}.controlSize(.small)
            }.padding(.horizontal, 14).frame(height: 34)
        }
    }
}

// MARK: - Sender H: signal chain

private struct SenderChain: View {
    var body: some View {
        VStack(spacing: 0) {
            SenderHeader()
            Divider()
            HStack(alignment: .top, spacing: 0) {
                block("This Mac", symbol: "desktopcomputer") {
                    Text("Edit Suite Mac").font(.system(size: 12, weight: .medium))
                    VStack(spacing: 3) { HBar(level: 0.8, height: 5); HBar(level: 0.74, height: 5) }
                    Text("16-bit · 48 kHz · stereo").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                arrow
                block("Inserts", symbol: "slider.horizontal.3") {
                    Text("1  AUGraphicEQ").font(.system(size: 12))
                    Text("2  Empty").font(.system(size: 12)).foregroundStyle(.secondary)
                    Text("Heard at the receivers only").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                arrow
                block("Receivers", symbol: "dot.radiowaves.right") {
                    ForEach(receivers.prefix(4)) { r in
                        HStack(spacing: 4) {
                            Image(systemName: r.asking ? "hand.raised" : "headphones").font(.system(size: 10))
                                .foregroundStyle(r.asking ? Color.orange : Color.secondary)
                            Text(r.name).font(.system(size: 11))
                            Spacer()
                            Text(r.asking ? "Asking" : r.how).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: 250)
            }
            .padding(16)
            Divider()
            // The selected block's detail opens below the chain.
            HStack {
                Text("Selected: Receivers — Allow or Deny Booth Mac, mute, remove, add by address").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Deny") {}.controlSize(.small)
                Button("Allow") {}.controlSize(.small)
            }.padding(14)
            Spacer()
        }
    }

    private var arrow: some View {
        Image(systemName: "arrow.right").font(.system(size: 16)).foregroundStyle(.secondary)
            .frame(width: 34).padding(.top, 50)
    }

    private func block<C: View>(_ t: String, symbol: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(t, systemImage: symbol).font(.system(size: 12, weight: .semibold))
            Divider()
            c()
        }
        .padding(10)
        .frame(width: 190, alignment: .leading)
        .frame(minHeight: 150, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)))
    }
}

// MARK: - Sender X: menu-bar extra

private struct SenderMenuBar: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Spacer()
                Image(systemName: "wifi"); Image(systemName: "battery.75")
                AppEmblem(.sender, size: 15, caption: .none).opacity(1.6)
                Text("12:00")
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12).frame(height: 24)
            .background(Color.primary.opacity(0.08))
            HStack {
                Spacer()
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        AppEmblem(.sender, size: 18, caption: .beside)
                        Spacer()
                        Toggle("", isOn: .constant(true)).toggleStyle(.switch).labelsHidden()
                    }
                    Text("Sending “Edit Suite Mac”").font(.system(size: 12, weight: .medium))
                    VStack(spacing: 3) { HBar(level: 0.8, height: 5); HBar(level: 0.74, height: 5) }
                    Divider()
                    ForEach(receivers) { ReceiverRow(r: $0).padding(.horizontal, -10) }
                    Divider()
                    HStack {
                        Text("Open Network Audio Sender…").font(.system(size: 12))
                        Spacer()
                        Text("⌘O").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Text("Quit").font(.system(size: 12))
                }
                .padding(12)
                .frame(width: 330)
                .background(RoundedRectangle(cornerRadius: 12).fill(panel))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.18)))
                .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
                .padding(.trailing, 20).padding(.top, 6)
            }
            Spacer()
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

// MARK: - R, second round: every current feature, the pill labels kept, inserts loaded
//
// `--mockup-compare <current-renders> <out>`: the same sample the render harness draws — the
// same streams, states, plugins and readings — drawn as R, then stacked under the harness's own
// render of today's app, so the two can be compared one above the other.

enum UICompare {
    @MainActor
    static func run(arguments: [String]) {
        guard let i = arguments.firstIndex(of: "--mockup-compare"), arguments.count > i + 2 else {
            print("usage: --mockup-compare <folder of current renders> <out folder>"); exit(2)
        }
        let current = arguments[i + 1], out = arguments[i + 2]
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let dark = NSAppearance(named: .darkAqua)
        let items: [(String, String, AnyView, CGSize)] = [
            ("grabber-detailed", "ui-detailed.png", AnyView(R2Grabber(detailed: true)), CGSize(width: 1120, height: 660)),
            ("grabber-simple", "ui-dark.png", AnyView(R2Grabber(detailed: false)), CGSize(width: 1120, height: 660)),
            ("compact", "ui-compact-dark.png", AnyView(R2Compact()), CGSize(width: 380, height: 700)),
            ("sender", "sender-dark.png", AnyView(R2Sender()), CGSize(width: 480, height: 760)),
        ]
        for (name, file, view, size) in items {
            UIMockupsCapture.capture(view, size: size, appearance: dark, to: "\(out)/R4-\(name).png")
            guard let now = NSImage(contentsOfFile: "\(current)/\(file)"),
                  let proposed = NSImage(contentsOfFile: "\(out)/R4-\(name).png") else { continue }
            let pair = AnyView(ComparePair(now: now, proposed: proposed, width: size.width))
            let height = (size.height + 30) * 2 + 10
            UIMockupsCapture.capture(pair, size: CGSize(width: size.width, height: height), appearance: dark,
                                     to: "\(out)/compare4-\(name).png")
        }
        print("Wrote R2-* and compare-* to \(out)")
        exit(0)
    }
}

enum UIMockupsCapture {
    @MainActor
    static func capture(_ view: AnyView, size: CGSize, appearance: NSAppearance?, to path: String) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        window.orderFrontRegardless()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        window.displayIfNeeded()
        if let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                            [.boundsIgnoreFraming, .bestResolution]),
           let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
        window.orderOut(nil)
    }
}

/// Today's app above, R below, each labelled.
private struct ComparePair: View {
    let now: NSImage, proposed: NSImage, width: CGFloat
    var body: some View {
        VStack(spacing: 10) {
            labelled("Now — today's app, rendered by the harness", now)
            labelled("R4 — R3 with your notes: white on mute, solid badges, aligned Trim, even channel meters, MONO shown on", proposed)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }
    private func labelled(_ t: String, _ image: NSImage) -> some View {
        VStack(spacing: 0) {
            Text(t).font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).frame(height: 30)
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: width)
        }
    }
}

/// The source pill, as the app draws it: tinted fill, bold rounded caps.
private struct Pill: View {
    let text: String, tint: Color
    var filled = true
    var body: some View {
        Text(text).font(.system(size: 9, weight: .bold, design: .rounded))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Capsule().fill(filled ? tint.opacity(0.28) : Color.primary.opacity(0.08)))
            .foregroundStyle(filled ? tint : Color.secondary)
    }
}

private func sourceTint(_ s: String) -> Color {
    switch s {
    case "RAVENNA": return Color(red: 0.36, green: 0.62, blue: 0.94)
    case "SAP": return Color(red: 0.75, green: 0.60, blue: 0.95)
    case "DANTE": return Color(red: 0.36, green: 0.78, blue: 0.55)
    case "VBAN": return Color(red: 0.94, green: 0.56, blue: 0.40)
    default: return Color.secondary
    }
}

private struct R2Stream: Identifiable {
    let id = UUID()
    let name: String, source: String, channels: Int
    var playing = false, level = 0.0, mute = false, solo = false
    var status = "", warn = false, asking = false, favourite = false, open = false
}

private let r2Streams: [R2Stream] = [
    R2Stream(name: "Dub Stage 7.1", source: "RAVENNA", channels: 8),
    R2Stream(name: "Edit Bay 3 Monitor", source: "SAP", channels: 6),
    R2Stream(name: "Edit Suite Mac", source: "VBAN", channels: 2, asking: true),
    R2Stream(name: "Laptop VBAN", source: "VBAN", channels: 2),
    R2Stream(name: "Live Room 1-8", source: "RAVENNA", channels: 8, playing: true, level: 0.66, solo: true, status: "OK", favourite: true, open: true),
    R2Stream(name: "Ref Mix (manual)", source: "MANUAL", channels: 2),
    R2Stream(name: "Stagebox-1 TX 1-2", source: "DANTE", channels: 2, playing: true, level: 0, status: "No packets", warn: true),
    R2Stream(name: "Studio A 5.1 Bed", source: "RAVENNA", channels: 6, playing: true, level: 0.5, mute: true, status: "OK"),
]

private struct R2Grabber: View {
    let detailed: Bool
    enum W { static let bus: CGFloat = 70, level: CGFloat = 58, trim: CGFloat = 108, ms: CGFloat = 46,
                    source: CGFloat = 104, status: CGFloat = 92, jitter: CGFloat = 54 }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    header
                    Divider()
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(r2Streams) { s in
                                row(s)
                                if s.open { detail }
                                Divider().opacity(0.5)
                            }
                        }
                    }
                    Divider()
                    statusBar
                }
                Divider()
                R2Panel().frame(width: 330)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            AppEmblem(.grabber, size: 22, caption: .beside)
            Divider().frame(height: 18)
            HStack(spacing: 3) { Text("en5").font(.system(size: 12, weight: .medium)); Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)) }
                .foregroundStyle(amber)
            Divider().frame(height: 14)
            HStack(spacing: 5) {
                Image(systemName: "headphones").font(.system(size: 11)).foregroundStyle(.secondary)
                Text("Headphones").font(.system(size: 12))
                Text("48 kHz").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(.secondary)
                Text("Filter").font(.system(size: 12)).foregroundStyle(.tertiary); Spacer()
            }
            .frame(width: 140).padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            Pill(text: "ACTIVE", tint: amber, filled: false)
            ForEach(["plus.rectangle.on.rectangle", "sidebar.trailing", "arrow.down.right.and.arrow.up.left", "moon", "gearshape"], id: \.self) {
                Image(systemName: $0).font(.system(size: 12)).foregroundStyle($0 == "sidebar.trailing" ? amber : Color.secondary)
            }
        }
        .padding(.horizontal, 12).frame(height: 44)
    }

    private var header: some View {
        HStack(spacing: 7) {
            Color.clear.frame(width: 12); Color.clear.frame(width: 20)
            Text("Stream").frame(maxWidth: .infinity, alignment: .leading)
            Text("Bus").frame(width: W.bus, alignment: .leading)
            Text("Level").frame(width: W.level, alignment: .leading)
            Text("Trim").padding(.leading, 6.5).frame(width: W.trim, alignment: .leading)
            Text("M / S").frame(width: W.ms, alignment: .leading)
            Text("Source").frame(width: W.source, alignment: .leading)
            Text("Status").frame(width: W.status, alignment: .leading)
            if detailed { Text("Jitter").frame(width: W.jitter, alignment: .trailing) }
            Color.clear.frame(width: 10)
        }
        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        .padding(.horizontal, 12).frame(height: 26)
    }

    private func row(_ s: R2Stream) -> some View {
        HStack(spacing: 7) {
            Image(systemName: s.favourite ? "star.fill" : "star").font(.system(size: 10))
                .foregroundStyle(s.favourite ? amber : Color.secondary.opacity(0.5)).frame(width: 12)
            Image(systemName: s.playing ? "stop.circle.fill" : "play.circle").font(.system(size: 17))
                .foregroundStyle(s.playing ? amber : Color.secondary).frame(width: 20)
            Text(s.name).font(.system(size: 13, weight: s.playing ? .medium : .regular)).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Group { if s.playing { HStack(spacing: 2) { Text("Ch 1/2"); Image(systemName: "chevron.down").font(.system(size: 7)) }.font(.system(size: 11)).foregroundStyle(amber) } else { Text("") } }
                .frame(width: W.bus, alignment: .leading)
            Group { if s.playing { HBar(level: s.level, height: 5) } else { Color.clear } }.frame(width: W.level)
            Group { if s.playing { HStack(spacing: 5) { FakeSlider(value: 0.6, fill: amber); Text("+0.0").font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary) } } else { Color.clear } }
                .frame(width: W.trim)
            Group { if s.playing { MS(mute: s.mute, solo: s.solo) } else { Color.clear } }.frame(width: W.ms, alignment: .leading)
            HStack(spacing: 4) { Pill(text: s.source, tint: sourceTint(s.source)); Pill(text: "\(s.channels) ch", tint: .secondary, filled: false) }
                .frame(width: W.source, alignment: .leading)
            Group {
                if s.asking { Status(text: "Asking…", warn: false) } else { Status(text: s.status, warn: s.warn) }
            }.frame(width: W.status, alignment: .leading)
            if detailed { Text(s.playing && !s.warn ? "0.00 ms" : "").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary).frame(width: W.jitter, alignment: .trailing) }
            Image(systemName: s.open ? "chevron.down" : (s.playing ? "chevron.right" : "")).font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary).frame(width: 10)
        }
        .padding(.horizontal, 12).frame(height: 32)
        .background(s.open ? Color.primary.opacity(0.06) : Color.clear)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 18) {
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(Array(["L", "R", "C", "LFE", "Ls", "Rs", "Lrs", "Rrs"].enumerated()), id: \.0) { i, c in
                        VStack(spacing: 3) {
                            VBar(level: i >= 6 ? 0.7 : 0.45, width: 9).frame(height: 56)
                                .saturation(i >= 6 ? 1 : 0)
                            Text(c).font(.system(size: 10, weight: i >= 6 ? .semibold : .regular))
                                .padding(.horizontal, 2)
                                .background(RoundedRectangle(cornerRadius: 3).fill(i >= 6 ? Color.yellow : Color.clear))
                                .foregroundStyle(i >= 6 ? Color.black : Color.secondary)
                                .fixedSize()
                        }
                        .frame(width: 24)   // equal columns, whatever the label's width
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Pill(text: "Solo Lrs Rrs", tint: .yellow)
                    Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 6) {
                        if detailed {
                            GridRow { stat("Jitter", "0.00 ms"); stat("Worst", "0.00 ms"); stat("Buffer", "15 ms"); stat("Low water", "0 ms") }
                            GridRow { stat("Drift", "+18 ppm"); stat("Lost", "0"); stat("Underruns", "0"); stat("Last underrun", "—") }
                            GridRow { stat("Packets", "128400"); stat("Clock", "ptp=IEEE1588-2008:…-00-00-01:0").gridCellColumns(3) }
                        } else {
                            GridRow { stat("Group", "233.252.0.10:5004") }
                        }
                    }
                }
            }
            HStack(spacing: 4) {
                Text("Solo").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                ForEach(["L", "R", "C", "LFE", "Lss", "Rss", "Lrs", "Rrs"], id: \.self) { c in
                    Pill(text: c, tint: .yellow, filled: c == "Lrs" || c == "Rrs")
                }
                Text("Front").font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 6)
                Text("Sides").font(.system(size: 11)).foregroundStyle(.secondary)
                Text("Rears").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text("Clear").font(.system(size: 11, weight: .medium)).foregroundStyle(amber)
            }
        }
        .padding(.leading, 51).padding(.trailing, 14).padding(.vertical, 10)
        .background(Color.primary.opacity(0.06))
    }

    private func stat(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(k).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(v).font(.system(size: 12)).monospacedDigit().lineLimit(1)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Text("Solo").font(.system(size: 11, weight: .semibold)).foregroundStyle(.yellow)
            Button("Clear") {}.controlSize(.small)
            Spacer()
            Button("Connect to a Sender over VBAN…") {}.controlSize(.small)
            Text("3 of 8").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            Button("Stop all") {}.controlSize(.small)
            Image(systemName: "text.alignleft").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).frame(height: 34)
    }
}

/// Every section the panel has today — inputs, inserts with dry/wet, output, loudness — in
/// sentence case, flat, with the level in dB and the loudness target shown.
private struct R2Panel: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                section("Inputs", detail: "3 joined") {
                    VStack(spacing: 2) {
                        input("Live Room 1-8", badges: [("S", Color.yellow)], bars: 8, level: 0.6, highlight: true)
                        input("Stagebox-1 TX 1-2", badges: [], bars: 2, level: 0, highlight: false)
                        input("Studio A 5.1 Bed", badges: [("M", Color.red)], bars: 6, level: 0.45, highlight: false)
                    }
                }
                section("Inserts", detail: "2 AU") {
                    VStack(spacing: 6) {
                        insert("1", "SoundID Reference", mix: 1.0)
                        insert("2", "Pro-Q 4", mix: 0.6)
                        HStack(spacing: 6) {
                            Text("3").font(.system(size: 11)).foregroundStyle(.secondary)
                            HStack(spacing: 3) { Text("Empty").foregroundStyle(.secondary); Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold)).foregroundStyle(amber) }.font(.system(size: 12))
                            Spacer()
                        }.padding(.horizontal, 8).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                    }
                }
                section("Output", device: "Headphones", detail: "48 kHz") {
                    HStack(alignment: .top, spacing: 12) {
                        HStack(spacing: 4) { VBar(level: 0.72, width: 11); VBar(level: 0.7, width: 11) }.frame(height: 96)
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text("−3.3").font(.system(size: 20, weight: .light)).monospacedDigit()
                                Text("dBFS max").font(.system(size: 10)).foregroundStyle(.secondary)
                                Spacer()
                                Text("−22.8").font(.system(size: 20, weight: .light)).monospacedDigit().foregroundStyle(.green)
                                Text("LUFS-I").font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            HStack(spacing: 6) {
                                Image(systemName: "speaker.wave.2").font(.system(size: 11)).foregroundStyle(.secondary)
                                FakeSlider(value: 1.0, fill: amber)
                                Text("0.0 dB").font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary).fixedSize().padding(.leading, 4)
                            }
                            HStack(spacing: 6) {
                                Pill(text: "DIM", tint: .orange, filled: false)
                                // On, to show it: an active toggle fills with the secondary colour.
                                Text("MONO").font(.system(size: 9, weight: .bold, design: .rounded))
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(Capsule().fill(amber)).foregroundStyle(Color.black)
                            }
                        }
                    }
                }
                section("Loudness", detail: "60 s · target −23") {
                    VStack(spacing: 3) {
                        reading("Short-term", "−21.2", "+1.8", Color.yellow)
                        reading("Window 60 s", "−23.1", "−0.1", Color.green)
                        reading("Integrated", "−22.8", "+0.2", Color.green)
                    }
                }
            }
            .padding(14)
        }
    }

    private func section<C: View>(_ t: String, device: String? = nil, detail: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(t).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                if let device { Text(device).font(.system(size: 11)).foregroundStyle(.secondary) }
                Spacer()
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
            }
            c()
            Divider()
        }
    }

    private func input(_ name: String, badges: [(String, Color)], bars: Int, level: Double, highlight: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(name).font(.system(size: 12, weight: .medium))
                Spacer()
                ForEach(badges, id: \.0) { b in
                    Text(b.0).font(.system(size: 9, weight: .bold, design: .rounded))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(b.1))
                        .foregroundStyle(b.0 == "M" ? Color.white : Color.black)
                }
                Text("Ch 1/2").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            VStack(spacing: 2) {
                ForEach(0..<min(bars, 8), id: \.self) { i in HBar(level: level * (i % 2 == 0 ? 1 : 0.93), height: 2.5) }
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(highlight ? Color.primary.opacity(0.06) : Color.clear))
    }

    /// Today's insert row — number, plugin menu, BYP, Δ, editor — with the dry/wet always shown.
    private func insert(_ n: String, _ name: String, mix: Double) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Text(n).font(.system(size: 11)).foregroundStyle(.secondary)
                HStack(spacing: 3) { Text(name); Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold)).foregroundStyle(amber) }.font(.system(size: 12))
                Spacer()
                Pill(text: "BYP", tint: amber, filled: false)
                Pill(text: "Δ", tint: amber, filled: false)
                Image(systemName: "slider.horizontal.below.rectangle").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text("DRY").font(.system(size: 8, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
                FakeSlider(value: mix, fill: amber)
                Text("WET").font(.system(size: 8, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
                Text("\(Int(mix * 100)) %").font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary).fixedSize()
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
    }

    private func reading(_ label: String, _ value: String, _ delta: String, _ tint: Color) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 11)).frame(width: 78, alignment: .leading)
            Text(value).font(.system(size: 14, weight: .medium)).monospacedDigit()
            Spacer()
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12)).frame(width: 70, height: 3)
                Rectangle().fill(Color.primary.opacity(0.4)).frame(width: 1, height: 8).offset(x: 35)
                Circle().fill(tint).frame(width: 7, height: 7).offset(x: 35 + CGFloat(Double(delta) ?? 0) * 5)
            }
            Text(delta).font(.system(size: 11)).monospacedDigit().foregroundStyle(tint).frame(width: 34, alignment: .trailing)
        }
    }
}

private struct R2Compact: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                AppEmblem(.grabber, size: 18, caption: .beside)
                HStack(spacing: 2) { Text("en5"); Image(systemName: "chevron.down").font(.system(size: 7)) }.font(.system(size: 11, weight: .medium))
                    .foregroundStyle(amber)
                Text("Headphones").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Text("48 kHz 2 ch").font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 10)).foregroundStyle(.secondary)
                Image(systemName: "gearshape").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).frame(height: 40)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("−3.3").font(.system(size: 30, weight: .light)).monospacedDigit()
                    Text("dBFS max").font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 0) {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text("−22.8").font(.system(size: 30, weight: .light)).monospacedDigit()
                            Text("LUFS-I").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Text("+0.2 against −23").font(.system(size: 10)).foregroundStyle(.green)
                    }
                }
                VStack(spacing: 4) {
                    HStack { Text("L").font(.system(size: 10)).foregroundStyle(.secondary); HBar(level: 0.72, height: 7) }
                    HStack { Text("R").font(.system(size: 10)).foregroundStyle(.secondary); HBar(level: 0.70, height: 7) }
                }
                HStack(spacing: 6) {
                    Image(systemName: "speaker.wave.2").font(.system(size: 11)).foregroundStyle(.secondary)
                    FakeSlider(value: 1.0, fill: amber)
                    Text("0.0 dB").font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary).fixedSize().padding(.leading, 6)
                }
                HStack(spacing: 6) { Pill(text: "DIM", tint: .orange, filled: false); Pill(text: "MONO", tint: amber, filled: false) }
            }
            .padding(12)
            Divider()
            fold("Loudness", open: false) { EmptyView() } trailing: {
                // As the full window's readings: each value with its offset from the target,
                // coloured the same way.
                HStack(spacing: 8) {
                    foldedReading("S", "−21.2", "+1.8", .yellow)
                    foldedReading("W", "−23.1", "−0.1", .green)
                    foldedReading("I", "−22.8", "+0.2", .green)
                }
            }
            Divider()
            fold("Inserts", open: true) {
                VStack(spacing: 5) {
                    compactInsert("1", "SoundID Reference", mix: 1.0)
                    compactInsert("2", "Pro-Q 4", mix: 0.6)
                    HStack(spacing: 6) {
                        Text("3").foregroundStyle(.secondary)
                        HStack(spacing: 3) { Text("Empty").foregroundStyle(.secondary); Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold)).foregroundStyle(amber) }
                        Spacer()
                    }
                    .font(.system(size: 11)).padding(.horizontal, 8)
                }.padding(.horizontal, 12).padding(.bottom, 8)
            } trailing: { Text("2 loaded").font(.system(size: 10)).foregroundStyle(.secondary) }
            Divider()
            fold("Listening", open: true) {
                VStack(spacing: 0) {
                    listening("Live Room 1-8", "8 ch", level: 0.66, mute: false, solo: true, note: "")
                    listening("Stagebox-1 TX 1-2", "2 ch", level: 0, mute: false, solo: false, note: "No packets")
                    listening("Studio A 5.1 Bed", "6 ch", level: 0.5, mute: true, solo: false, note: "")
                    HStack { Text("5 available").font(.system(size: 11)).foregroundStyle(.secondary); Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.secondary); Spacer() }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                }
            } trailing: { Text("3").font(.system(size: 10)).foregroundStyle(.secondary) }
            Spacer()
            Divider()
            HStack(spacing: 8) {
                Text("Solo").font(.system(size: 11, weight: .semibold)).foregroundStyle(.yellow)
                Button("Clear") {}.controlSize(.small)
                Spacer()
                Text("3 of 8").font(.system(size: 11)).foregroundStyle(.secondary)
                Button("Stop all") {}.controlSize(.small)
            }
            .padding(.horizontal, 12).frame(height: 34)
        }
    }

    private func fold<C: View, T: View>(_ t: String, open: Bool, @ViewBuilder _ c: () -> C, @ViewBuilder trailing: () -> T) -> some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                Text(t).font(.system(size: 12, weight: .semibold))
                Spacer()
                trailing()
            }
            .padding(.horizontal, 12).frame(height: 30)
            if open { c() }
        }
    }

    private func foldedReading(_ label: String, _ value: String, _ delta: String, _ tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 11, weight: .medium)).monospacedDigit()
            Text(delta).font(.system(size: 9)).monospacedDigit().foregroundStyle(tint)
        }
    }

    private func compactInsert(_ n: String, _ name: String, mix: Double) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Text(n).font(.system(size: 11)).foregroundStyle(.secondary)
                HStack(spacing: 3) { Text(name); Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold)).foregroundStyle(amber) }.font(.system(size: 11))
                Spacer()
                Text("\(Int(mix * 100)) %").font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                Pill(text: "BYP", tint: amber, filled: false)
                Pill(text: "Δ", tint: amber, filled: false)
                Image(systemName: "slider.horizontal.below.rectangle").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack(spacing: 5) {
                Text("DRY").font(.system(size: 8, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
                FakeSlider(value: mix, fill: amber)
                Text("WET").font(.system(size: 8, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
    }

    /// Today's listening row, without the tinted card behind it: stop and the bus menu keep the
    /// secondary colour.
    private func listening(_ name: String, _ ch: String, level: Double, mute: Bool, solo: Bool, note: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "stop.circle.fill").font(.system(size: 16)).foregroundStyle(amber)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Circle().fill(note.isEmpty ? Color(red: 0.36, green: 0.62, blue: 0.94) : Color(red: 0.36, green: 0.78, blue: 0.55)).frame(width: 5, height: 5)
                    Text(name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                }
                HBar(level: level, height: 4).frame(width: 80)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 4) {
                    Text(ch).font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                    if !note.isEmpty { Text("no packets").font(.system(size: 10)).foregroundStyle(.orange) }
                }
                HStack(spacing: 2) { Text("Ch 1/2"); Image(systemName: "chevron.down").font(.system(size: 7)) }
                    .font(.system(size: 10)).foregroundStyle(amber)
            }
            MS(mute: mute, solo: solo)
        }
        .padding(.horizontal, 12).frame(height: 46)
    }
}

private struct R2Sender: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                AppEmblem(.sender, size: 22, caption: .beside)
                Divider().frame(height: 18)
                HStack(spacing: 3) { Text("All networks").font(.system(size: 12, weight: .medium)); Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)) }
                    .foregroundStyle(amber)
                Divider().frame(height: 14)
                HStack(spacing: 5) {
                    Image(systemName: "headphones").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text("Studio Monitors").font(.system(size: 11))
                    Text("48 kHz").font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "circle.lefthalf.filled").font(.system(size: 12)).foregroundStyle(.secondary)
                Image(systemName: "gearshape").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).frame(height: 44)
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text("This Mac").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary); Spacer(); Text("16-bit").font(.system(size: 10)).foregroundStyle(.secondary) }
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Stream name").font(.system(size: 10)).foregroundStyle(.secondary)
                            TextField("", text: .constant("Edit Suite Mac")).textFieldStyle(.roundedBorder).frame(width: 170)
                        }
                        VStack(spacing: 3) {
                            HBar(level: 0.8, height: 6); HBar(level: 0.74, height: 6)
                            HStack { Text("−60"); Spacer(); Text("−18"); Spacer(); Text("0 dBFS") }.font(.system(size: 9)).foregroundStyle(.secondary).monospacedDigit()
                        }.padding(.top, 14)
                    }
                }
                // The request stands apart, highlighted: someone is asking, and it wants an answer.
                request
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.40), lineWidth: 1))
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Receivers").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Text("2 listening · 2 of 3 sending").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Connect to a Grabber over VBAN…") {}.controlSize(.small)
                        Spacer()
                        Text("Offer to Grabbers").font(.system(size: 11))
                        Toggle("", isOn: .constant(true)).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    }
                    VStack(spacing: 0) {
                        receiver(star: nil, playing: nil, name: "Control Room", address: "192.0.2.40", how: "Listening", bcast: false, muted: false)
                        Divider().opacity(0.5)
                        receiver(star: nil, playing: nil, name: "Edit Bay Grabber", address: "198.51.100.7", how: "Listening", bcast: false, muted: false)
                        Divider().opacity(0.5)
                        receiver(star: true, playing: true, name: "Studio PC", address: "192.0.2.20", how: "Sent to", bcast: true, muted: false)
                        Divider().opacity(0.5)
                        receiver(star: true, playing: true, name: "192.0.2.31", address: "192.0.2.31", how: "Sent to", bcast: true, muted: true)
                        Divider().opacity(0.5)
                        receiver(star: false, playing: false, name: "Edit Bay Grabber", address: "198.51.100.7", how: "Stopped", bcast: true, muted: false)
                        Divider().opacity(0.5)
                        HStack(spacing: 6) {
                            TextField("", text: .constant(""), prompt: Text("Receiver IP address")).textFieldStyle(.roundedBorder)
                            Text(":").foregroundStyle(.secondary)
                            TextField("", text: .constant("6980")).textFieldStyle(.roundedBorder).frame(width: 64)
                            Button("Add") {}.controlSize(.small)
                        }.padding(8)
                    }
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                }
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text("Inserts").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary); Spacer(); Text("440 AU").font(.system(size: 10)).foregroundStyle(.secondary) }
                    ForEach([("1", "AUGraphicEQ"), ("2", "Empty"), ("3", "Empty")], id: \.0) { n, name in
                        HStack(spacing: 6) {
                            Text(n).foregroundStyle(.secondary).frame(width: 12, alignment: .leading)
                            HStack(spacing: 3) {
                                Text(name).foregroundStyle(name == "Empty" ? Color.secondary : Color.primary)
                                Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold)).foregroundStyle(amber)
                            }
                            Spacer()
                            if name != "Empty" {
                                Pill(text: "BYP", tint: amber, filled: false)
                                Image(systemName: "slider.horizontal.below.rectangle").foregroundStyle(.secondary)
                            }
                        }
                        .font(.system(size: 12)).padding(.horizontal, 8).frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                    }
                    Label("Inserts are applied to the stream only — you hear them at the receiver, not on this Mac.", systemImage: "info.circle")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            Spacer()
            Divider()
            HStack {
                Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.green)
                Text("Sending to 2 targets and 2 listening · 0 kbit/s").font(.system(size: 11))
                Spacer()
                Button("Stop all") {}.controlSize(.small)
            }.padding(.horizontal, 14).frame(height: 34)
        }
    }

    private var request: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange).frame(width: 34)
            VStack(alignment: .leading, spacing: 0) {
                Text("Booth Mac wants to listen").font(.system(size: 12, weight: .medium))
                Text("192.0.2.41").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Deny") {}.controlSize(.small)
            Button("Allow") {}.controlSize(.small)
        }
        .padding(.horizontal, 8).frame(height: 40)
    }

    private func receiver(star: Bool?, playing: Bool?, name: String, address: String, how: String, bcast: Bool, muted: Bool) -> some View {
        HStack(spacing: 7) {
            if let star {
                Image(systemName: star ? "star.fill" : "star").font(.system(size: 10)).foregroundStyle(star ? amber : Color.secondary.opacity(0.5)).frame(width: 12)
                Image(systemName: playing == true ? "stop.circle.fill" : "play.circle").font(.system(size: 15)).foregroundStyle(playing == true ? amber : Color.secondary).frame(width: 16)
            } else {
                Image(systemName: "headphones").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 35)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(name).font(.system(size: 12, weight: .medium))
                Text(address).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            Spacer()
            Text(how).font(.system(size: 10)).foregroundStyle(.secondary)
            if bcast { Pill(text: "BCAST", tint: amber, filled: false) }
            if star != nil {
                Text("M").font(.system(size: 10, weight: .semibold)).frame(width: 20, height: 18)
                    .background(RoundedRectangle(cornerRadius: 4).fill(muted ? Color.red : Color.primary.opacity(0.10)))
                    .foregroundStyle(muted ? Color.white : Color.secondary)
                Image(systemName: "xmark").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8).frame(height: 38)
    }
}

// MARK: - S5: the Sender simplified, in the Grabber compact window's shape
//
// `--mockup-sender <current-renders> <out>`: today's Sender beside the proposal, busy and quiet.
// The principle: the Grabber reads as clean, important data first; the Sender as words, stats
// and two ways to the same place. The proposal keeps every function and moves the rest behind one
// control each.

enum SenderCompare {
    @MainActor
    static func run(arguments: [String]) {
        guard let i = arguments.firstIndex(of: "--mockup-sender"), arguments.count > i + 2 else {
            print("usage: --mockup-sender <folder of current renders> <out folder>"); exit(2)
        }
        let current = arguments[i + 1], out = arguments[i + 2]
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let size = CGSize(width: 480, height: 760)
        let shots: [(String, String, Bool, NSAppearance?)] = [
            ("busy-dark", "sender-full-tall.png", true, NSAppearance(named: .darkAqua)),
            ("quiet-dark", "sender-empty-tall.png", false, NSAppearance(named: .darkAqua)),
            ("busy-light", "sender-light.png", true, NSAppearance(named: .aqua)),
        ]
        for (name, file, busy, look) in shots {
            UIMockupsCapture.capture(AnyView(SenderSimple(busy: busy)), size: size, appearance: look,
                                     to: "\(out)/S5-\(name).png")
            guard let now = NSImage(contentsOfFile: "\(current)/\(file)"),
                  let proposed = NSImage(contentsOfFile: "\(out)/S5-\(name).png") else { continue }
            let pair = AnyView(SideBySide(now: now, proposed: proposed, size: size))
            UIMockupsCapture.capture(pair, size: CGSize(width: size.width * 2 + 30, height: size.height + 40),
                                     appearance: look, to: "\(out)/compare-sender-\(name).png")
        }
        print("Wrote S5-* and compare-sender-* to \(out)")
        exit(0)
    }
}

private struct SideBySide: View {
    let now: NSImage, proposed: NSImage, size: CGSize
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            column("Now (R4 as built)", now)
            column("S5 — proposed", proposed)
        }
        .padding(.horizontal, 5)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
    private func column(_ t: String, _ image: NSImage) -> some View {
        VStack(spacing: 0) {
            Text(t).font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6).frame(height: 36)
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipped()
        }
    }
}

private struct SenderSimple: View {
    let busy: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            // What is going out, the way the compact Grabber leads with its output: the name large,
            // the level under it, the format as one small line. Renaming is a click on the name.
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(busy ? "Edit Suite Mac" : "Mac Audio").font(.system(size: 20, weight: .medium))
                    Image(systemName: "pencil").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Text(busy ? "16-bit · 48 kHz · stereo" : "16-bit").font(.system(size: 10))
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                VStack(spacing: 4) {
                    HStack { Text("L").font(.system(size: 10)).foregroundStyle(.secondary); HBar(level: busy ? 0.78 : 0, height: 7) }
                    HStack { Text("R").font(.system(size: 10)).foregroundStyle(.secondary); HBar(level: busy ? 0.72 : 0, height: 7) }
                }
            }
            .padding(12)

            if busy {
                request.padding(.horizontal, 12).padding(.bottom, 10)
            }
            Divider()

            // One place for everyone the audio reaches. The offer switch sits in the heading it
            // governs; + adds a receiver by address (a small popover, not a permanent field).
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text("Receivers").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text("Findable by Grabbers").font(.system(size: 11)).foregroundStyle(.secondary)
                    Toggle("", isOn: .constant(busy)).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    Image(systemName: "plus").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        .frame(width: 22, height: 20)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
                }
                .padding(.horizontal, 12).frame(height: 36)
                if busy {
                    VStack(spacing: 0) {
                        row(icon: .listener, name: "Control Room", address: "192.0.2.40", status: "Listening")
                        row(icon: .listener, name: "Edit Bay Grabber", address: "198.51.100.7", status: "Listening")
                        row(icon: .playing, name: "Studio PC", address: "192.0.2.20", status: "Sending", star: true)
                        row(icon: .playing, name: "192.0.2.31", address: nil, status: "Sending", star: true, muted: true)
                        row(icon: .stopped, name: "Booth Mac", address: "192.0.2.41", status: "Stopped")
                    }
                } else {
                    Text("Nobody is receiving. Turn on Findable so Grabbers on this network can list this Mac, or add a receiver by address with +.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12).padding(.bottom, 12)
                }
            }
            Divider()

            // Folded, as in the compact Grabber: the summary says what is loaded.
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary).frame(width: 8)
                Text("Inserts").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(busy ? "AUGraphicEQ" : "none").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).frame(height: 34)
            Divider()
            Spacer()
            Divider()
            HStack(spacing: 8) {
                Circle().fill(busy ? Color.green : Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
                Text(busy ? "Sending · 4 receivers · 1.5 Mbit/s" : "Not sending").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                // The same button, in the same place, as the Grabber's status bar.
                Button {} label: {
                    Label("Connect…", systemImage: "point.3.connected.trianglepath.dotted").font(.system(size: 11))
                        .foregroundStyle(Color.primary)
                }.buttonStyle(.bordered).controlSize(.small)
                if busy { Button("Stop all") {}.controlSize(.small) }
            }
            .padding(.horizontal, 12).frame(height: 34)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 10) {
            AppEmblem(.sender, size: 22, caption: .beside)
            Divider().frame(height: 18)
            HStack(spacing: 3) { Text("All networks").font(.system(size: 12, weight: .medium)); Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)) }
                .foregroundStyle(amber)
            Divider().frame(height: 14)
            HStack(spacing: 5) {
                Image(systemName: "headphones").font(.system(size: 10)).foregroundStyle(.secondary)
                Text("Studio Monitors").font(.system(size: 11))
                Text("48 kHz").font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "circle.lefthalf.filled").font(.system(size: 12)).foregroundStyle(.secondary)
            Image(systemName: "gearshape").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).frame(height: 44)
    }

    private var request: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised.fill").font(.system(size: 13)).foregroundStyle(.orange).frame(width: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text("Booth Mac wants to listen").font(.system(size: 12, weight: .medium))
                Text("192.0.2.41").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Deny") {}.controlSize(.small)
            Button("Allow") {}.controlSize(.small).buttonStyle(.borderedProminent).tint(amber)
        }
        .padding(.horizontal, 9).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.40), lineWidth: 1))
    }

    private enum Icon { case listener, playing, stopped }

    private func row(icon: Icon, name: String, address: String?, status: String,
                     star: Bool = false, muted: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                switch icon {
                case .listener:
                    Image(systemName: "headphones").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 20)
                case .playing:
                    Image(systemName: "stop.circle.fill").font(.system(size: 17)).foregroundStyle(amber).frame(width: 20)
                case .stopped:
                    Image(systemName: "play.circle").font(.system(size: 17)).foregroundStyle(.secondary).frame(width: 20)
                }
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) {
                        Text(name).font(.system(size: 12, weight: .medium))
                        if star { Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(.yellow) }
                    }
                    if let address { Text(address).font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit() }
                }
                Spacer()
                Text(status).font(.system(size: 11)).foregroundStyle(.secondary)
                // Mute on the targets; broadcast, rename, favourite and remove are in the row's
                // menu (right-click, or the … on hover), where BCAST was a faint pill on every row.
                if icon != .listener {
                    Text("M").font(.system(size: 10, weight: .semibold)).frame(width: 22, height: 18)
                        .background(RoundedRectangle(cornerRadius: 4).fill(muted ? Color.red : Color.primary.opacity(0.10)))
                        .foregroundStyle(muted ? Color.white : Color.secondary)
                } else {
                    Color.clear.frame(width: 22, height: 18)
                }
                Image(systemName: "ellipsis").font(.system(size: 11)).foregroundStyle(.secondary.opacity(0.6)).frame(width: 14)
            }
            .padding(.horizontal, 12).frame(height: 40)
            Divider().opacity(0.5).padding(.leading, 40)
        }
    }
}

// MARK: - Adoptions, proposed: `--mockup-adopt <out>`
//
// From the Audio Hijack study: an idle meter that looks idle (2), errors on the thing that failed
// (3), a level history (4), a per-insert "signal passing" indicator (7), and a search on top of
// the per-maker plugin list (6). Each drawn beside what it would replace; R4's colours unchanged.

enum AdoptMockups {
    @MainActor
    static func run(arguments: [String]) {
        guard let i = arguments.firstIndex(of: "--mockup-adopt"), i + 1 < arguments.count else {
            print("usage: --mockup-adopt <out folder>"); exit(2)
        }
        let out = arguments[i + 1]
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let dark = NSAppearance(named: .darkAqua)
        let shots: [(String, AnyView, CGSize)] = [
            ("adopt-rows", AnyView(AdoptRows()), CGSize(width: 1000, height: 560)),
            ("adopt-inserts", AnyView(AdoptInserts()), CGSize(width: 1000, height: 600)),
            ("adopt-output", AnyView(AdoptOutput()), CGSize(width: 1000, height: 560)),
            ("adopt-compact", AnyView(AdoptCompact()), CGSize(width: 820, height: 560)),
        ]
        for (name, view, size) in shots {
            UIMockupsCapture.capture(view, size: size, appearance: dark, to: "\(out)/\(name).png")
        }
        print("Wrote \(shots.map(\.0).joined(separator: ", ")) to \(out)")
        exit(0)
    }
}

/// "Now" and "Proposed", side by side, with a line saying what changes.
private struct BeforeAfter<A: View, B: View>: View {
    let title: String, note: String
    let now: A, proposed: B
    init(_ title: String, _ note: String, @ViewBuilder now: () -> A, @ViewBuilder proposed: () -> B) {
        self.title = title; self.note = note; self.now = now(); self.proposed = proposed()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(note).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: 16) {
                column("Now", now)
                column("Proposed", proposed)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
    private func column<V: View>(_ label: String, _ v: V) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            v.frame(maxWidth: .infinity, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// A level bar that can say "no data": dots where there is nothing to measure, the usual track
/// where the signal is simply quiet.
private struct IdleAwareBar: View {
    enum State { case level(Double), silent, noData }
    let state: State
    var height: CGFloat = 6
    var body: some View {
        switch state {
        case .level(let v): HBar(level: v, height: height)
        case .silent: HBar(level: 0, height: height)
        case .noData:
            GeometryReader { g in
                HStack(spacing: 4) {
                    ForEach(0..<Int(g.size.width / 7), id: \.self) { _ in
                        Circle().fill(Color.secondary.opacity(0.45)).frame(width: 3, height: 3)
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: height)
        }
    }
}

/// A scrolling history of the peak: one thin bar per quarter-second, dropouts marked.
private struct LevelHistory: View {
    let values: [Double]
    var gapAt: Set<Int> = []
    var height: CGFloat = 26
    var body: some View {
        HStack(alignment: .center, spacing: 1.5) {
            ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                if gapAt.contains(i) {
                    Rectangle().fill(Color.red.opacity(0.85)).frame(width: 2, height: height)
                } else {
                    Capsule().fill(v > 0.85 ? Color.orange : (v > 0.6 ? Color.yellow.opacity(0.9) : Color.green.opacity(0.85)))
                        .frame(width: 2, height: max(2, height * v))
                }
            }
        }
        .frame(height: height)
    }
}

private func sampleHistory(_ n: Int, seed: Double = 1) -> [Double] {
    (0..<n).map { i in
        let x = Double(i)
        return max(0.08, min(0.95, 0.55 + 0.22 * sin(x / 5 * seed) + 0.12 * sin(x / 1.7) + 0.06 * cos(x * 1.3)))
    }
}

// MARK: Stream rows

private struct AdoptRows: View {
    var body: some View {
        BeforeAfter("2 · An idle meter that looks idle — and 3 · the fault on the row itself",
                    "Now an empty bar means any of: silent, no packets, not joined. Proposed: dots mean nothing is arriving; a flat track means it is arriving and quiet. A stream that failed to join says so on its row, with the fix, instead of only in the log.") {
            rows(proposed: false)
        } proposed: {
            rows(proposed: true)
        }
    }

    private func rows(proposed: Bool) -> some View {
        VStack(spacing: 0) {
            row("Live Room 1–8", "7.1 → 2.0", state: .level(0.7), status: ("OK", "checkmark.circle", Color.secondary), proposed: proposed)
            Divider().opacity(0.5)
            row("Talkback Mic", "Ch 1/2", state: .silent, status: ("Quiet", "checkmark.circle", Color.secondary), proposed: proposed)
            Divider().opacity(0.5)
            row("Stagebox-1 TX 1–2", "Ch 1/2", state: .noData, status: ("No packets", "exclamationmark.triangle.fill", Color.orange), proposed: proposed)
            Divider().opacity(0.5)
            if proposed {
                VStack(alignment: .leading, spacing: 6) {
                    row("Studio A 5.1 Bed", "5.1 → 2.0", state: .noData, status: ("Can't join", "xmark.octagon.fill", Color.red), proposed: true)
                    HStack(spacing: 8) {
                        Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).font(.system(size: 11))
                        Text("Port 5004 is in use by another app on this Mac.").font(.system(size: 11))
                        Spacer()
                        Button("Try again") {}.controlSize(.small)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.10)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.red.opacity(0.35)))
                    .padding(.leading, 44).padding(.trailing, 10).padding(.bottom, 8)
                }
            } else {
                row("Studio A 5.1 Bed", "5.1 → 2.0", state: .silent, status: ("No packets", "exclamationmark.triangle.fill", Color.orange), proposed: false)
            }
        }
        .padding(.vertical, 4)
    }

    private func row(_ name: String, _ bus: String, state: IdleAwareBar.State,
                     status: (String, String, Color), proposed: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "stop.circle.fill").font(.system(size: 17)).foregroundStyle(amber)
            Text(name).font(.system(size: 13, weight: .medium)).frame(width: 150, alignment: .leading).lineLimit(1)
            HStack(spacing: 2) { Text(bus); Image(systemName: "chevron.down").font(.system(size: 7)) }
                .font(.system(size: 11)).foregroundStyle(amber).frame(width: 70, alignment: .leading)
            Group {
                if proposed { IdleAwareBar(state: state) }
                else {
                    switch state {
                    case .level(let v): HBar(level: v)
                    default: HBar(level: 0)
                    }
                }
            }
            .frame(width: 70)
            Label(status.0, systemImage: status.1).font(.system(size: 11)).foregroundStyle(status.2)
                .frame(width: 100, alignment: .leading)
        }
        .padding(.horizontal, 10).frame(height: 36)
    }
}

// MARK: Inserts

private struct AdoptInserts: View {
    var body: some View {
        BeforeAfter("7 · Signal through each insert — 3 · a failed slot says so — 6 · search on top of the maker list",
                    "Proposed: a pair of tiny meters per slot, in → out, so a plugin passing nothing (or silencing) is obvious without Δ; a slot whose plugin crashed or would not load turns red with Reload; the plugin menu keeps its per-maker lists and gains \"Search…\" at the top.") {
            VStack(spacing: 6) {
                slot("1", "SoundID Reference", proposed: false)
                slot("2", "Pro-Q 4", proposed: false)
                slot("3", "Empty", proposed: false, empty: true)
            }.padding(12)
        } proposed: {
            VStack(alignment: .leading, spacing: 6) {
                slot("1", "SoundID Reference", proposed: true, inLevel: 0.7, outLevel: 0.62)
                failed
                slot("3", "Empty", proposed: true, empty: true)
                searchPopover.padding(.top, 6)
            }.padding(12)
        }
    }

    private func slot(_ n: String, _ name: String, proposed: Bool, empty: Bool = false,
                      inLevel: Double = 0, outLevel: Double = 0) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Text(n).font(.system(size: 11)).foregroundStyle(.secondary)
                HStack(spacing: 3) { Text(name).foregroundStyle(empty ? Color.secondary : Color.primary)
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold)).foregroundStyle(amber) }
                    .font(.system(size: 12))
                Spacer()
                if !empty {
                    if proposed {
                        // in → out, 3 points tall each: the signal either side of the plugin.
                        HStack(spacing: 3) {
                            VStack(spacing: 2) { HBar(level: inLevel, height: 3); HBar(level: inLevel * 0.95, height: 3) }.frame(width: 26)
                            Image(systemName: "arrow.right").font(.system(size: 7)).foregroundStyle(.secondary)
                            VStack(spacing: 2) { HBar(level: outLevel, height: 3); HBar(level: outLevel * 0.95, height: 3) }.frame(width: 26)
                        }
                        .help("Level going into and coming out of this plugin")
                    }
                    Pill(text: "BYP", tint: amber, filled: false)
                    Pill(text: "Δ", tint: amber, filled: false)
                    Image(systemName: "slider.horizontal.below.rectangle").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if !empty {
                HStack(spacing: 6) {
                    Text("DRY").font(.system(size: 8, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
                    FakeSlider(value: 1, fill: amber)
                    Text("WET").font(.system(size: 8, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
                    Text("100 %").font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary).fixedSize()
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
    }

    private var failed: some View {
        HStack(spacing: 6) {
            Text("2").font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 3) { Text("Pro-Q 4"); Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold)).foregroundStyle(amber) }
                .font(.system(size: 12))
            Label("Stopped responding — taken out of the chain", systemImage: "xmark.octagon.fill")
                .font(.system(size: 11)).foregroundStyle(.red).lineLimit(1)
            Spacer()
            Button("Reload") {}.controlSize(.small)
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.red.opacity(0.35)))
    }

    private var searchPopover: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("The plugin menu, proposed").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                menuItem("Search…", symbol: "magnifyingglass", bold: true)
                Divider()
                menuItem("— Empty —")
                Divider()
                menuItem("Apple", chevron: true)
                menuItem("FabFilter", chevron: true)
                menuItem("iZotope", chevron: true)
                menuItem("Kilohearts", chevron: true)
                menuItem("Waves", chevron: true)
            }
            .frame(width: 200)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
            Text("Search… opens a field and the same list, filtered as you type:").font(.system(size: 10)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text("delay").font(.system(size: 12)); Spacer()
                }
                .padding(5).background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
                Text("Apple").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Text("   AUDelay").font(.system(size: 12))
                Text("Waves").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Text("   H-Delay (s)").font(.system(size: 12))
                Text("   H-Delay (m→s)").font(.system(size: 12))
            }
            .padding(8)
            .frame(width: 200, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
        }
    }

    private func menuItem(_ t: String, symbol: String? = nil, bold: Bool = false, chevron: Bool = false) -> some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10)) }
            Text(t).font(.system(size: 12, weight: bold ? .medium : .regular))
            Spacer()
            if chevron { Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 8).frame(height: 22)
    }
}

// MARK: Output with history

private struct AdoptOutput: View {
    var body: some View {
        BeforeAfter("4 · A level history under the output",
                    "The last 30 seconds of the output peak, a thin bar every quarter-second, scrolling left. A dropout (no audio arriving) is a red mark in it, so \"did it cut out a moment ago?\" is answered at a glance. Elapsed time since joining beside it.") {
            output(history: false)
        } proposed: {
            output(history: true)
        }
    }

    private func output(history: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Output").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Text("Headphones").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text("48 kHz").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 12) {
                HStack(spacing: 4) { VBar(level: 0.72, width: 11); VBar(level: 0.7, width: 11) }.frame(height: 110)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("-3.3").font(.system(size: 22, weight: .light)).monospacedDigit()
                        Text("dBFS max").font(.system(size: 10)).foregroundStyle(.secondary)
                        Spacer()
                        Text("-22.8").font(.system(size: 22, weight: .light)).monospacedDigit().foregroundStyle(.green)
                        Text("LUFS-I").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 6) {
                        Image(systemName: "speaker.wave.2").font(.system(size: 11)).foregroundStyle(.secondary)
                        FakeSlider(value: 1, fill: amber)
                        Text("0.0 dB").font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary).fixedSize()
                    }
                    HStack(spacing: 6) { Pill(text: "DIM", tint: amber, filled: false); Pill(text: "MONO", tint: amber, filled: false) }
                }
                .frame(height: 110)
            }
            if history {
                VStack(alignment: .leading, spacing: 3) {
                    LevelHistory(values: sampleHistory(120), gapAt: [83, 84])
                    HStack {
                        Text("30 s ago").font(.system(size: 9)).foregroundStyle(.secondary)
                        Spacer()
                        Text("1 dropout · playing 12:41").font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary)
                        Text("now").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
    }
}

// MARK: Compact

private struct AdoptCompact: View {
    var body: some View {
        BeforeAfter("2 and 4 in the compact window",
                    "The history sits under the big readouts; listening rows use the idle-aware bar, so a stream with nothing arriving shows dots.") {
            compact(proposed: false)
        } proposed: {
            compact(proposed: true)
        }
    }

    private func compact(proposed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("-3.3").font(.system(size: 28, weight: .light)).monospacedDigit()
                Text("dBFS max").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Text("-22.8").font(.system(size: 28, weight: .light)).monospacedDigit()
                Text("LUFS-I").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            VStack(spacing: 4) { HBar(level: 0.72, height: 7); HBar(level: 0.7, height: 7) }
            if proposed {
                LevelHistory(values: sampleHistory(95, seed: 1.3), gapAt: [60], height: 20)
            }
            Divider()
            ForEach([("Live Room 1–8", IdleAwareBar.State.level(0.66)), ("Stagebox-1 TX 1–2", .noData), ("Talkback Mic", .silent)], id: \.0) { name, state in
                HStack(spacing: 8) {
                    Image(systemName: "stop.circle.fill").font(.system(size: 15)).foregroundStyle(amber)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(name).font(.system(size: 12, weight: .medium))
                        Group {
                            if proposed { IdleAwareBar(state: state, height: 4) }
                            else {
                                switch state { case .level(let v): HBar(level: v, height: 4); default: HBar(level: 0, height: 4) }
                            }
                        }.frame(width: 90)
                    }
                    Spacer()
                }
            }
        }
        .padding(12)
    }
}
