import SwiftUI
import AppKit

extension ActivityLog {
    /// The log file for an app with this bundle identifier: in the one shared folder (`AppData`).
    public static func standardFile(bundleID: String) -> URL? { AppData.logFile(bundleID: bundleID) }

    /// Asks where to save, suggesting "<app> log <date> at <time>.txt".
    public func exportWithPanel() {
        let panel = NSSavePanel()
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        panel.nameFieldStringValue = "\(appName) log \(f.string(from: Date())).txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.title = "Export Log"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try exportText().write(to: url, atomically: true, encoding: .utf8)
            add(.done, "Exported the log to \(url.lastPathComponent).")
        } catch {
            add(.failed, "Could not export the log: \(error.localizedDescription)")
        }
    }
}


/// The log, newest first, in a view of its own: a filter, Export… and Clear, and the entries in
/// a scrolling list with the time, the kind and what happened.
public struct ActivityLogView: View {
    var log: ActivityLog
    @State private var problemsOnly = false
    @State private var confirmClear = false

    public init(log: ActivityLog) { self.log = log }

    private var shown: [ActivityLog.Entry] {
        let all = log.entries.reversed()
        return problemsOnly ? all.filter { $0.kind == .failed || $0.kind == .warning } : Array(all)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("", selection: $problemsOnly) {
                    Text("All").tag(false)
                    Text("Problems").tag(true)
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 150)
                Text(verbatim: "\(log.entries.count) of \(ActivityLog.maxEntries) kept")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.mutedLabel)
                Spacer()
                Button("Export…") { log.exportWithPanel() }
                    .controlSize(.small)
                    .help("Save the whole log as a text file.")
                Button("Clear") { confirmClear = true }
                    .controlSize(.small)
                    .disabled(log.entries.isEmpty)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if shown.isEmpty {
                        Text(problemsOnly ? "No failures or warnings." : "Nothing logged yet.")
                            .font(.caption).foregroundStyle(Color.mutedLabel).padding(8)
                    }
                    ForEach(shown) { e in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(verbatim: Self.time(e.date))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Color.mutedLabel)
                                .help(ActivityLog.timestamp(e.date))
                            Text(verbatim: e.kind.label)
                                .font(.system(size: 8.5, weight: .bold, design: .rounded))
                                .foregroundStyle(e.kind.tint)
                                .frame(width: 54, alignment: .leading)
                            Text(verbatim: e.text)
                                .font(.system(size: 11))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        Divider().opacity(0.4)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.04)))
            Text(verbatim: "The most recent \(ActivityLog.maxEntries) entries are kept between launches, oldest dropped first.")
                .font(.caption2).foregroundStyle(Color.mutedLabel)
        }
        .confirmationDialog("Clear the log?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) { log.clear() }
        } message: {
            Text("Every entry is removed. Export it first to keep a copy.")
        }
    }

    /// Time of day, with the date too for anything not from today.
    public static func time(_ d: Date) -> String {
        (Calendar.current.isDateInToday(d) ? todayFormat : earlierFormat).string(from: d)
    }

    /// Made once each, not per row per update (see `ActivityLog.timestamp`).
    private static let todayFormat: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
    private static let earlierFormat: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d MMM HH:mm"; return f
    }()
}

extension LogKind {
    public var tint: Color {
        switch self {
        case .request: return .blue
        case .done:    return .green
        case .failed:  return .red
        case .stopped: return .secondary
        case .note:    return .secondary
        case .warning: return .orange
        }
    }
}
