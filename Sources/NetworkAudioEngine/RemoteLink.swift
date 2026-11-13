import Foundation
#if canImport(WinSDK)
import WinSDK          // the Windows port: WinSock, and WindowsCompat.swift beside it
#endif
#if canImport(Darwin)
import Darwin
#endif

/// Connecting to another location by address: supported, and
/// said plainly to be the advanced way — an open port on a router, and audio crossing the
/// internet unencrypted. Used by both apps.
public enum RemoteAddresses {
    /// Whether an IPv4 address is somewhere else: not on one of this Mac's networks, and not in a
    /// private, link-local, loopback or VPN range. A VPN's addresses (Tailscale's 100.64/10 and
    /// the private ranges) count as here — the VPN makes the other place part of the network.
    /// The documentation ranges count as here too, so the render harness's made-up addresses do
    /// not read as the internet.
    /// `documentationIsLocal: false` is for the checks, which may use only documentation
    /// addresses (the project's rule) and still need one that reads as the internet.
    /// RENDER HARNESS only: 203.0.113.0/24 (TEST-NET-3) reads as the internet, so a shot can show
    /// a remote row without a real address in it; the other documentation ranges stay local.
    nonisolated(unsafe) public static var harnessDocumentationIsRemote = false

    /// TESTS ONLY: every address reads as remote (the connection test on this Mac's own streams).
    nonisolated(unsafe) public static var testEverythingRemote = false

    public static func isRemote(_ address: String, documentationIsLocal: Bool = true) -> Bool {
        if testEverythingRemote { return true }
        var a = in_addr()
        guard inet_pton(AF_INET, address, &a) == 1 else { return false }
        let v = UInt32(bigEndian: a.s_addr)
        func inRange(_ base: UInt32, _ bits: UInt32) -> Bool { v >> (32 - bits) == base >> (32 - bits) }
        let here: [(UInt32, UInt32)] = [
            (0x0A00_0000, 8),   // 10/8
            (0xAC10_0000, 12),  // 172.16/12
            (0xC0A8_0000, 16),  // 192.168/16
            (0xA9FE_0000, 16),  // 169.254/16, link-local
            (0x7F00_0000, 8),   // loopback
            (0x6440_0000, 10),  // 100.64/10: carrier-grade NAT, and Tailscale
            (0xE000_0000, 4),   // multicast
        ] + (!documentationIsLocal ? []
             : harnessDocumentationIsRemote ? [(0xC000_0200, 24), (0xC633_6400, 24)]
             : [(0xC000_0200, 24), (0xC633_6400, 24), (0xCB00_7100, 24)])
        if here.contains(where: { inRange($0.0, $0.1) }) { return false }
        // A public address this Mac itself is on (a network with public addressing): here.
        return !onLocalNetwork(v)
    }

    /// This Mac's networks, looked up at most every 5 s: rows ask on every redraw.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: (at: CFAbsoluteTime, nets: [(UInt32, UInt32)]) = (0, [])
    private static func onLocalNetwork(_ v: UInt32) -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock(); defer { lock.unlock() }
        if now - cache.at > 5 {
            cache = (now, LocalNetworks.list().compactMap { n in
                var a = in_addr(), m = in_addr()
                guard inet_pton(AF_INET, n.address, &a) == 1, inet_pton(AF_INET, n.netmask, &m) == 1 else { return nil }
                return (UInt32(bigEndian: a.s_addr), UInt32(bigEndian: m.s_addr))
            })
        }
        return cache.nets.contains { $0.0 & $0.1 == v & $0.1 }
    }

    /// Whether an address is a VPN's (100.64/10 — Tailscale, and meshes like it): on "this
    /// network" as far as reaching it goes, but across the internet all the same.
    public static func isVPN(_ address: String) -> Bool {
        if testEverythingRemote { return false }
        var a = in_addr()
        guard inet_pton(AF_INET, address, &a) == 1 else { return false }
        return UInt32(bigEndian: a.s_addr) >> 22 == 0x6440_0000 >> 22
    }

    /// The host part of "address" or "address:port".
    public static func host(_ text: String) -> String {
        String(text.trimmingCharacters(in: .whitespaces).split(separator: ":").first ?? "")
    }

    /// The warning, one wording everywhere it is shown.
    public static let warningTitle = "Not advised over the internet."
    public static func warning(receivingEnd: Bool?) -> String {
        let router: String
        switch receivingEnd {
        case true?:  router = "This Mac's router has to forward a port to it (UDP \(VBAN.port))"
        case false?: router = "The other end's router has to forward a port to it"
        case nil:    router = "A router has to forward a port"
        }
        return router + ", which lets anyone on the internet send to that Mac, and the audio crosses the "
            + "internet unencrypted. Fine over a VPN, or for a short test."
    }
}

