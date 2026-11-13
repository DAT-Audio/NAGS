import Foundation

/// Multichannel streams are interpreted as **SMPTE** channel order everywhere in this app.
/// AES67 and Dante carry no channel-order metadata, so an assumption has to be made, and
/// SMPTE is the one broadcast and game audio use:
///
/// | Channels | Order |
/// | --- | --- |
/// | 1 | M |
/// | 2 | L R |
/// | 4 | L R Ls Rs |
/// | 6 (5.1) | L R C LFE Ls Rs |
/// | 8 (7.1) | L R C LFE Lss Rss Lrs Rrs |
///
/// This is SMPTE ST 2036-2 ordering — *not* the ITU "L C R Ls Rs LFE" variant. A stream whose
/// channel count is not one of the above is treated as discrete mono channels.
public enum SMPTELayout: String {
    case mono = "Mono"
    case stereo = "Stereo"
    case quad = "4.0"
    case surround51 = "5.1"
    case surround71 = "7.1"

    public static func forChannelCount(_ channels: Int) -> SMPTELayout? {
        switch channels {
        case 1: return .mono
        case 2: return .stereo
        case 4: return .quad
        case 6: return .surround51
        case 8: return .surround71
        default: return nil                 // discrete channels, no meaningful fold-down
        }
    }

    /// Short SMPTE names for each channel position, in order.
    public var channelNames: [String] {
        switch self {
        case .mono: return ["M"]
        case .stereo: return ["L", "R"]
        case .quad: return ["L", "R", "Ls", "Rs"]
        case .surround51: return ["L", "R", "C", "LFE", "Ls", "Rs"]
        case .surround71: return ["L", "R", "C", "LFE", "Lss", "Rss", "Lrs", "Rrs"]
        }
    }

    public var foldsDown: Bool { self == .quad || self == .surround51 || self == .surround71 }

    /// Where the LFE sits, in the layouts that have one.
    ///
    /// It is excluded from the mono fold for the same reason BS.1770 excludes it from loudness:
    /// it is a band-limited effects channel, not programme, and summing it in would count bass
    /// that is already in the bed a second time. Under MONO it passes through untouched.
    public var lfeIndex: Int? { (self == .surround51 || self == .surround71) ? 3 : nil }
}

/// What a channel *is*, as opposed to where it sits.
///
/// Every decision this app makes about a multichannel stream — the fold-down gains, the label
/// under a meter, which channel is excluded from the mono fold, which carries the +1.5 dB
/// loudness weighting — depends on the channel's role rather than its index. Separating the two
/// is what lets a stream arrive in an order other than SMPTE without any of those decisions
/// having to know about it.
public enum ChannelRole {
    case left, right, centre, lfe
    case leftSide, rightSide            // Ls / Rs on 5.1, Lss / Rss on 7.1
    case leftRear, rightRear            // Lrs / Rrs on 7.1 only

    /// Short SMPTE name, used under the meters and in the mix menu.
    public var label: String {
        switch self {
        case .left:      return "L"
        case .right:     return "R"
        case .centre:    return "C"
        case .lfe:       return "LFE"
        case .leftSide:  return "Ls"
        case .rightSide: return "Rs"
        case .leftRear:  return "Lrs"
        case .rightRear: return "Rrs"
        }
    }

    /// ITU-R BS.775 fold-down contribution to the stereo bus.
    public func foldGains(includeLFE: Bool) -> (Float, Float) {
        switch self {
        case .left:      return (1, 0)
        case .right:     return (0, 1)
        case .centre:    return (Downmix.centerGain, Downmix.centerGain)
        case .lfe:       return includeLFE ? (Downmix.lfeGain, Downmix.lfeGain) : (0, 0)
        case .leftSide:  return (Downmix.surroundGain, 0)
        case .rightSide: return (0, Downmix.surroundGain)
        case .leftRear:  return (Downmix.rearGain, 0)
        case .rightRear: return (0, Downmix.rearGain)
        }
    }

    /// Where this role sits in a SMPTE-ordered bus of the given width, which is the order the
    /// monitor bus itself is always in.
    public func busIndex(busChannels: Int) -> Int? {
        ChannelOrder.smpte.roles(channels: busChannels).firstIndex(of: self)
    }
}

