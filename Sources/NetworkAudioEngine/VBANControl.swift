import Foundation

/// The Sender ↔ Grabber handshake: how a Sender offers
/// its stream on the network and a Grabber asks for it, so audio goes only to whoever listens.
///
/// **Carried in VBAN service packets**, which a strict VBAN receiver ignores, so the audio itself
/// stays plain VBAN that Voicemeeter and VBAN Receptor still play. Not the text sub-protocol:
/// Voicemeeter reads incoming VBAN text as remote-control commands.
///
/// Layout: the usual 28-byte VBAN header with sub-protocol `0x60` (service), our service type in
/// byte 5, then a payload of a 4-byte magic, a version byte, a message type byte and a list of
/// tagged fields (tag, length, value). **Unknown tags are skipped**, which is how later versions
/// add fields — the receiver name is one — without breaking older builds.
///
/// Everything here reads untrusted bytes: every length is checked before it is used.
public enum VBANControl {
    /// The Sender's control port, which it also sends its audio from.
    public static let controlPort = 6981
    /// Our service type. **Verify** against VB-Audio's current specification before relying on it
    /// being unallocated; the published ones are 0 (identification), 1 (chat) and 32–33.
    public static let serviceType: UInt8 = 0x4E
    static let magic: [UInt8] = Array("NAGS".utf8)
    public static let version: UInt8 = 1
    public static let maxPacket = 512
    /// A SUBSCRIBE shorter than this is ignored, and it is longer than any CHALLENGE, so the
    /// reply to a request can never be bigger than the request: nothing to amplify.
    public static let minSubscribeBytes = 128

    public enum Kind: UInt8 {
        case beacon = 1, subscribe, challenge, confirm, offer, keepalive, unsubscribe
        /// Sender → Grabber after a valid CONFIRM from a Grabber it has not been told to allow:
        /// its user has been asked. The Grabber keeps confirming, slowly, until OFFER or DECLINED.
        case pending
        /// Sender → Grabber: its user said no. The Grabber stops asking.
        case declined
    }

    public struct Format: Equatable {
        public var sampleRate: Int
        public var channels: Int
        public var dataType: VBAN.DataType
        public init(sampleRate: Int, channels: Int, dataType: VBAN.DataType) {
            self.sampleRate = sampleRate; self.channels = channels; self.dataType = dataType
        }
    }

    public struct Message: Equatable {
        public var kind: Kind
        public var nonce: [UInt8]?
        public var cookie: [UInt8]?
        /// The stream's name (BEACON, OFFER) or the receiver's (SUBSCRIBE, CONFIRM, KEEPALIVE).
        public var name: String?
        public var format: Format?
        public var port: Int?
        /// BEACON: the Sender's own random identity for this run. A Sender on several
        /// networks beacons from each of its addresses, and without this a Grabber that hears two
        /// of them — the same Mac, or two paths on one LAN — listed the one stream once per address.
        /// Older Grabbers skip the unknown field.
        public var instance: [UInt8]?

        public init(kind: Kind, nonce: [UInt8]? = nil, cookie: [UInt8]? = nil, name: String? = nil,
                    format: Format? = nil, port: Int? = nil, instance: [UInt8]? = nil) {
            self.kind = kind; self.nonce = nonce; self.cookie = cookie; self.name = name
            self.format = format; self.port = port; self.instance = instance
        }
    }

    enum Tag: UInt8 { case nonce = 1, cookie, name, format, port, padding, instance }
    public static let instanceBytes = 8
    public static let nonceBytes = 8
    public static let cookieBytes = 16

    // MARK: - Writing

    /// The whole datagram. `headerName` goes in the VBAN header's name field, where a packet
    /// sniffer would show it; nothing reads it back.
    public static func encode(_ m: Message, headerName: String = "") -> [UInt8] {
        var out: [UInt8] = [0x56, 0x42, 0x41, 0x4E, 0x60, serviceType, 0, 0]
        let name = Array(VBAN.wireName(headerName).utf8)
        out += (0..<16).map { $0 < name.count ? name[$0] : 0 }
        out += [0, 0, 0, 0]
        out += magic + [version, m.kind.rawValue]
        func field(_ tag: Tag, _ value: [UInt8]) { out += [tag.rawValue, UInt8(value.count)] + value }
        if let n = m.nonce, n.count == nonceBytes { field(.nonce, n) }
        if let c = m.cookie, c.count == cookieBytes { field(.cookie, c) }
        if let n = m.name, !VBAN.wireName(n).isEmpty { field(.name, Array(VBAN.wireName(n).utf8)) }
        if let f = m.format {
            let r = UInt32(clamping: f.sampleRate), c = UInt16(clamping: f.channels)
            field(.format, [UInt8(r & 0xFF), UInt8(r >> 8 & 0xFF), UInt8(r >> 16 & 0xFF), UInt8(r >> 24),
                            UInt8(c & 0xFF), UInt8(c >> 8), f.dataType.rawValue])
        }
        if let p = m.port { let v = UInt16(clamping: p); field(.port, [UInt8(v & 0xFF), UInt8(v >> 8)]) }
        if let n = m.instance, n.count == instanceBytes { field(.instance, n) }
        if m.kind == .subscribe, out.count < minSubscribeBytes {
            field(.padding, [UInt8](repeating: 0, count: max(0, minSubscribeBytes - out.count - 2)))
        }
        return out
    }

