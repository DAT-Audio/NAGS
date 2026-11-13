import Foundation
import CryptoKit

/// `NetworkAudioGrabber --checkvban`
///
/// Fixed checks of the Sender ↔ Grabber handshake's wire format and cookie (VBAN stage 3), with
/// no network at all. Exits 1 if any case fails. `Tools/vban_offer_test.py` covers the same
/// handshake live, against a running Sender.
enum VBANCheck {
    static func run() -> Never {
        var failed = 0
        func check(_ what: String, _ ok: Bool) {
            print((ok ? "PASS  " : "FAIL  ") + what)
            if !ok { failed += 1 }
        }
        typealias M = VBANControl.Message
        let format = VBANControl.Format(sampleRate: 48000, channels: 2, dataType: .int24)
        let nonce = VBANControl.randomNonce(), cookie = [UInt8](repeating: 7, count: 16)
        let messages: [M] = [
            M(kind: .beacon, name: "Studio Mac", format: format, port: 6981),
            // With the Sender's identity; the line above is an older Sender's.
            M(kind: .beacon, name: "Studio Mac", format: format, port: 6981,
              instance: [1, 2, 3, 4, 5, 6, 7, 8]),
            M(kind: .subscribe, nonce: nonce, name: "Control Room"),
            M(kind: .challenge, nonce: nonce, cookie: cookie),
            M(kind: .confirm, nonce: nonce, cookie: cookie, name: "Control Room"),
            M(kind: .offer, name: "Studio Mac", format: format),
            M(kind: .keepalive, cookie: cookie, name: "Control Room"),
            M(kind: .unsubscribe, cookie: cookie),
        ]
        for m in messages {
            let bytes = VBANControl.encode(m, headerName: "x")
            check("\(m.kind): round trip", VBANControl.decode(bytes) == m)
            check("\(m.kind): every truncation rejected or still well-formed",
                  (0..<bytes.count).allSatisfy { n in
                      guard let d = VBANControl.decode(Array(bytes.prefix(n))) else { return true }
                      return d.kind == m.kind              // a shorter packet may drop only optional fields
                  })
            check("\(m.kind): not taken for audio",
                  bytes.withUnsafeBufferPointer { VBAN.audioHeader($0.baseAddress!, $0.count) } == nil)
        }
        let subscribe = VBANControl.encode(M(kind: .subscribe, nonce: nonce))
        let challenge = VBANControl.encode(M(kind: .challenge, nonce: nonce, cookie: cookie))
        check("a SUBSCRIBE is never shorter than its CHALLENGE (no amplification)",
              subscribe.count >= VBANControl.minSubscribeBytes && subscribe.count >= challenge.count)
        check("an unpadded SUBSCRIBE is refused",
              VBANControl.decode(Array(subscribe.prefix(40))) == nil)
        check("missing required fields are refused",
              VBANControl.decode(VBANControl.encode(M(kind: .beacon, name: "No Format"))) == nil
                  && VBANControl.decode(VBANControl.encode(M(kind: .keepalive))) == nil)
        var unknown = VBANControl.encode(M(kind: .unsubscribe, cookie: cookie))
        unknown += [0xEE, 3, 1, 2, 3]                       // a field a later version might add
        check("an unknown field is skipped", VBANControl.decode(unknown)?.cookie == cookie)
        var wrongVersion = VBANControl.encode(M(kind: .unsubscribe, cookie: cookie))
        wrongVersion[32] = 99
        check("another version is refused", VBANControl.decode(wrongVersion) == nil)
        var audio = [UInt8](repeating: 0, count: 28 + 1024)
        audio.withUnsafeMutableBufferPointer { p in
            let s = [Float](repeating: 0, count: 512)
            _ = s.withUnsafeBufferPointer { VBAN.writeAudioPacket(into: p.baseAddress!, samples: $0.baseAddress!,
                                                                  frames: 256, channels: 2, sampleRate: 48000,
                                                                  dataType: .int16, name: "A", counter: 0) }
        }
        check("an audio packet is not taken for a handshake message", VBANControl.decode(audio) == nil)
        var rng = SystemRandomNumberGenerator()
        let survived = (0..<20000).allSatisfy { _ -> Bool in
            var b = VBANControl.encode(messages.randomElement()!)
            for _ in 0..<Int.random(in: 0...6) { b[Int.random(in: 0..<b.count)] = UInt8.random(in: 0...255, using: &rng) }
            _ = VBANControl.decode(Array(b.prefix(Int.random(in: 0...b.count))))
            return true
        }
        check("20,000 corrupted packets decoded without a crash", survived)

        let jar = VBANCookie()
        let issued = jar.make(ip: "192.0.2.40", port: 6980)
        check("cookie: accepted from the address it was issued to", jar.verify(issued, ip: "192.0.2.40", port: 6980))
        check("cookie: refused from another port", !jar.verify(issued, ip: "192.0.2.40", port: 6981))
        check("cookie: refused from another address", !jar.verify(issued, ip: "192.0.2.41", port: 6980))
        check("cookie: still good in the next 30 s window",
              jar.verify(issued, ip: "192.0.2.40", port: 6980, at: Date().addingTimeInterval(VBANCookie.bucketSeconds)))
        check("cookie: expired after two windows",
              !jar.verify(issued, ip: "192.0.2.40", port: 6980, at: Date().addingTimeInterval(VBANCookie.bucketSeconds * 2.5)))
        check("cookie: another launch's secret does not accept it",
              !VBANCookie().verify(issued, ip: "192.0.2.40", port: 6980))

        // Another location: which addresses read as the internet, and the outside
        // address lookup's reply parsing. Documentation addresses only (the project's rule).
        check("remote: private, link-local, loopback and VPN ranges are here",
              !["10.1.2.3", "172.20.0.5", "192.168.1.9", "169.254.3.4", "127.0.0.1", "100.101.102.103"]
                .contains { RemoteAddresses.isRemote($0, documentationIsLocal: false) })
        check("remote: an internet address is somewhere else", RemoteAddresses.isRemote("203.0.113.40", documentationIsLocal: false))
        check("remote: documentation addresses are here in the harness", !RemoteAddresses.isRemote("203.0.113.40"))
        check("remote: not an address is not remote", !RemoteAddresses.isRemote("studio-pc"))
        check("remote: the host of address:port", RemoteAddresses.host(" 203.0.113.40:6980 ") == "203.0.113.40")
        let tid: [UInt8] = Array(1...12)
        let xored = [203, 0, 113, 40].enumerated().map { UInt8($0.element) ^ [0x21, 0x12, 0xA4, 0x42][$0.offset] }
        let reply: [UInt8] = [0x01, 0x01, 0x00, 0x0C, 0x21, 0x12, 0xA4, 0x42] + tid
            + [0x00, 0x20, 0x00, 0x08, 0x00, 0x01, 0x00, 0x00] + xored
        check("outside address: a Binding reply reads as 203.0.113.40", OutsideAddress.parse(reply, transaction: tid) == "203.0.113.40")
        check("outside address: another transaction's reply is ignored", OutsideAddress.parse(reply, transaction: Array(repeating: 9, count: 12)) == nil)
        check("outside address: a cut-off reply is ignored", OutsideAddress.parse(Array(reply.prefix(26)), transaction: tid) == nil)
        check("outside address: noise is ignored", OutsideAddress.parse((0..<64).map { UInt8($0 * 37 & 0xFF) }, transaction: tid) == nil)

        // Remote link codes: round trip, forgiving typing, refusing a wrong or damaged one.
        // The engine's own SHA-256/HMAC (no CryptoKit on Windows): RFC 4231's test
        // cases, then CryptoKit on random keys and messages of every length that matters.
        check("SHA-256 of \"abc\" (FIPS 180-4)", ProtocolVectors.hex(SHA256.hash(Array("abc".utf8)))
              == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        check("HMAC-SHA256, RFC 4231 case 2", ProtocolVectors.hex(SHA256.hmac(key: Array("Jefe".utf8),
              message: Array("what do ya want for nothing?".utf8)))
              == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
        check("HMAC-SHA256, RFC 4231 case 6 (131-byte key)", ProtocolVectors.hex(SHA256.hmac(
              key: [UInt8](repeating: 0xaa, count: 131),
              message: Array("Test Using Larger Than Block-Size Key - Hash Key First".utf8)))
              == "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54")
        var same = true
        for length in [0, 1, 55, 56, 63, 64, 65, 119, 120, 200, 1000] {
            let key = (0..<32).map { _ in UInt8.random(in: 0...255) }
            let message = (0..<length).map { _ in UInt8.random(in: 0...255) }
            let theirs = Array(HMAC<CryptoKit.SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
            if SHA256.hmac(key: key, message: message) != theirs { same = false }
        }
        check("HMAC-SHA256 matches CryptoKit at every padding boundary", same)

        // docs/PROTOCOL.md's sample packets: the encoders still make exactly what
        // the document says, and each decodes back to itself. A failure here is a protocol change.
        for v in ProtocolVectors.all {
            check("protocol vector \(v.label): encoder makes the documented bytes",
                  ProtocolVectors.expected[v.label] == ProtocolVectors.hex(v.bytes))
            if let m = VBANControl.decode(v.bytes) {
                check("protocol vector \(v.label): decodes and re-encodes the same",
                      VBANControl.encode(m, headerName: "") .dropFirst(VBAN.headerBytes) == v.bytes.dropFirst(VBAN.headerBytes))
            }
        }
        for c in ProtocolVectors.codes {
            check("protocol code (\(c.label)): documented text, and reads back",
                  ProtocolVectors.expected["CODE " + c.label] == c.text && RemoteCode(text: c.text) == c.code)
        }
        let sendingCode = RemoteCode(role: .sending, address: "203.0.113.40", port: 6981)
        check("remote code: reads back as it was written", RemoteCode(text: sendingCode.text) == sendingCode)
        check("remote code: NAG- and eight groups (version 2, with the secret)", sendingCode.text.split(separator: "-").count == 9 && sendingCode.text.hasPrefix("NAG-"))
        check("remote code: an older (version 1) code is recognised as one", RemoteCode.isOlderVersion("NAG-2B5G-0W8Y-3D2RE") && RemoteCode(text: "NAG-2B5G-0W8Y-3D2RE") == nil)
        check("remote code: case, spaces and O/I/L typed for 0/1 are forgiven",
              RemoteCode(text: " " + sendingCode.text.lowercased().replacingOccurrences(of: "-", with: " ")
                                      .replacingOccurrences(of: "0", with: "o").replacingOccurrences(of: "1", with: "l") + " ") == sendingCode)
        var damaged = Array(sendingCode.text)
        damaged[damaged.count - 3] = damaged[damaged.count - 3] == "A" ? "B" : "A"
        check("remote code: a mistyped character is caught", RemoteCode(text: String(damaged)) == nil)
        check("remote code: the receiving end's is told apart",
              RemoteCode(text: RemoteCode(role: .receiving, address: "198.51.100.7", port: 6980).text)?.role == .receiving)
        check("remote code: not a code at all", RemoteCode(text: "hello") == nil && RemoteCode(text: "") == nil)

        print(failed == 0 ? "All passed." : "\(failed) failed.")
        exit(failed == 0 ? 0 : 1)
    }
}
