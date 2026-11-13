import Foundation
import NetworkAudioEngine

// `NetworkAudioEngineCheck`: the shared engine on its own, on any platform. The Windows
// build's first milestone is this printing "All passed." — it proves the engine compiles there
// and speaks the protocol byte for byte as the Mac apps do (`docs/PROTOCOL.md`). Touches no
// network, no audio device and no settings.

var failures = 0
func check(_ what: String, _ ok: Bool) {
    print((ok ? "PASS  " : "FAIL  ") + what)
    if !ok { failures += 1 }
}

// The protocol's sample packets, as the document gives them.
for v in ProtocolVectors.all {
    check("protocol \(v.label): the documented bytes", ProtocolVectors.expected[v.label] == ProtocolVectors.hex(v.bytes))
    if let m = VBANControl.decode(v.bytes) {
        check("protocol \(v.label): decodes and re-encodes the same",
              VBANControl.encode(m).dropFirst(VBAN.headerBytes) == v.bytes.dropFirst(VBAN.headerBytes))
    }
}
for c in ProtocolVectors.codes {
    check("Remote link code (\(c.label)): documented, and reads back",
          ProtocolVectors.expected["CODE " + c.label] == c.text && RemoteCode(text: c.text) == c.code)
}
check("Remote link code: a mistyped character is caught",
      RemoteCode(text: String(ProtocolVectors.codes[0].text.dropLast()) + "0") == nil
        || RemoteCode(text: String(ProtocolVectors.codes[0].text.dropLast()) + "0") != ProtocolVectors.codes[0].code)

// The Remote link's sealing (protocol v2).
do {
    let keys = RemoteSeal.keys(senderSecret: ProtocolVectors.sealSenderSecret,
                               receiverSecret: ProtocolVectors.sealReceiverSecret)
    let pending = ProtocolVectors.all.first { $0.label == "PENDING" }!.bytes
    let sealed = ProtocolVectors.all.first { $0.label == "SEALED" }!.bytes
    check("sealed: overhead is 37 bytes", sealed.count == pending.count + RemoteSeal.overhead)
    check("sealed: the Grabber opens it to the PENDING it was",
          RemoteOpener(key: keys.senderToReceiver).open(sealed) == pending)
    check("sealed: the other direction's key can't open it",
          RemoteOpener(key: keys.receiverToSender).open(sealed) == nil)
    let wrong = RemoteSeal.keys(senderSecret: RemoteSeal.newSecret(), receiverSecret: ProtocolVectors.sealReceiverSecret)
    check("sealed: a key from another secret can't open it", RemoteOpener(key: wrong.senderToReceiver).open(sealed) == nil)
    var tampered = sealed; tampered[30] ^= 0x01
    check("sealed: one bit changed in the body is refused", RemoteOpener(key: keys.senderToReceiver).open(tampered) == nil)
    var header = sealed; header[13] ^= 0x01                 // the counter, in the authenticated header
    check("sealed: one bit changed in the header is refused", RemoteOpener(key: keys.senderToReceiver).open(header) == nil)
    let opener = RemoteOpener(key: keys.senderToReceiver)
    let sealer = RemoteSealer(key: keys.senderToReceiver)
    let packets = (0..<6).map { i in sealer.seal([UInt8](repeating: UInt8(i), count: 100)) }
    check("sealed: a run of packets opens in order", packets.prefix(3).allSatisfy { opener.open($0) != nil })
    check("sealed: one arriving late, within the window, opens",
          opener.open(packets[5]) != nil && opener.open(packets[4]) != nil && opener.open(packets[3]) != nil)
    check("sealed: a replay is refused", opener.open(packets[4]) == nil && opener.open(packets[0]) == nil)
    let restarted = RemoteSealer(key: keys.senderToReceiver)          // a new run: a new epoch
    let fresh = restarted.seal([1, 2, 3])
    check("sealed: a new run is refused while the current one is still talking", opener.open(fresh) == nil)
    Thread.sleep(forTimeInterval: RemoteOpener.newEpochAfterQuiet + 0.1)
    check("sealed: …and taken once it has gone quiet (the other end restarted)", opener.open(restarted.seal([4, 5])) == [4, 5])
    check("sealed: the old run's packets are refused after that", opener.open(packets[1]) == nil)
    check("sealed: a plain packet is not taken for a sealed one",
          ProtocolVectors.all.first { $0.label == "AUDIO" }!.bytes.withUnsafeBufferPointer { !RemoteSeal.isSealed($0.baseAddress!, $0.count) })
}

