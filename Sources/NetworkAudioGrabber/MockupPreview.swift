import SwiftUI
import AppKit

/// `NetworkAudioGrabber --mockup <folder>` draws **proposals** for the full window, not the app.
///
/// Development tooling, and deliberately separate from `RenderPreview`: these views touch no
/// `AppState`, drive no audio and are wired to nothing. They exist to be looked at and argued
/// with before any of the real layout is disturbed, which is cheaper than rebuilding the window
/// three times to find out which arrangement reads best.
///
/// They share the app's real components where those are state-free — `Chip`, `MeterStrip`, the
/// section-header shape, the type sizes — so the comparison is about arrangement rather than
/// about one of them being a sketch.
enum MockupPreview {

    // MARK: - Mock data
    //
    // Names and addresses are a synthetic set: a shot of the real app shows someone's machines
    // and streams.

    struct Row: Identifiable {
        let id = UUID()
        var name: String
        var address: String
        var source: DiscoverySource
        var channels: Int
        var mix: String
        var peak: Float
        var joined: Bool
        var favourite = false
        var muted = false
        var soloed = false
        var jitter: Double = 0.2
        var buffer: Double = 14.8
        var lost: Int = 0
        var trim: Double = 0
    }

    static let rows: [Row] = [
        Row(name: "Dub Stage 7.1", address: "233.252.0.14:5004", source: .ravenna,
            channels: 8, mix: "—", peak: 0, joined: false),
        Row(name: "Edit Bay 3 Monitor", address: "233.252.0.13:5004", source: .sap,
            channels: 6, mix: "—", peak: 0, joined: false),
        Row(name: "Live Room 1-8", address: "233.252.0.10:5004", source: .ravenna,
            channels: 8, mix: "7.1 → 2.0", peak: 0.52, joined: true, favourite: true,
            soloed: true, jitter: 0.18, buffer: 14.9, trim: 0),
        Row(name: "Ref Mix (manual)", address: "233.252.0.15:5004", source: .manual,
            channels: 2, mix: "—", peak: 0, joined: false),
        Row(name: "Stagebox-1 TX 1-2", address: "233.252.0.12:5004", source: .dante,
            channels: 2, mix: "Ch 1/2", peak: 0.11, joined: true, jitter: 0.41,
            buffer: 12.2, lost: 3),
        Row(name: "Studio A 5.1 Bed", address: "233.252.0.11:5004", source: .ravenna,
            channels: 6, mix: "5.1 → 2.0", peak: 0.31, joined: true, muted: true,
            jitter: 0.22, buffer: 14.7),
        Row(name: "Foley B Spot", address: "233.252.0.16:5004", source: .ravenna,
            channels: 2, mix: "—", peak: 0, joined: false),
        Row(name: "Music Stem L/R", address: "233.252.0.17:5004", source: .dante,
            channels: 2, mix: "—", peak: 0, joined: false),
        Row(name: "VO Booth 2", address: "233.252.0.18:5004", source: .sap,
            channels: 1, mix: "—", peak: 0, joined: false),
        Row(name: "Cinematics 5.1", address: "233.252.0.19:5004", source: .ravenna,
            channels: 6, mix: "—", peak: 0, joined: false),
        Row(name: "Example Stream B", address: "233.252.0.20:5004", source: .dante,
            channels: 2, mix: "—", peak: 0, joined: false),
        Row(name: "Stagebox-2 TX 1-8", address: "233.252.0.21:5004", source: .dante,
            channels: 8, mix: "—", peak: 0, joined: false),
    ]

    /// Bus levels for the output meters, so the three figures agree with each other.
    static let busLevels: [Float] = [0.62, 0.58, 0.31, 0.12, 0.22, 0.19, 0, 0]

    /// A minute of short-term loudness, for the history strip in fig 2 and 3.
    static let history: [Double] = (0..<120).map { i in
        let t = Double(i) / 12
        return -23 + 2.4 * sin(t) + 1.1 * sin(t * 2.7) + 0.6 * sin(t * 6.1)
    }

    // MARK: - Entry point

    @MainActor
    static func run(arguments: [String]) {
        let outDir = value(for: "--mockup", in: arguments) ?? NSTemporaryDirectory()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()

        let size = CGSize(width: 1120, height: 692)
        for (name, view) in [("mock-A-inspector-simple", AnyView(SelectLayout(detailed: false))),
                             ("mock-A-inspector-detailed", AnyView(SelectLayout(detailed: true))),
                             ("mock-B-inline-simple", AnyView(InlineLayout(detailed: false))),
                             ("mock-B-inline-detailed", AnyView(InlineLayout(detailed: true))),
                             ("mock-B-selection", AnyView(SelectionStudy())),
                             ("mock-2-dock", AnyView(DockLayout())),
                             ("mock-3-three", AnyView(ThreePaneLayout()))] {
            capture(view, size: size, to: "\(outDir)/\(name).png")
        }
        print("Wrote mock-A-inspector-{simple,detailed}, mock-B-inline-{simple,detailed}, "
              + "mock-2-dock and mock-3-three to \(outDir)")
        exit(0)
    }

