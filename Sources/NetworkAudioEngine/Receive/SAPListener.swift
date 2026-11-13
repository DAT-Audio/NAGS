import Foundation
#if canImport(WinSDK)
import WinSDK          // the Windows port: WinSock, and WindowsCompat.swift beside it
#endif

/// Listens for SAP/SDP session announcements (RFC 2974) on the AES67 and legacy SAP groups.
///
/// AES67 mandates 239.255.255.255:9875; older gear (and some Ravenna/Merging setups) still
/// uses the historic sap.mcast.net group, so both are joined.
public final class SAPListener {
    public init() {}

    public static let groups = ["239.255.255.255", "224.2.127.254"]
    public static let port = 9875

    /// (sdpText, isDeletion)
    public var onAnnouncement: ((String, Bool) -> Void)?
    public var onError: ((String) -> Void)?

    private var sockets: [MulticastSocket] = []
    private var threads: [Thread] = []
    private var running = false

    public func start(interfaceAddress: String) {
        stop()
        running = true
        for group in Self.groups {
            let sock = MulticastSocket(group: group, port: Self.port, interfaceAddress: interfaceAddress)
            if let err = sock.open(receiveBufferBytes: 512 * 1024) {
                // A failure on the legacy group is not fatal — keep whichever group works.
                onError?("SAP \(group): \(err)")
                continue
            }
            sockets.append(sock)
            let t = Thread { [weak self] in self?.receiveLoop(sock) }
            t.name = "SAP \(group)"
            t.qualityOfService = .utility
            threads.append(t)
            t.start()
        }
        if sockets.isEmpty {
            onError?("Could not join any SAP group. Check the interface selection and Local Network permission.")
        }
    }

    public func stop() {
        running = false
        sockets.forEach { $0.close() }
        sockets.removeAll()
        threads.removeAll()
    }

    private func receiveLoop(_ sock: MulticastSocket) {
        var buf = [UInt8](repeating: 0, count: 8192)
        while running && sock.fd >= 0 {
            let n = recv(sock.fd, &buf, buf.count, 0)
            if n <= 0 { continue }   // timeout or shutdown
            if let (sdp, deletion) = Self.decode(Array(buf[0..<n])) {
                onAnnouncement?(sdp, deletion)
            }
        }
    }

    /// Strips the SAP header and returns the SDP body plus whether this is a deletion packet.
    public static func decode(_ packet: [UInt8]) -> (String, Bool)? {
        guard packet.count > 8 else { return nil }
        let flags = packet[0]
        guard (flags >> 5) & 0x07 == 1 else { return nil }       // version must be 1
        let ipv6 = (flags & 0x10) != 0
        let isDeletion = (flags & 0x04) != 0
        let encrypted = (flags & 0x02) != 0
        let compressed = (flags & 0x01) != 0
        if encrypted { return nil }                              // we cannot read encrypted payloads

        let authLen = Int(packet[1]) * 4
        let offset = 4 + (ipv6 ? 16 : 4) + authLen
        guard offset < packet.count else { return nil }

        var body = Array(packet[offset...])

        if compressed, let inflated = inflate?(body) { body = inflated }

        // Optional null-terminated MIME payload-type field, omitted when the body starts with "v=0".
        if !(body.count >= 3 && body[0] == UInt8(ascii: "v") && body[1] == UInt8(ascii: "=")) {
            if let nul = body.firstIndex(of: 0) {
                body = Array(body[(nul + 1)...])
            }
        }

        guard let text = String(bytes: body, encoding: .utf8) ?? String(bytes: body, encoding: .isoLatin1),
              text.contains("v=") else { return nil }
        return (text, isDeletion)
    }

    /// Inflates a zlib-compressed announcement (rare: most senders don't compress). Each
    /// platform gives its own — the Mac's Compression framework — or none, and a compressed
    /// announcement is then skipped.
    public nonisolated(unsafe) static var inflate: (([UInt8]) -> [UInt8]?)?
}
