import Foundation

public enum SampleEncoding: String {
    /// AES67: big-endian linear PCM, as SDP names it.
    case L16, L24, L32
    /// VBAN: little-endian, and floats as well as integers. Never announced over SDP.
    case PCM16, PCM24, PCM32, F32, F64

    public var bytesPerSample: Int {
        switch self {
        case .L16, .PCM16: return 2
        case .L24, .PCM24: return 3
        case .L32, .PCM32, .F32: return 4
        case .F64: return 8
        }
    }
}

/// One receivable audio stream: parsed out of an SDP session description, or, for VBAN, out of
/// the stream's own packet headers.
public struct StreamDescription: Identifiable, Hashable {
    /// AES67 keeps the form it has always had, because saved favourites, listening lists and mix
    /// modes are keyed on it. VBAN streams all share one port, so one is its sender plus its
    /// name. Nothing parses an ID back into an address.
    public var id: String {
        switch source {
        case .vban:   return "vban:\(originAddress)/\(name)"
        case .scream: return "scream:\(originAddress)"          // one stream per sender
        case .web:    return "web:\(groupAddress)"              // its address
        default:      return "\(groupAddress):\(port)"
        }
    }

    public var name: String
    public var originAddress: String       // sender, from o=
    public var groupAddress: String        // multicast destination, from c=
    public var port: Int                   // from m=audio
    public var payloadType: UInt8
    public var encoding: SampleEncoding
    public var sampleRate: Int
    public var channels: Int
    public var ptimeMs: Double
    public var ptpRef: String?             // a=ts-refclk, informational
    public var source: DiscoverySource
    public var rawSDP: String
    /// What an internet stream is compressed as — "MP3 128 kbit/s" — for the format line. Nil for
    /// the uncompressed transports.
    public var codec: String? = nil

    public init(name: String, originAddress: String, groupAddress: String, port: Int, payloadType: UInt8,
                encoding: SampleEncoding, sampleRate: Int, channels: Int, ptimeMs: Double, ptpRef: String?,
                source: DiscoverySource, rawSDP: String, codec: String? = nil) {
        self.name = name; self.originAddress = originAddress; self.groupAddress = groupAddress
        self.port = port; self.payloadType = payloadType; self.encoding = encoding
        self.sampleRate = sampleRate; self.channels = channels; self.ptimeMs = ptimeMs
        self.ptpRef = ptpRef; self.source = source; self.rawSDP = rawSDP; self.codec = codec
    }

    /// How this stream keeps time. An RTP stream is real-time only if it says which PTP clock
    /// it follows (`a=ts-refclk`); one without — PipeWire, PulseAudio, VLC, GStreamer — runs on
    /// its sender's own clock and is treated like VBAN.
    public var latencyClass: LatencyClass {
        let byMechanism = source.latencyClass
        if byMechanism == .realTime, ptpRef == nil { return .lan }
        return byMechanism
    }

    /// Whether the stream is sent to this Mac directly rather than to a multicast group.
    public var isUnicast: Bool { !MulticastSocket.isMulticast(groupAddress) }

    /// Frames carried by one RTP packet.
    public var framesPerPacket: Int { max(1, Int((ptimeMs * Double(sampleRate) / 1000.0).rounded())) }

    public var formatSummary: String {
        let sr = String(format: "%.4g", Double(sampleRate) / 1000.0)
        if let codec { return "\(codec) · \(channels) ch · \(sr) kHz" }
        return "\(encoding.rawValue) · \(channels) ch · \(sr) kHz · \(fmtPtime) ms"
    }

    private var fmtPtime: String {
        ptimeMs == ptimeMs.rounded() ? String(Int(ptimeMs)) : String(format: "%.3g", ptimeMs)
    }
}

/// How a source keeps time, which decides the buffer it plays against and what the app can
/// promise about it. Every receiver has one; a new protocol picks one of these rather
/// than inventing its own rules.
public enum LatencyClass {
    /// Locked to a shared PTP clock: AES67, RAVENNA, Dante in AES67 mode. Milliseconds of buffer.
    case realTime
    /// On the local network with no shared clock — the receiver follows the sender's own timing
    /// and corrects its drift: VBAN, and later Scream and plain RTP. Tens of milliseconds.
    case lan
    /// Seconds of buffer by design, like an internet stream: listened to, not monitored live.
    case buffered

    public var clockLabel: String {
        switch self {
        case .realTime: return "PTP"
        case .lan:      return "sender's own (no PTP)"
        case .buffered: return "buffered stream"
        }
    }

    public var help: String {
        switch self {
        case .realTime: return "Real-time: locked to the network's PTP clock, played against the AES67 buffer."
        case .lan:      return "Local network, no shared clock: this app follows the sender's timing and corrects its drift, against the VBAN buffer."
        case .buffered: return "Buffered: seconds behind by design, for listening rather than live monitoring."
        }
    }
}

public enum DiscoverySource: String, Hashable {
    case sap = "SAP"
    case ravenna = "RAVENNA"
    case dante = "DANTE"
    case manual = "MANUAL"
    case vban = "VBAN"
    case scream = "SCREAM"
    /// An internet stream — Icecast, SHOUTcast, plain HTTP — added by its address.
    case web = "WEB"

    /// What the list shows. Dante says "AES67" with it: the Grabber hears
    /// Dante devices in AES67 mode only, never native Dante, and "Dante" alone promised more.
    /// The raw value stays as it was — saved filters and stream IDs use it.
    public var label: String {
        switch self {
        case .dante: "DANTE (AES67)"
        default: rawValue
        }
    }