    private static func value(for flag: String, in arguments: [String]) -> String? {
        guard let i = arguments.firstIndex(of: flag), arguments.count > i + 1 else { return nil }
        let next = arguments[i + 1]
        return next.hasPrefix("--") ? nil : next
    }

    @MainActor
    private static func capture<V: View>(_ view: V, size: CGSize, to path: String) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(
            rootView: view.frame(width: size.width, height: size.height))
        window.orderFrontRegardless()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(2.0))
        window.displayIfNeeded()

        // **This needs a live display, and there is no offscreen substitute.** The window
        // server sees the whole composited tree; `cacheDisplay` redraws the views and misses
        // everything SwiftUI has already drawn (most of the text) in the process appearance
        // rather than the window's, and `CALayer.render` returns the same gaps upside down.
        // Both were tried. So when the screen is asleep or locked the honest thing is to write
        // nothing and say so — a silently blank mockup is worse than no mockup, and it
        // overwrites the last good one.
        var written = false
        for attempt in 1...3 {
            let id = CGWindowID(window.windowNumber)
            if let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, id,
                                                [.boundsIgnoreFraming, .bestResolution]),
               cg.width > 10 {
                let rep = NSBitmapImageRep(cgImage: cg)
                if !isBlank(rep), let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                    written = true
                    break
                }
            }
            if attempt < 3 {
                window.displayIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(1.0))
            }
        }
        if !written {
            let name = (path as NSString).lastPathComponent
            let message = name + ": the window server returned a blank frame, so nothing was "
                + "written. This needs the display awake and unlocked — try `caffeinate -u -t 5` "
                + "and run it again.\n"
            FileHandle.standardError.write(Data(message.utf8))
        }
        window.orderOut(nil)
    }

    /// One flat colour across a coarse grid: an empty frame from a sleeping window server.
    private static func isBlank(_ rep: NSBitmapImageRep) -> Bool {
        let xs = stride(from: 4, to: rep.pixelsWide - 4, by: max(1, rep.pixelsWide / 24))
        let ys = stride(from: 4, to: rep.pixelsHigh - 4, by: max(1, rep.pixelsHigh / 24))
        var first: NSColor?
        for x in xs {
            for y in ys {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                guard let seen = first else { first = c; continue }
                if abs(c.redComponent - seen.redComponent) > 0.02
                    || abs(c.greenComponent - seen.greenComponent) > 0.02
                    || abs(c.blueComponent - seen.blueComponent) > 0.02 { return false }
            }
        }
        return true
    }
}

// MARK: - Shared mock furniture

/// The app's real top bar, redrawn without state so the mockups start from the same place.
private struct MockTopBar: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label("en5", systemImage: "chevron.down")
                    .labelStyle(.titleOnly)
                    .font(.system(size: 11, weight: .semibold))
                Divider().frame(height: 14)
                HStack(spacing: 5) {
                    Image(systemName: "headphones").font(.system(size: 10))
                    Text(verbatim: "Headphones").font(.system(size: 11))
                    Text(verbatim: "48 kHz").font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text(verbatim: "8 ch").font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text(verbatim: "Filter").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))
                .frame(width: 150)
                Text(verbatim: "ACTIVE")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.10)))
                ForEach(["rectangle.split.2x1", "sidebar.right", "circle.lefthalf.filled", "gear"],
                        id: \.self) { icon in
                    Image(systemName: icon).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            Divider()
        }
    }
}

private struct MockHeader: View {
    var title: String
    var trailing: String = ""
    var body: some View {
        HStack {
            Text(verbatim: title)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.tertiary)
            Spacer()
            Text(verbatim: trailing)
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .padding(.bottom, 6)
    }
}

/// A caption strip, so an image out of context still says which proposal it is.
private struct MockCaption: View {
    var title: String
    var note: String
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Text(verbatim: title)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                Text(verbatim: note)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(verbatim: "mockup — not wired up")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .frame(height: 24)
            .background(Color.primary.opacity(0.05))
        }
    }
}

private struct MockMeter: View {
    var levels: [Float]
    var thickness: CGFloat
    var slot: CGFloat
    var length: CGFloat
    var horizontal = false
    var hold: Float? = nil
    /// Channels not reaching the output — outside a channel solo, or muted.
    var dimmed: Set<Int> = []
    var body: some View {
        MeterStrip(count: levels.count,
                   orientation: horizontal ? .horizontal : .vertical,
                   thickness: thickness, slot: slot, length: length,
                   fps: 0, paused: true,
                   level: { levels[min($0, levels.count - 1)] },
                   hold: { hold },
                   isDimmed: { dimmed.contains($0) })
            .frame(width: horizontal ? length : slot * CGFloat(levels.count),
                   height: horizontal ? slot * CGFloat(levels.count) : length)
    }
}

