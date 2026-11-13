import SwiftUI
import AppKit

/// `NetworkAudioGrabber --mockup-headers <folder>` draws **proposals** for both apps' headers:
/// the title bar, the header and the first of the content, at real size, so the height each
/// option costs is visible rather than described.
///
/// Development tooling, like `MockupPreview`: nothing here touches `AppState` or is wired to
/// anything. The pieces are the app's own where they need no state — `AppEmblem`, `PillToggle`,
/// the type sizes and symbols of the real toolbars — and plain text where they would. Names and
/// devices are generic ("en0", "MacBook Pro Speakers"); nothing identifies a machine.
enum HeaderMockups {
    static let amber = Color(red: 0.94, green: 0.63, blue: 0.16)

    @MainActor
    static func run(arguments: [String]) {
        let outDir = arguments.firstIndex(of: "--mockup-headers").flatMap {
            $0 + 1 < arguments.count ? arguments[$0 + 1] : nil
        } ?? NSTemporaryDirectory()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()

        for (suffix, appearance) in [("dark", NSAppearance(named: .darkAqua)),
                                     ("light", NSAppearance(named: .aqua))] {
            capture(Sheet(app: .grabber), width: 1204, appearance: appearance,
                    to: "\(outDir)/headers-grabber-\(suffix).png")
            capture(Sheet(app: .sender), width: 480, appearance: appearance,
                    to: "\(outDir)/headers-sender-\(suffix).png")
        }
        print("Wrote headers-{grabber,sender}-{dark,light}.png to \(outDir)")
        exit(0)
    }

    enum Option: CaseIterable {
        case current, larger, identity, unified

        var title: String {
            switch self {
            case .current:  return "A · Current"
            case .larger:   return "B · Larger mark, same bar"
            case .identity: return "C · Identity block"
            case .unified:  return "D · Native: header in the title bar"
            }
        }

        var note: String {
            switch self {
            case .current:  return "14 pt mark, name beneath. Header 44 pt."
            case .larger:   return "22 pt mark (the icon's two-packet design), name beneath. Header 52 pt: +8."
            case .identity: return "28 pt mark, the app's name beside it in two lines. Header 56 pt: +12."
            case .unified:  return "Controls share the title bar, as Apple's own apps do. 16 pt mark, no name (the menu bar and Dock say it). Saves ~28 pt."
            }
        }

        var headerHeight: CGFloat {
            switch self {
            case .current:  return 44
            case .larger:   return 52
            case .identity: return 56
            case .unified:  return 0
            }
        }
    }

    /// Every option for one app, stacked, each labelled with what it costs.
    struct Sheet: View {
        let app: AppEmblem.App

        var body: some View {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(Option.allCases, id: \.self) { option in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(option.title).font(.system(size: 13, weight: .semibold))
                            Text(option.note).font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        WindowTop(app: app, option: option)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.18)))
                    }
                }
            }
            .padding(20)
            .background(Color(nsColor: .underPageBackgroundColor))
        }
    }

    /// The title bar, the header, and a strip of what follows.
    struct WindowTop: View {
        let app: AppEmblem.App
        let option: Option

        var body: some View {
            VStack(spacing: 0) {
                if option == .unified {
                    HStack(spacing: 10) {
                        trafficLights
                        AppEmblem(app, size: 16, caption: .none)
                            .padding(.leading, 6)
                        controls(compactSpacing: true)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(Color(nsColor: .windowBackgroundColor))
                } else {
                    HStack(spacing: 8) {
                        trafficLights
                        Spacer()
                        Text(app == .grabber ? "Network Audio Grabber" : "Network Audio Sender")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Color.clear.frame(width: 52, height: 1)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Color(nsColor: .windowBackgroundColor))
                    HStack(spacing: 10) {
                        identity
                        controls(compactSpacing: false)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: option.headerHeight)
                    .background(Color(nsColor: .windowBackgroundColor).opacity(0.92))
                }
                Divider()
                contentStrip
            }
        }

        private var trafficLights: some View {
            HStack(spacing: 8) {
                Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34))
                Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.18))
                Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25))
            }
            .frame(width: 52, height: 12)
        }

        @ViewBuilder
        private var identity: some View {
            switch option {
            case .current:
                AppEmblem(app)
            case .larger:
                AppEmblem(app, size: 22)
            case .identity:
                HStack(spacing: 8) {
                    AppEmblem(app, size: 28, caption: .none)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Network Audio")
                            .font(.system(size: 9, weight: .medium))
                        Text(app == .grabber ? "Grabber" : "Sender")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(Color.mutedLabel)
                    .opacity(0.75)
                }
            case .unified:
                EmptyView()
            }
        }

        @ViewBuilder
        private func controls(compactSpacing: Bool) -> some View {
            if app == .grabber {
                grabberControls
            } else {
                Spacer()
                Image(systemName: "circle.lefthalf.filled").font(.system(size: 11)).foregroundStyle(amber)
                Image(systemName: "gearshape").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }

        private var grabberControls: some View {
            HStack(spacing: 10) {
                if option != .unified { Divider().frame(height: 14) }
                HStack(spacing: 3) {
                    Text(verbatim: "en0").font(.system(size: 11, weight: .medium))
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }
                Divider().frame(height: 14)
                HStack(spacing: 5) {
                    Image(systemName: "headphones").font(.system(size: 10)).foregroundStyle(Color.mutedLabel)
                    Text(verbatim: "MacBook Pro Speakers").font(.system(size: 11))
                    Text(verbatim: "48 kHz").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
                .fixedSize()
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(Color.mutedLabel)
                    Text("Filter").font(.system(size: 11)).foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
                .frame(width: 144)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
                PillToggle(title: "ACTIVE", isOn: .constant(false), tint: amber)
                ForEach(["plus.rectangle.on.rectangle", "sidebar.trailing",
                         "arrow.down.right.and.arrow.up.left", "circle.lefthalf.filled", "gearshape"],
                        id: \.self) { symbol in
                    Image(systemName: symbol).font(.system(size: 11))
                        .foregroundStyle(symbol == "sidebar.trailing" ? amber : Color.secondary)
                }
            }
        }

        /// What sits under the header, so the header is judged in place.
        @ViewBuilder
        private var contentStrip: some View {
            if app == .grabber {
                HStack(spacing: 10) {
                    Text(verbatim: "STREAM").font(.system(size: 8, weight: .bold, design: .rounded))
                    Text(verbatim: "Connect to a Sender over VBAN…").font(.system(size: 10))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
                    Spacer()
                    ForEach(["TO BUS", "LEVEL", "TRIM", "M / S", "SOURCE"], id: \.self) {
                        Text(verbatim: $0).font(.system(size: 8, weight: .bold, design: .rounded)).frame(width: 64, alignment: .leading)
                    }
                }
                .foregroundStyle(Color.mutedLabel)
                .padding(.horizontal, 20)
                .frame(height: 34)
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.85))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: "THIS MAC").font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.mutedLabel)
                    Text(verbatim: "Stream name").font(.caption2).foregroundStyle(Color.mutedLabel)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 58, alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.85))
            }
        }
    }

    @MainActor
    private static func capture<V: View>(_ view: V, width: CGFloat, appearance: NSAppearance?, to path: String) {
        let host = NSHostingView(rootView: view.frame(width: width))
        host.appearance = appearance
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        window.orderFrontRegardless()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        window.displayIfNeeded()
        let id = CGWindowID(window.windowNumber)
        if let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, id,
                                            [.boundsIgnoreFraming, .bestResolution]),
           let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
        window.orderOut(nil)
    }
}
