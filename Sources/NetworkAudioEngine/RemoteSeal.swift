import Foundation
import Crypto

/// The Remote link's encryption (`docs/PROTOCOL.md` §7a):
/// every packet between two linked ends — the handshake and the audio — sealed with
/// ChaCha20-Poly1305 (RFC 8439) from Apple's swift-crypto, under keys only those two ends have.
///
/// **Keys.** Each end's Remote link code carries a 16-byte random secret, made once and kept, so a
/// new code does not break a link already made. The two secrets, swapped with the codes, give one
/// key per direction: `HKDF-SHA256(senderSecret ‖ receiverSecret, salt "NAG remote link v2",
/// info "sender to receiver" | "receiver to sender")`.
///
/// **Packets.** `"NAGE" · version 2 · epoch (8) · counter (8, big-endian) · ciphertext · tag (16)`.
/// The epoch is random for each run of a sealer, and each epoch has its own subkey
/// (`HKDF(key, salt: epoch, info "packet")`), so a restarted app never reuses a nonce; the nonce is
/// four zero bytes and the counter. The header is authenticated as associated data. An opener
/// keeps a 64-packet window per epoch and refuses a replay — checked only after the packet has
/// authenticated, so a forged packet cannot move the window. A new epoch (the other end restarted)
/// is taken only after the current one has been quiet for 2 s, and old epochs are remembered, so
/// a captured packet replayed later can't pass as a new run.
public enum RemoteSeal {
    public static let magic: [UInt8] = [0x4E, 0x41, 0x47, 0x45]          // "NAGE"
    public static let version: UInt8 = 2
    public static let secretBytes = 16
    public static let epochBytes = 8
    public static let headerBytes = 4 + 1 + epochBytes + 8                // 21
    public static let tagBytes = 16
    /// What sealing adds to a packet.
    public static let overhead = headerBytes + tagBytes                   // 37

    /// Whether a datagram is a sealed one (by its first five bytes), before any key is looked up.
    public static func isSealed(_ p: UnsafePointer<UInt8>, _ length: Int) -> Bool {
        length >= overhead && p[0] == magic[0] && p[1] == magic[1] && p[2] == magic[2]
            && p[3] == magic[3] && p[4] == version
    }

    /// A new end's secret.
    public static func newSecret() -> [UInt8] {
        var g = SystemRandomNumberGenerator()
        return (0..<secretBytes).map { _ in UInt8.random(in: 0...255, using: &g) }
    }

    /// The two directions' keys for one link.
    public struct LinkKeys {
        public let senderToReceiver: SymmetricKey
        public let receiverToSender: SymmetricKey
    }

    public static func keys(senderSecret: [UInt8], receiverSecret: [UInt8]) -> LinkKeys {
        let ikm = SymmetricKey(data: senderSecret + receiverSecret)
        let salt = Array("NAG remote link v2".utf8)
        func derive(_ info: String) -> SymmetricKey {
            HKDF<Crypto.SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Array(info.utf8), outputByteCount: 32)
        }
        return LinkKeys(senderToReceiver: derive("sender to receiver"), receiverToSender: derive("receiver to sender"))
    }

    static func subkey(_ key: SymmetricKey, epoch: [UInt8]) -> SymmetricKey {
        HKDF<Crypto.SHA256>.deriveKey(inputKeyMaterial: key, salt: epoch, info: Array("packet".utf8), outputByteCount: 32)
    }

    static func nonce(_ counter: UInt64) -> ChaChaPoly.Nonce {
        var bytes = [UInt8](repeating: 0, count: 12)
        for i in 0..<8 { bytes[4 + i] = UInt8(truncatingIfNeeded: counter >> (56 - 8 * UInt64(i))) }
        return try! ChaChaPoly.Nonce(data: bytes)
    }
}

/// Seals one direction of one link, for one run. Safe from several threads.
public final class RemoteSealer: @unchecked Sendable {
    private let subkey: SymmetricKey
    private let header: [UInt8]                     // magic, version, epoch: the counter follows
    private var counter: UInt64
    private let lock = NSLock()

    /// `epoch` and `counter` are for the sample packets only; leave them out.
    public init(key: SymmetricKey, epoch: [UInt8]? = nil, counter: UInt64 = 0) {
        let e = epoch ?? (0..<RemoteSeal.epochBytes).map { _ in UInt8.random(in: 0...255) }
        subkey = RemoteSeal.subkey(key, epoch: e)
        header = RemoteSeal.magic + [RemoteSeal.version] + e
        self.counter = counter
    }

    public func seal(_ plain: UnsafeRawBufferPointer) -> [UInt8] {
        lock.lock(); let n = counter; counter &+= 1; lock.unlock()
        var head = header
        for i in 0..<8 { head.append(UInt8(truncatingIfNeeded: n >> (56 - 8 * UInt64(i)))) }
        guard let box = try? ChaChaPoly.seal(plain, using: subkey, nonce: RemoteSeal.nonce(n), authenticating: head)
        else { return [] }
        return head + Array(box.ciphertext) + Array(box.tag)
    }