/// One line per stream, with everything the two-line row carried. **The proposal all three
/// mockups share**: the list is a list, and detail belongs to the one stream being looked at.
private struct MockDenseRow: View {
    var row: MockupPreview.Row
    var selected = false
    var showHealth = true
    var showAddress = true
    /// Tighter columns for a list that is a sidebar rather than the whole window: the stream's
    /// name is the column that must not be the one that gives way.
    var narrow = false
    var height: CGFloat = 26
    /// Set false when an enclosing container draws the selection, so the row does not paint a
    /// second, differently-shaped one inside it.
    var chrome = true

    private var mixWidth: CGFloat { narrow ? 46 : 58 }
    private var meterWidth: CGFloat { narrow ? 44 : 70 }
    private var chipWidth: CGFloat { narrow ? 84 : 96 }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: row.favourite ? "star.fill" : "star")
                .font(.system(size: 9))
                .foregroundStyle(row.favourite ? Color.yellow : Color.secondary.opacity(0.5))
            Image(systemName: row.joined ? "largecircle.fill.circle" : "play.circle")
                .font(.system(size: 12))
                .foregroundStyle(row.joined ? Color.accentColor : Color.secondary)
            Text(verbatim: row.name)
                .font(.system(size: 11, weight: row.joined ? .semibold : .regular))
                .lineLimit(1)
            if showAddress {
                Text(verbatim: row.address)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if row.joined {
                Text(verbatim: row.mix)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: mixWidth, alignment: .trailing)
                MockMeter(levels: [row.peak], thickness: 5, slot: 5, length: meterWidth,
                          horizontal: true)
                HStack(spacing: 3) {
                    Text(verbatim: "M").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(row.muted ? Color.white : Color.secondary)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(row.muted ? Color.red.opacity(0.8)
                                                             : Color.primary.opacity(0.08)))
                    Text(verbatim: "S").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(row.soloed ? Color.black : Color.secondary)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(row.soloed ? Color.yellow
                                                              : Color.primary.opacity(0.08)))
                }
            } else {
                Text(verbatim: "—")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.quaternary)
                    .frame(width: mixWidth, alignment: .trailing)
                Color.clear.frame(width: meterWidth, height: 5)
                Color.clear.frame(width: 42, height: 5)
            }
            // Fixed width, so the column titles above can line up with the columns. Natural
            // width is what makes a "column" in this list a coincidence rather than a column.
            HStack(spacing: 5) {
                Chip(text: row.source.rawValue, tint: .tint(for: row.source), filled: true)
                Chip(text: "\(row.channels) ch")
                Spacer(minLength: 0)
            }
            .frame(width: chipWidth)
            if showHealth {
                // **New, and the point of the space saved.** The figures already exist behind
                // each row's disclosure; this puts the one that matters on the row.
                Text(verbatim: row.joined ? String(format: "%.2f ms", row.jitter) : "")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(row.jitter > 0.35 ? Color.orange : Color.secondary)
                    .frame(width: 52, alignment: .trailing)
                Circle()
                    .fill(row.joined ? (row.lost > 0 ? Color.orange : Color.green)
                                     : Color.secondary.opacity(0.25))
                    .frame(width: 6, height: 6)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(!chrome ? Color.clear
                  : (selected ? Color.accentColor.opacity(0.16)
                     : (row.joined ? Color.primary.opacity(0.05) : Color.clear))))
    }
}

private struct MockColumnTitles: View {
    var showHealth = true
    var body: some View {
        HStack(spacing: 7) {
            Color.clear.frame(width: 9, height: 1)
            Color.clear.frame(width: 12, height: 1)
            Text(verbatim: "STREAM").frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: "TO BUS").frame(width: 58, alignment: .trailing)
            Text(verbatim: "LEVEL").frame(width: 70, alignment: .leading)
            Text(verbatim: "MUTE/SOLO").frame(width: 42, alignment: .leading)
            Text(verbatim: "SOURCE").frame(width: 96, alignment: .leading)
            if showHealth {
                Text(verbatim: "JITTER").frame(width: 52, alignment: .trailing)
            }
            Color.clear.frame(width: 6, height: 1)
            Color.clear.frame(width: 9, height: 1)
        }
        .font(.system(size: 8, weight: .bold, design: .rounded))
        .foregroundStyle(.quaternary)
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 3)
    }
}

// MARK: - Panel pieces, sized for the room each layout gives them