/// This network's address as the internet sees it, asked of a public STUN server (RFC 8489,
/// an open standard). **Only when the user presses the button**, and said so beside it: it tells
/// that server this network's outside address, and nothing else is sent.
///
/// Cloudflare's public STUN service, which Cloudflare offers free for anyone to use (credited in
/// Settings → Credits).
public enum OutsideAddress {
    public static let server = ("stun.cloudflare.com", UInt16(3478))
    public static let note = "Asks a public address server (Cloudflare's) what this network's outside address is — nothing else is sent, and only when you press it."

    public enum Failure: Error, CustomStringConvertible {
        case noAnswer, noServer
        public var description: String {
            switch self {
            case .noAnswer: return "No answer from the address server: this network may block it."
            case .noServer: return "The address server could not be found: is this Mac online?"
            }
        }
    }

    /// Looks it up off the main thread; the answer comes back on the main thread.
    public static func lookup(_ done: @escaping (Result<String, Failure>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = query()
            DispatchQueue.main.async { done(result) }
        }
    }

    private static func query() -> Result<String, Failure> {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_DGRAM, ai_protocol: IPPROTO_UDP,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(server.0, String(server.1), &hints, &info) == 0, let first = info, let target = first.pointee.ai_addr
        else { return .failure(.noServer) }
        defer { freeaddrinfo(info) }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return .failure(.noAnswer) }
        defer { close(fd) }
        #if os(Windows)
        // WinSock takes the receive timeout as a DWORD of milliseconds, not a `timeval`.
        var timeout = DWORD(1500)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<DWORD>.size))
        #else
        var tv = timeval(tv_sec: 1, tv_usec: 500_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        #endif
        for _ in 0..<2 {
            // Binding request: type 1, length 0, the magic cookie, a random transaction ID.
            var request: [UInt8] = [0x00, 0x01, 0x00, 0x00, 0x21, 0x12, 0xA4, 0x42]
            let transaction = (0..<12).map { _ in UInt8.random(in: 0...255) }
            request += transaction
            _ = request.withUnsafeBytes { sendto(fd, $0.baseAddress, $0.count, 0, target, first.pointee.ai_addrlen) }
            var buf = [UInt8](repeating: 0, count: 1024)
            let n = recv(fd, &buf, buf.count, 0)
            guard n > 0 else { continue }
            if let ip = parse(Array(buf[0..<n]), transaction: transaction) { return .success(ip) }
        }
        return .failure(.noAnswer)
    }

    /// The address in a Binding success response (XOR-MAPPED-ADDRESS, IPv4), or nil. Everything
    /// in it is untrusted and bounds-checked.
    public static func parse(_ buf: [UInt8], transaction: [UInt8]) -> String? {
        let n = buf.count
        guard n >= 20, buf[0] == 0x01, buf[1] == 0x01, Array(buf[8..<20]) == transaction else { return nil }
        var i = 20
        while i + 4 <= n {
            let type = Int(buf[i]) << 8 | Int(buf[i + 1]), length = Int(buf[i + 2]) << 8 | Int(buf[i + 3])
            let value = i + 4
            if type == 0x0020, length >= 8, value + 8 <= n, buf[value + 1] == 0x01 {
                let cookie: [UInt8] = [0x21, 0x12, 0xA4, 0x42]
                return (0..<4).map { String(buf[value + 4 + $0] ^ cookie[$0]) }.joined(separator: ".")
            }
            i = value + length + ((4 - length % 4) % 4)
        }
        return nil
    }
}

/// One Remote link as a guide lists it: which end, what it is called once known, and whether it
/// is connected yet.
public struct RemoteLinkInfo: Hashable {
    public let key: String
    public let name: String?
    public let connected: Bool
    public init(key: String, name: String?, connected: Bool) { self.key = key; self.name = name; self.connected = connected }

    /// Why a pasted code will not do as a link, when it carries this end's own outside address:
    /// both ends are behind one router, and the Remote link is not the way.
    public static let sameRouter = "That code has the same outside address as this end's, so both ends are on "
        + "the same network, or behind one router. On this network is the way: the stream is found there "
        + "by itself, and plays on the low local buffer — nothing to set."