    /// Two mechanisms can find the same stream, and whichever reported last used to win, so a
    /// label could flip between refreshes. Higher wins: a manual entry is the user's own word,
    /// an RTSP session description is definitive proof of RAVENNA, a Dante-device address match
    /// is more specific than plain SAP.
    ///
    /// VBAN never competes: its IDs cannot match an AES67 one. It must also never be relabelled,
    /// because the label is part of a VBAN stream's ID.
    public var latencyClass: LatencyClass {
        switch self {
        case .vban, .scream: return .lan
        case .sap, .ravenna, .dante, .manual: return .realTime
        case .web: return .buffered
        }
    }

    public var precedence: Int {
        switch self {
        case .manual, .web:  return 4
        case .ravenna: return 3
        case .dante:   return 2
        case .sap:     return 1
        case .vban, .scream: return 1
        }
    }
}

public enum SDPParser {
    /// Parses an SDP body. Returns nil when it is not a usable linear-PCM audio session.
    public static func parse(_ text: String, source: DiscoverySource) -> StreamDescription? {
        var sessionName = "Unnamed"
        var origin = ""
        var sessionConnection: String?
        var mediaConnection: String?
        var port = 0
        var declaredPayloadTypes: [UInt8] = []
        var rtpmap: [UInt8: (SampleEncoding, Int, Int)] = [:]   // pt -> (encoding, rate, channels)
        var ptime: Double?
        var ptpRef: String?
        var inAudioMedia = false
        var sawAudioMedia = false

        // Split on `isNewline`, not on "\n"/"\r": Swift treats CRLF as a single Character,
        // so comparing against either half never matches an SDP line ending.
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard line.count > 2, line.dropFirst().first == "=" else { continue }
            let key = line.first!
            let value = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)

            switch key {
            case "s":
                sessionName = value.isEmpty ? sessionName : value
            case "o":
                // o=<user> <sess-id> <sess-version> IN IP4 <unicast-address>
                origin = value.split(separator: " ").last.map(String.init) ?? ""
            case "c":
                // c=IN IP4 233.252.0.2/32
                let parts = value.split(separator: " ")
                guard parts.count >= 3, parts[1] == "IP4" else { break }
                let addr = String(parts[2].split(separator: "/").first ?? "")
                if inAudioMedia { mediaConnection = addr } else { sessionConnection = addr }
            case "m":
                // m=audio 5004 RTP/AVP 98
                let parts = value.split(separator: " ")
                inAudioMedia = parts.first == "audio"
                guard inAudioMedia, !sawAudioMedia, parts.count >= 4 else { break }
                sawAudioMedia = true
                port = Int(parts[1]) ?? 0
                declaredPayloadTypes = parts[3...].compactMap { UInt8($0) }
            case "a":
                guard let colon = value.firstIndex(of: ":") else { break }
                let attr = String(value[value.startIndex..<colon])
                let arg = String(value[value.index(after: colon)...])
                switch attr {
                case "rtpmap":
                    // 98 L24/48000/8
                    let bits = arg.split(separator: " ")
                    guard bits.count >= 2, let pt = UInt8(bits[0]) else { break }
                    let fmt = bits[1].split(separator: "/")
                    guard let enc = SampleEncoding(rawValue: String(fmt[0]).uppercased()),
                          fmt.count >= 2, let rate = Int(fmt[1]) else { break }
                    let ch = fmt.count >= 3 ? (Int(fmt[2]) ?? 1) : 1
                    rtpmap[pt] = (enc, rate, ch)
                case "ptime":
                    ptime = Double(arg)
                case "ts-refclk":
                    ptpRef = arg
                default:
                    break
                }
            default:
                break
            }
        }

        guard sawAudioMedia, port > 0 else { return nil }
        guard let group = mediaConnection ?? sessionConnection else { return nil }

        // Pick the first declared payload type that we have an rtpmap for and can decode.
        // RFC 3551's static types need no rtpmap, and some senders leave it out: 10 and 11 are
        // L16 at 44.1 kHz, stereo and mono. An rtpmap, if present, still wins.
        for (pt, format) in [(UInt8(10), (SampleEncoding.L16, 44_100, 2)), (UInt8(11), (SampleEncoding.L16, 44_100, 1))]
            where rtpmap[pt] == nil && declaredPayloadTypes.contains(pt) {
            rtpmap[pt] = format
        }
        guard let pt = declaredPayloadTypes.first(where: { rtpmap[$0] != nil }),
              let (enc, rate, ch) = rtpmap[pt] else { return nil }

        // **An announcement is untrusted input**, and anything on the network can send one.
        // Out-of-range formats are refused here, before a receiver sizes its buffers from them:
        // `--fuzzcheck` found 906 in 200 000 mutated announcements accepted with rates, channel
        // counts or packet times no stream has — a zero rate divides by zero, a huge channel
        // count allocates without limit.
        let packetTime = ptime ?? 1.0
        guard (8000...384_000).contains(rate), (1...64).contains(ch), (1...65_535).contains(port),
              packetTime.isFinite, packetTime > 0, packetTime <= 1000 else { return nil }

        return StreamDescription(
            name: sessionName,
            originAddress: origin,
            groupAddress: group,
            port: port,
            payloadType: pt,
            encoding: enc,
            sampleRate: rate,
            channels: ch,
            ptimeMs: packetTime,
            ptpRef: ptpRef,
            source: source,
            rawSDP: text
        )
    }
}