private struct MockOutputBlock: View {
    var barLength: CGFloat
    var showRouting: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MockHeader(title: "OUTPUT", trailing: "8 of 16 ch · 48 kHz")
            HStack(alignment: .bottom, spacing: 12) {
                VStack(spacing: 3) {
                    MockMeter(levels: MockupPreview.busLevels, thickness: 9, slot: 13,
                              length: barLength, hold: 0.74)
                    HStack(spacing: 0) {
                        ForEach(["L", "R", "C", "LF", "Ls", "Rs", "Lr", "Rr"], id: \.self) {
                            Text(verbatim: $0)
                                .font(.system(size: 7, weight: .semibold, design: .rounded))
                                .foregroundStyle(.tertiary)
                                .frame(width: 13)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(verbatim: "−3.3")
                            .font(.system(size: 26, weight: .medium, design: .rounded))
                            .monospacedDigit()
                        VStack(alignment: .leading, spacing: 0) {
                            Text(verbatim: "dBFS").font(.system(size: 8))
                            Text(verbatim: "max").font(.system(size: 8))
                        }
                        .foregroundStyle(.tertiary)
                        Circle().fill(Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                    }
                    // **New:** true peak beside the sample peak, and how long since a clip.
                    // Detailed only — true peak is the one addition with real audio-thread
                    // cost, so a mockup should not imply it comes for free in the plain view.
                    if showRouting {
                        HStack(spacing: 6) {
                            Text(verbatim: "−2.9 dBTP")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(verbatim: "no clip 12m")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "speaker.wave.2.fill").font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Capsule().fill(Color.primary.opacity(0.12)).frame(height: 4)
                            .overlay(alignment: .leading) {
                                Capsule().fill(Color.accentColor).frame(width: 118, height: 4)
                            }
                        Text(verbatim: "100 %").font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    HStack(spacing: 6) {
                        ForEach(["DIM", "MONO"], id: \.self) { title in
                            Text(verbatim: title)
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(Capsule().fill(Color.primary.opacity(0.10)))
                        }
                        Text(verbatim: "8 of 16 ch")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                    if showRouting {
                        // **New:** which physical output each bus channel lands on, which is
                        // currently something you find out by playing a tone.
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: "ROUTING")
                                .font(.system(size: 8, weight: .bold, design: .rounded))
                                .foregroundStyle(.quaternary)
                            Text(verbatim: "bus 1–8  →  device out 1–8")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            Text(verbatim: "device buffer 512 · 0 underruns · 10.7 ms")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }
}

private struct MockLoudnessBlock: View {
    var wide: Bool
    var showHistory: Bool
    var showMomentary = true
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MockHeader(title: "LOUDNESS", trailing: "60 s · target −23")
            VStack(alignment: .leading, spacing: wide ? 7 : 5) {
                // **New:** momentary, which is the reading a spike shows up in first.
                let readings: [(String, String, String, Color)] =
                    (showMomentary ? [("LUFS-M", "−21.8", "+1.2", Color.green)] : [])
                    + [("LUFS-S", "−21.2", "+1.8", Color.yellow),
                       ("LUFS-W", "−23.1", "−0.1", Color.green),
                       ("LUFS-I", "−22.8", "+0.2", Color.green)]
                ForEach(readings, id: \.0) { row in
                    HStack(spacing: 8) {
                        Text(verbatim: row.0)
                            .font(.system(size: wide ? 10 : 9, weight: .semibold,
                                          design: .rounded))
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .leading)
                        Text(verbatim: row.1)
                            .font(.system(size: wide ? 20 : 15, weight: .medium,
                                          design: .rounded))
                            .monospacedDigit()
                            .frame(width: wide ? 76 : 60, alignment: .trailing)
                        Capsule().fill(Color.primary.opacity(0.10)).frame(height: 5)
                            .overlay(alignment: .center) {
                                Circle().fill(row.3).frame(width: 7, height: 7)
                                    .offset(x: row.2.hasPrefix("+") ? 14 : -4)
                            }
                        Text(verbatim: row.2)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(row.3)
                            .frame(width: 38, alignment: .trailing)
                    }
                }
                // **New:** loudness range, the other half of a delivery spec.
                HStack(spacing: 8) {
                    Text(verbatim: "LRA")
                        .font(.system(size: wide ? 10 : 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .leading)
                    Text(verbatim: "6.4 LU")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                if showHistory {
                    // **New:** a minute of short-term loudness, so a drift is visible as a
                    // shape rather than inferred from a number that moved. Labelled, because
                    // an unlabelled line on a dark box is a decoration — the first question it
                    // got was "what is this showing?", which is the whole answer.
                    HStack {
                        Text(verbatim: "LUFS-S, LAST 60 s")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(verbatim: "dashed = target −23")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.05))
                        Canvas { ctx, size in
                            let series = MockupPreview.history
                            let lo = -34.0, hi = -14.0
                            var path = Path()
                            for (i, v) in series.enumerated() {
                                let x = size.width * CGFloat(i) / CGFloat(series.count - 1)
                                let y = size.height * CGFloat(1 - (v - lo) / (hi - lo))
                                i == 0 ? path.move(to: CGPoint(x: x, y: y))
                                       : path.addLine(to: CGPoint(x: x, y: y))
                            }
                            ctx.stroke(path, with: .color(.green.opacity(0.85)),
                                       lineWidth: 1.4)
                            let targetY = size.height * CGFloat(1 - (-23.0 - lo) / (hi - lo))
                            var target = Path()
                            target.move(to: CGPoint(x: 0, y: targetY))
                            target.addLine(to: CGPoint(x: size.width, y: targetY))
                            ctx.stroke(target, with: .color(.white.opacity(0.25)),
                                       style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        }
                        .padding(4)
                    }
                    .frame(height: wide ? 62 : 46)
                    .overlay(alignment: .topLeading) {
                        Text(verbatim: "−14")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 3)
                    }
                    .overlay(alignment: .bottomLeading) {
                        Text(verbatim: "−34")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 3)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }
}

private struct MockInsertsBlock: View {
    var showLatency = true
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MockHeader(title: "INSERTS", trailing: showLatency ? "2 AU · +4.2 ms" : "2 AU")
            VStack(spacing: 5) {
                ForEach([("1", "kHs 3-Band EQ", true), ("2", "Pro-Q 4", false)], id: \.0) { row in
                    HStack(spacing: 6) {
                        Text(verbatim: row.0)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        Text(verbatim: row.1)
                            .font(.system(size: 10)).lineLimit(1)
                        Spacer(minLength: 4)
                        // **New:** the latency each plugin adds, which delta already knows.
                        if showLatency {
                            Text(verbatim: row.2 ? "0.0 ms" : "4.2 ms")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        Text(verbatim: "BYP")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange.opacity(0.85)))
                            .foregroundStyle(.black)
                        Text(verbatim: "Δ")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                        Image(systemName: "macwindow").font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill(Color.primary.opacity(0.05)))
                }
                HStack {
                    Text(verbatim: "3  Empty")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.horizontal, 7).padding(.vertical, 4)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }
}

/// The selected stream, in the room the dense list frees up: per-channel meters big enough to
/// read, the assumptions spelled out, and the diagnostics that are behind a disclosure today.
private struct MockStreamDetail: View {
    var row: MockupPreview.Row
    var barHeight: CGFloat
    var showDiagnostics: Bool
    /// Drops the address from the header where the block is a column rather than a pane.
    var showAddress = true
    /// The channel-order override. Nothing in an AES67 stream declares its order, so this is
    /// always an assumption — but changing it is an expert's job, and the default comes
    /// from Settings. Simple hides the menu; it earns its place back the moment a stream is
    /// set to something other than the default, which is the one case that must never be silent.
    var showOrder = true

    /// Laid out as two columns rather than a stack: the meters are tall and narrow, so a
    /// stacked block leaves the whole middle of the window empty and then puts the figures
    /// *below* it, pushing rows off the list for space that was already there.
    var inline = false
    /// **Per-channel solo**, which in this app lives on the input's channel labels: click one
    /// and only those channels reach the bus, everything else greys out. Shown
    /// engaged in one of the two shots because the state is the half worth seeing — the
    /// control is on the labels in both.
    var solo: Set<Int> = []

    private let labels = ["L", "R", "C", "LFE", "Ls", "Rs", "Lrs", "Rrs"]
    private let levels: [Float] = [0.52, 0.48, 0.30, 0.10, 0.22, 0.20, 0.44, 0.41]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MockHeader(title: "SELECTED INPUT", trailing: "\(row.channels) ch · L24 · 1 ms")
            if inline {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        nameRow
                        meters
                    }
                    .frame(width: 290, alignment: .leading)
                    VStack(alignment: .leading, spacing: 10) {
                        controls
                        // Simple has no diagnostics to put here, and an empty right-hand
                        // two-thirds is what made the stacked version look wasteful in the
                        // first place. What goes there is exactly what every row lost when the
                        // list went to one line — shown once, for the stream being looked at,
                        // instead of twelve times for streams nobody is looking at.
                        if showDiagnostics { diagnostics } else { facts }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    nameRow
                    meters
                    controls
                    if showDiagnostics {
                        Divider()
                        diagnostics
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
    }

    private var nameRow: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.green).frame(width: 6, height: 6)
            Text(verbatim: row.name).font(.system(size: 12, weight: .semibold))
            Chip(text: row.source.rawValue, tint: .tint(for: row.source), filled: true)
            Spacer()
            if showAddress {
                Text(verbatim: row.address)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    private var meters: some View {
        VStack(alignment: .leading, spacing: 3) {
            MockMeter(levels: levels, thickness: 13, slot: 20, length: barHeight,
                      dimmed: solo.isEmpty ? [] : Set(0..<labels.count).subtracting(solo))
            HStack(spacing: 0) {
                ForEach(Array(labels.enumerated()), id: \.offset) { i, name in
                    Text(verbatim: name)
                        .font(.system(size: 8, weight: .semibold, design: .rounded))
                        .foregroundStyle(solo.contains(i) ? Color.black : Color.secondary)
                        .frame(width: 18, height: 12)
                        .background(RoundedRectangle(cornerRadius: 3)
                            .fill(solo.contains(i) ? Color.yellow : Color.primary.opacity(0.07)))
                        .frame(width: 20)
                }
            }
            if !solo.isEmpty {
                HStack(spacing: 5) {
                    Text(verbatim: "SOLO " + solo.sorted().map { labels[$0] }.joined(separator: " "))
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(Color.yellow))
                    Text(verbatim: "Clear")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                mockMenu("7.1 → 2.0 fold")
                if showOrder { mockMenu("SMPTE order") }
                Text(verbatim: "LFE dropped")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 6) {
                Image(systemName: "dial.low").font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Capsule().fill(Color.primary.opacity(0.12)).frame(height: 4)
                    .overlay(alignment: .center) {
                        Circle().fill(Color.white.opacity(0.9)).frame(width: 11, height: 11)
                    }
                Text(verbatim: "+0.0 dB")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// The stream's own facts: what the second line of every row used to carry.
    private var facts: some View {
        // Three columns, not four: the group address is the widest thing here and truncating
        // an address is the one thing that makes it useless.
        let cells: [(String, String)] = [
            ("source", row.source.rawValue), ("format", "L24 · 48 kHz · 1 ms"),
            ("group", row.address),
        ]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading),
                                        count: 3), spacing: 8) {
            ForEach(cells, id: \.0) { cell in
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: cell.0.uppercased())
                        .font(.system(size: 7, weight: .bold, design: .rounded))
                        .foregroundStyle(.quaternary)
                    Text(verbatim: cell.1)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    /// Everything here is already measured and already in `StreamFigures` — it is only ever
    /// seen one row at a time behind a chevron.
    private var diagnostics: some View {
        let cells: [(String, String, Bool)] = [
            ("jitter", "0.18 ms", false), ("worst", "0.94 ms", false),
            ("buffer", "14.9 ms", false), ("low water", "11.2 ms", false),
            ("drift", "+1.4 ppm", false), ("lost", "0", false),
            ("underruns", "0", false), ("packets", "1 284 902", false),
        ]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading),
                                        count: 4), spacing: 8) {
            ForEach(cells, id: \.0) { cell in
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: cell.0.uppercased())
                        .font(.system(size: 7, weight: .bold, design: .rounded))
                        .foregroundStyle(.quaternary)
                    Text(verbatim: cell.1)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(cell.2 ? Color.orange : Color.secondary)
                }
            }
        }
    }

    private func mockMenu(_ title: String) -> some View {
        HStack(spacing: 3) {
            Text(verbatim: title).font(.system(size: 10))
            Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))
    }
}

private struct MockFooter: View {
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                Text(verbatim: "SOLO")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.yellow)
                Text(verbatim: "Clear")
                    .font(.system(size: 10))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill(Color.primary.opacity(0.10)))
                Spacer()
                Text(verbatim: "3 of 12")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(verbatim: "Stop all")
                    .font(.system(size: 10))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill(Color.primary.opacity(0.10)))
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
        }
    }
}

