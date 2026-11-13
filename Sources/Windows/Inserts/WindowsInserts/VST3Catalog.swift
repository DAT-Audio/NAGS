import Foundation
import WinSDK
import NAGVST3

/// One installed VST3 effect class.
public struct VST3PluginInfo: Codable, Hashable, Sendable, Identifiable {
    public let name: String
    public let vendor: String
    /// The module: a `.vst3` bundle folder, or an old single-file DLL.
    public let path: String
    /// 32 hex digits, as VST3 prints a class ID on Windows.
    public let classID: String
    /// `Fx`, `EQ`, `Dynamics`…
    public let subcategories: [String]
    public let version: String

    public init(name: String, vendor: String, path: String, classID: String,
                subcategories: [String], version: String = "") {
        self.name = name
        self.vendor = vendor
        self.path = path
        self.classID = classID
        self.subcategories = subcategories
        self.version = version
    }

    /// The class ID: what identifies the effect wherever it is installed, so a saved slot finds
    /// it again after the plug-in moves.
    public var id: String { classID }
    public var display: String { "\(name) — \(vendor)" }
}

/// The installed VST3 effects: found under `%CommonProgramFiles%\VST3`, described, and cached by
/// path and modification time so only new or updated modules are looked at again.
///
/// **Crash-safe scanning.** A module with a `moduleinfo.json` is described from it without any of
/// its code running. One without has to be loaded, and loading an unknown plug-in can crash, so
/// that happens in a **child process**: `nag-vst3-scan.exe`, found beside the running exe and
/// started with no window. It reports each module before and after looking at it; if it dies
/// part-way the module it was on is recorded as having crashed it (and is not tried again until
/// it changes on disk, or a forced rescan), and a fresh child carries on with the rest. A module
/// silent for `childTimeout` — waiting on a dialog nobody can see, say — is treated the same.
///
/// A separate exe rather than the app re-launching itself, so nothing in the app's `main` has to
/// know about scanning. An app that prefers the second can set `scannerCommand` to its own path
/// and `VST3ScannerChild.flag`, and call `VST3ScannerChild.runIfRequested()` first thing in main.
public final class VST3Catalog: @unchecked Sendable {
    /// The effects found, sorted by vendor then name, as the Mac's menus are. Main thread.
    public private(set) var plugins: [VST3PluginInfo] = []
    /// Modules that could not be described, with why. Main thread.
    public private(set) var problems: [(path: String, reason: String)] = []
    /// Whether a scan is running.
    public private(set) var scanning = false

    public let folder: String
    public let cacheURL: URL
    /// The scanner child: exe and arguments. Nil runs no child, and modules without a
    /// `moduleinfo.json` are then left out (and not cached, so they are tried when it is back).
    public var scannerCommand: (exe: String, arguments: String)?
    /// How long a module may keep the scanner quiet before it is given up on.
    public var childTimeout: TimeInterval = 30

    public init(folder: String? = nil, cacheURL: URL? = nil) {
        self.folder = folder ?? Self.defaultFolder
        self.cacheURL = cacheURL ?? Self.defaultCacheURL
        let scanner = Self.executableDirectory.appendingPathComponent("nag-vst3-scan.exe").path
        if FileManager.default.fileExists(atPath: scanner) { scannerCommand = (scanner, "") }
    }

    /// `%CommonProgramFiles%\VST3`.
    public static var defaultFolder: String {
        guard let p = nag_vst3_default_folder() else { return "" }
        defer { nag_vst3_free(p) }
        return String(cString: p)
    }