/// The order a stream's channels arrive in.
///
/// **Nothing in an AES67 or Dante stream declares this** — no SDP field, no metadata — so it can
/// only ever be an assumption, and the app's job is to make the assumption visible and
/// changeable rather than silently right for some senders and silently wrong for others. SMPTE
/// is the default because it is what broadcast and game audio use.
///
/// The cases spell out their own order in `menuLabel`, deliberately: naming a standard invites
/// an argument about which variant is meant, whereas "L R Ls Rs C LFE" does not.
public enum ChannelOrder: String, CaseIterable, Identifiable {
    case smpte
    case itu

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .smpte: return "SMPTE"
        case .itu:   return "ITU/DTS"
        }
    }

    /// What the roles are, in the order the channels arrive.
    public func roles(channels: Int) -> [ChannelRole] {
        switch (self, channels) {
        case (_, 1):            return [.centre]
        case (_, 2):            return [.left, .right]
        case (_, 4):            return [.left, .right, .leftSide, .rightSide]
        case (.smpte, 6):       return [.left, .right, .centre, .lfe, .leftSide, .rightSide]
        case (.itu, 6):         return [.left, .right, .leftSide, .rightSide, .centre, .lfe]
        case (.smpte, 8):       return [.left, .right, .centre, .lfe,
                                        .leftSide, .rightSide, .leftRear, .rightRear]
        case (.itu, 8):         return [.left, .right, .leftSide, .rightSide,
                                        .centre, .lfe, .leftRear, .rightRear]
        default:                return []          // discrete channels, no roles to assign
        }
    }

    /// Spelled out, so the choice is unambiguous at the point of making it.
    public func menuLabel(channels: Int) -> String {
        let roles = self.roles(channels: channels)
        guard !roles.isEmpty else { return name }
        return "\(name) — \(roles.map(\.label).joined(separator: " "))"
    }
}

/// One source channel's contribution to the monitor bus.
///
/// **Two destinations, and no more,** because two is the most any single source channel needs:
/// a fold-down sends C to both L and R, and everything else — a pass-through, a stereo pair, a
/// soloed channel — uses one and leaves the other idle. Holding it to a fixed pair is what keeps
/// the tap list exactly one entry per source channel, which is the size the double-buffered tap
/// slots in `StreamReceiver` are allocated for.
///
/// `destB` of −1 means unused. Every builder in this file targets the stereo bus and goes on
/// using `init(channel:gainL:gainR:)`; a wider bus is `passthroughTaps`.
public struct MixTap {
    public var channel: Int32
    public var destA: Int32
    public var gainA: Float
    public var destB: Int32
    public var gainB: Float

    public init(channel: Int32, destA: Int32, gainA: Float, destB: Int32 = -1, gainB: Float = 0) {
        self.channel = channel
        self.destA = destA
        self.gainA = gainA
        self.destB = destB
        self.gainB = gainB
    }

    /// A tap onto the stereo bus — bus channel 0 is left, 1 is right.
    public init(channel: Int32, gainL: Float, gainR: Float) {
        self.init(channel: channel, destA: 0, gainA: gainL, destB: 1, gainB: gainR)
    }
}

/// How one stream is folded into the stereo monitor bus.
public enum MixMode: Hashable {
    case pair(Int)      // a stereo pair starting at this channel index
    case mono(Int)      // one channel to both sides
    case downmix        // SMPTE fold-down of the whole stream
    case passthrough    // channel for channel, as far as the bus goes

    /// Text form, for the per-stream preference and for `--mixmode`. Channel indices are
    /// 0-based here, as they are in the cases themselves; only the UI counts from one.
    public var token: String {
        switch self {
        case .downmix:          return "downmix"
        case .passthrough:      return "direct"
        case .pair(let start):  return "pair:\(start)"
        case .mono(let channel):return "mono:\(channel)"
        }
    }