// MARK: - Fig 1 — dense list, wider panel

private struct DenseLayout: View {
    var body: some View {
        VStack(spacing: 0) {
            MockTopBar()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    MockColumnTitles()
                    Divider()
                    // Ten of the twelve, because the expanded row takes the space of four and
                    // the list scrolls. A mockup that overflows its own window clips the parts
                    // it is arguing about, which is worse than showing two fewer rows.
                    VStack(spacing: 2) {
                        ForEach(Array(MockupPreview.rows.prefix(10).enumerated()),
                                id: \.element.id) { i, row in
                            MockDenseRow(row: row, selected: i == 2)
                            // **The detail opens in place.** A one-line list only works if the
                            // line it hides can be got back, and the row that is expanded is
                            // the row being worked on — which is also where the eye already is.
                            if i == 2 {
                                MockStreamDetail(row: row, barHeight: 70, showDiagnostics: true)
                                    .background(RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.primary.opacity(0.05)))
                                    .padding(.bottom, 3)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                    Spacer(minLength: 0)
                    MockFooter()
                }
                .frame(maxWidth: .infinity)
                Divider()
                VStack(spacing: 0) {
                    MockOutputBlock(barLength: 150, showRouting: true)
                    Divider()
                    MockLoudnessBlock(wide: true, showHistory: true)
                    Divider()
                    MockInsertsBlock()
                    Spacer(minLength: 0)
                }
                .frame(width: 352)
                .background(Color.primary.opacity(0.03))
            }
            MockCaption(title: "FIG 1 — dense list, wider panel",
                        note: "one line per stream · panel 268 → 352 · monitor path first, "
                            + "input detail last")
        }
    }
}

