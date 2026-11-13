import Foundation
import AVFoundation
import AudioToolbox

/// The dry leg of an insert, for delta monitoring: **delay, then invert**.
///
/// Delta means hearing only what a plugin changed — `wet − dry` — and the parallel pair each
/// insert is already wired as puts both halves side by side. What it cannot express is
/// the subtraction: `AVAudioMixerNode` gains clamp at zero, so there is no way to ask the dry
/// path for −1, and an `AVAudioEngine` graph has no delay compensation, so the two legs are not
/// sample-aligned across a plugin that reports latency. Both are this unit's job, and they have
/// to happen together: subtracting a misaligned dry leg comb-filters rather than nulls, which
/// would show a difference the plugin never made.
///
/// It sits in the dry leg **whenever a plugin is loaded**, not only while delta is engaged.
/// Inactive it is a copy, which costs one pass over the buffer, and that price buys the thing
/// the app cares about more: engaging delta stays a parameter change on a graph that already
/// exists, like bypass and dry/wet, instead of a rebuild that stops the engine mid-listen.
///
/// `AVAudioUnitDelay` is not an alternative. It is a wet/dry delay effect with its own smoothing
/// and a minimum delay time, where this needs an exact whole number of samples and nothing else.
final class DeltaAudioUnit: AUAudioUnit {

    /// `'dlta'` / `'NAGr'`. A private component, registered in-process — it is never installed,
    /// never scanned, and deliberately not something `PluginCatalog.effects()` can return.
    static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: 0x646C7461,           // 'dlta'
        componentManufacturer: 0x4E414772,      // 'NAGr'
        componentFlags: 0,
        componentFlagsMask: 0)

    private static var registered = false

    /// Registers the subclass once per process. Must run before the first instantiation.
    static func registerOnce() {
        guard !registered else { return }
        registered = true
        AUAudioUnit.registerSubclass(DeltaAudioUnit.self,
                                     as: componentDescription,
                                     name: "Network Audio Grabber Delta",
                                     version: 1)
    }

    /// Longest compensation this will hold: two seconds. Plugin latencies run to tens of
    /// milliseconds — a linear-phase EQ or a look-ahead limiter is the worst of it — so this is
    /// far more than needed, and it is allocated once rather than grown.
    private static let maxDelayFrames = 96_000

    // MARK: - State shared with the main thread
    //
    // One word, written by the UI and read by the render thread, so there is no pair of values
    // to tear between:
    //
    //     0   pass-through
    //   > 0   invert, with n − 1 frames of delay          (delta)
    //   < 0   delay only, by −n − 1 frames                (dry/wet compensation)
    //
    // An aligned 32-bit store is atomic on every machine this runs on, and the worst a race
    // could do is apply the change one callback late.
    private let state: UnsafeMutablePointer<Int32> = {
        let p = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        p.initialize(to: 0)
        return p
    }()

    private func clamp(_ frames: Int) -> Int32 {
        Int32(min(max(0, frames), Self.maxDelayFrames - 1))
    }

    /// Engages the subtraction. `delayFrames` is the plugin's reported latency in whole samples.
    func engageDelta(delayFrames: Int) { state.pointee = clamp(delayFrames) + 1 }

    /// Aligns the dry leg with the plugin without inverting it, so a **partial dry/wet blend**
    /// sums instead of comb-filtering. The same delay line, doing the half of the job that is
    /// not the subtraction.
    func compensate(delayFrames: Int) { state.pointee = -(clamp(delayFrames) + 1) }

    func disengage() { state.pointee = 0 }

    var isEngaged: Bool { state.pointee > 0 }

    // MARK: - Buses

    private var inputBus: AUAudioUnitBus
    private var outputBus: AUAudioUnitBus
    private var inputBusArray: AUAudioUnitBusArray!
    private var outputBusArray: AUAudioUnitBusArray!

    override var inputBusses: AUAudioUnitBusArray { inputBusArray }
    override var outputBusses: AUAudioUnitBusArray { outputBusArray }
    override var canProcessInPlace: Bool { true }

    // MARK: - Delay storage
    //
    // One flat buffer per channel, written and read by the render thread only. Allocated in
    // `allocateRenderResources` and never resized while rendering.

    private var lines: [UnsafeMutablePointer<Float>] = []
    private var writeIndex = 0
    private var lineChannels = 0

    override init(componentDescription: AudioComponentDescription,
                  options: AudioComponentInstantiationOptions = []) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        inputBus = try AUAudioUnitBus(format: format)
        outputBus = try AUAudioUnitBus(format: format)
        try super.init(componentDescription: componentDescription, options: options)
        inputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inputBus])
        outputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
        maximumFramesToRender = 4096
    }

    deinit {
        releaseLines()
        state.deallocate()
    }

    private func releaseLines() {
        for line in lines { line.deallocate() }
        lines.removeAll()
        lineChannels = 0
    }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        releaseLines()
        lineChannels = Int(outputBus.format.channelCount)
        lines = (0..<lineChannels).map { _ in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxDelayFrames)
            p.initialize(repeating: 0, count: Self.maxDelayFrames)
            return p
        }
        writeIndex = 0
    }

    override func deallocateRenderResources() {
        releaseLines()
        super.deallocateRenderResources()
    }

    // MARK: - Render

    override var internalRenderBlock: AUInternalRenderBlock {
        // Captured once, deliberately: the render block must not touch `self`, so everything it
        // needs is copied in here and the mutable parts are raw pointers.
        let statePointer = state
        let capacity = Self.maxDelayFrames

        return { [weak self] _, timestamp, frameCount, _, outputData, _, pullInputBlock in
            guard let pullInputBlock else { return kAudioUnitErr_NoConnection }

            // Pull the upstream straight into our own output buffers and work in place.
            var pullFlags = AudioUnitRenderActionFlags(rawValue: 0)
            let status = pullInputBlock(&pullFlags, timestamp, frameCount, 0, outputData)
            guard status == noErr else { return status }

            // `self` is only read for the line pointers, which the audio thread owns for the
            // lifetime of the render resources. Nothing here allocates or locks.
            guard let unit = self else { return noErr }

            let buffers = UnsafeMutableAudioBufferListPointer(outputData)
            let frames = Int(frameCount)
            let word = statePointer.pointee
            let channels = min(buffers.count, unit.lineChannels)
            guard channels > 0 else { return noErr }

            // Always fed into the delay line, even when doing nothing, so engaging mid-signal
            // starts from real history rather than from silence.
            let invert = word > 0
            let delayed = word != 0
            let delay = delayed ? Int(abs(word) - 1) : 0

            var index = unit.writeIndex
            for channel in 0..<channels {
                guard let data = buffers[channel].mData?.assumingMemoryBound(to: Float.self)
                else { continue }
                let line = unit.lines[channel]
                index = unit.writeIndex
                for i in 0..<frames {
                    line[index] = data[i]
                    if delayed {
                        let read = (index - delay + capacity) % capacity
                        data[i] = invert ? -line[read] : line[read]
                    }
                    index = index + 1 == capacity ? 0 : index + 1
                }
            }
            unit.writeIndex = index
            return noErr
        }
    }
}
