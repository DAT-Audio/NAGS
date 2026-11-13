import SwiftUI

// MOCKUPS: where the Sender's controls could live inside the
// Grabber. Drawn by `--mockup-send` with the app's own parts; nothing here runs in the app unless
// `AppState.previewSendLayout` is set, which only the render tool does. Made-up names and
// documentation addresses throughout.

/// The small "● Sending · 2" in the status bar and the compact footer, shown only while sending:
/// green when audio is going out, amber when the Mac is silent or macOS delivers nothing.
struct SendingIndicator: View {
    let targets: Int
    var ok = true

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(ok ? Color.green : Color.orange).frame(width: 7, height: 7)
            Text(verbatim: "Sending · \(targets)").font(.system(size: 11)).monospacedDigit()
                .foregroundStyle(ok ? Color.primary : Color.orange)
        }
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .help(ok ? "Sending this Mac's audio to \(targets) Grabbers. Click for the Send controls."
                 : "Sending, but this Mac is silent. Click for the Send controls.")
    }
}

/// The Sender's controls, as they would sit inside the Grabber: this Mac's stream, its meter,
/// Findable, and who is receiving.
struct SendControlsMock: View {
    @Environment(AppState.self) var state
    @Environment(\.colorScheme) private var scheme
    var compact = false

    private struct Row: Identifiable { let id = UUID(); let name: String; let address: String; let status: String; let on: Bool; let star: Bool; let listener: Bool; let muted: Bool }
    private let rows: [Row] = [
        .init(name: "Control Room", address: "192.0.2.40", status: "Listening", on: true, star: false, listener: true, muted: false),
        .init(name: "Studio PC", address: "192.0.2.20", status: "Sending", on: true, star: true, listener: false, muted: false),
        .init(name: "192.0.2.31", address: "", status: "Sending", on: true, star: true, listener: false, muted: true),
        .init(name: "Edit Bay Grabber", address: "198.51.100.7", status: "Stopped", on: false, star: false, listener: false, muted: false),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Edit Suite Mac").font(.system(size: compact ? 14 : 17, weight: .semibold))
                Image(systemName: "pencil").font(.system(size: 10)).foregroundStyle(Color.mutedLabel)
                Spacer()
                Text("24-bit · 48 kHz · stereo").font(.system(size: 10)).foregroundStyle(Color.mutedLabel)
            }
            if !compact {
                Text("This Mac: 192.0.2.30").font(.system(size: 11)).foregroundStyle(Color.mutedLabel)
            }
            MeterStrip(count: 2, orientation: .horizontal, thickness: 4, slot: 6, length: 300,
                       level: { [0.42, 0.30][$0] })
                .frame(maxWidth: .infinity).frame(height: 12)
            HStack {
                Text("Receivers").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.mutedLabel)
                Spacer()
                Text("Findable by Grabbers").font(.system(size: 11)).foregroundStyle(Color.mutedLabel)
                Toggle("", isOn: .constant(true)).labelsHidden().controlSize(.mini)
                Image(systemName: "plus").font(.system(size: 11)).foregroundStyle(Color.mutedLabel)
            }
            VStack(spacing: 0) {
                ForEach(compact ? Array(rows.prefix(3)) : rows) { r in
                    HStack(spacing: 8) {
                        if r.listener {
                            Image(systemName: "headphones").font(.system(size: 12)).foregroundStyle(Color.mutedLabel)
                                .frame(width: 18)
                        } else {
                            PlayStopIcon(active: r.on, tint: state.tintActive(on: scheme), size: 16).frame(width: 18)
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 3) {
                                Text(verbatim: r.name).font(.system(size: 12, weight: .medium))
                                if r.star { Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(.yellow) }
                            }
                            if !r.address.isEmpty && !compact {
                                Text(verbatim: r.address).font(.system(size: 10)).foregroundStyle(Color.mutedLabel)
                            }
                        }
                        Spacer()
                        Text(r.status).font(.system(size: 11)).foregroundStyle(Color.mutedLabel)
                        if !r.listener {
                            PillToggle(title: "M", isOn: .constant(r.muted), tint: .red)
                        }
                        Image(systemName: "ellipsis").font(.system(size: 11)).foregroundStyle(state.tintActive)
                    }
                    .padding(.vertical, 5)
                    Divider().opacity(0.4)
                }
            }
            HStack {
                Text("Sending to 2 targets and 1 listening · 1.4 Mbit/s").font(.system(size: 11))
                    .foregroundStyle(Color.mutedLabel)
                Spacer()
                Button("Stop all") {}.controlSize(.small)
            }
        }
    }
}

/// Version 1: Connect… becomes Connect / Send…, a small window of its own with
/// two tabs — today's guide, and the Send controls.
struct ConnectSendWindowMock: View {
    @Environment(AppState.self) var state
    let sendTab: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("", selection: .constant(sendTab ? 1 : 0)) {
                    Text("Receive").tag(0)
                    Text("Send").tag(1)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                Spacer()
                if sendTab { SendingIndicator(targets: 2) }
            }
            // Which way the audio goes, said before anything else.
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: sendTab ? "arrow.up.forward.circle.fill" : "arrow.down.backward.circle.fill")
                    .font(.system(size: 22)).foregroundStyle(state.tintActive)
                VStack(alignment: .leading, spacing: 2) {
                    Text(sendTab ? "Send this Mac's audio to other receivers"
                                 : "Receive from Network Audio Sender on another Mac")
                        .font(.system(size: 13, weight: .semibold))
                    Text(sendTab ? "For another Grabber, Voicemeeter or any VBAN receiver. Everything "
                                   + "this Mac plays goes to the receivers you turn on."
                                 : "For a Mac running Network Audio Sender. Its stream appears in this "
                                   + "Grabber's list; AES67, RAVENNA and Dante need nothing here.")
                        .font(.system(size: 11)).foregroundStyle(Color.mutedLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            if sendTab {
                SendControlsMock()
            } else {
                // Today's guide, unchanged.
                ScrollView { ConnectToSender().padding(-18).padding(.top, 18) }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }
}

/// Version 2: a "Send" section in the signal panel, folding like Inserts.
struct SendPanelSectionMock: View {
    @Environment(AppState.self) var state
    let open: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: open ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold)).foregroundStyle(Color.mutedLabel).frame(width: 8)
                Text("Send").font(SignalPanel.headingFont).foregroundStyle(Color.mutedLabel)
                Spacer()
                if !open { SendingIndicator(targets: 2) }
            }
            if open { SendControlsMock(compact: true) }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }
}