// MARK: - Fig 2 — monitor dock along the bottom

private struct DockLayout: View {
    var body: some View {
        VStack(spacing: 0) {
            MockTopBar()
            VStack(spacing: 0) {
                MockColumnTitles()
                Divider()
                VStack(spacing: 2) {
                    ForEach(Array(MockupPreview.rows.enumerated()), id: \.element.id) { i, row in
                        MockDenseRow(row: row, selected: i == 2)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)
                Spacer(minLength: 0)
            }
            Divider()
            HStack(spacing: 0) {
                MockOutputBlock(barLength: 118, showRouting: false)
                    .frame(width: 322)
                Divider()
                MockLoudnessBlock(wide: false, showHistory: true)
                    .frame(width: 252)
                Divider()
                MockInsertsBlock()
                    .frame(width: 242)
                Divider()
                MockStreamDetail(row: MockupPreview.rows[2], barHeight: 56,
                                 showDiagnostics: false, showAddress: false)
                    .frame(maxWidth: .infinity)
            }
            .frame(height: 232)
            .background(Color.primary.opacity(0.03))
            MockFooter()
            MockCaption(title: "FIG 2 — monitor dock along the bottom",
                        note: "list takes the full width · output, loudness, inserts and the "
                            + "selected input side by side")
        }
    }
}

// MARK: - Fig 3 — three panes

private struct ThreePaneLayout: View {
    var body: some View {
        VStack(spacing: 0) {
            MockTopBar()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    MockHeader(title: "STREAMS", trailing: "3 of 12")
                    Divider()
                    VStack(spacing: 2) {
                        ForEach(Array(MockupPreview.rows.enumerated()), id: \.element.id) { i, row in
                            MockDenseRow(row: row, selected: i == 2, showHealth: false,
                                         showAddress: false, narrow: true)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.top, 4)
                    Spacer(minLength: 0)
                    MockFooter()
                }
                .frame(width: 420)
                Divider()
                VStack(spacing: 0) {
                    MockStreamDetail(row: MockupPreview.rows[2], barHeight: 132,
                                     showDiagnostics: true)
                    Divider()
                    MockInsertsBlock()
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
                .background(Color.primary.opacity(0.02))
                Divider()
                VStack(spacing: 0) {
                    MockOutputBlock(barLength: 150, showRouting: true)
                    Divider()
                    MockLoudnessBlock(wide: false, showHistory: true)
                    Spacer(minLength: 0)
                }
                .frame(width: 300)
                .background(Color.primary.opacity(0.03))
            }
            MockCaption(title: "FIG 3 — list · selected input · master rail",
                        note: "the middle pane is the stream you are working on, at a size "
                            + "you can read")
        }
    }
}

// MARK: - Fig 1b — selection instead of expansion, in two densities

/// The same dense list, with the detail in the panel rather than pushed into the list.
///
/// The list never reflows: clicking a row fills `SELECTED INPUT` at the top of the panel, which
/// is the sidebar/list/inspector shape macOS uses everywhere (Mail, Xcode, Finder) rather than
/// the outline-expansion shape a DAW track list uses. `detailed` is the proposed
/// **Simple / Detailed** switch, and is the only thing that differs between the two shots.
private struct SelectLayout: View {
    var detailed: Bool

