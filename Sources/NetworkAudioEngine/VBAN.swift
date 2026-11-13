import Foundation

/// VB-Audio's network audio protocol: PCM over UDP behind a 28-byte header, no clock, no announcements.
///
/// Shared by the Grabber, which reads it, and the Sender, which writes it — one definition of
/// the wire format, so the two cannot disagree about it.
public enum VBAN {
    public static let port = 6980
    public static let headerBytes = 28
    public static let maxPayloadBytes = 1436
    public static let maxFrames = 256

    /// Indexed by the low five bits of header byte 4. Indices 21–31 are invalid.
    public static let sampleRates = [6000, 12000, 24000, 48000, 96000, 192000, 384000,
                                     8000, 16000, 32000, 64000, 128000, 256000, 512000,
                                     11025, 22050, 44100, 88200, 176400, 352800, 705600]

    /// The sample formats this project reads and writes. 8-bit is left out rather than guessed
    /// at: the specification does not settle whether it is signed, and nothing common sends it.
    /// 12- and 10-bit are packed formats.
    public enum DataType: UInt8, CaseIterable {
        case int16 = 1, int24 = 2, int32 = 3, float32 = 4, float64 = 5

        public var bytesPerSample: Int {
            switch self {
            case .int16: return 2
            case .int24: return 3
            case .int32, .float32: return 4
            case .float64: return 8
            }
        }
    }

    public struct Header {
        public let sampleRate: Int
        public let frames: Int
        public let channels: Int
        public let dataType: DataType
        public let name: String
        public let counter: UInt32
    }

    /// Reads and validates one datagram's header. Nil for anything that is not a PCM audio packet
    /// this app decodes, or whose length disagrees with what the header claims — which is every
    /// check needed before a single sample is touched, since all of it is untrusted.
    public static func audioHeader(_ p: UnsafePointer<UInt8>, _ length: Int) -> Header? {
        guard length > headerBytes, p[0] == 0x56, p[1] == 0x42, p[2] == 0x41, p[3] == 0x4E,
              p[4] & 0xE0 == 0x00,                            // sub-protocol: audio
              p[7] & 0xF0 == 0x00 else { return nil }         // codec: PCM
        let rateIndex = Int(p[4] & 0x1F)
        guard rateIndex < sampleRates.count,
              let dataType = DataType(rawValue: p[7] & 0x07) else { return nil }
        let frames = Int(p[5]) + 1
        let channels = Int(p[6]) + 1
        let payload = frames * channels * dataType.bytesPerSample
        guard payload <= maxPayloadBytes, length == headerBytes + payload else { return nil }
        let counter = UInt32(p[24]) | UInt32(p[25]) << 8 | UInt32(p[26]) << 16 | UInt32(p[27]) << 24
        return Header(sampleRate: sampleRates[rateIndex], frames: frames, channels: channels,
                      dataType: dataType, name: streamName(p + 8), counter: counter)
    }

    /// The 16-byte name field: up to the first zero, printable ASCII only. It need not be
    /// terminated, and anyone can put anything in it.
    private static func streamName(_ p: UnsafePointer<UInt8>) -> String {
        var scalars = String.UnicodeScalarView()
        for i in 0..<16 {
            let b = p[i]
            if b == 0 { break }
            scalars.append(Unicode.Scalar((0x20...0x7E).contains(b) ? b : 0x3F))   // '?'
        }
        let name = String(scalars).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Unnamed" : name
    }

    /// What a stream name becomes on the wire: printable ASCII, at most 16 bytes. The Sender's
    /// name field shows the same, so what the user types is what a receiver lists.
    public static func wireName(_ name: String) -> String {
        let ascii = name.unicodeScalars.map { (0x20...0x7E).contains($0.value) ? Character($0) : "?" }
        return String(String(ascii).prefix(16)).trimmingCharacters(in: .whitespaces)
    }

    /// The name as the 16 bytes a packet carries, zero-padded. Made once per name change: the
    /// Sender used to clean the name and build this array for every packet, on the capture's
    /// real-time thread.
    public static func wireNameBytes(_ name: String) -> [UInt8] {
        let bytes = Array(wireName(name).utf8.prefix(16))
        return bytes + [UInt8](repeating: 0, count: 16 - bytes.count)
    }

    /// The largest packet that fits: at most 256 frames and 1436 bytes of payload. Stereo 16-bit
    /// is 256 frames (1024 bytes); stereo 24-bit is 239 (1434).
    public static func framesPerPacket(channels: Int, dataType: DataType, maxPayload: Int = maxPayloadBytes) -> Int {
        max(1, min(maxFrames, maxPayload / (channels * dataType.bytesPerSample)))
    }

