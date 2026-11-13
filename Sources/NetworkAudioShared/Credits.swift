import Foundation

/// The credits, in one place: what the apps work with and who
/// made it, what they are built with, the one outside service, and the trademarks. Shown by the
/// About window (scrolling) and by Settings → Credits (`Acknowledgements`), so the two cannot
/// drift apart. The protocols are listed because they are other people's work the apps build on.
public enum Credits {
    public struct Item: Identifiable {
        public let title: String
        public let detail: String
        public var id: String { title + detail }
    }

    public struct Section: Identifiable {
        public let title: String
        public let items: [Item]
        public var id: String { title }
    }

    /// What is shown: everything, less AudioUnitSDK where this bundle does not carry it (the
    /// Sender app: the plug-ins are built into the Grabber's bundle and the .component only).
    public static let sections: [Section] = {
        let hasAUSDK = LicenceFiles.carries("AudioUnitSDK LICENSE.txt")
        return all.map { section in
            Section(title: section.title,
                    items: section.items.filter { hasAUSDK || $0.title != "AudioUnitSDK" })
        }
    }()

    private static let all: [Section] = [
        Section(title: "Works with", items: [
            Item(title: "AES67", detail: "The AES standard for audio over IP, with RTP (RFC 3550, 3551), "
                 + "SDP (RFC 4566) and SAP (RFC 2974) from the IETF"),
            Item(title: "RAVENNA", detail: "ALC NetworX"),
            Item(title: "Dante, in its AES67 mode", detail: "Audinate"),
            Item(title: "VBAN", detail: "VB-Audio Software, from its published specification"),
            Item(title: "Scream", detail: "The open-source Scream project, from its own description of the format"),
            Item(title: "RTP without PTP", detail: "PipeWire, PulseAudio, VLC, GStreamer"),
            Item(title: "Icecast and SHOUTcast", detail: "Internet radio, over HTTP (RFC 1945) and the ICY "
                 + "conventions; decoding is macOS's own"),
            Item(title: "Audio Units", detail: "Apple"),
        ]),
        Section(title: "Built with", items: [
            Item(title: "swift-crypto", detail: "Apple Inc. · Apache License 2.0 · the Remote link's encryption, "
                 + "ChaCha20-Poly1305 (RFC 8439) and HKDF (RFC 5869)"),
            Item(title: "AudioUnitSDK", detail: "Apple Inc. · Apache License 2.0 · the DAT Audio plug-ins"),
            Item(title: "macOS", detail: "Core Audio, AVFoundation, CryptoKit, Network"),
        ]),
        Section(title: "Services", items: [
            Item(title: "Cloudflare's public STUN service", detail: "stun.cloudflare.com (RFC 8489), free for "
                 + "anyone to use. Asked only when you press Find this network's outside address."),
        ]),
        Section(title: "Trademarks", items: [
            Item(title: "", detail: "Dante is a trademark of Audinate. RAVENNA is a trademark of ALC NetworX. "
                 + "VBAN and Voicemeeter are trademarks of VB-Audio Software. Icecast is a trademark of the "
                 + "Xiph.Org Foundation. Audio Units and macOS are trademarks of Apple Inc. SHOUTcast, Scream, "
                 + "PipeWire, VLC and the other names mentioned belong to their owners."),
            Item(title: "", detail: "Not affiliated with, or endorsed by, any of them: names say only what the "
                 + "apps work with. No code from those projects is included."),
        ]),
        Section(title: "Thank you", items: [
            Item(title: "", detail: "To everyone who tested early builds."),
        ]),
    ]

    /// "© 2026 DAT Audio · free software, MIT licence".
    public static let copyright = "© 2026 DAT Audio · free software, MIT licence"
}

/// The licence texts each app carries in `Contents/Resources/Licences` (put there by `build.sh`),
/// listed for the Licences window: what is in *this* app, found rather than assumed.
public enum LicenceFiles {
    public struct Entry: Identifiable {
        public let title: String
        public let subtitle: String
        public let text: String
        public var id: String { title }
    }

    /// Known files, in the order shown: the apps' own licence first.
    private static let known: [(file: String, notice: String?, title: String, subtitle: String)] = [
        ("LICENSE.txt", nil, "Network Audio Grabber & Sender", "MIT · DAT Audio"),
        ("swift-crypto LICENSE.txt", "swift-crypto NOTICE.txt", "swift-crypto", "Apache 2.0 · Apple Inc."),
        ("AudioUnitSDK LICENSE.txt", nil, "AudioUnitSDK", "Apache 2.0 · Apple Inc. · the plug-ins"),
    ]

    /// The bundle this code is in: the app's own, or in a DAW the .component's — not
    /// `Bundle.main`, which there is the DAW and has no Licences folder.
    public static var own: Bundle { Bundle(for: Marker.self) }
    private final class Marker {}

    /// Whether this bundle carries `file` in its Licences folder.
    public static func carries(_ file: String, in bundle: Bundle = own) -> Bool {
        guard let folder = bundle.resourceURL?.appendingPathComponent("Licences") else { return false }
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent(file).path)
    }

    public static func entries(in bundle: Bundle = own) -> [Entry] {
        guard let folder = bundle.resourceURL?.appendingPathComponent("Licences") else { return [] }
        return known.compactMap { k in
            guard let text = try? String(contentsOf: folder.appendingPathComponent(k.file), encoding: .utf8)
            else { return nil }
            var full = text
            if let n = k.notice, let notice = try? String(contentsOf: folder.appendingPathComponent(n), encoding: .utf8) {
                full += "\n\n— NOTICE —\n\n" + notice
            }
            return Entry(title: k.title, subtitle: k.subtitle, text: full)
        }
    }
}