    var body: some View {
        VStack(spacing: 0) {
            MockTopBar()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    MockColumnTitles(showHealth: detailed)
                    Divider()
                    VStack(spacing: 2) {
                        ForEach(Array(MockupPreview.rows.enumerated()), id: \.element.id) { i, row in
                            MockDenseRow(row: row, selected: i == 2, showHealth: detailed,
                                         showAddress: false, height: 28)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                    Spacer(minLength: 0)
                    MockFooter()
                }
                .frame(maxWidth: .infinity)
                Divider()
                ScrollView {
                    VStack(spacing: 0) {
                        // The selected stream sits at the top of the monitor path, which is
                        // also where it sits in the signal.
                        // **In the order the audio travels**: the stream arrives, the inserts
                        // process it, the bus plays it out, and the loudness is measured on
                        // what left. Putting output above the inserts read as prominence and
                        // was really just the wrong order.
                        MockStreamDetail(row: MockupPreview.rows[2], barHeight: 74,
                                         showDiagnostics: detailed, showOrder: detailed,
                                         solo: detailed ? [6, 7] : [])
                        Divider()
                        MockInsertsBlock(showLatency: detailed)
                        Divider()
                        MockOutputBlock(barLength: 112, showRouting: detailed)
                        Divider()
                        MockLoudnessBlock(wide: true, showHistory: detailed,
                                          showMomentary: detailed)
                        Spacer(minLength: 0)
                    }
                }
                .frame(width: 352)
                .background(Color.primary.opacity(0.03))
            }
            MockCaption(title: detailed ? "FIG 1B — selection, not expansion · DETAILED"
                                        : "FIG 1B — selection, not expansion · SIMPLE",
                        note: detailed
                            ? "everything the figures already measure, behind one setting"
                            : "name, source, channels, level, mute/solo — and nothing else")
        }
    }
}

// MARK: - Option B — the detail drops down under its own row

/// The same dense list, with the selected stream opening **in place** and the far-right input
/// section gone entirely, which frees the whole panel for the DSP chain.
///
/// Two columns inside the expanded block, not a stack: the channel meters are tall and narrow,
/// so stacking left the middle of the window empty and then put the figures below it, pushing
/// rows off the list for room that was already on screen.
private struct InlineLayout: View {
    var detailed: Bool

