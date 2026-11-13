import AppKit
import SwiftUI

/// Help → Quick Start Guide: the illustrated guide
/// (`docs/quick-start/`), shipped inside each app as one self-contained page, opened in the
/// default browser. Nothing is fetched from anywhere.
public enum QuickStart {
    public static let menuTitle = "Quick Start Guide"

    /// The bundled copy; in a debug build run from the terminal, the project's own. Debug only:
    /// `#filePath` writes the folder the project was built in into the binary, and a release
    /// build must not carry it.
    public static var url: URL? {
        if let bundled = Bundle.main.url(forResource: "Quick Start", withExtension: "html") { return bundled }
        #if DEBUG
        let source = URL(fileURLWithPath: #filePath)            // …/Sources/NetworkAudioShared/QuickStart.swift
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/quick-start/QUICK-START.html")
        return FileManager.default.fileExists(atPath: source.path) ? source : nil
        #else
        return nil
        #endif
    }

    /// Opens it; false if this build has no copy.
    @discardableResult
    public static func open() -> Bool {
        guard let url else { return false }
        return NSWorkspace.shared.open(url)
    }
}


/// The guide, a click away where people set things up: pinned
/// under the Settings panes, and in the connection windows. `iconOnly` for narrow places.
public struct QuickStartLink: View {
    let iconOnly: Bool
    let short: Bool
    /// `short`: "Quick Start", for a narrow column.
    public init(iconOnly: Bool = false, short: Bool = false) { self.iconOnly = iconOnly; self.short = short }
    public var body: some View {
        Button { QuickStart.open() } label: {
            HStack(spacing: 5) {
                Image(systemName: "book").font(.system(size: 11))
                if !iconOnly {
                    Text(short ? "Quick Start" : QuickStart.menuTitle).font(.system(size: 11))
                        .lineLimit(1).fixedSize()
                    Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .semibold))
                }
            }
            .foregroundStyle(Color.mutedLabel)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Opens the illustrated Quick Start Guide in your browser (also under Help).")
        .accessibilityLabel(QuickStart.menuTitle)
    }
}
