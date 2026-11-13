import Foundation
import AudioToolbox

/// Compressed stream bytes in, interleaved float out. macOS does the work: AudioFileStream
/// finds the packets in MP3, AAC (ADTS) or FLAC data, AudioConverter decodes them — and resamples
/// to the output rate if asked. No decoder of our own and no dependency.
///
/// Not thread-safe: fed from one queue (the stream's).
final class WebAudioDecoder {
    /// The source's format, once the parser has seen enough to know it.
    private(set) var sourceFormat: AudioStreamBasicDescription?
    /// Called with each run of decoded frames: interleaved Float32, `outputChannels` wide.
    var onFrames: (UnsafePointer<Float>, Int) -> Void = { _, _ in }
    /// Called once the source format is known.
    var onFormat: (AudioStreamBasicDescription) -> Void = { _ in }

    private var parser: AudioFileStreamID?
    private var converter: AudioConverterRef?
    private let outputRate: Double?
    private let outputChannels: Int?
    private(set) var failure: String?

    // Packets waiting for the converter.
    fileprivate var pendingData: [UInt8] = []
    fileprivate var pendingPackets: [AudioStreamPacketDescription] = []
    fileprivate var packetIndex = 0
    fileprivate var feedDescription = AudioStreamPacketDescription()
    fileprivate var feedBytes: [UInt8] = []

    private let outFrames = 4096
    private var outBuffer: UnsafeMutablePointer<Float>

    /// `rate` and `channels` fix the output; nil means "whatever the source is" (the probe).
    init(typeHint: AudioFileTypeID, rate: Double?, channels: Int?) {
        outputRate = rate
        outputChannels = channels
        outBuffer = .allocate(capacity: outFrames * max(1, channels ?? 8))
        let status = AudioFileStreamOpen(Unmanaged.passUnretained(self).toOpaque(),
                                         WebAudioDecoder.propertyProc, WebAudioDecoder.packetsProc,
                                         typeHint, &parser)
        if status != noErr { failure = "This kind of stream cannot be decoded (\(status))." }
    }

    deinit {
        if let parser { AudioFileStreamClose(parser) }
        if let converter { AudioConverterDispose(converter) }
        outBuffer.deallocate()
    }

    /// The type hint for a content type, so the parser need not guess.
    static func typeHint(contentType: String) -> AudioFileTypeID {
        if contentType.contains("mpeg") || contentType.contains("mp3") { return kAudioFileMP3Type }
        if contentType.contains("aac") { return kAudioFileAAC_ADTSType }
        if contentType.contains("flac") { return kAudioFileFLACType }
        return 0
    }

    func feed(_ bytes: [UInt8]) {
        guard let parser, failure == nil, !bytes.isEmpty else { return }
        let status = bytes.withUnsafeBufferPointer {
            AudioFileStreamParseBytes(parser, UInt32($0.count), $0.baseAddress!, [])
        }
        if status != noErr, sourceFormat == nil {
            failure = "The stream's audio could not be read (\(status))."
        }
    }

    // MARK: - Parser callbacks

    private static let propertyProc: AudioFileStream_PropertyListenerProc = { client, stream, property, _ in
        let me = Unmanaged<WebAudioDecoder>.fromOpaque(client).takeUnretainedValue()
        guard property == kAudioFileStreamProperty_ReadyToProducePackets else { return }
        me.formatReady(stream)
    }

    private static let packetsProc: AudioFileStream_PacketsProc = { client, byteCount, packetCount, data, descriptions in
        let me = Unmanaged<WebAudioDecoder>.fromOpaque(client).takeUnretainedValue()
        me.packets(byteCount: Int(byteCount), count: Int(packetCount), data: data, descriptions: descriptions)
    }