    var body: some View {
        VStack(spacing: 0) {
            MockTopBar()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    MockColumnTitles(showHealth: detailed)
                    Divider()
                    VStack(spacing: 2) {
                        ForEach(Array(MockupPreview.rows.prefix(11).enumerated()),
                                id: \.element.id) { i, row in
                            MockDenseRow(row: row, selected: i == 2, showHealth: detailed,
                                         showAddress: false, height: 28)
                            if i == 2 {
                                MockStreamDetail(row: row, barHeight: 70,
                                                 showDiagnostics: detailed,
                                                 showAddress: false,
                                                 showOrder: detailed, inline: true,
                                                 solo: detailed ? [6, 7] : [])
                                    .background(RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.primary.opacity(0.05)))
                                    .padding(.bottom, 3)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                    Spacer(minLength: 0)
                    MockFooter()
                }
                .frame(maxWidth: .infinity)
                Divider()
                // The panel is the DSP chain and nothing else: what the inserts do to the
                // signal, what leaves on the bus, and what that measures.
                VStack(spacing: 0) {
                    MockInsertsBlock(showLatency: detailed)
                    Divider()
                    MockOutputBlock(barLength: 150, showRouting: detailed)
                    Divider()
                    MockLoudnessBlock(wide: true, showHistory: detailed,
                                      showMomentary: detailed)
                    Spacer(minLength: 0)
                }
                .frame(width: 352)
                .background(Color.primary.opacity(0.03))
            }
            MockCaption(title: detailed ? "OPTION B — detail in place · DETAILED"
                                        : "OPTION B — detail in place · SIMPLE",
                        note: "two columns in the expanded row · panel is the DSP chain: "
                            + "inserts, output, loudness")
        }
    }
}

// MARK: - How far the selection colour should reach

/// Three treatments of the selected stream and its detail, and nothing else, because the
/// question — does the tint cover the whole box? — is not answerable from a description.
private struct SelectionStudy: View {
    private var row: MockupPreview.Row { MockupPreview.rows[2] }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            variant("1 — as drawn now",
                    "tinted row, neutral detail: reads as two objects, and the detail "
                    + "looks like a panel that happened to appear") {
                VStack(spacing: 2) {
                    MockDenseRow(row: row, selected: true, showHealth: true,
                                 showAddress: false, height: 28)
                    detail
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(Color.primary.opacity(0.05)))
                }
            }

            variant("2 — the whole box in the selection colour",
                    "one object, unmistakably — but a wash behind small monospace figures, "
                    + "and behind meters whose colour is the reading") {
                VStack(spacing: 0) {
                    MockDenseRow(row: row, selected: true, showHealth: true,
                                 showAddress: false, height: 28, chrome: false)
                    detail
                }
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.16)))
            }

            variant("3 — one container, two weights",
                    "same hue throughout and a full-height edge, with the detail at a third "
                    + "of the strength so the figures keep their contrast") {
                VStack(spacing: 0) {
                    MockDenseRow(row: row, selected: true, showHealth: true,
                                 showAddress: false, height: 28, chrome: false)
                        .background(Color.accentColor.opacity(0.18))
                    detail
                        .background(Color.accentColor.opacity(0.06))
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.accentColor).frame(width: 3)
                }
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.accentColor.opacity(0.35), lineWidth: 1))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.primary.opacity(0.02))
    }

    private var detail: some View {
        MockStreamDetail(row: row, barHeight: 70, showDiagnostics: true, showAddress: false,
                         showOrder: true, inline: true, solo: [6, 7])
    }

    private func variant<V: View>(_ title: String, _ note: String,
                                  @ViewBuilder content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(verbatim: title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
            Text(verbatim: note)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            content()
        }
    }
}