    /// Checked again once this end's code is made: a code pasted before it could not be compared,
    /// as when a link on one Mac sat at Waiting, behind one router.
    public static func linkedBehindSameRouter(_ links: [String], own: RemoteCode) -> String? {
        guard let key = links.first(where: { $0.split(separator: ":").first.map(String.init) == own.address })
        else { return nil }
        return "The link to \(key) has this end's own outside address: both ends are behind one router, "
            + "where a Remote link can't connect. Unlink it and use On this network instead."
    }
}

/// TESTS ONLY: `NAG_TEST_BOUND_IF=en6` pins a socket's traffic to that interface, so two apps on
/// one Mac can reach the internet through two different routers (the Remote link test).
/// Does nothing unless the variable is set.
public enum TestBinding {
    public static func apply(_ fd: Int32) {
        #if os(Windows)
        // Nothing to do: `IP_BOUND_IF` is Darwin's, and the two-router Remote link test it serves
        // is run between Macs. If Windows ever needs it, the equivalent is `IP_UNICAST_IF` with
        // the interface index in network order.
        _ = fd
        #else
        guard let name = ProcessInfo.processInfo.environment["NAG_TEST_BOUND_IF"] else { return }
        var index = UInt32(if_nametoindex(name))
        guard index != 0 else { return }
        setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size))
        #endif
    }
}

/// A Remote link's code: what one end tells the other, by message or email, so the
/// two can reach each other across their routers with no port opened. It carries which end made
/// it (the one receiving, or the one sending), and that end's address and port **as the internet
/// sees them** — found by asking the STUN server from the very socket the audio will use, so the
/// router's mapping is the one the other end will reach.
///
/// **Version 2 (the encrypted Remote link):** 24 bytes — version and role, the IPv4
/// address, the port, the end's 16-byte secret (`RemoteSeal`), a check — written in Crockford
/// base 32 (no I, L, O or U, so it survives being read aloud or retyped), 39 characters in groups
/// of five: "NAG-XXXXX-…-XXXX". Version 1 (8 bytes, no secret, the unencrypted link)
/// is recognised and refused, so an older build's code says so instead of "not a code".
public struct RemoteCode: Equatable {
    public enum Role: UInt8 { case receiving = 1, sending = 2 }
    public let role: Role
    public let address: String
    public let port: UInt16
    /// The end's secret, from which the link's keys come (`RemoteSeal.keys`).
    public let secret: [UInt8]

    /// `secret`: the end's own; a code without one is for the render harness only.
    public init(role: Role, address: String, port: UInt16, secret: [UInt8] = [UInt8](repeating: 0, count: RemoteSeal.secretBytes)) {
        self.role = role; self.address = address; self.port = port; self.secret = secret
    }

    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    static let version: UInt8 = 2
    static let byteCount = 1 + 4 + 2 + RemoteSeal.secretBytes + 1      // 24

    public var text: String {
        var a = in_addr()
        guard secret.count == RemoteSeal.secretBytes, inet_pton(AF_INET, address, &a) == 1 else { return "" }
        let ip = withUnsafeBytes(of: a.s_addr) { Array($0) }        // network order
        var bytes: [UInt8] = [Self.version << 4 | role.rawValue] + ip + [UInt8(port >> 8), UInt8(port & 0xFF)] + secret
        bytes.append(Self.check(bytes))
        let chars = Self.encode(bytes)                              // 39 characters
        guard chars.count == 39 else { return "" }
        let groups = stride(from: 0, to: chars.count, by: 5).map { String(chars[$0..<min($0 + 5, chars.count)]) }
        return "NAG-" + groups.joined(separator: "-")
    }

    /// The code's characters, with the prefix, spaces, dashes and case forgiven, and the letters
    /// people confuse (O for 0, I and L for 1) read as meant.
    private static func cleaned(_ text: String) -> String {
        var raw = text.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("NAG") { raw.removeFirst(3) }             // only the prefix: the code may spell it too
        return String(raw.filter { !" -\n\t".contains($0) })
            .replacingOccurrences(of: "O", with: "0").replacingOccurrences(of: "I", with: "1")
            .replacingOccurrences(of: "L", with: "1")
    }

    /// Reads a pasted code. Nil for anything that is not a current one.
    public init?(text: String) {
        guard let bytes = Self.decode(Self.cleaned(text)), bytes.count == Self.byteCount,
              bytes[Self.byteCount - 1] == Self.check(Array(bytes[0..<(Self.byteCount - 1)])),
              bytes[0] >> 4 == Self.version, let role = Role(rawValue: bytes[0] & 0x0F) else { return nil }
        let ip = "\(bytes[1]).\(bytes[2]).\(bytes[3]).\(bytes[4])"
        self.init(role: role, address: ip, port: UInt16(bytes[5]) << 8 | UInt16(bytes[6]),
                  secret: Array(bytes[7..<(7 + RemoteSeal.secretBytes)]))
    }

