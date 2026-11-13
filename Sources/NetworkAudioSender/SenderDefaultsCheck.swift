import Foundation

/// `NetworkAudioSender --checkdefaults`
///
/// Checks that settings saved by an earlier build still load, and what a fresh install starts
/// with. Exits 1 if any case fails. Uses encoded values and a throwaway preferences suite only.
enum SenderDefaultsCheck {
    static func run() -> Never {
        var failed = 0
        func check(_ what: String, _ ok: Bool) {
            print((ok ? "PASS  " : "FAIL  ") + what)
            if !ok { failed += 1 }
        }
        // A target as saved before names existed (documentation address, RFC 5737).
        let old = #"[{"id":"6F1C2A10-3C4B-4E5D-9A8B-7C6D5E4F3A21","host":"192.0.2.20","port":6980,"favourite":true,"broadcast":false,"muted":false}]"#
        let decoded = try? JSONDecoder().decode([SendTarget].self, from: Data(old.utf8))
        check("a target saved before names existed still loads", decoded?.count == 1)
        check("…unnamed, showing its address", decoded?.first?.name == nil && decoded?.first?.label == "192.0.2.20")
        check("…with its favourite kept", decoded?.first?.favourite == true)

        var named = decoded?.first
        named?.name = "Studio PC"
        let round = named.flatMap { try? JSONEncoder().encode([$0]) }
            .flatMap { try? JSONDecoder().decode([SendTarget].self, from: $0) }?.first
        check("a name survives saving and loading", round?.name == "Studio PC" && round?.label == "Studio PC")
        check("…and the address is still what is copied", round?.address == "192.0.2.20")

        // Broadcast on this network: the new fields round-trip, older targets still
        // load, and a kept broadcast resumes only on the network it was started on.
        var bcast = SendTarget(host: "192.0.2.30", broadcast: true, name: "Everyone on en0")
        bcast.interface = "en0"; bcast.networkSignature = "sig-home"; bcast.keepOn = true
        let bRound = (try? JSONEncoder().encode([bcast])).flatMap { try? JSONDecoder().decode([SendTarget].self, from: $0) }?.first
        check("a kept broadcast survives saving and loading",
              bRound?.interface == "en0" && bRound?.networkSignature == "sig-home" && bRound?.keepOn == true)
        check("…and a target saved before broadcasts still loads, not kept on", decoded?.first?.keepOn == nil)
        check("a kept broadcast resumes on its own network",
              SenderState.keptBroadcastsToResume([bcast]) { $0 == "en0" ? "sig-home" : nil } == [bcast.id])
        check("…not on another network with the same interface",
              SenderState.keptBroadcastsToResume([bcast]) { $0 == "en0" ? "sig-studio" : nil }.isEmpty)
        check("…not when that interface is not on any network",
              SenderState.keptBroadcastsToResume([bcast]) { _ in nil }.isEmpty)
        var notKept = bcast; notKept.keepOn = false
        check("…and one not kept on never resumes by itself",
              SenderState.keptBroadcastsToResume([notKept]) { _ in "sig-home" }.isEmpty)

        // Remote links: no longer turn Findable on; Stop sending pauses them, Resume
        // lets them in again.
        let linkSuite = "app.networkaudiosender.checklinks"
        UserDefaults.standard.removePersistentDomain(forName: linkSuite)
        MainActor.assumeIsolated {
            let s = SenderState(defaults: UserDefaults(suiteName: linkSuite)!)
            let code = RemoteCode(role: .receiving, address: "203.0.113.40", port: 6980).text
            check("a Remote link is made", s.linkRemote(code) == nil && s.remoteLinks.count == 1)
            check("…without turning Findable on", !s.offering)
            check("…and the offer runs for it", s.remoteWanted)
            s.stopAll()
            check("Stop sending pauses the links", s.remoteLinksPaused && !s.remoteWanted)
            s.resumeRemoteLinks()
            check("…and Resume lets them in again", !s.remoteLinksPaused && s.remoteWanted)
            check("a second end links too", s.linkRemote(RemoteCode(role: .receiving, address: "198.51.100.7", port: 51000).text) == nil
                  && s.remoteLinks.count == 2)
            check("the same end twice is refused", s.linkRemote(code) != nil)
        }
        UserDefaults.standard.removePersistentDomain(forName: linkSuite)

        // Auto-stop: off unless chosen, 15 min ready; a choice is kept.
        let name = "app.networkaudiosender.checkdefaults"
        UserDefaults.standard.removePersistentDomain(forName: name)
        MainActor.assumeIsolated {
            let fresh = SenderState(defaults: UserDefaults(suiteName: name)!)
            check("fresh install: auto-stop off for sends, 15 min ready",
                  !fresh.autoStopSends && fresh.autoStopSendsMinutes == 15)
            check("fresh install: the Sender plugin passes its track through", fresh.passThrough)
            fresh.autoStopSends = true
            fresh.autoStopSendsMinutes = 120
            let again = SenderState(defaults: UserDefaults(suiteName: name)!)
            check("chose auto-stop after 2 h: kept", again.autoStopSends && again.autoStopSendsMinutes == 120)
        }
        // The Grabber's Send takes the Grabber's name, follows it, and stops once renamed.
        UserDefaults.standard.removePersistentDomain(forName: name)
        MainActor.assumeIsolated {
            let g = SenderState(defaults: UserDefaults(suiteName: name)!, defaultName: "Studio Grabber")
            check("the Grabber's Send starts with the Grabber's name", g.streamName == "Studio Grabber")
            g.adoptDefaultName("Control Room")
            check("…follows a rename of the Grabber", g.streamName == "Control Room")
            check("…without saving it as a choice", UserDefaults(suiteName: name)!.string(forKey: "streamName") == nil)
            g.streamName = "Booth Feed"
            g.adoptDefaultName("Another Name")
            check("…and keeps its own name once renamed", g.streamName == "Booth Feed")
        }
        UserDefaults.standard.removePersistentDomain(forName: name)

        print(failed == 0 ? "All passed." : "\(failed) failed.")
        exit(failed == 0 ? 0 : 1)
    }
}