    public init?(token: String) {
        let parts = token.split(separator: ":")
        switch parts.first {
        case "downmix": self = .downmix
        case "direct":  self = .passthrough
        case "pair":    guard parts.count > 1, let n = Int(parts[1]) else { return nil }
                        self = .pair(n)
        case "mono":    guard parts.count > 1, let n = Int(parts[1]) else { return nil }
                        self = .mono(n)
        default:        return nil
        }
    }

    /// Whether this mode makes sense for a stream of this width — a remembered `pair:6` must
    /// not be restored onto a stream that came back with two channels, and `downmix` means
    /// nothing on a layout that does not fold.
    public func fits(channels: Int) -> Bool {
        switch self {
        case .passthrough:
            return true
        case .downmix:
            return SMPTELayout.forChannelCount(channels)?.foldsDown ?? false
        case .pair(let start):
            return start >= 0 && start < channels
        case .mono(let channel):
            return channel >= 0 && channel < channels
        }
    }
}

public enum Downmix {
    /// ITU-R BS.775 fold-down coefficients.
    public static let centerGain: Float = 0.7071        // −3 dB
    public static let surroundGain: Float = 0.7071      // −3 dB
    public static let rearGain: Float = 0.5             // −6 dB (rears fold to sides, then to stereo)
    public static let lfeGain: Float = 0.3162           // −10 dB, only when the user opts in

    /// Builds the channel-to-stereo mix for one stream. `trimDB` is the downmix normalisation
    /// applied to fold-downs only — summing L + −3 dB C + −3 dB Ls can reach +7.6 dB, so some
    /// attenuation is needed to keep correlated material off the clip point.
    ///
    /// `soloed` is a set of channel indices to monitor on their own. Empty means no channel solo
    /// and `mode` decides everything, which is the normal case. See `soloTaps` for what a
    /// non-empty set does — it deliberately overrides `mode`.
    /// Straight through: stream channel *n* to bus channel *n*, as far as the narrower of the
    /// two goes.
    ///
    /// A stream narrower than the bus leaves the rest of the bus silent, and one wider than the
    /// bus has its extra channels dropped — which is why `AudioOutput` folds a too-wide stream
    /// to stereo instead of calling this. No upmix, ever: inventing a centre channel from a
    /// stereo stream is a creative decision, not a monitoring one.
    public static func passthroughTaps(channels: Int, busChannels: Int,
                                order: ChannelOrder = .smpte) -> [MixTap] {
        // The monitor bus is always SMPTE-ordered, so a stream that arrives in another order is
        // mapped **by role** rather than by index: an ITU 5.1 stream's Ls goes to the bus
        // position where a surround belongs, not to the one where its index happens to land.
        let roles = order.roles(channels: channels)
        if order != .smpte, !roles.isEmpty {
            return roles.enumerated().compactMap { index, role in
                guard let destination = role.busIndex(busChannels: busChannels) else { return nil }
                return MixTap(channel: Int32(index), destA: Int32(destination), gainA: 1)
            }
        }
        return (0..<min(channels, busChannels)).map {
            MixTap(channel: Int32($0), destA: Int32($0), gainA: 1)
        }
    }

    public static func taps(channels: Int, busChannels: Int = 2, mode: MixMode,
                     order: ChannelOrder = .smpte,
                     includeLFE: Bool, trimDB: Double, soloed: Set<Int> = []) -> [MixTap] {
        if !soloed.isEmpty {
            return soloTaps(channels: channels, soloed: soloed, order: order, trimDB: trimDB)
        }
        let last = max(0, channels - 1)

        switch mode {
        case .passthrough:
            return passthroughTaps(channels: channels, busChannels: busChannels, order: order)

        case .mono(let ch):
            let c = Int32(min(max(0, ch), last))
            return [MixTap(channel: c, gainL: 0.7071, gainR: 0.7071)]

        case .pair(let start):
            let l = Int32(min(max(0, start), last))
            let r = Int32(min(max(0, start + 1), last))
            if l == r { return [MixTap(channel: l, gainL: 0.7071, gainR: 0.7071)] }
            return [MixTap(channel: l, gainL: 1, gainR: 0),
                    MixTap(channel: r, gainL: 0, gainR: 1)]

        case .downmix:
            // Built from the channels' **roles**, so the same code folds a SMPTE stream and an
            // ITU one — only the role-to-index mapping differs. A channel count with no roles
            // to assign is discrete audio and has no meaningful fold.
            let roles = order.roles(channels: channels)
            guard roles.count > 2 else {
                return taps(channels: channels, busChannels: busChannels, mode: .pair(0),
                            order: order, includeLFE: includeLFE, trimDB: trimDB)
            }
            let trim = Float(pow(10.0, trimDB / 20.0))
            var result: [MixTap] = []
            for (index, role) in roles.enumerated() where index < channels {
                let (left, right) = role.foldGains(includeLFE: includeLFE)
                guard left != 0 || right != 0 else { continue }
                result.append(MixTap(channel: Int32(index),
                                     gainL: left * trim, gainR: right * trim))
            }
            return result
        }
    }