    /// Whether this is a code from before the link was encrypted (version 1), for a plainer
    /// message than "not a code".
    public static func isOlderVersion(_ text: String) -> Bool {
        guard let bytes = decode(cleaned(text)), bytes.count == 8 else { return false }
        return bytes[7] == check(Array(bytes[0..<7])) && bytes[0] >> 4 == 1
    }

    /// What to say when a pasted code won't do.
    public static func problem(with text: String) -> String {
        isOlderVersion(text)
            ? "That code was made by an older version, before Remote links were encrypted. Update both ends, then make new codes."
            : "That is not a Remote link code. It starts NAG- and has eight groups."
    }

    private static func check(_ b: [UInt8]) -> UInt8 {
        b.enumerated().reduce(UInt8(0x5A)) { ($0 &* 31) &+ $1.element &+ UInt8($1.offset) }
    }

    private static func encode(_ bytes: [UInt8]) -> [Character] {
        var out: [Character] = [], buffer = 0, bits = 0
        for b in bytes {
            buffer = buffer << 8 | Int(b); bits += 8
            while bits >= 5 { bits -= 5; out.append(alphabet[(buffer >> bits) & 31]) }
        }
        if bits > 0 { out.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return out
    }

    private static func decode(_ text: String) -> [UInt8]? {
        var out: [UInt8] = [], buffer = 0, bits = 0
        for c in text {
            guard let v = alphabet.firstIndex(of: c) else { return nil }
            buffer = buffer << 5 | v; bits += 5
            if bits >= 8 { bits -= 8; out.append(UInt8((buffer >> bits) & 0xFF)) }
        }
        return out
    }
}

extension OutsideAddress {
    /// The server's address, looked up once (off the main thread).
    public static func serverAddress() -> sockaddr_in? {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_DGRAM, ai_protocol: IPPROTO_UDP,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(server.0, String(server.1), &hints, &info) == 0, let first = info,
              let a = first.pointee.ai_addr else { return nil }
        defer { freeaddrinfo(info) }
        return a.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
    }

    /// A Binding request, and the transaction it carries, for a socket that already exists.
    public static func request() -> (bytes: [UInt8], transaction: [UInt8]) {
        let transaction = (0..<12).map { _ in UInt8.random(in: 0...255) }
        return ([0x00, 0x01, 0x00, 0x00, 0x21, 0x12, 0xA4, 0x42] + transaction, transaction)
    }

    /// Whether a packet looks like a STUN reply at all (the magic cookie where it belongs), so a
    /// receive loop can hand it on instead of treating it as audio.
    public static func isReply(_ p: UnsafePointer<UInt8>, _ length: Int) -> Bool {
        length >= 20 && p[0] == 0x01 && p[4] == 0x21 && p[5] == 0x12 && p[6] == 0xA4 && p[7] == 0x42
    }

    /// The address **and port** in a Binding reply.
    public static func parseEndpoint(_ buf: [UInt8], transaction: [UInt8]) -> (String, UInt16)? {
        let n = buf.count
        guard n >= 20, buf[0] == 0x01, buf[1] == 0x01, Array(buf[8..<20]) == transaction else { return nil }
        var i = 20
        while i + 4 <= n {
            let type = Int(buf[i]) << 8 | Int(buf[i + 1]), length = Int(buf[i + 2]) << 8 | Int(buf[i + 3])
            let value = i + 4
            if type == 0x0020, length >= 8, value + 8 <= n, buf[value + 1] == 0x01 {
                let cookie: [UInt8] = [0x21, 0x12, 0xA4, 0x42]
                let port = (UInt16(buf[value + 2]) << 8 | UInt16(buf[value + 3])) ^ 0x2112
                let ip = (0..<4).map { String(buf[value + 4 + $0] ^ cookie[$0]) }.joined(separator: ".")
                return (ip, port)
            }
            i = value + length + ((4 - length % 4) % 4)
        }
        return nil
    }
}

/// The small packet the sending end sends the receiving end's way, to open its own router to it
/// ("punching"). Nothing acts on it but the check that it is not audio: "NAGK" and a version.
public enum RemoteKnock {
    public static let bytes: [UInt8] = [0x4E, 0x41, 0x47, 0x4B, 0x01]
    public static func isKnock(_ p: UnsafePointer<UInt8>, _ length: Int) -> Bool {
        length == 5 && p[0] == 0x4E && p[1] == 0x41 && p[2] == 0x47 && p[3] == 0x4B
    }
}