    /// `%LOCALAPPDATA%\Network Audio Grabber\vst3-plugins.json`.
    public static var defaultCacheURL: URL {
        let base = ProcessInfo.processInfo.environment["LOCALAPPDATA"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Network Audio Grabber").appendingPathComponent("vst3-plugins.json")
    }

    /// The folder the running exe is in.
    public static var executableDirectory: URL {
        var buffer = [WCHAR](repeating: 0, count: 32768)
        let n = GetModuleFileNameW(nil, &buffer, DWORD(buffer.count))
        let path = String(decoding: buffer.prefix(Int(n)), as: UTF16.self)
        return URL(fileURLWithPath: path).deletingLastPathComponent()
    }

    public func plugin(id: String) -> VST3PluginInfo? { plugins.first { $0.id == id } }

    // MARK: - Scanning

    /// Scans on a background thread and calls back on the main queue with the effects found.
    public func scanInBackground(force: Bool = false, completion: (([VST3PluginInfo]) -> Void)? = nil) {
        guard !scanning else { return }
        scanning = true
        Thread.detachNewThread { [self] in
            let result = self.performScan(force: force)
            DispatchQueue.main.async {
                self.publish(result)
                completion?(self.plugins)
            }
        }
    }

    /// Scans and waits. Starts child processes, so keep it off a thread that must stay responsive.
    @discardableResult
    public func scan(force: Bool = false) -> [VST3PluginInfo] {
        scanning = true
        publish(performScan(force: force))
        return plugins
    }

    /// The effects in the cache, without scanning: what to show at launch while a scan runs.
    @discardableResult
    public func loadCached() -> [VST3PluginInfo] {
        publish(Self.effects(in: readCache().modules))
        scanning = false
        return plugins
    }

    private func publish(_ result: (plugins: [VST3PluginInfo], problems: [(String, String)])) {
        plugins = result.plugins
        problems = result.problems.map { (path: $0.0, reason: $0.1) }
        scanning = false
    }

    // MARK: - The cache

    struct ClassRecord: Codable {
        var cid: String
        var name: String
        var vendor: String
        var category: String
        var subCategories: [String]
        var version: String
    }

    struct ModuleRecord: Codable {
        var path: String
        var mtime: Int64
        var source: String
        var vendor: String
        var error: String
        var classes: [ClassRecord]
    }

    struct Cache: Codable {
        var version = 1
        var modules: [ModuleRecord] = []
    }

    private func readCache() -> Cache {
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(Cache.self, from: data), cache.version == 1 else { return Cache() }
        return cache
    }

    private func writeCache(_ cache: Cache) {
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(cache) { try? data.write(to: cacheURL, options: .atomic) }
    }

    /// Audio effects only: VST3's "Audio Module Class" with an `Fx` subcategory, and not an
    /// instrument. Sorted by vendor then name, de-duplicated by class ID.
    static func effects(in modules: [ModuleRecord]) -> (plugins: [VST3PluginInfo], problems: [(String, String)]) {
        var seen = Set<String>()
        var list: [VST3PluginInfo] = []
        var problems: [(String, String)] = []
        for module in modules {
            if !module.error.isEmpty { problems.append((module.path, module.error)) }
            for c in module.classes where c.category == "Audio Module Class" {
                let subs = c.subCategories.flatMap { $0.split(separator: "|").map(String.init) }
                guard subs.contains(where: { $0.hasPrefix("Fx") }), !subs.contains("Instrument") else { continue }
                guard seen.insert(c.cid).inserted else { continue }
                list.append(VST3PluginInfo(name: c.name, vendor: c.vendor.isEmpty ? module.vendor : c.vendor,
                                           path: module.path, classID: c.cid, subcategories: subs,
                                           version: c.version))
            }
        }
        list.sort { ($0.vendor.lowercased(), $0.name.lowercased()) < ($1.vendor.lowercased(), $1.name.lowercased()) }
        return (list, problems)
    }

    private func performScan(force: Bool) -> (plugins: [VST3PluginInfo], problems: [(String, String)]) {
        let found = Self.findModules(in: folder)
        let cached = Dictionary(readCache().modules.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })

        var records: [String: ModuleRecord] = [:]
        var toDescribe: [String] = []
        for (path, mtime) in found {
            if !force, let record = cached[path], record.mtime == mtime { records[path] = record }
            else { toDescribe.append(path) }
        }

        if !toDescribe.isEmpty {
            let times = Dictionary(found.map { ($0.path, $0.mtime) }, uniquingKeysWith: { a, _ in a })
            for var record in describe(toDescribe) {
                record.mtime = times[record.path] ?? 0
                records[record.path] = record
            }
        }

        // Kept in the cache: everything described, and every crash, so a module that crashed the
        // scanner is not loaded again until it changes. Not kept: modules that were not looked at
        // because there was no scanner to look at them with.
        let modules = found.compactMap { records[$0.path] }
        var cache = Cache()
        cache.modules = modules.filter { $0.error != Self.notLoaded }
        writeCache(cache)
        return Self.effects(in: modules)
    }

    static let notLoaded = "not described without loading"

    /// One module described in this process, loading it if it has no moduleinfo.json — **not**
    /// crash-safe. For diagnosis only (`nag-vst3-check --describe`).
    public static func describeInProcess(_ path: String) -> String {
        guard let json = nag_vst3_describe_module(path, 1) else { return "" }
        defer { nag_vst3_free(json) }
        return String(cString: json)
    }

