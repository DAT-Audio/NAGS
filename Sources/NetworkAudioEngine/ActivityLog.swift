import Foundation
import Observation

/// What the app did and why: the actions the user asked for, what came of them, and the
/// changes the app made by itself. Both apps keep one, shown under Settings → Log.
///
/// **Kept between launches, within limits:** at most `maxEntries` entries and `maxBytes` on
/// disk, the oldest dropped first. It lives in the app's own Application Support folder, and a
/// log made for a self-test or the render harness (no file) keeps nothing.
@Observable
public final class ActivityLog {
    /// Kept in the engine; its colour is in the UI.
    public typealias Kind = LogKind

    public struct Entry: Codable, Identifiable, Equatable {
        public var id = UUID()
        public var date: Date
        public var kind: Kind
        public var text: String
    }

    public static let maxEntries = 1000
    public static let maxBytes = 256 * 1024

    public private(set) var entries: [Entry] = []
    public let appName: String
    private let file: URL?
    @ObservationIgnored private var saveScheduled = false

    /// `file` nil keeps the log in memory only.
    public init(appName: String, file: URL?) {
        self.appName = appName
        self.file = file
        if let file, let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = Array(saved.suffix(Self.maxEntries))
        }
    }

    /// Adds an entry. Main thread.
    public func add(_ kind: Kind, _ text: String) {
        entries.append(Entry(date: Date(), kind: kind, text: text))
        if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }
        scheduleSave()
    }

    public func clear() {
        entries.removeAll()
        scheduleSave()
    }

    /// Written a moment after the last change rather than on every one: a burst of entries
    /// costs one write.
    private func scheduleSave() {
        guard file != nil, !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.saveScheduled = false
            self?.save()
        }
    }

    /// Now, for quitting.
    public func save() {
        guard let file else { return }
        var kept = entries
        var data = (try? JSONEncoder().encode(kept)) ?? Data()
        // Over the size limit: drop the oldest tenth until it fits.
        while data.count > Self.maxBytes, kept.count > 10 {
            kept.removeFirst(max(1, kept.count / 10))
            data = (try? JSONEncoder().encode(kept)) ?? Data()
        }
        try? data.write(to: file, options: .atomic)
    }

    // MARK: - Export

    /// Made once: a `DateFormatter` is expensive to create, and the log view formats every
    /// entry it shows.
    private static let timestampFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    public static func timestamp(_ d: Date) -> String { timestampFormat.string(from: d) }

    /// The whole log as plain text, oldest first, under a few lines saying what it is.
    public func exportText() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        var lines = ["\(appName) activity log",
                     "Version \(version), \(os)",
                     "Exported \(Self.timestamp(Date())) (local time)"]
        if let first = entries.first, let last = entries.last {
            lines.append("\(entries.count) entries, \(Self.timestamp(first.date)) to \(Self.timestamp(last.date))")
        } else {
            lines.append("No entries")
        }
        lines.append("")
        for e in entries {
            lines.append("\(Self.timestamp(e.date))  \(e.kind.label.padding(toLength: 7, withPad: " ", startingAt: 0))  \(e.text)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
