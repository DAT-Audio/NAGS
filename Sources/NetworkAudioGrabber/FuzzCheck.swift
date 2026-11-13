import Foundation

/// `NetworkAudioGrabber --fuzzcheck [--rounds N]`: every parser that reads from the network is
/// fed random and mutated packets, and must neither crash nor accept nonsense as valid audio.
/// A new protocol's parser is added here before its receiver is.
///
/// Deterministic — a fixed seed — so a failure reproduces. Exits 1 if any check fails.
enum FuzzCheck {
    /// xorshift64*: small, fast, seedable, and good enough to scatter bytes.
    struct Random {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state >> 12; state ^= state << 25; state ^= state >> 27
            return state &* 2685821657736338717
        }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(max(1, n))) }
        mutating func byte() -> UInt8 { UInt8(truncatingIfNeeded: next()) }
    }

    static func run(arguments: [String]) -> Never {
        let rounds = arguments.firstIndex(of: "--rounds").flatMap {
            $0 + 1 < arguments.count ? Int(arguments[$0 + 1]) : nil } ?? 200_000
        var rng = Random(state: 0x9E37_79B9_7F4A_7C15)
        var failed = 0
        func check(_ what: String, _ ok: Bool) {
            print((ok ? "PASS  " : "FAIL  ") + what)
            if !ok { failed += 1 }
        }

        /// Random lengths up to `max`, and valid seeds with bytes flipped, cut short or extended.
        func inputs(seeds: [[UInt8]], max: Int, _ body: ([UInt8]) -> Void) {
            for i in 0..<rounds {
                if i % 2 == 0 || seeds.isEmpty {
                    body((0..<rng.below(max + 1)).map { _ in rng.byte() })
                } else {
                    var p = seeds[rng.below(seeds.count)]
                    switch rng.below(3) {
                    case 0: for _ in 0...rng.below(4) where !p.isEmpty { p[rng.below(p.count)] = rng.byte() }
                    case 1: p = Array(p.prefix(rng.below(p.count + 1)))
                    default: p += (0..<rng.below(64)).map { _ in rng.byte() }
                    }
                    body(p)
                }
            }
        }

        // VBAN audio headers: a valid packet must decode; nothing malformed may.
        var valid = [UInt8](repeating: 0, count: VBAN.headerBytes + 256 * 2 * 2)
        let samples = [Float](repeating: 0.25, count: 256 * 2)
        let length = samples.withUnsafeBufferPointer {
            VBAN.writeAudioPacket(into: &valid, samples: $0.baseAddress!, frames: 256, channels: 2,
                                  sampleRate: 48000, dataType: .int16, name: "Fuzz", counter: 1) ?? 0
        }
        valid = Array(valid.prefix(length))
        check("VBAN: the valid seed decodes", valid.withUnsafeBufferPointer {
            VBAN.audioHeader($0.baseAddress!, $0.count) != nil })
        var accepted = 0, wrongLength = 0
        inputs(seeds: [valid], max: 1600) { p in
            guard !p.isEmpty else { return }
            p.withUnsafeBufferPointer {
                if let h = VBAN.audioHeader($0.baseAddress!, $0.count) {
                    accepted += 1
                    if VBAN.headerBytes + h.frames * h.channels * h.dataType.bytesPerSample != $0.count { wrongLength += 1 }
                }
            }
        }
        check("VBAN: \(rounds) inputs, no crash; every accepted header matches its length (\(accepted) accepted)", wrongLength == 0)

        // VBAN service messages.
        let control = VBANControl.encode(.init(kind: .beacon, name: "Fuzz",
                                               format: .init(sampleRate: 48000, channels: 2, dataType: .int16),
                                               port: 6981), headerName: "Fuzz")
        var controlAccepted = 0
        inputs(seeds: [control], max: 512) { p in if VBANControl.decode(p) != nil { controlAccepted += 1 } }
        check("VBAN service: \(rounds) inputs, no crash (\(controlAccepted) accepted)", true)

        // SAP, and the SDP inside it.
        let sdp = "v=0\r\no=- 1 1 IN IP4 192.0.2.10\r\ns=Fuzz\r\nc=IN IP4 233.252.0.1/32\r\nt=0 0\r\n"
            + "m=audio 5004 RTP/AVP 96\r\na=rtpmap:96 L24/48000/2\r\na=ptime:1\r\n"
        let sap: [UInt8] = [0x20, 0, 0, 1, 192, 0, 2, 10] + Array("application/sdp".utf8) + [0] + Array(sdp.utf8)
        check("SAP: the valid seed decodes", SAPListener.decode(sap) != nil)
        check("SDP: the valid seed parses", SDPParser.parse(sdp, source: .sap) != nil)
        var sapAccepted = 0, sdpAccepted = 0, sdpInsane = 0
        inputs(seeds: [sap], max: 1200) { p in
            if let (text, _) = SAPListener.decode(p) {
                sapAccepted += 1
                if let d = SDPParser.parse(text, source: .sap) {
                    sdpAccepted += 1
                    if d.channels < 1 || d.channels > 64 || d.sampleRate < 8000 || d.sampleRate > 384_000 || d.ptimeMs <= 0 { sdpInsane += 1 }
                }
            }
        }
        check("SAP → SDP: \(rounds) inputs, no crash (\(sapAccepted) SAP, \(sdpAccepted) SDP accepted)", true)
        check("SDP: nothing accepted with an impossible format (\(sdpInsane))", sdpInsane == 0)

        // Scream: a valid packet decodes; nothing accepted may disagree with its length.
        let screamSeed: [UInt8] = [0x01, 16, 2, 0x03, 0x00] + [UInt8](repeating: 0x10, count: 1152)
        check("Scream: the valid seed decodes", screamSeed.withUnsafeBufferPointer {
            Scream.header($0.baseAddress!, $0.count) != nil })
        var screamAccepted = 0, screamWrong = 0
        inputs(seeds: [screamSeed], max: 1400) { p in
            guard !p.isEmpty else { return }
            p.withUnsafeBufferPointer {
                if let h = Scream.header($0.baseAddress!, $0.count) {
                    screamAccepted += 1
                    if Scream.headerBytes + h.frames * h.channels * h.encoding.bytesPerSample != $0.count
                        || !(8000...384_000).contains(h.sampleRate) { screamWrong += 1 }
                }
            }
        }
        check("Scream: \(rounds) inputs, no crash; every accepted packet matches its length and a real rate (\(screamAccepted) accepted)", screamWrong == 0)

        // Internet streams: the response head, ICY metadata, playlists and URLs. Nothing
        // may crash; an accepted head must have a real status and a body offset inside the input.
        let headSeed = Array("ICY 200 OK\r\ncontent-type: audio/aac\r\nicy-metaint: 8192\r\nicy-name: Test\r\n\r\nAUDIO".utf8)
        var headsAccepted = 0, headsWrong = 0
        inputs(seeds: [headSeed, Array("HTTP/1.0 302 Found\r\nLocation: http://x/\r\n\r\n".utf8)], max: 600) { p in
            if case .head(let h)? = WebParsing.head(p) {
                headsAccepted += 1
                if !(100...599).contains(h.status) || h.length > p.count || (h.metaInterval.map { $0 < 1 } ?? false) { headsWrong += 1 }
            }
        }
        check("HTTP/ICY head: \(rounds) inputs, no crash; every accepted head is sane (\(headsAccepted) accepted)", headsWrong == 0)
        let metaSeed = Array("StreamTitle='Artist - Song';StreamUrl='';".utf8) + [0, 0, 0]
        var titlesTooLong = 0
        inputs(seeds: [metaSeed], max: 4200) { p in
            if let t = WebParsing.streamTitle(p), t.count > 300 { titlesTooLong += 1 }
        }
        check("ICY metadata: \(rounds) inputs, no crash; no title over 300 characters", titlesTooLong == 0)
        let listSeed = Array("[playlist]\nFile1=http://192.0.2.1:8000/stream\n#EXTM3U\n".utf8)
        var badPlaylist = 0
        inputs(seeds: [listSeed], max: 2000) { p in
            if case .stream(let url) = WebParsing.playlist(String(decoding: p, as: UTF8.self)),
               !(url.lowercased().hasPrefix("http://") || url.lowercased().hasPrefix("https://")) { badPlaylist += 1 }
            _ = WebParsing.target(String(decoding: p, as: UTF8.self))
        }
        check("Playlists and URLs: \(rounds) inputs, no crash; a playlist only ever yields an http(s) address", badPlaylist == 0)

        // The reader every new parser is built on: no read may pass the end.
        var readerBad = 0
        for _ in 0..<rounds / 10 {
            let bytes = (0..<rng.below(40)).map { _ in rng.byte() }
            bytes.withUnsafeBufferPointer { buf in
                guard let base = buf.baseAddress else { return }
                var r = ByteReader(base, count: buf.count)
                while r.remaining > 0 {
                    switch rng.below(5) {
                    case 0: _ = r.u8()
                    case 1: _ = r.u16be()
                    case 2: _ = r.u32le()
                    case 3: _ = r.bytes(rng.below(12))
                    default: _ = r.skip(rng.below(6))
                    }
                    if r.offset > r.count { readerBad += 1; break }
                    if rng.below(8) == 0 { break }
                }
            }
        }
        check("ByteReader: never reads past the end (\(readerBad))", readerBad == 0)

        print(failed == 0 ? "All passed." : "\(failed) failed.")
        exit(failed == 0 ? 0 : 1)
    }
}
