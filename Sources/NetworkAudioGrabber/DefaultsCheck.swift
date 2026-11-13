import Foundation

/// `NetworkAudioGrabber --checkdefaults`
///
/// Checks what a fresh install and an upgraded one start with, against throwaway preferences
/// suites, so a change of default can't quietly overwrite a setting someone chose. Exits 1 if
/// any case fails. The real app's settings are never read or written.
enum DefaultsCheck {
    static func run() -> Never {
        var failed = 0
        func check(_ what: String, _ ok: Bool) {
            print((ok ? "PASS  " : "FAIL  ") + what)
            if !ok { failed += 1 }
        }
        func suite(_ values: [String: Any]) -> UserDefaults {
            let name = "app.networkaudiograbber.checkdefaults"
            UserDefaults.standard.removePersistentDomain(forName: name)
            let d = UserDefaults(suiteName: name)!
            values.forEach { d.set($1, forKey: $0) }
            return d
        }
        let graphite = ThemePreset.standard, old = ThemePreset.previousFallback

        // Colour scheme (the system's colours by default, Graphite & Amber ready if
        // theming is switched on without picking).
        var t = ThemeChoice.stored(in: suite([:]))
        check("fresh install: System colour scheme (theming off), Graphite & Amber ready",
              !t.enabled && t.primaryHex == graphite.primary && t.secondaryHex == graphite.secondary)
        t = ThemeChoice.stored(in: suite(["themeEnabled": false]))
        check("chose System colour scheme (theming off): stays off", !t.enabled)
        t = ThemeChoice.stored(in: suite(["themeEnabled": true]))
        check("switched on without picking colours: keeps the old fallback colours",
              t.enabled && t.primaryHex == old.primary && t.secondaryHex == old.secondary)
        t = ThemeChoice.stored(in: suite(["themeEnabled": true, "themePrimaryHex": "#0E8C8C", "themeSecondaryHex": "#FF6F5E"]))
        check("chose Teal & Coral: kept", t.enabled && t.preset?.name == "Teal & Coral")

        // The meters' shared values: a writer thread flat out, the main thread reading.
        // Under the sequence lock a reader must never see half an update — the writer keeps two
        // fields equal, so any read where they differ is a torn one. And an atomic float must
        // never read as anything the writer did not write.
        do {
            let lock = SeqLock()
            let pair = UnsafeMutablePointer<Double>.allocate(capacity: 2)
            pair.initialize(repeating: 0, count: 2)
            let floats = SharedFloats(count: 1)
            let done = UnsafeMutablePointer<UInt32>.allocate(capacity: 1); done.initialize(to: 0)
            let writer = Thread {
                var n = 0.0
                while nag_load32(done) == 0 {
                    n += 1
                    lock.write { pair[0] = n; pair[1] = n }
                    floats[0] = n.truncatingRemainder(dividingBy: 2) == 0 ? 0.5 : 0.25
                }
            }
            writer.start()
            var torn = 0, strange = 0, reads = 0
            let until = Date().addingTimeInterval(1.0)
            while Date() < until {
                let (a, b) = lock.read { (pair[0], pair[1]) }
                if a != b { torn += 1 }
                let f = floats[0]
                if f != 0 && f != 0.5 && f != 0.25 { strange += 1 }
                reads += 1
            }
            nag_store32(done, 1)
            Thread.sleep(forTimeInterval: 0.05)
            check("meter lock: \(reads) reads against a writer flat out, none torn", torn == 0 && reads > 1000)
            check("meter floats: every read is a value that was written", strange == 0)
        }

        // The beta receivers: off on a fresh install, kept on once switched on.
        check("fresh install: RTP without PTP off", !AppState.storedBeta("plainRTPEnabled", in: suite([:])))
        check("fresh install: internet streams off", !AppState.storedBeta("webStreamsEnabled", in: suite([:])))
        check("switched internet streams on: stays on",
              AppState.storedBeta("webStreamsEnabled", in: suite(["webStreamsEnabled": true])))

        check("fresh install: streams from SDP not kept past two quiet minutes",
              !AppState.storedBeta("keepManualStreams", in: suite([:])))

        // One folder for every log: an old per-app log folder moves into it.
        do {
            let fm = FileManager.default
            let id = "app.networkaudiograbber.checkmove"
            let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let oldFolder = base.appendingPathComponent(id)
            try? fm.createDirectory(at: oldFolder, withIntermediateDirectories: true)
            try? Data("[]".utf8).write(to: oldFolder.appendingPathComponent("activity-log.json"))
            let moved = AppData.logFile(bundleID: id)
            check("an old log moves into the one Network Audio folder",
                  moved.map { fm.fileExists(atPath: $0.path) && $0.deletingLastPathComponent().lastPathComponent == "Network Audio" } ?? false)
            check("…and its old folder goes", !fm.fileExists(atPath: oldFolder.path))
            if let moved { try? fm.removeItem(at: moved) }
            if let folder = AppData.folder, (try? fm.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
                try? fm.removeItem(at: folder)
            }
            check("every settings domain is found by its name", AppData.preferenceDomains().allSatisfy {
                $0.hasPrefix("app.networkaudio") || $0.hasPrefix("NetworkAudio")
            })
        }

        // Auto-stop: nothing stops by itself unless chosen; a choice is kept.
        MainActor.assumeIsolated {
            let fresh = AppState(defaults: suite([:]))
            check("fresh install: auto-stop off for streams, 15 min ready",
                  !fresh.autoStopStreams && fresh.autoStopStreamsMinutes == 15)
            let chosen = AppState(defaults: suite(["autoStopStreams": true, "autoStopStreamsMinutes": 60]))
            check("chose auto-stop after 1 h: kept", chosen.autoStopStreams && chosen.autoStopStreamsMinutes == 60)
        }

        // Level history: on for a fresh install, and a choice to turn it off is kept.
        check("fresh install: level history on", AppState.storedShowLevelHistory(in: suite([:])))
        check("turned the level history off: stays off",
              !AppState.storedShowLevelHistory(in: suite(["showLevelHistory": false])))

        // VBAN buffer (its own setting, 20 ms by default).
        check("fresh install: VBAN buffer 20 ms", AppState.storedVBANLatency(in: suite([:])) == 20)
        check("had set the shared buffer to 32 ms: VBAN keeps 32",
              AppState.storedVBANLatency(in: suite(["latencyMs": 32.0])) == 32)
        check("has its own VBAN buffer: kept",
              AppState.storedVBANLatency(in: suite(["latencyMs": 32.0, "vbanLatencyMs": 24.0])) == 24)
        let fresh = suite([:])
        check("fresh install: AES67 buffer still 15 ms",
              (fresh.object(forKey: "latencyMs") as? Double ?? AppState.defaultLatencyMs) == 15)

        // The activity log's limits, on a file in a temporary folder.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nag-log-check-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("activity-log.json")
        let log = ActivityLog(appName: "Check", file: file)
        for i in 0..<1200 { log.add(i % 2 == 0 ? .request : .done, "Entry \(i)") }
        check("log: 1200 added, the newest 1000 kept", log.entries.count == 1000 && log.entries.first?.text == "Entry 200")
        log.save()
        let reloaded = ActivityLog(appName: "Check", file: file)
        check("log: kept across a relaunch", reloaded.entries.count == 1000 && reloaded.entries.last?.text == "Entry 1199")
        let long = String(repeating: "x", count: 2000)
        for i in 0..<400 { reloaded.add(.note, "Long \(i) \(long)") }
        reloaded.save()
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? .max
        let again = ActivityLog(appName: "Check", file: file)
        check("log: the file stays under 256 KB, oldest dropped first",
              size <= ActivityLog.maxBytes && again.entries.last?.text.hasPrefix("Long 399") == true)
        let text = again.exportText()
        check("log: export has its header and every entry",
              text.hasPrefix("Check activity log\n") && text.contains("entries,")
                  && text.components(separatedBy: "\n").count >= again.entries.count + 5)
        check("log: a log with no file keeps nothing on disk",
              { let m = ActivityLog(appName: "Mem", file: nil); m.add(.note, "x"); m.save(); return m.entries.count == 1 }())
        try? FileManager.default.removeItem(at: dir)

        UserDefaults.standard.removePersistentDomain(forName: "app.networkaudiograbber.checkdefaults")
        print(failed == 0 ? "All passed." : "\(failed) failed.")
        exit(failed == 0 ? 0 : 1)
    }
}