/// Version 3: a strip under the stream list, opening upward into the full controls.
/// Version 3, round 2: a section along the bottom, taller, with
/// its own area for connections — this Mac on the left, the receivers on the right — resized
/// against the stream list by a handle, up to a maximum; folded, one line.
struct SendBottomMock: View {
    @Environment(AppState.self) var state
    @Environment(\.colorScheme) private var scheme
    let open: Bool

    var body: some View {
        VStack(spacing: 0) {
            // The handle: drag to resize against the list (between the folded line and a maximum).
            ZStack {
                Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 7)
                Capsule().fill(Color.primary.opacity(0.25)).frame(width: 36, height: 3)
            }
            HStack(spacing: 10) {
                Image(systemName: open ? "chevron.down" : "chevron.up").font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.mutedLabel)
                Text("Send").font(SignalPanel.headingFont).foregroundStyle(Color.mutedLabel)
                SendingIndicator(targets: 2)
                if !open {
                    Text("Edit Suite Mac → Control Room, Studio PC, 192.0.2.31")
                        .font(.system(size: 11)).lineLimit(1).foregroundStyle(Color.mutedLabel)
                }
                Spacer()
                Toggle("Findable by Grabbers", isOn: .constant(true)).controlSize(.mini)
                    .font(.system(size: 11)).foregroundStyle(Color.mutedLabel)
                Button("Stop sending") {}.controlSize(.small)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            if open {
                HStack(alignment: .top, spacing: 18) {
                    // This Mac: what is sent.
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Edit Suite Mac").font(.system(size: 15, weight: .semibold))
                            Image(systemName: "pencil").font(.system(size: 10)).foregroundStyle(Color.mutedLabel)
                        }
                        Text("This Mac: 192.0.2.30 · 24-bit · 48 kHz · stereo")
                            .font(.system(size: 10)).foregroundStyle(Color.mutedLabel)
                        MeterStrip(count: 2, orientation: .horizontal, thickness: 5, slot: 8, length: 260,
                                   level: { [0.42, 0.30][$0] })
                            .frame(width: 260, height: 16)
                        Text("1.4 Mbit/s").font(.system(size: 10)).monospacedDigit().foregroundStyle(Color.mutedLabel)
                    }
                    .frame(width: 280, alignment: .leading)
                    Divider()
                    // Receivers: its own area, scrolling when there are many.
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("Receivers").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.mutedLabel)
                            Spacer()
                            Label("Add", systemImage: "plus").font(.system(size: 11)).foregroundStyle(Color.mutedLabel)
                        }
                        .padding(.bottom, 4)
                        ForEach(Array([("Control Room", "192.0.2.40", "Listening", true, false),
                                       ("Studio PC", "192.0.2.20", "Sending", false, false),
                                       ("192.0.2.31", "", "Sending", false, true),
                                       ("Edit Bay Grabber", "198.51.100.7", "Stopped", false, false)].enumerated()), id: \.offset) { _, r in
                            HStack(spacing: 8) {
                                if r.3 {
                                    Image(systemName: "headphones").font(.system(size: 12)).foregroundStyle(Color.mutedLabel).frame(width: 18)
                                } else {
                                    PlayStopIcon(active: r.2 == "Sending", tint: state.tintActive(on: scheme), size: 15).frame(width: 18)
                                }
                                Text(verbatim: r.0).font(.system(size: 12, weight: .medium))
                                Text(verbatim: r.1).font(.system(size: 10)).foregroundStyle(Color.mutedLabel)
                                Spacer()
                                Text(r.2).font(.system(size: 11)).foregroundStyle(Color.mutedLabel)
                                if !r.3 { PillToggle(title: "M", isOn: .constant(r.4), tint: .red) }
                                Image(systemName: "ellipsis").font(.system(size: 11)).foregroundStyle(state.tintActive)
                            }
                            .padding(.vertical, 4)
                            Divider().opacity(0.4)
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 10)
                .frame(height: 170, alignment: .top)
            }
        }
        .background(Color.primary.opacity(0.03))
    }
}

struct SendStripMock: View {
    @Environment(AppState.self) var state
    let open: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if open { SendControlsMock(compact: true).padding(.bottom, 4); Divider() }
            HStack(spacing: 10) {
                Text("SEND").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.mutedLabel)
                SendingIndicator(targets: 2)
                Text("Edit Suite Mac → Control Room, Studio PC, 192.0.2.31")
                    .font(.system(size: 11)).lineLimit(1).foregroundStyle(Color.mutedLabel)
                MeterStrip(count: 2, orientation: .horizontal, thickness: 3, slot: 4, length: 90,
                           level: { [0.42, 0.30][$0] })
                    .frame(width: 90, height: 8)
                Spacer()
                Image(systemName: open ? "chevron.down" : "chevron.up").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.mutedLabel)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Color.primary.opacity(0.04))
    }
}