    public func seal(_ plain: [UInt8]) -> [UInt8] { plain.withUnsafeBytes { seal($0) } }
}

/// Opens one direction of one link. Safe from several threads.
public final class RemoteOpener: @unchecked Sendable {
    private let key: SymmetricKey
    private let lock = NSLock()
    /// Per epoch seen: its subkey, the highest counter and the 64 below it, already accepted.
    private var epochs: [[UInt8]: (subkey: SymmetricKey, highest: UInt64, window: UInt64, seen: Bool)] = [:]
    private var order: [[UInt8]] = []
    /// When a packet last authenticated, for the new-epoch rule below.
    private var lastAccepted: CFAbsoluteTime = 0
    /// A new epoch is a restarted end: taken only once the current one has gone quiet this long,
    /// so a replayed packet from an old run can't start one mid-session.
    public static let newEpochAfterQuiet: CFAbsoluteTime = 2

    public init(key: SymmetricKey) { self.key = key }

    /// The packet inside, or nil: not sealed, not for this key, altered, or a replay.
    public func open(_ p: UnsafePointer<UInt8>, _ length: Int) -> [UInt8]? {
        guard RemoteSeal.isSealed(p, length) else { return nil }
        let epoch = Array(UnsafeBufferPointer(start: p + 5, count: RemoteSeal.epochBytes))
        var n: UInt64 = 0
        for i in 0..<8 { n = n << 8 | UInt64(p[5 + RemoteSeal.epochBytes + i]) }
        let head = Array(UnsafeBufferPointer(start: p, count: RemoteSeal.headerBytes))
        let body = length - RemoteSeal.overhead
        let cipher = Data(bytes: p + RemoteSeal.headerBytes, count: body)
        let tag = Data(bytes: p + RemoteSeal.headerBytes + body, count: RemoteSeal.tagBytes)

        lock.lock()
        let state = epochs[epoch]
        lock.unlock()
        let subkey = state?.subkey ?? RemoteSeal.subkey(key, epoch: epoch)
        guard let box = try? ChaChaPoly.SealedBox(nonce: RemoteSeal.nonce(n), ciphertext: cipher, tag: tag),
              let plain = try? ChaChaPoly.open(box, using: subkey, authenticating: head) else { return nil }

        // Authentic: now the replay check, and the window moves.
        lock.lock(); defer { lock.unlock() }
        let now = CFAbsoluteTimeGetCurrent()
        var s = epochs[epoch] ?? (subkey, 0, 0, false)
        if !s.seen {
            guard order.isEmpty || now - lastAccepted >= Self.newEpochAfterQuiet else { return nil }
            s = (subkey, n, 1, true)
            order.append(epoch)
            // Every run remembered, up to many restarts: an old run's packets stay refused.
            if order.count > 256 { epochs[order.removeFirst()] = nil }
        } else if n > s.highest {
            let shift = n - s.highest
            s.window = shift >= 64 ? 1 : (s.window << shift) | 1
            s.highest = n
        } else {
            let back = s.highest - n
            guard back < 64, s.window & (1 << back) == 0 else { return nil }   // too old, or a replay
            s.window |= 1 << back
        }
        epochs[epoch] = s
        lastAccepted = now
        return Array(plain)
    }

    public func open(_ bytes: [UInt8]) -> [UInt8]? {
        bytes.withUnsafeBufferPointer { $0.baseAddress.flatMap { open($0, bytes.count) } }
    }
}

/// One Remote link's two directions, at one end, for one run: what it seals going out and opens
/// coming in. Made once per link per run and kept, so the other end sees one epoch.
public final class LinkCrypto: @unchecked Sendable {
    public let sealer: RemoteSealer
    public let opener: RemoteOpener

    /// `own`/`peer`: this end's secret and the other's (from its code); `sendingEnd`: whether this
    /// end is the Sender.
    public init(own: [UInt8], peer: [UInt8], sendingEnd: Bool) {
        let keys = sendingEnd ? RemoteSeal.keys(senderSecret: own, receiverSecret: peer)
                              : RemoteSeal.keys(senderSecret: peer, receiverSecret: own)
        sealer = RemoteSealer(key: sendingEnd ? keys.senderToReceiver : keys.receiverToSender)
        opener = RemoteOpener(key: sendingEnd ? keys.receiverToSender : keys.senderToReceiver)
    }
}

extension RemoteSeal {
    /// The bytes of a secret as kept in settings, and back.
    public static func hex(_ secret: [UInt8]) -> String { secret.map { String(format: "%02x", $0) }.joined() }
    public static func secret(fromHex text: String) -> [UInt8]? {
        guard text.count == secretBytes * 2 else { return nil }
        var out: [UInt8] = []
        var i = text.startIndex
        while i < text.endIndex {
            let j = text.index(i, offsetBy: 2)
            guard let b = UInt8(text[i..<j], radix: 16) else { return nil }
            out.append(b); i = j
        }
        return out
    }
}