    /// Channel solo: monitor just these channels, **in the positions the fold-down would give
    /// them**. Soloing Lrs and Rrs on a 7.1 stream puts them where the fold-down puts them —
    /// left and right at −6 dB — rather than re-panning them, so what you hear is that part of
    /// the mix rather than a new one.
    ///
    /// Two consequences worth knowing:
    ///
    /// * **It overrides the mix mode** rather than filtering it. Filtering would have meant that
    ///   soloing channel 7 while the row was set to `Ch 1/2` produced silence, because channel 7
    ///   is not in that matrix at all. Starting from the positional matrix means a solo always
    ///   makes a sound.
    /// * **The fold-down trim stays applied**, so a solo sits at the same level as the same
    ///   channels inside the full fold-down. That is what makes it useful for A/B rather than
    ///   just for listening.
    ///
    /// A single soloed channel is heard in its own position, which on a rear channel means one
    /// ear. `Ch N mono` in the mix menu is the way to hear one channel centred — the two
    /// controls answer different questions and both are kept.
    ///
    /// LFE is forced in here: asking to solo LFE is explicit enough to override the global
    /// "include LFE in the fold-down" preference.
    private static func soloTaps(channels: Int, soloed: Set<Int>,
                                 order: ChannelOrder, trimDB: Double) -> [MixTap] {
        let base: [MixTap]
        if let layout = SMPTELayout.forChannelCount(channels), layout.foldsDown {
            base = taps(channels: channels, mode: .downmix, order: order,
                        includeLFE: true, trimDB: trimDB)
        } else {
            // No meaningful fold-down for this channel count, so treat the channels as discrete
            // and lay them alternately left and right. Arbitrary, but it gives every channel a
            // position, which is all the solo needs.
            var discrete: [MixTap] = []
            for channel in 0..<channels {
                let left: Float = channel % 2 == 0 ? 1 : 0
                let right: Float = channel % 2 == 0 ? 0 : 1
                discrete.append(MixTap(channel: Int32(channel), gainL: left, gainR: right))
            }
            base = discrete
        }
        let kept = base.filter { soloed.contains(Int($0.channel)) }
        // If nothing matched — a stale solo set left over from a stream that has been
        // re-announced with a different channel count — fall back to the whole matrix. An empty
        // tap list would not just be silent: `RingBuffer.mix` bails out before advancing
        // the read pointer, so the stream's buffer would fill and never drain.
        return kept.isEmpty ? base : kept
    }

    /// Menu label for a mix mode, e.g. "5.1 → 2.0" or "Ch 3/4".
    public static func label(for mode: MixMode, channels: Int) -> String {
        switch mode {
        case .passthrough:
            let layout = SMPTELayout.forChannelCount(channels)
            return layout.map { "\($0.rawValue) direct" } ?? "\(channels) ch direct"
        case .downmix:
            let layout = SMPTELayout.forChannelCount(channels)
            return "\(layout?.rawValue ?? "Multi") → 2.0"

        case .mono(let ch):
            return "Ch \(ch + 1) mono"
        case .pair(let start):
            // Always numeric. Naming a pair "L/R" would be a guess about channel order, and
            // the point of the SMPTE assumption is that it stays visible rather than implied.
            return start + 1 < channels ? "Ch \(start + 1)/\(start + 2)" : "Ch \(start + 1)"
        }
    }
}
