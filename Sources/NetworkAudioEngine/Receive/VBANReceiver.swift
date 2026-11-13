import Foundation

/// Receives one VBAN stream. Owns no socket: `VBANListener` has the one port every VBAN stream
/// shares and hands over this stream's packets, already header-checked. Decodes little-endian
/// integer and float PCM; everything after that is `StreamReceiver`'s.
public final class VBANReceiver: StreamReceiver {
    private weak var listener: VBANListener?
    private var expectedCounter: UInt32 = 0
    private var haveCounter = false

    /// Packets that arrived in a format other than the one this receiver was built for. The
    /// format change itself is handled by `AppState`, which rebuilds the receiver.
    public private(set) var mismatched: UInt64 = 0

    public init(stream: StreamDescription, latencyMs: Double, listener: VBANListener) {
        self.listener = listener
        super.init(stream: stream, latencyMs: latencyMs)
    }

    deinit { stop() }

    /// The listener is already running whenever VBAN is on, so starting is only joining it.
    public override func start(interfaceAddress: String) -> String? {
        listener?.attach(self)
        return nil
    }

    public override func stop() {
        listener?.detach(self)
    }

    /// Network thread. `payload` holds exactly `frames × channels` samples: the listener has
    /// checked the length against the header.
    public func handle(_ payload: UnsafePointer<UInt8>, _ header: VBAN.Header) {
        guard header.sampleRate == stream.sampleRate, header.channels == stream.channels,
              header.dataType.encoding == stream.encoding, header.frames <= maxPacketFrames else {
            mismatched += 1
            return
        }
        let frames = header.frames

        // The frame counter is VBAN's sequence number: pad short gaps with silence so timing
        // survives loss, as the RTP path does.
        if haveCounter {
            let delta = Int(Int32(bitPattern: header.counter &- expectedCounter))   // wrap-safe
            if delta < 0 {
                return                                                // reordered or duplicate
            } else if delta > 0 && delta < 64 {
                recordLoss(packets: delta, silenceFrames: delta * frames)
            } else if delta >= 64 {
                recordLoss(packets: 1, silenceFrames: 0)              // sender restarted
            }
        }
        expectedCounter = header.counter &+ 1
        haveCounter = true

        decodeLittleEndian(payload, count: frames * stream.channels)
        deliver(frames: frames)
    }

}