    /// Writes a complete audio packet — header and interleaved samples — into `out`, which must
    /// hold `headerBytes + frames × channels × bytesPerSample`. Returns the byte count, or nil
    /// if the rate is not one VBAN can express or the packet would not fit.
    ///
    /// Samples arrive as float, as CoreAudio delivers them, and are clipped to ±1 before an
    /// integer conversion; a float stream passes them through, with NaN and infinity zeroed.
    public static func writeAudioPacket(into out: UnsafeMutablePointer<UInt8>,
                                        samples: UnsafePointer<Float>, frames: Int,
                                        channels: Int, sampleRate: Int, dataType: DataType,
                                        name: String, counter: UInt32) -> Int? {
        writeAudioPacket(into: out, samples: samples, frames: frames, channels: channels,
                         sampleRate: sampleRate, dataType: dataType,
                         nameBytes: wireNameBytes(name), counter: counter)
    }

    /// The same, with the name already made into its 16 bytes (`wireNameBytes`). This one
    /// allocates nothing, so it is the one for a real-time thread.
    public static func writeAudioPacket(into out: UnsafeMutablePointer<UInt8>,
                                        samples: UnsafePointer<Float>, frames: Int,
                                        channels: Int, sampleRate: Int, dataType: DataType,
                                        nameBytes: [UInt8], counter: UInt32) -> Int? {
        guard let rateIndex = sampleRates.firstIndex(of: sampleRate),
              frames >= 1, frames <= maxFrames, channels >= 1, channels <= 256 else { return nil }
        let payload = frames * channels * dataType.bytesPerSample
        guard payload <= maxPayloadBytes else { return nil }

        out[0] = 0x56; out[1] = 0x42; out[2] = 0x41; out[3] = 0x4E        // "VBAN"
        out[4] = UInt8(rateIndex)                                          // sub-protocol audio
        out[5] = UInt8(frames - 1)
        out[6] = UInt8(channels - 1)
        out[7] = dataType.rawValue                                         // codec PCM
        for i in 0..<16 { out[8 + i] = i < nameBytes.count ? nameBytes[i] : 0 }
        out[24] = UInt8(counter & 0xFF)
        out[25] = UInt8((counter >> 8) & 0xFF)
        out[26] = UInt8((counter >> 16) & 0xFF)
        out[27] = UInt8(counter >> 24)

        let dst = out + headerBytes
        let count = frames * channels
        switch dataType {
        case .int16:
            for i in 0..<count {
                let v = Int16(clip(samples[i]) * 32767)
                dst[i * 2] = UInt8(truncatingIfNeeded: v)
                dst[i * 2 + 1] = UInt8(truncatingIfNeeded: v >> 8)
            }
        case .int24:
            for i in 0..<count {
                let v = Int32(clip(samples[i]) * 8_388_607)
                dst[i * 3] = UInt8(truncatingIfNeeded: v)
                dst[i * 3 + 1] = UInt8(truncatingIfNeeded: v >> 8)
                dst[i * 3 + 2] = UInt8(truncatingIfNeeded: v >> 16)
            }
        case .int32:
            for i in 0..<count {
                let v = Int32(Double(clip(samples[i])) * 2_147_483_647)
                writeWord(UInt32(bitPattern: v), to: dst + i * 4)
            }
        case .float32:
            for i in 0..<count {
                let s = samples[i]
                writeWord((s.isFinite ? s : 0).bitPattern, to: dst + i * 4)
            }
        case .float64:
            for i in 0..<count {
                let s = samples[i]
                let bits = Double(s.isFinite ? s : 0).bitPattern
                writeWord(UInt32(truncatingIfNeeded: bits), to: dst + i * 8)
                writeWord(UInt32(truncatingIfNeeded: bits >> 32), to: dst + i * 8 + 4)
            }
        }
        return headerBytes + payload
    }

    private static func clip(_ s: Float) -> Float {
        s.isFinite ? min(1, max(-1, s)) : 0
    }

    private static func writeWord(_ w: UInt32, to p: UnsafeMutablePointer<UInt8>) {
        p[0] = UInt8(w & 0xFF); p[1] = UInt8((w >> 8) & 0xFF)
        p[2] = UInt8((w >> 16) & 0xFF); p[3] = UInt8(w >> 24)
    }
}
