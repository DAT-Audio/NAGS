import Foundation
import AVFoundation

/// The three insert slots and the wiring around each — shared by the Grabber's monitor output and
/// the Sender's processing, so an insert behaves the same in both: the same hard bypass, the same
/// dry/wet, the same latency-aligned dry leg, the same Δ.
///
/// Moved out of the Grabber's `AudioOutput` unchanged when the Sender gained inserts.
/// Each loaded insert is wired as a parallel pair rather than in line, so its dry/wet balance is
/// our own mixer rather than the plugin's honour system:
///
///     upstream ─┬─ plugin ─ wetGain ─┬─ sum ─→
///               └─ delta ─ dryGain ──┘
///
/// The chain does not own an engine. The owner builds its graph, calls `connect(…)` to splice the
/// inserts in after its source, and gets back the node the rest of its graph continues from.
public final class InsertChain {
    /// Three, not two. Everything that touches them is index-driven, so the count is the only
    /// thing that changes. Two was never a considered number; it was the number that fitted the
    /// Grabber's panel before the panel was 352 points wide.
    public let slots: [PluginSlot]

    /// The rate the owner's graph runs at, for turning a plugin's reported latency into whole
    /// samples of dry-leg delay. Set it whenever the graph is rebuilt.
    public var sampleRate: Double = 48000

    /// Slots whose plugin cannot take the current width, and is therefore held out of circuit
    /// rather than quietly applied to the front pair. Room correction on channels 1–2 of a 7.1
    /// bed is a lie about what is being heard.
    public private(set) var refused: Set<Int> = []

    /// Which slot, if any, is carrying its difference. One at a time: delta on two inserts at
    /// once has no single meaning, and it behaves like solo.
    public private(set) var deltaSlot: Int?

    /// The dry and wet gain stages of each loaded insert, keyed by slot index. Only slots with a
    /// plugin in them appear here; an empty slot is not in the graph at all.
    private var gains: [Int: (dry: AVAudioMixerNode, wet: AVAudioMixerNode, sum: AVAudioMixerNode)] = [:]

    /// The delay-and-invert node sitting in each loaded slot's dry leg. Present whenever the
    /// slot is, engaged only while that slot is in delta — see `DeltaAudioUnit`.
    private var deltas: [Int: AVAudioUnit] = [:]

    /// Level taps either side of each loaded plugin: what goes in, what comes out.
    private var taps: [Int: (input: AVAudioUnit, output: AVAudioUnit)] = [:]
    /// What the in/out meters last showed, main thread only, for their fall.
    private var shown: [Int: (input: Float, output: Float)] = [:]

    /// Level going into and coming out of slot `index`'s plugin, 0…1, for a meter polled once a
    /// frame: the loudest since the last poll, falling gently between. Zero for an empty slot.
    public func level(slot index: Int, output: Bool) -> Float {
        guard let tap = taps[index],
              let unit = (output ? tap.output : tap.input).auAudioUnit as? LevelTapAudioUnit else { return 0 }
        var s = shown[index] ?? (0, 0)
        let fresh = unit.takePeak()
        if output { s.output = max(fresh, s.output * 0.82) } else { s.input = max(fresh, s.input * 0.82) }
        shown[index] = s
        return output ? s.output : s.input
    }

    public init(count: Int = 3) {
        slots = (0..<count).map { PluginSlot(index: $0) }
    }

    /// Whether any slot has a plugin in it. With none, an owner can leave the chain out of its
    /// signal path entirely.
    public var isEmpty: Bool { !slots.contains { $0.isLoaded } }

    // MARK: - Building