    private func formatReady(_ stream: AudioFileStreamID) {
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_DataFormat, &size, &asbd) == noErr,
              asbd.mSampleRate >= 8000, asbd.mSampleRate <= 384_000,
              asbd.mChannelsPerFrame >= 1, asbd.mChannelsPerFrame <= 8 else {
            failure = "The stream's format is not one this can play."
            return
        }
        sourceFormat = asbd
        onFormat(asbd)
        let channels = UInt32(outputChannels ?? Int(asbd.mChannelsPerFrame))
        var out = AudioStreamBasicDescription(
            mSampleRate: outputRate ?? asbd.mSampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * channels, mFramesPerPacket: 1, mBytesPerFrame: 4 * channels,
            mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
        var converter: AudioConverterRef?
        guard AudioConverterNew(&asbd, &out, &converter) == noErr, let converter else {
            failure = "macOS cannot decode this stream's format."
            return
        }
        // AAC and FLAC carry their setup in a "magic cookie"; the converter needs it.
        var cookieSize: UInt32 = 0
        if AudioFileStreamGetPropertyInfo(stream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, nil) == noErr,
           cookieSize > 0 {
            var cookie = [UInt8](repeating: 0, count: Int(cookieSize))
            if AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, &cookie) == noErr {
                AudioConverterSetProperty(converter, kAudioConverterDecompressionMagicCookie, cookieSize, cookie)
            }
        }
        self.converter = converter
        let needed = outFrames * Int(channels)
        if needed > outFrames * max(1, outputChannels ?? 8) {
            outBuffer.deallocate()
            outBuffer = .allocate(capacity: needed)
        }
    }

    private func packets(byteCount: Int, count: Int, data: UnsafeRawPointer,
                         descriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?) {
        guard let converter, let descriptions, count > 0 else { return }
        pendingData = [UInt8](UnsafeRawBufferPointer(start: data, count: byteCount))
        pendingPackets = Array(UnsafeBufferPointer(start: descriptions, count: count))
        packetIndex = 0
        let channels = Int(outputChannels ?? Int(sourceFormat?.mChannelsPerFrame ?? 2))
        while true {
            var frames = UInt32(outFrames)
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: UInt32(channels), mDataByteSize: UInt32(outFrames * channels * 4),
                mData: UnsafeMutableRawPointer(outBuffer)))
            let status = AudioConverterFillComplexBuffer(converter, WebAudioDecoder.inputProc,
                                                         Unmanaged.passUnretained(self).toOpaque(),
                                                         &frames, &list, nil)
            if frames > 0 { onFrames(outBuffer, Int(frames)) }
            // "No more input for now" ends this pass; the converter keeps its state for the next.
            if status == WebAudioDecoder.drained || status != noErr || frames == 0 { break }
        }
    }

    fileprivate static let drained: OSStatus = 0x6E6F6474          // 'nodt'

    /// Hands the converter one packet at a time from what the parser just produced.
    private static let inputProc: AudioConverterComplexInputDataProc = { _, ioPackets, ioData, outDescription, client in
        let me = Unmanaged<WebAudioDecoder>.fromOpaque(client!).takeUnretainedValue()
        guard me.packetIndex < me.pendingPackets.count else {
            ioPackets.pointee = 0
            return WebAudioDecoder.drained
        }
        var d = me.pendingPackets[me.packetIndex]
        me.packetIndex += 1
        let start = Int(d.mStartOffset), size = Int(d.mDataByteSize)
        guard start >= 0, size > 0, start + size <= me.pendingData.count else {
            ioPackets.pointee = 0
            return WebAudioDecoder.drained
        }
        me.feedBytes = Array(me.pendingData[start..<(start + size)])
        d.mStartOffset = 0
        me.feedDescription = d
        ioPackets.pointee = 1
        ioData.pointee.mNumberBuffers = 1
        me.feedBytes.withUnsafeMutableBytes { raw in
            ioData.pointee.mBuffers.mData = raw.baseAddress
            ioData.pointee.mBuffers.mDataByteSize = UInt32(size)
        }
        if let outDescription {
            withUnsafeMutablePointer(to: &me.feedDescription) { outDescription.pointee = $0 }
        }
        return noErr
    }
}

extension AudioStreamBasicDescription {
    /// "MP3", "AAC", "HE-AAC", "FLAC" — what the stream is, in the words people use.
    var codecName: String {
        switch mFormatID {
        case kAudioFormatMPEGLayer3: return "MP3"
        case kAudioFormatMPEGLayer2: return "MP2"
        case kAudioFormatMPEG4AAC: return "AAC"
        case kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2: return "HE-AAC"
        case kAudioFormatFLAC: return "FLAC"
        case kAudioFormatOpus: return "Opus"
        default: return "compressed"
        }
    }
}