// The cookie's SHA-256/HMAC (FIPS 180-4, RFC 4231).
check("SHA-256 of \"abc\"", ProtocolVectors.hex(SHA256.hash(Array("abc".utf8)))
      == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
check("HMAC-SHA256, RFC 4231 case 2", ProtocolVectors.hex(SHA256.hmac(key: Array("Jefe".utf8),
      message: Array("what do ya want for nothing?".utf8)))
      == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
let cookies = VBANCookie()
let cookie = cookies.make(ip: "192.0.2.20", port: 6980)
check("cookie: accepted from where it was sent", cookies.verify(cookie, ip: "192.0.2.20", port: 6980))
check("cookie: refused from another port", !cookies.verify(cookie, ip: "192.0.2.20", port: 6981))

// VBAN audio: the sample packet reads back as what was written.
let audio = ProtocolVectors.all.first { $0.label == "AUDIO" }!.bytes
let header = audio.withUnsafeBufferPointer { VBAN.audioHeader($0.baseAddress!, $0.count) }
check("VBAN audio header: 48 kHz, 2 frames, 2 ch, 16-bit, \"Mac Audio\", counter 7",
      header?.sampleRate == 48000 && header?.frames == 2 && header?.channels == 2
        && header?.dataType == .int16 && header?.name == "Mac Audio" && header?.counter == 7)

// SDP, as an AES67 sender announces a stream.
let sdp = """
v=0\r\no=- 1 1 IN IP4 192.0.2.44\r\ns=Stagebox-1 TX 1-2\r\nc=IN IP4 233.252.0.12/32\r\nt=0 0\r
m=audio 5004 RTP/AVP 96\r\na=rtpmap:96 L24/48000/2\r\na=ptime:1\r\na=ts-refclk:ptp=IEEE1588-2008:00-00-00-FF-FE-00-00-01:0\r\n
"""
let d = SDPParser.parse(sdp, source: .sap)
check("SDP: name, group, port, L24, 48 kHz, 2 ch, 1 ms",
      d?.name == "Stagebox-1 TX 1-2" && d?.groupAddress == "233.252.0.12" && d?.port == 5004
        && d?.sampleRate == 48000 && d?.channels == 2 && d?.ptimeMs == 1)

// Dante label: from the SDP's own keyword, not from the sender's address.
check("Dante: a=keywds:Dante is Dante, another maker's SDP from the same PC is not",
      GrabberEngine.sdpSaysDante("v=0\r\no=- 1 1 IN IP4 192.0.2.44\r\na=keywds:Dante\r\nm=audio 5004 RTP/AVP 97\r\n")
        && !GrabberEngine.sdpSaysDante(sdp))

// Addresses: what counts as here and what as elsewhere.
check("addresses: private is here, documentation range TEST-NET-3 is here",
      !RemoteAddresses.isRemote("192.168.1.20") && !RemoteAddresses.isRemote("203.0.113.5"))
check("addresses: 100.64/10 is a VPN", RemoteAddresses.isVPN("100.64.0.10"))

// Gone: a playing stream whose sender has left.
check("gone: VBAN quiet and unheard for 30 s is gone",
      GrabberEngine.isGone(source: .vban, quiet: 31, unheard: 31, announceLimit: 120))
check("gone: VBAN still beaconing is not gone (no packets, but the sender is there)",
      !GrabberEngine.isGone(source: .vban, quiet: 600, unheard: 2, announceLimit: 120))
check("gone: SAP waits for its announcements to lapse, not just 30 s",
      !GrabberEngine.isGone(source: .sap, quiet: 60, unheard: 60, announceLimit: 120)
        && GrabberEngine.isGone(source: .sap, quiet: 130, unheard: 121, announceLimit: 120))
check("gone: a short drop-out is not gone, and internet streams never are",
      !GrabberEngine.isGone(source: .ravenna, quiet: 10, unheard: 500, announceLimit: 120)
        && !GrabberEngine.isGone(source: .web, quiet: 900, unheard: 900, announceLimit: 120))

// A Sender renamed while its old name played from broadcast audio alone: its beacon
// comes from the port the audio did.
let playing: Set<String> = ["vban:192.0.2.20/Old name", "vban:192.0.2.20/Other app", "vban:192.0.2.21/Old name"]
let ports: [String: UInt16] = ["vban:192.0.2.20/Old name": 6981, "vban:192.0.2.20/Other app": 50000,
                               "vban:192.0.2.21/Old name": 6981]
check("rename by port: same address and port, audio stopped, is the old name",
      VBANListener.renamedByPort(beacon: "vban:192.0.2.20/New name", ip: "192.0.2.20", port: 6981, wanted: playing,
                                 audioPorts: ports, owned: [], flowing: []) == ["vban:192.0.2.20/Old name"])
check("rename by port: not while the old audio still flows, nor a name another Sender beacons",
      VBANListener.renamedByPort(beacon: "vban:192.0.2.20/New name", ip: "192.0.2.20", port: 6981, wanted: playing,
                                 audioPorts: ports, owned: [], flowing: ["vban:192.0.2.20/Old name"]).isEmpty
        && VBANListener.renamedByPort(beacon: "vban:192.0.2.20/New name", ip: "192.0.2.20", port: 6981, wanted: playing,
                                      audioPorts: ports, owned: ["vban:192.0.2.20/Old name"], flowing: []).isEmpty)
check("rename by port: another port or another address is another sender",
      VBANListener.renamedByPort(beacon: "vban:192.0.2.20/New name", ip: "192.0.2.20", port: 6982, wanted: playing,
                                 audioPorts: ports, owned: [], flowing: []).isEmpty
        && VBANListener.renamedByPort(beacon: "vban:192.0.2.22/New name", ip: "192.0.2.22", port: 6981, wanted: playing,
                                      audioPorts: ports, owned: [], flowing: []).isEmpty)

// Priority marking: the send socket carries DSCP EF. Opens a socket on any port and
// reads the marking back; sends nothing. Windows does not mark yet, so it is checked on a Mac only.
#if canImport(Darwin)
check("send socket marked as audio (DSCP EF)",
      UDPSocket.open(ports: [0], audio: true)?.dscp == UDPSocket.audioDSCP
        && UDPSocket.open(ports: [0])?.dscp == 0)
#endif

print(failures == 0 ? "All passed." : "\(failures) failed.")
exit(failures == 0 ? 0 : 1)
