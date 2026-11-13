import Foundation
import AVFoundation
import AudioToolbox

/// A pass-through that notes the loudest sample going through it — the in and out meters of an
/// insert. Our own unit, like `DeltaAudioUnit`, because nothing in `AVAudioEngine`
/// hands a mixer's buffers to anyone, and a plugin's own render notification cannot be relied on
/// once the plugin runs in another process.
///
/// Costs one pass over the buffer, in place. The peak is held in a `SharedFloats` and only ever
/// raised by the audio thread; the meter takes it (reads and clears it) once a frame, so what it
/// shows is the loudest since it last looked, not whichever buffer happened to be last.
final class LevelTapAudioUnit: AUAudioUnit {
    /// `'ltap'` / `'NAGr'`: private, registered in-process, never scanned.
    static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: 0x6C746170,           // 'ltap'
        componentManufacturer: 0x4E414772,      // 'NAGr'
        componentFlags: 0,
        componentFlagsMask: 0)

    private static var registered = false

    static func registerOnce() {
        guard !registered else { return }
        registered = true
        AUAudioUnit.registerSubclass(LevelTapAudioUnit.self, as: componentDescription,
                                     name: "Network Audio Level Tap", version: 1)
    }

    let peak = SharedFloats(count: 1)

    /// The loudest sample since the last call, and clear it.
    func takePeak() -> Float {
        let v = peak[0]
        peak[0] = 0
        return v
    }

    private var inputBus: AUAudioUnitBus
    private var outputBus: AUAudioUnitBus
    private var inputBusArray: AUAudioUnitBusArray!
    private var outputBusArray: AUAudioUnitBusArray!

    override var inputBusses: AUAudioUnitBusArray { inputBusArray }
    override var outputBusses: AUAudioUnitBusArray { outputBusArray }
    override var canProcessInPlace: Bool { true }

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

    override var internalRenderBlock: AUInternalRenderBlock {
        let peak = self.peak
        return { _, timestamp, frameCount, _, outputData, _, pullInputBlock in
            guard let pullInputBlock else { return kAudioUnitErr_NoConnection }
            var flags = AudioUnitRenderActionFlags(rawValue: 0)
            let status = pullInputBlock(&flags, timestamp, frameCount, 0, outputData)
            guard status == noErr else { return status }
            var loudest: Float = 0
            for buffer in UnsafeMutableAudioBufferListPointer(outputData) {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let n = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                for i in 0..<min(n, Int(frameCount) * Int(max(1, buffer.mNumberChannels))) {
                    loudest = max(loudest, abs(data[i]))
                }
            }
            if loudest > peak[0] { peak[0] = loudest }
            return noErr
        }
    }
}