    /// Every module under `folder`, with its modification time.
    static func findModules(in folder: String) -> [(path: String, mtime: Int64)] {
        guard let text = nag_vst3_find_modules(folder) else { return [] }
        defer { nag_vst3_free(text) }
        return String(cString: text).split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), Int64(parts[1]) ?? 0)
        }
    }

    struct Described: Decodable {
        var path: String
        var source: String
        var vendor: String
        var error: String
        var classes: [ClassRecord]
    }

    static func record(fromJSON json: Substring) -> ModuleRecord? {
        guard let d = try? JSONDecoder().decode(Described.self, from: Data(json.utf8)) else { return nil }
        return ModuleRecord(path: d.path, mtime: 0, source: d.source, vendor: d.vendor, error: d.error, classes: d.classes)
    }

    /// Describes `paths` in the scanner child, starting a fresh one after each crash.
    private func describe(_ paths: [String]) -> [ModuleRecord] {
        guard let command = scannerCommand else {
            // No child: what moduleinfo.json can say, and nothing loaded in this process.
            return paths.compactMap { path in
                guard let json = nag_vst3_describe_module(path, 0) else { return nil }
                defer { nag_vst3_free(json) }
                return Self.record(fromJSON: Substring(String(cString: json)))
            }
        }

        var results: [ModuleRecord] = []
        var remaining = paths
        var attempts = 0
        while !remaining.isEmpty, attempts <= paths.count {
            attempts += 1
            var exitCode: Int32 = 0, timedOut: Int32 = 0
            let input = remaining.joined(separator: "\n") + "\n"
            let output = nag_vst3_run_child(command.exe, command.arguments, input,
                                            Int32(childTimeout * 1000), &exitCode, &timedOut)
            guard let output else {
                // The scanner would not start at all: fall back to moduleinfo.json only.
                scannerCommand = nil
                results += describe(remaining)
                return results
            }
            let text = String(cString: output)
            nag_vst3_free(output)

            var begun: String?
            var done = Set<String>()
            // `isNewline`, because "\r\n" — what the child's C runtime writes — is one Character.
            for line in text.split(whereSeparator: \.isNewline) {
                if line.hasPrefix(VST3ScannerChild.beginPrefix) {
                    begun = String(line.dropFirst(VST3ScannerChild.beginPrefix.count))
                } else if line.hasPrefix(VST3ScannerChild.resultPrefix),
                          let record = Self.record(fromJSON: line.dropFirst(VST3ScannerChild.resultPrefix.count)) {
                    results.append(record)
                    done.insert(record.path)
                    begun = nil
                }
            }
            if let begun, !done.contains(begun) {
                let reason = timedOut != 0
                    ? "stopped responding while being scanned — left out"
                    : String(format: "ended the scanner (exit 0x%08X) — left out", UInt32(bitPattern: exitCode))
                results.append(ModuleRecord(path: begun, mtime: 0, source: "", vendor: "", error: reason, classes: []))
                done.insert(begun)
            }
            let next = remaining.filter { !done.contains($0) }
            if next.count == remaining.count { break }     // no progress at all: give up
            remaining = next
        }
        for path in remaining {
            results.append(ModuleRecord(path: path, mtime: 0, source: "", vendor: "",
                                        error: "the scanner could not describe it", classes: []))
        }
        return results
    }
}

/// The scanner child's side (`nag-vst3-scan`): module paths on standard input, one per line; for
/// each, a line saying it has begun and a line with its description, flushed at once, so a crash
/// part-way leaves the parent knowing which module did it. Lines are prefixed because a plug-in
/// may print to standard output too.
public enum VST3ScannerChild {
    /// For an app that runs itself as the scanner instead of shipping `nag-vst3-scan.exe`.
    public static let flag = "--nag-vst3-scan"
    static let beginPrefix = "@@NAG BEGIN "
    static let resultPrefix = "@@NAG RESULT "

    /// Runs the scanner and exits if the process was started with `flag`.
    public static func runIfRequested() {
        if CommandLine.arguments.contains(flag) { run() }
    }

    public static func run() -> Never {
        nag_vst3_quiet_crashes()
        // A plug-in may want COM on the thread it is loaded on.
        _ = CoInitializeEx(nil, DWORD(COINIT_APARTMENTTHREADED.rawValue))
        while let line = readLine(strippingNewline: true) {
            let path = line.trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else { continue }
            print(beginPrefix + path)
            fflush(stdout)
            if let json = nag_vst3_describe_module(path, 1) {
                print(resultPrefix + String(cString: json))
                nag_vst3_free(json)
            }
            fflush(stdout)
        }
        exit(0)
    }
}
