import Foundation
import AVFoundation

/// Runs the captured audio through the insert chain before it is sent.
///
/// The same `InsertChain` as the Grabber's monitor output — the same hard bypass, dry/wet and
/// latency-aligned dry leg — hosted in an `AVAudioEngine` that **renders offline and never
/// plays**: the capture hands it a buffer, it renders exactly that many frames through the chain,
/// and the result goes to the network. Nothing reaches this Mac's speakers from here.
///
/// **With nothing loaded it is out of the path entirely**: `process` returns its input untouched
/// and the engine is not even rendered, so a Sender with no plugins costs what it did before.
///
/// No Δ here, unlike the Grabber: this Mac only ever hears the audio before the inserts, so there
/// is nothing local to judge the difference against. The chain's delta leg stays disengaged.
///
/// Threads: `process` runs on the capture queue; loading a plugin, bypass and dry/wet come from
/// the main thread. A rebuild holds the lock, and a buffer that arrives mid-rebuild goes out
/// unprocessed rather than waiting — a moment of dry signal, not a gap.
final class InsertProcessor: SendProcessor {
    let chain = InsertChain()
    var onError: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var source: AVAudioSourceNode?
    private var output: AVAudioPCMBuffer?
    private var configured: (rate: Int, channels: Int)?
    private static let maxFrames: AVAudioFrameCount = 4096

    // What the source node reads from during a render. Set on the capture queue immediately
    // before `renderOffline`, which calls the source back synchronously on the same thread.
    private var input: UnsafePointer<Float>?
    private var inputChannels = 0
    private var interleaved: UnsafeMutablePointer<Float>
    private let interleavedCapacity = Int(maxFrames) * 64

    init() {
        interleaved = .allocate(capacity: interleavedCapacity)
    }

    deinit { interleaved.deallocate() }

    // MARK: - Capture queue

    /// The samples to send: processed through the chain, or the input itself when there is
    /// nothing to process it with.
    func process(_ samples: UnsafePointer<Float>, frames: Int, channels: Int,
                 sampleRate: Int) -> UnsafePointer<Float> {
        guard lock.try() else { return samples }
        defer { lock.unlock() }
        guard !chain.isEmpty, frames > 0, frames <= Int(Self.maxFrames),
              frames * channels <= interleavedCapacity else { return samples }
        if configured?.rate != sampleRate || configured?.channels != channels {
            rebuildLocked(rate: sampleRate, channels: channels)
        }
        guard engine.isRunning, let output else { return samples }

        input = samples
        inputChannels = channels
        defer { input = nil }
        guard let status = try? engine.renderOffline(AVAudioFrameCount(frames), to: output),
              status == .success, let data = output.floatChannelData else { return samples }
        let rendered = min(Int(output.frameLength), frames)
        let outChannels = min(Int(output.format.channelCount), channels)
        for c in 0..<channels {
            let from = data[min(c, outChannels - 1)]
            for f in 0..<rendered { interleaved[f * channels + c] = from[f] }
            for f in rendered..<frames { interleaved[f * channels + c] = 0 }
        }
        return UnsafePointer(interleaved)
    }

    // MARK: - Main thread

    /// Rewires the chain after a plugin is loaded, removed or finishes loading.
    func rebuild() {
        lock.lock()
        defer { lock.unlock() }
        guard let c = configured else { return }
        rebuildLocked(rate: c.rate, channels: c.channels)
    }

    func setBypass(slot: Int, _ on: Bool) { chain.setBypass(slot: slot, on) }
    func setMix(slot: Int, _ mix: Double) { chain.setMix(slot: slot, mix) }

    /// Channels the chain is running at, for "needs N ch" — the capture's own count once known.
    var channels: Int { configured?.channels ?? 2 }

    // MARK: - Building

    /// Tears the graph down to nothing and builds it again for this format. Lock held.
    ///
    /// Everything but the engine's own mixer and output is detached, not only what the chain
    /// knows about: a slot whose plugin was swapped no longer holds the old node, and a node
    /// left attached would stay in the graph unseen.
    private func rebuildLocked(rate: Int, channels: Int) {
        configured = (rate, channels)
        if engine.isRunning { engine.stop() }
        chain.disconnect(in: engine)
        chain.detachGains(from: engine)
        for node in engine.attachedNodes where node !== engine.mainMixerNode && node !== engine.outputNode {
            engine.disconnectNodeOutput(node)
            engine.detach(node)
        }
        source = nil
        output = nil
        guard !chain.isEmpty,
              let format = BusFormat.make(rate: Double(rate), channels: channels) else { return }

        do {
            if engine.isInManualRenderingMode { engine.disableManualRenderingMode() }
            try engine.enableManualRenderingMode(.offline, format: format,
                                                 maximumFrameCount: Self.maxFrames)
        } catch {
            onError?("Inserts could not be set up: \(error.localizedDescription)")
            return
        }

        let node = AVAudioSourceNode(format: format) { [unowned self] isSilence, _, frameCount, abl in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            guard let input = self.input else {
                isSilence.pointee = true
                for b in buffers { b.mData?.initializeMemory(as: UInt8.self, repeating: 0,
                                                             count: Int(b.mDataByteSize)) }
                return noErr
            }
            let frames = Int(frameCount)
            let channels = self.inputChannels
            for (c, buffer) in buffers.enumerated() {
                guard let out = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let from = min(c, channels - 1)
                for f in 0..<frames { out[f] = input[f * channels + from] }
            }
            return noErr
        }
        engine.attach(node)
        source = node

        chain.sampleRate = Double(rate)
        let last = chain.connect(in: engine, after: node, format: format, channels: channels)
        engine.connect(last, to: engine.mainMixerNode, format: format)
        // By hand and at full width, as in the Grabber: left to itself the engine joins its
        // mixer to the output at stereo, and a wider bus arrives folded or silent.
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: format)
        engine.mainMixerNode.outputVolume = 1

        output = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                  frameCapacity: Self.maxFrames)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            onError?("Inserts could not start: \(error.localizedDescription)")
        }
    }

    /// The chain as wired, for the self-test.
    var summary: String {
        let parts = chain.summary(channels: channels)
        return parts.isEmpty ? "no inserts" : parts.joined(separator: " → ")
    }
}
