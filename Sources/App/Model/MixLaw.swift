// The monitor mixer's law: how the panel's faders, pans, mutes, solos and master section become hardware gains.
// Pure functions over the state tree; MboxHardware turns the results into USB requests.

import Foundation

enum MixSource: Hashable {
    case software(Int)  // Software Return 1-4 (DAW playback)
    case hardware(Int)  // Input 1, Input 2, S/PDIF L, S/PDIF R
    case fxReturn       // the effect unit's output
}

/// One mixer crosspoint: `source` into hardware output `output` (0-3) at `level` (0 muted ... 100 unity, fractions
/// allowed; MboxKit turns it into dB with the panel taper).
struct Crosspoint: Hashable {
    let source: MixSource
    let output: Int
    let level: Double
}

struct EffectSettings: Equatable {
    let preset: Int     // 0-5 reverbs, 6 delay, 7 echo
    let volume: Int     // 0-255
    let duration: Int   // 0-65535
    let feedback: Int   // 0-255 (delay and echo only)
}

enum MixLaw {
    /// Fader position of 0 dB. Faders above it stay at unity; the master above it lifts channels below unity.
    static let unityFader = 85.0

    static func faderToLevel(_ fader: Double) -> Double { clampLevel(fader / unityFader * 100.0) }

    private static func clampLevel(_ v: Double) -> Double { max(0, min(100, v)) }
    /// Levels are kept to 0.01 % (well below the hardware's 0.25 dB steps), so equal settings compare equal.
    private static func tidy(_ v: Double) -> Double { (clampLevel(v) * 100).rounded() / 100 }

    private static func anySolo(_ mix: NSMutableDictionary, includeFx: Bool) -> Bool {
        let fx = mix.dict("fx_ret")
        return (mix.array("hw").dicts + mix.array("sw").dicts).contains { $0.bool("solo") } ||
            (includeFx && (fx.bool("solo_l") || fx.bool("solo_r")))
    }

    /// Crosspoints of one stereo mix: fader, pan scaled by width, balance, mutes, solo, master fader/swap/mutes.
    static func crosspoints(for mix: NSMutableDictionary, bus: Bus) -> [Crosspoint] {
        let master = mix.dict("master"), fxr = mix.dict("fx_ret")
        let soloing = anySolo(mix, includeFx: true)
        let masterFader = master.num("fader")
        let mScale = masterFader / unityFader
        let bal = master.num("balance") / 50.0
        let balL = bal <= 0 ? 1.0 : 1.0 - bal, balR = bal >= 0 ? 1.0 : 1.0 + bal
        let width = master.num("width") / 100.0

        func lr(_ fader: Double, _ pan: Double, _ muted: Bool, _ soloed: Bool) -> (Double, Double) {
            if muted || (soloing && !soloed) || fader <= 0 || masterFader <= 0 { return (0, 0) }
            let base = faderToLevel(fader) * mScale
            let p = pan / 50.0 * width
            var l = base * (p <= 0 ? 1.0 : 1.0 - p) * balL
            var r = base * (p >= 0 ? 1.0 : 1.0 + p) * balR
            if master.bool("swap") { swap(&l, &r) }
            if master.bool("mute_l") { l = 0 }
            if master.bool("mute_r") { r = 0 }
            return (tidy(l), tidy(r))
        }

        let outL = bus.firstOutput, outR = bus.firstOutput + 1
        var out: [Crosspoint] = []
        func add(_ source: MixSource, _ gains: (Double, Double)) {
            out.append(Crosspoint(source: source, output: outL, level: gains.0))
            out.append(Crosspoint(source: source, output: outR, level: gains.1))
        }
        for (i, ch) in mix.array("hw").dicts.prefix(4).enumerated() {
            add(.hardware(i), lr(ch.num("fader"), ch.num("pan"), ch.bool("mute"), ch.bool("solo")))
        }
        for (i, ch) in mix.array("sw").dicts.prefix(4).enumerated() {
            add(.software(i), lr(ch.num("fader"), ch.num("pan"), ch.bool("mute"), ch.bool("solo")))
        }
        // The FX return is one stereo source: its L level feeds the left output, its R level the right one
        let fxL = lr(fxr.num("l"), -50, fxr.bool("mute_l"), fxr.bool("solo_l") || !soloing).0
        let fxR = lr(fxr.num("r"), 50, fxr.bool("mute_r"), fxr.bool("solo_r") || !soloing).1
        add(.fxReturn, (fxL, fxR))
        return out
    }

    /// Post-fader meter scaling for the input and return strips of a mix (fader gain, 0 when muted or not soloed).
    static func meterGains(for mix: NSMutableDictionary) -> [String: [Double]] {
        let soloing = anySolo(mix, includeFx: false)
        var gains: [String: [Double]] = [:]
        for kind in ["hw", "sw"] {
            gains[kind] = mix.array(kind).dicts.map { ch in
                let audible = !ch.bool("mute") && (ch.bool("solo") || !soloing)
                return audible ? faderToLevel(ch.num("fader")) / 100.0 : 0
            }
        }
        return gains
    }

    /// FX send levels (0-100). Post-fader sends follow the faders of the Analog 1/2 mix, as on Avid's panel.
    static func fxSends(state: NSMutableDictionary) -> (software: [Double], hardware: [Double]) {
        let sends = state.dict("fx_sends"), mix = state.dict("mixes").dict(Bus.analog.rawValue)
        let post = state.dict("setup").str("fx_send_mode") == "post"
        func levels(_ kind: String) -> [Double] {
            let chans = mix.array(kind).dicts
            return (0..<4).map { i in
                var send = sends.array(kind).num(i)
                if post { send = send * (i < chans.count ? chans[i].num("fader") : 0) / unityFader }
                return tidy(send)
            }
        }
        return (levels("sw"), levels("hw"))
    }

    static func effect(_ dsp: NSMutableDictionary) -> EffectSettings {
        let preset = Int(dsp.num("effect"))
        let echoes = preset == 6 || preset == 7
        return EffectSettings(preset: preset,
                              volume: Int((dsp.num("volume") / 100.0 * 255).rounded()),
                              duration: Int((dsp.num("duration") / 100.0 * 65535).rounded()),
                              feedback: echoes ? Int((dsp.num("feedback") / 100.0 * 255).rounded()) : 0)
    }
}
