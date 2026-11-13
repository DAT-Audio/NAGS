import Foundation

/// The pure parsing behind internet streams (D4): an HTTP or ICY response head, ICY metadata
/// blocks, and playlist files. No I/O here, so every piece goes through `--fuzzcheck`.
///
/// Written from the HTTP/1.0 description (RFC 1945) and the de facto ICY conventions that
/// Icecast and SHOUTcast servers follow; no server's code is used (PROTO-1).
public enum WebParsing {

    /// A response head: the status and the headers, names lower-cased.
    public struct Head: Equatable {
        public var status: Int
        public var headers: [String: String]
        /// Bytes of the head, including the blank line, so the body starts after them.
        public var length: Int

        public var contentType: String { headers["content-type"]?.lowercased() ?? "" }
        /// Bytes of audio between ICY metadata blocks, if the server interleaves them.
        public var metaInterval: Int? {
            guard let v = headers["icy-metaint"].flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }),
                  (1...655_360).contains(v) else { return nil }
            return v
        }
        public var location: String? { headers["location"] }
    }

    /// The largest head accepted. Real ones are a few hundred bytes; more is not a stream server.
    public static let maxHeadBytes = 16 * 1024

    /// Parses a response head from the start of `bytes`, or nil while it is incomplete.
    /// `.failure` for something that is not an HTTP or ICY response at all.
    public enum HeadResult: Equatable { case head(Head), bad(String) }

    public static func head(_ bytes: [UInt8]) -> HeadResult? {
        let limit = min(bytes.count, maxHeadBytes)
        var end: Int?
        var i = 0
        while i + 3 < limit {
            if bytes[i] == 13, bytes[i + 1] == 10, bytes[i + 2] == 13, bytes[i + 3] == 10 { end = i; break }
            i += 1
        }
        guard let end else {
            return bytes.count >= maxHeadBytes ? .bad("The server's reply was not an audio stream.") : nil
        }
        let text = String(decoding: bytes[0..<end], as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return .bad("The server sent an empty reply.") }
        let statusLine = lines.removeFirst()
        // "HTTP/1.1 200 OK", or SHOUTcast's own "ICY 200 OK".
        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2,
              parts[0].hasPrefix("HTTP/") || parts[0] == "ICY",
              let status = Int(parts[1]), (100...599).contains(status) else {
            return .bad("The server's reply was not an audio stream.")
        }
        var headers: [String: String] = [:]
        for line in lines.prefix(200) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.count <= 64, value.count <= 2048 else { continue }
            headers[name] = value
        }
        return .head(Head(status: status, headers: headers, length: end + 4))
    }

    /// The title in an ICY metadata block — `StreamTitle='Artist - Song';…` — or nil.
    public static func streamTitle(_ block: [UInt8]) -> String? {
        let text = String(decoding: block.prefix(4080).filter { $0 != 0 }, as: UTF8.self)
        guard let start = text.range(of: "StreamTitle='") else { return nil }
        let rest = text[start.upperBound...]
        // Up to "';", not the first quote: titles carry apostrophes.
        let end = rest.range(of: "';")?.lowerBound ?? rest.lastIndex(of: "'") ?? rest.endIndex
        let title = rest[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        return String(title.prefix(300))
    }

    public enum Playlist: Equatable {
        case stream(String)        // the first stream URL in it
        case hls                   // an HTTP Live Streaming playlist, which this does not play
        case empty
    }

    /// The stream an M3U or PLS playlist points at.
    public static func playlist(_ text: String) -> Playlist {
        let lines = text.prefix(65_536).components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.contains(where: { $0.hasPrefix("#EXT-X-") }) { return .hls }
        for line in lines {
            var candidate = line
            // PLS: File1=http://…
            if let eq = line.firstIndex(of: "="), line.lowercased().hasPrefix("file") {
                candidate = String(line[line.index(after: eq)...])
            }
            let lower = candidate.lowercased()
            if !candidate.hasPrefix("#"), lower.hasPrefix("http://") || lower.hasPrefix("https://") {
                return .stream(candidate)
            }
        }
        return .empty
    }

    /// Whether a reply is a playlist to follow rather than audio to play.
    public static func isPlaylist(contentType: String, path: String) -> Bool {
        let t = contentType
        let p = path.lowercased()
        return t.contains("mpegurl") || t.contains("scpls") || t.contains("x-mpequrl")
            || p.hasSuffix(".m3u") || p.hasSuffix(".m3u8") || p.hasSuffix(".pls")
    }

    /// An `http(s)://host[:port]/path` URL, checked.
    public struct Target: Equatable {
        public var secure: Bool
        public var host: String
        public var port: UInt16
        public var path: String
        public var text: String
    }

    public static func target(_ text: String) -> Target? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 2048, let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        let secure = scheme == "https"
        let port = url.port ?? (secure ? 443 : 80)
        guard (1...65535).contains(port) else { return nil }
        var path = url.path.isEmpty ? "/" : url.path
        if let q = url.query { path += "?" + q }
        return Target(secure: secure, host: host, port: UInt16(port), path: path, text: trimmed)
    }
}