    /// Wires every loaded slot that can take `channels` after `upstream`, and returns the node
    /// the owner's graph should continue from — `upstream` itself if nothing is loaded.
    public func connect(in engine: AVAudioEngine, after upstream: AVAudioNode,
                        format: AVAudioFormat, channels: Int) -> AVAudioNode {
        var upstream = upstream
        refused.removeAll()
        for slot in slots {
            guard let plugin = slot.node else { continue }
            // Asked before connecting: an Audio Unit that cannot take this width is left out
            // of the chain entirely, and the app says so rather than pretending it is in.
            guard slot.accepts(channels: channels) else {
                refused.insert(slot.index)
                continue
            }
            if !engine.attachedNodes.contains(plugin) { engine.attach(plugin) }

            // The two level taps: in before the split into plugin and dry leg, out straight after
            // the plugin, so each reads exactly its side whatever the dry/wet balance.
            LevelTapAudioUnit.registerOnce()
            let tapIn = AVAudioUnitEffect(audioComponentDescription: LevelTapAudioUnit.componentDescription)
            let tapOut = AVAudioUnitEffect(audioComponentDescription: LevelTapAudioUnit.componentDescription)
            engine.attach(tapIn)
            engine.attach(tapOut)
            taps[slot.index] = (tapIn, tapOut)
            engine.connect(upstream, to: tapIn, format: format)

            let dry = AVAudioMixerNode()
            let wet = AVAudioMixerNode()
            let sum = AVAudioMixerNode()
            for node in [dry, wet, sum] { engine.attach(node) }
            gains[slot.index] = (dry: dry, wet: wet, sum: sum)

            // One output feeding two destinations is what makes the dry path possible; the two
            // are summed on separate buses of `sum` so each can carry its own gain.
            engine.connect(tapIn,
                           to: [AVAudioConnectionPoint(node: plugin, bus: 0),
                                AVAudioConnectionPoint(node: dry, bus: 0)],
                           fromBus: 0, format: format)
            engine.connect(plugin, to: tapOut, format: format)
            engine.connect(tapOut, to: wet, format: format)
            engine.connect(wet, to: sum, fromBus: 0, toBus: 0, format: format)

            // The dry leg runs through the delta unit whether or not delta is engaged, so that
            // engaging it later is a parameter change rather than a graph rebuild. Inactive it
            // is a copy.
            DeltaAudioUnit.registerOnce()
            let delta = AVAudioUnitEffect(audioComponentDescription: DeltaAudioUnit.componentDescription)
            engine.attach(delta)
            deltas[slot.index] = delta
            engine.connect(dry, to: delta, format: format)
            engine.connect(delta, to: sum, fromBus: 0, toBus: 1, format: format)
            applyMix(slot: slot.index)
            upstream = sum
        }
        return upstream
    }

    /// Disconnects the outputs of every insert node, ahead of a rewire. Disconnecting the owner's
    /// source cascades too, but a plugin can keep an output connection of its own.
    public func disconnect(in engine: AVAudioEngine) {
        for slot in slots {
            if let n = slot.node, engine.attachedNodes.contains(n) { engine.disconnectNodeOutput(n) }
        }
        for (_, g) in gains {
            for node in [g.dry, g.wet, g.sum] where engine.attachedNodes.contains(node) {
                engine.disconnectNodeOutput(node)
            }
        }
        for (_, t) in taps {
            for node in [t.input, t.output] where engine.attachedNodes.contains(node) {
                engine.disconnectNodeOutput(node)
            }
        }
    }

    /// Detaches the gain and delta nodes. The plugins stay loaded in their slots.
    public func detachGains(from engine: AVAudioEngine) {
        for (_, g) in gains {
            for node in [g.dry, g.wet, g.sum] where engine.attachedNodes.contains(node) {
                engine.detach(node)
            }
        }
        gains.removeAll()
        for (_, node) in deltas where engine.attachedNodes.contains(node) {
            engine.detach(node)
        }
        deltas.removeAll()
        for (_, t) in taps {
            for node in [t.input, t.output] where engine.attachedNodes.contains(node) { engine.detach(node) }
        }
        taps.removeAll()
        shown.removeAll()
    }

    /// Detaches the plugins' own nodes from the engine, for a full teardown.
    public func detachPlugins(from engine: AVAudioEngine) {
        for slot in slots {
            if let n = slot.node, engine.attachedNodes.contains(n) { engine.detach(n) }
        }
    }

    // MARK: - State

    /// Whether a slot's plugin is instantiated and wired, as opposed to merely chosen.
    public func isLive(_ index: Int) -> Bool {
        slots.indices.contains(index) && slots[index].isLoaded && deltas[index] != nil
    }

    /// Whether a slot's plugin was refused for being too narrow for the width.
    public func isRefused(_ index: Int) -> Bool { refused.contains(index) }

    /// Each loaded slot's health check (`PluginSlot.probe`). About once a second, main thread.
    public func probe() { for slot in slots { slot.probe() } }

    // MARK: - Bypass, dry/wet, delta

    /// Bypass is a hard bypass: the wet path is silenced and the dry path carries the signal at
    /// unity, so it does not depend on the plugin honouring `shouldBypassEffect` — several do
    /// not. The plugin is told anyway, so it can stop working while it is out of circuit.
    public func setBypass(slot index: Int, _ bypassed: Bool) {
        guard slots.indices.contains(index) else { return }
        slots[index].bypassed = bypassed
        applyMix(slot: index)
    }

    /// 0 = all dry, 1 = all wet.
    public func setMix(slot index: Int, _ mix: Double) {
        guard slots.indices.contains(index) else { return }
        slots[index].mix = min(1, max(0, mix))
        applyMix(slot: index)
    }

