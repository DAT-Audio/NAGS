import Foundation

/// The sample packets in `docs/PROTOCOL.md`: every message of the Sender ↔ Grabber
/// protocol, made by the real encoders from fixed inputs. They are the contract another
/// implementation (the Windows port) is tested against — byte for byte.
///
/// `NetworkAudioSender --protocol-vectors` prints them as the document shows them, and the
/// Grabber's `--checkvban` checks that the encoders still make exactly `expected`, so the
/// document and the code cannot drift apart unnoticed. **Changing one of these bytes is a
/// protocol change**: give it a new version, don't edit the vector to match.
public enum ProtocolVectors {
    public struct Vector {
        public let label: String
        public let note: String
        public let bytes: [UInt8]
    }

    static let streamName = "Edit Suite Mac"
    static let grabberName = "Control Room"
    static let senderInstance: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]
    static let grabberInstance: [UInt8] = [0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7, 0xA8]
    static let nonce: [UInt8] = [0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18]
    static let cookie: [UInt8] = (0x21...0x30).map { UInt8($0) }
    static let format = VBANControl.Format(sampleRate: 48000, channels: 2, dataType: .int16)
    public static let sealSenderSecret: [UInt8] = (0x01...0x10).map { UInt8($0) }
    public static let sealReceiverSecret: [UInt8] = (0x11...0x20).map { UInt8($0) }
    static let sealEpoch: [UInt8] = (0xE0...0xE7).map { UInt8($0) }

    public static var all: [Vector] {
        func control(_ label: String, _ note: String, _ m: VBANControl.Message, header: String) -> Vector {
            Vector(label: label, note: note, bytes: VBANControl.encode(m, headerName: header))
        }
        var out: [Vector] = [
            control("BEACON", "Sender → broadcast:6980, every second while Findable",
                    .init(kind: .beacon, name: streamName, format: format, port: VBANControl.controlPort,
                          instance: senderInstance), header: streamName),
            control("SUBSCRIBE", "Grabber → Sender's control port (padded to 128 bytes)",
                    .init(kind: .subscribe, nonce: nonce, name: grabberName), header: grabberName),
            control("CHALLENGE", "Sender → the SUBSCRIBE's source address and port",
                    .init(kind: .challenge, nonce: nonce, cookie: cookie), header: streamName),
            control("CONFIRM", "Grabber → Sender, echoing the nonce and cookie, with its identity",
                    .init(kind: .confirm, nonce: nonce, cookie: cookie, name: grabberName,
                          instance: grabberInstance), header: grabberName),
            control("PENDING", "Sender → Grabber: its user has been asked",
                    .init(kind: .pending), header: streamName),
            control("DECLINED", "Sender → Grabber: its user said no",
                    .init(kind: .declined), header: streamName),
            control("OFFER", "Sender → Grabber: accepted; audio follows to this address and port",
                    .init(kind: .offer, name: streamName, format: format), header: streamName),
            control("KEEPALIVE", "Grabber → Sender, every 5 s while listening",
                    .init(kind: .keepalive, cookie: cookie, name: grabberName), header: grabberName),
            control("UNSUBSCRIBE", "Grabber → Sender: stopped listening",
                    .init(kind: .unsubscribe, cookie: cookie), header: grabberName),
        ]
        // Plain VBAN audio: 2 frames of stereo 16-bit at 48 kHz, frame counter 7.
        var audio = [UInt8](repeating: 0, count: VBAN.headerBytes + 2 * 2 * 2)
        let samples: [Float] = [0.5, -0.5, 0.25, -1.0]
        let n = audio.withUnsafeMutableBufferPointer { out in
            samples.withUnsafeBufferPointer { s in
                VBAN.writeAudioPacket(into: out.baseAddress!, samples: s.baseAddress!, frames: 2, channels: 2,
                                      sampleRate: 48000, dataType: .int16, name: "Mac Audio", counter: 7)
            }
        }
        out.append(Vector(label: "AUDIO", note: "VBAN audio, 2 frames stereo i16 48 kHz: 0.5, −0.5, 0.25, −1.0; counter 7",
                          bytes: Array(audio.prefix(n ?? 0))))
        out.append(Vector(label: "KNOCK", note: "Remote link: Sender → the receiving end's code address, to open its router",
                          bytes: RemoteKnock.bytes))
        // Protocol version 2, the Remote link: the PENDING above, sealed Sender →
        // Grabber, from fixed secrets, epoch and counter.
        let pending = out.first { $0.label == "PENDING" }!.bytes
        let keys = RemoteSeal.keys(senderSecret: sealSenderSecret, receiverSecret: sealReceiverSecret)
        out.append(Vector(label: "SEALED", note: "Remote link (v2): PENDING sealed Sender → Grabber; secrets 01…10 and 11…20, epoch e0…e7, counter 0",
                          bytes: RemoteSealer(key: keys.senderToReceiver, epoch: sealEpoch, counter: 0).seal(pending)))
        return out
    }

    /// Remote link codes, from documentation addresses.
    public static var codes: [(label: String, code: RemoteCode, text: String)] {
        [("sending end", RemoteCode(role: .sending, address: "203.0.113.30", port: 6981, secret: sealSenderSecret)),
         ("receiving end", RemoteCode(role: .receiving, address: "198.51.100.7", port: 6980, secret: sealReceiverSecret))]
            .map { ($0.0, $0.1, $0.1.text) }
    }

    /// What the encoders made when the document was written. `--checkvban` compares.
    public static let expected: [String: String] = [
        "BEACON": "5642414e604e000045646974205375697465204d61630000000000004e4147530101030e45646974205375697465204d6163040780bb00000200010502451b07080102030405060708",
        "SUBSCRIBE": "5642414e604e0000436f6e74726f6c20526f6f6d00000000000000004e414753010201081112131415161718030c436f6e74726f6c20526f6f6d06440000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
        "CHALLENGE": "5642414e604e000045646974205375697465204d61630000000000004e41475301030108111213141516171802102122232425262728292a2b2c2d2e2f30",
        "CONFIRM": "5642414e604e0000436f6e74726f6c20526f6f6d00000000000000004e41475301040108111213141516171802102122232425262728292a2b2c2d2e2f30030c436f6e74726f6c20526f6f6d0708a1a2a3a4a5a6a7a8",
        "PENDING": "5642414e604e000045646974205375697465204d61630000000000004e4147530108",
        "DECLINED": "5642414e604e000045646974205375697465204d61630000000000004e4147530109",
        "OFFER": "5642414e604e000045646974205375697465204d61630000000000004e4147530105030e45646974205375697465204d6163040780bb0000020001",
        "KEEPALIVE": "5642414e604e0000436f6e74726f6c20526f6f6d00000000000000004e414753010602102122232425262728292a2b2c2d2e2f30030c436f6e74726f6c20526f6f6d",
        "UNSUBSCRIBE": "5642414e604e0000436f6e74726f6c20526f6f6d00000000000000004e414753010702102122232425262728292a2b2c2d2e2f30",
        "AUDIO": "5642414e030101014d616320417564696f0000000000000007000000ff3f01c0ff1f0180",
        "KNOCK": "4e41474b01",
        "SEALED": "4e41474502e0e1e2e3e4e5e6e70000000000000000e8ce37b1f266f9b71edc509ba70c959fa7c9e85a08ccb7c4308753b70735df2f79bf7192d5e59f2a03c2cd2d1450e8885192",
        "CODE sending end": "NAG-4B5G0-W8Y3D-2G20G-30G2G-C1R81-450P3-0D1R7-H19R",
        "CODE receiving end": "NAG-47336-S073D-2124G-K2GAH-C5RR3-4D1P7-0X3RF-J1MR",
    ]

    public static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    /// The document's section, as Markdown.
    public static func markdown() -> String {
        var s = ""
        for v in all {
            s += "**\(v.label)** — \(v.note) (\(v.bytes.count) bytes)\n\n```\n"
            let h = v.bytes.map { String(format: "%02x", $0) }
            for row in stride(from: 0, to: h.count, by: 16) {
                s += String(format: "%04x  ", row) + h[row..<min(row + 16, h.count)].joined(separator: " ") + "\n"
            }
            s += "```\n\n"
        }
        s += "**Remote link codes**\n\n"
        for c in codes { s += "- \(c.label), \(c.code.address):\(c.code.port) → `\(c.text)`\n" }
        return s
    }
}
