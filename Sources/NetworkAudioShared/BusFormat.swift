import AVFoundation

public enum BusFormat {
    /// The format every stage of the graph is built from.
    ///
    /// `standardFormatWithSampleRate:channels:` accepts **one or two channels only** and
    /// returns nil for anything wider, which is the whole reason a wide bus needs a channel
    /// layout rather than a count.
    ///
    /// The layout is `DiscreteInOrder` rather than a surround tag like `MPEG_5_1_A`,
    /// deliberately: a tagged layout invites every stage in the chain to be clever about
    /// mapping — to pan, fold or re-order according to what it thinks the channels *mean* —
    /// and this app has one rule, which is that channel *n* goes to output *n*. The SMPTE
    /// ordering is an assumption stated everywhere in the UI, not something the graph should
    /// act on.
    public static func make(rate: Double, channels: Int) -> AVAudioFormat? {
        if channels <= 2 {
            return AVAudioFormat(standardFormatWithSampleRate: rate,
                                 channels: AVAudioChannelCount(max(1, channels)))
        }
        let tag = kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)
        guard let layout = AVAudioChannelLayout(layoutTag: tag) else { return nil }
        return AVAudioFormat(standardFormatWithSampleRate: rate, channelLayout: layout)
    }
}