    // MARK: - Reading

    /// A handshake message, or nil for anything else — audio, another app's service packet, or
    /// anything malformed, truncated or missing a field its kind needs.
    public static func decode(_ p: UnsafePointer<UInt8>, _ length: Int) -> Message? {
        let payload = VBAN.headerBytes
        guard length >= payload + 6, length <= maxPacket,
              p[0] == 0x56, p[1] == 0x42, p[2] == 0x41, p[3] == 0x4E,
              p[4] & 0xE0 == 0x60, p[5] == serviceType,
              p[payload] == magic[0], p[payload + 1] == magic[1],
              p[payload + 2] == magic[2], p[payload + 3] == magic[3],
              p[payload + 4] == version,
              let kind = Kind(rawValue: p[payload + 5]) else { return nil }
        var m = Message(kind: kind)
        var i = payload + 6
        while i < length {
            guard i + 2 <= length else { return nil }
            let tag = p[i], count = Int(p[i + 1])
            let v = i + 2
            guard v + count <= length else { return nil }
            switch Tag(rawValue: tag) {
            case .nonce?:
                guard count == nonceBytes else { return nil }
                m.nonce = Array(UnsafeBufferPointer(start: p + v, count: count))
            case .cookie?:
                guard count == cookieBytes else { return nil }
                m.cookie = Array(UnsafeBufferPointer(start: p + v, count: count))
            case .name?:
                guard count >= 1, count <= 16 else { return nil }
                let text = String(decoding: UnsafeBufferPointer(start: p + v, count: count), as: UTF8.self)
                m.name = VBAN.wireName(text)
            case .format?:
                guard count == 7 else { return nil }
                let rate = Int(p[v]) | Int(p[v + 1]) << 8 | Int(p[v + 2]) << 16 | Int(p[v + 3]) << 24
                let channels = Int(p[v + 4]) | Int(p[v + 5]) << 8
                guard VBAN.sampleRates.contains(rate), (1...256).contains(channels),
                      let type = VBAN.DataType(rawValue: p[v + 6]) else { return nil }
                m.format = Format(sampleRate: rate, channels: channels, dataType: type)
            case .port?:
                guard count == 2 else { return nil }
                let port = Int(p[v]) | Int(p[v + 1]) << 8
                guard port > 0 else { return nil }
                m.port = port
            case .instance?:
                guard count == instanceBytes else { return nil }
                m.instance = Array(UnsafeBufferPointer(start: p + v, count: count))
            case .padding?, nil:
                break                                   // unknown tags are skipped, by design
            }
            i = v + count
        }
        switch kind {
        case .beacon:      guard m.name != nil, m.format != nil, m.port != nil else { return nil }
        case .subscribe:   guard m.nonce != nil, length >= minSubscribeBytes else { return nil }
        case .challenge,
             .confirm:     guard m.nonce != nil, m.cookie != nil else { return nil }
        case .offer:       guard m.name != nil, m.format != nil else { return nil }
        case .keepalive,
             .unsubscribe: guard m.cookie != nil else { return nil }
        case .pending,
             .declined:    break
        }
        return m
    }

    public static func decode(_ bytes: [UInt8]) -> Message? {
        bytes.withUnsafeBufferPointer { b in b.baseAddress.flatMap { decode($0, b.count) } }
    }

    public static func randomNonce() -> [UInt8] { (0..<nonceBytes).map { _ in UInt8.random(in: 0...255) } }
}

/// The Sender's proof that a subscriber really receives at the address it claims, **without
/// keeping any state until it does**.
///
/// Without it, one forged SUBSCRIBE with a victim's address as its source would make the Sender
/// stream megabits at the victim: a textbook UDP amplification. The cookie is an HMAC of the
/// requester's address and port and a 30-second time bucket, under a secret made fresh each
/// launch, so only someone who received the CHALLENGE at that address can send it back.
public struct VBANCookie {
    private let key: [UInt8] = {
        var g = SystemRandomNumberGenerator()
        return (0..<32).map { _ in UInt8.random(in: 0...255, using: &g) }
    }()
    public static let bucketSeconds = 30.0

    public init() {}

    public func make(ip: String, port: Int, at date: Date = Date()) -> [UInt8] {
        make(ip: ip, port: port, bucket: Int(date.timeIntervalSince1970 / Self.bucketSeconds))
    }

    /// Accepts this bucket or the one before, so a CHALLENGE answered across a boundary works.
    public func verify(_ cookie: [UInt8], ip: String, port: Int, at date: Date = Date()) -> Bool {
        guard cookie.count == VBANControl.cookieBytes else { return false }
        let bucket = Int(date.timeIntervalSince1970 / Self.bucketSeconds)
        return [bucket, bucket - 1].contains { Self.equal(make(ip: ip, port: port, bucket: $0), cookie) }
    }

    private func make(ip: String, port: Int, bucket: Int) -> [UInt8] {
        let message = Array("\(ip)|\(port)|\(bucket)".utf8)
        return Array(SHA256.hmac(key: key, message: message).prefix(VBANControl.cookieBytes))
    }

    /// Constant time, so how long a wrong guess takes says nothing about how wrong it is.
    public static func equalBytes(_ a: [UInt8], _ b: [UInt8]) -> Bool { equal(a, b) }
    static func equal(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