    private func applyMix(slot index: Int) {
        guard let gains = gains[index], slots.indices.contains(index) else { return }
        let slot = slots[index]
        let delta = deltas[index]?.auAudioUnit as? DeltaAudioUnit
        // Whole samples. A plugin reporting a fractional latency is already telling us the
        // alignment will be imperfect, and interpolating would only hide that.
        let latencyFrames = Int((slot.latencySeconds * sampleRate).rounded())

        // Delta is a unity comparison whatever the dry/wet knob says — `wet − dry`, both legs
        // at full. Reaper's delta solo is independent of its wet/dry for the same reason: a
        // difference taken across a partial blend is a different signal, and not one anybody
        // asks for. The knob is untouched and comes back when delta is released.
        if deltaSlot == index, !slot.bypassed {
            delta?.engageDelta(delayFrames: latencyFrames)
            gains.wet.outputVolume = 1
            gains.dry.outputVolume = 1
            return
        }

        // Otherwise the same delay line aligns the dry leg without inverting it, which is what
        // stops a partial blend comb-filtering. Applied at
        // **every** blend rather than only partial ones, so moving the knob does not move the
        // timing under you: A/B at any position is like for like. BYP remains the way to hear
        // the path with no insert latency in it at all.
        if !slot.bypassed, latencyFrames > 0 {
            delta?.compensate(delayFrames: latencyFrames)
        } else {
            delta?.disengage()
        }

        let wet = slot.bypassed ? 0 : Float(slot.mix)
        gains.wet.outputVolume = wet
        gains.dry.outputVolume = 1 - wet
    }

    /// Carries the difference this insert is making: `wet − dry`, with the dry leg delayed to
    /// match whatever latency the plugin reports.
    ///
    /// Returns the compensation actually applied, in frames, so the caller can say whether the
    /// null is trustworthy: a plugin that under-reports its latency — or reports none while
    /// having some — will comb-filter rather than null, and there is no way to detect that from
    /// here. Bypassed and empty slots refuse, because the difference a plugin out of circuit is
    /// making is nothing.
    @discardableResult
    public func setDelta(slot index: Int, _ on: Bool) -> Int? {
        guard slots.indices.contains(index) else { return nil }

        // One at a time.
        if on, let previous = deltaSlot, previous != index {
            (deltas[previous]?.auAudioUnit as? DeltaAudioUnit)?.disengage()
            deltaSlot = nil
            applyMix(slot: previous)
        }

        guard on else {
            guard deltaSlot == index else { return nil }
            (deltas[index]?.auAudioUnit as? DeltaAudioUnit)?.disengage()
            deltaSlot = nil
            applyMix(slot: index)
            return nil
        }

        guard deltas[index]?.auAudioUnit is DeltaAudioUnit,
              slots[index].isLoaded, !slots[index].bypassed else { return nil }

        let frames = Int((slots[index].latencySeconds * sampleRate).rounded())
        deltaSlot = index
        applyMix(slot: index)
        return frames
    }

    // MARK: - Diagnostics

    /// The chain as it is actually wired, one part per slot, for the self-tests. The parallel
    /// dry path around each insert is invisible from the outside, so this is how it gets verified.
    private func levelsText(_ index: Int) -> String {
        guard let t = taps[index],
              let i = t.input.auAudioUnit as? LevelTapAudioUnit,
              let o = t.output.auAudioUnit as? LevelTapAudioUnit else { return "" }
        func db(_ v: Float) -> String { v > 0.00001 ? String(format: "%.0f", 20 * log10(v)) : "−∞" }
        return ", in \(db(i.peak[0])) → out \(db(o.peak[0])) dBFS"
    }

    public func summary(channels: Int) -> [String] {
        var parts: [String] = []
        for slot in slots {
            if refused.contains(slot.index) {
                parts.append("[\(slot.displayName): OUT — cannot take \(channels) ch]")
                continue
            }
            guard slot.node != nil, let gains = gains[slot.index] else { continue }
            let wet = Int((gains.wet.outputVolume * 100).rounded())
            let dry = Int((gains.dry.outputVolume * 100).rounded())
            if deltaSlot == slot.index,
               let unit = deltas[slot.index]?.auAudioUnit as? DeltaAudioUnit, unit.isEngaged {
                let ms = slot.latencySeconds * 1000
                parts.append(String(format: "[%@: DELTA wet − dry, dry delayed %.1f ms]",
                                    slot.displayName, ms))
            } else {
                let ms = slot.latencySeconds * 1000
                let aligned = !slot.bypassed && ms > 0
                    ? String(format: ", dry aligned %.1f ms", ms) : ""
                let host = (slot.outOfProcess ? ", own process" : ", in-process")
                    + levelsText(slot.index)
                parts.append("[\(slot.displayName): wet \(wet) % ∥ dry \(dry) %\(aligned)\(host)]")
            }
        }
        return parts
    }
}
