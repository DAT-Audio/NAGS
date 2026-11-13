import Foundation

/// Receives one Scream sender. Owns no socket: `ScreamListener` has UDP 4010 and hands over this
/// sender's packets, already checked. Decoding and everything after it is `StreamReceiver`'s.
///
/// Scream carries no sequence number, so a lost packet cannot be told from a pause: the ring's
/// drift correction and underrun handling are all there is, as for any sender without a clock.
public final class ScreamReceiver: StreamReceiver {
    private weak var listener: ScreamListener?
    /// Packets in a format other than the one this receiver was built for; `AppState` rebuilds
    /// the receiver when the sender's format really changes.
    public private(set) var mismatched: UInt64 = 0

    public init(stream: StreamDescription, latencyMs: Double, listener: ScreamListener) {
        self.listener = listener
        super.init(stream: stream, latencyMs: latencyMs)
    }

    deinit { stop() }

    public override func start(interfaceAddress: String) -> String? {
        listener?.attach(self)
        return nil
    }

    public override func stop() {
        listener?.detach(self)
    }

    /// Network thread. `payload` holds exactly `header.frames × channels` samples.
    public func handle(_ payload: UnsafePointer<UInt8>, _ header: Scream.Header) {
        guard header.sampleRate == stream.sampleRate, header.channels == stream.channels,
              header.encoding == stream.encoding, header.frames <= maxPacketFrames else {
            mismatched += 1
            return
        }
        decodeLittleEndian(payload, count: header.frames * stream.channels)
        deliver(frames: header.frames)
    }
}
