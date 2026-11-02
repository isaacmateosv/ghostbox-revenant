// Unit tests for the app's pure model layer (Sources/App/Model): mixer law, meters, tuner decoding, state
// persistence rules. No hardware, no AppKit. Run with ./build.sh test.

import Foundation

var checks = 0, failures = 0

func expect(_ condition: @autoclosure () -> Bool, _ message: String, file: String = #file, line: Int = #line) {
    checks += 1
    if !condition() { failures += 1; print("  FAIL \((file as NSString).lastPathComponent):\(line)  \(message)") }
}

func near(_ a: Double, _ b: Double, _ tol: Double = 1e-6) -> Bool { abs(a - b) <= tol }

func test(_ name: String, _ body: () -> Void) {
    let before = failures
    body()
    print("\(failures == before ? "ok  " : "FAIL") \(name)")
}

func defaultState() -> NSMutableDictionary { PanelState.makeDefault(version: "test") }

func gains(_ points: [Crosspoint], _ source: MixSource) -> [Double] {
    points.filter { $0.source == source }.sorted { $0.output < $1.output }.map(\.level)
}

@main
enum AppModelTests {
    static func main() {
        test("fader taper") {
            expect(MixLaw.faderToLevel(85) == 100, "unity at 85")
            expect(MixLaw.faderToLevel(42.5) == 50, "half travel is level 50")
            expect(MixLaw.faderToLevel(100) == 100, "never above unity")
            expect(MixLaw.faderToLevel(-5) == 0, "never below zero")
            expect(near(MixLaw.faderToLevel(11.72), 13.79, 0.01), "fractions survive (fine steps at low levels)")
        }

        test("default analog mix") {
            let s = defaultState()
            let points = MixLaw.crosspoints(for: s.dict("mixes").dict("analog"), bus: .analog)
            expect(points.count == 18, "8 hardware + 8 software + 2 FX return crosspoints, got \(points.count)")
            expect(Set(points.map(\.output)) == [0, 1], "analog mix writes outputs 1/2 only")
            expect(gains(points, .software(0)) == [100, 0], "return 1 hard left at unity")
            expect(gains(points, .software(1)) == [0, 100], "return 2 hard right at unity")
            expect(gains(points, .hardware(0)) == [0, 0], "inputs start muted")
            expect(gains(points, .fxReturn) == [0, 0], "FX return starts muted")
            let spdif = MixLaw.crosspoints(for: s.dict("mixes").dict("spdif"), bus: .spdif)
            expect(Set(spdif.map(\.output)) == [2, 3], "S/PDIF mix writes outputs 3/4 only")
            expect(gains(spdif, .software(2)) == [100, 0], "returns 3/4 feed the S/PDIF mix")
        }

        test("solo, mute, master") {
            let s = defaultState()
            let mix = s.dict("mixes").dict("analog")
            let in1 = mix.array("hw").dicts[0]
            in1["fader"] = 85; in1["pan"] = 0
            expect(gains(MixLaw.crosspoints(for: mix, bus: .analog), .hardware(0)) == [100, 100], "centre pan: both sides at unity")
            in1["solo"] = true
            var points = MixLaw.crosspoints(for: mix, bus: .analog)
            expect(gains(points, .hardware(0)) == [100, 100], "soloed input stays")
            expect(gains(points, .software(0)) == [0, 0], "a solo silences everything else")
            in1["solo"] = false; in1["mute"] = true
            expect(gains(MixLaw.crosspoints(for: mix, bus: .analog), .hardware(0)) == [0, 0], "mute")
            in1["mute"] = false
            let master = mix.dict("master")
            master["swap"] = true
            expect(gains(MixLaw.crosspoints(for: mix, bus: .analog), .software(0)) == [0, 100], "swap L/R")
            master["swap"] = false; master["mute_l"] = true
            points = MixLaw.crosspoints(for: mix, bus: .analog)
            expect(gains(points, .software(0)) == [0, 0] && gains(points, .software(1)) == [0, 100], "master mute L")
            master["mute_l"] = false; master["width"] = 0
            expect(gains(MixLaw.crosspoints(for: mix, bus: .analog), .software(0)) == [100, 100], "width 0 folds pans to centre")
            master["width"] = 100; master["balance"] = 25
            expect(gains(MixLaw.crosspoints(for: mix, bus: .analog), .software(0)) == [50, 0], "balance right halves the left side")
            master["balance"] = 0; master["fader"] = 0
            expect(MixLaw.crosspoints(for: mix, bus: .analog).allSatisfy { $0.level == 0 }, "master down mutes the mix")
        }

        test("meter gains and FX sends") {
            let s = defaultState()
            let mix = s.dict("mixes").dict("analog")
            mix.array("hw").dicts[0]["fader"] = 42.5
            var g = MixLaw.meterGains(for: mix)
            expect(near(g["hw"]![0], 0.5) && near(g["sw"]![0], 1), "post-fader meter follows the fader")
            mix.array("sw").dicts[1]["solo"] = true
            g = MixLaw.meterGains(for: mix)
            expect(g["sw"]![1] == 1 && g["sw"]![0] == 0 && g["hw"]![0] == 0, "solo silences other meters")
            s.dict("fx_sends")["hw"] = [50, 0, 0, 0]
            var sends = MixLaw.fxSends(state: s)
            expect(sends.hardware[0] == 25, "post-fader send scales with the Analog 1/2 fader, got \(sends.hardware[0])")
            s.dict("setup")["fx_send_mode"] = "pre"
            sends = MixLaw.fxSends(state: s)
            expect(sends.hardware[0] == 50, "pre-fader send ignores the fader")
            let dsp = s.dict("dsp")
            dsp["effect"] = 0; dsp["feedback"] = 100; dsp["volume"] = 100; dsp["duration"] = 0
            expect(MixLaw.effect(dsp) == EffectSettings(preset: 0, volume: 255, duration: 0, feedback: 0), "reverbs have no feedback")
            dsp["effect"] = 7
            expect(MixLaw.effect(dsp).feedback == 255, "echo uses feedback")
            let written = EffectSettings(preset: 2, volume: 74, duration: 15073, feedback: 0)
            expect(EffectSettings(preset: 2, volume: 80, duration: 15073, feedback: 0).changes(from: written).map(\.0) == [.volume],
                   "a volume move sends only the volume, never the preset (a re-sent preset silences the Mbox)")
            expect(EffectSettings(preset: 2, volume: 80, duration: 900, feedback: 0).changes(from: written).map(\.0) == [.volume, .duration],
                   "only changed controls are sent")
            expect(written.changes(from: written).isEmpty, "nothing changed, nothing sent")
            expect(EffectSettings(preset: 6, volume: 74, duration: 15073, feedback: 0).changes(from: written).map(\.0) == [.preset],
                   "a new preset is sent")
            expect(written.changes(from: nil).count == 4, "unknown hardware state: everything is sent")
            expect(written.changes(from: .presetOnly(2)).map(\.0) == [.volume, .duration, .feedback],
                   "attach to a running Mbox: the preset it holds is kept, the rest is sent")
            expect(written.changes(from: .presetOnly(5)).map(\.0) == [.preset, .volume, .duration, .feedback],
                   "a different saved preset is sent")
        }

        test("meter ballistics") {
            var m = MeterProcessor()
            var raw = [UInt16](repeating: 0, count: 15)
            raw[0] = 32767
            let t0 = Date()
            var f = m.process(raw, gains: [:], now: t0)
            expect(f.levels["hw"]![0] == 1, "full scale reads 1")
            expect(f.clips["hw"]![0], "full scale clips")
            raw[0] = 0
            f = m.process(raw, gains: [:], now: t0.addingTimeInterval(0.1))
            expect(near(f.levels["hw"]![0], 0.82, 0.001), "release 0.82 per poll")
            expect(f.clips["hw"]![0], "clip held 0.35 s")
            f = m.process(raw, gains: [:], now: t0.addingTimeInterval(0.5))
            expect(!f.clips["hw"]![0], "clip released after 0.35 s")
            expect(near(MeterProcessor.level(32767 / 2), (20 * log10(0.5) + 60) / 60, 0.001), "-6 dBFS")
            raw[13] = 0; raw[12] = 32767
            f = m.process(raw, gains: [:], now: t0)
            expect(f.clips["fx"]![0] && f.clips["fx"]![1], "FX input overload lights both FX clip LEDs")
            f = m.process(nil, gains: [:], now: t0)
            expect(f.levels["sw"]!.allSatisfy { $0 == 0 }, "failed read decays to silence")
        }

        test("hardware tuner messages") {
            expect(TunerDecoder.decode([0xA0, 0, 0]) == .init(note: "A", cents: 0), "A in tune")
            expect(TunerDecoder.decode([0xA0, 3, 0x7F]) == .init(note: "C", cents: -1), "C, 1 cent flat")
            expect(TunerDecoder.decode([0xA0, 64, 100]) == .init(note: "E4", cents: -28), "MIDI note numbers above 11")
            expect(TunerDecoder.decode([0xA0, 0, 60])?.cents == 50, "clamped to +50")
            expect(TunerDecoder.decode([0x90, 60, 100]) == nil, "note-on is not a tuner reading")
            expect(TunerDecoder.decode([0xA0, 0]) == nil, "short message")
        }

        test("state persistence rules") {
            let saved = defaultState()
            saved["connected"] = true; saved["firmware"] = "9.99"; saved["package"] = "1.0.10"; saved["bogus"] = 1
            saved.removeObject(forKey: "ui")  // a session saved before the "ui" settings existed
            saved.dict("setup")["latency_mode"] = "low"
        saved.dict("multi_button")["press_release"] = "Start/Stop Record"  // a Pro Tools command from the Python panel
            let state = defaultState()
            PanelState.restore(saved, into: state)
            expect(state.str("package") == "test", "version is never restored")
            expect(!state.bool("connected") && state.str("firmware") == "-", "runtime keys are never restored")
            expect(state["bogus"] == nil, "unknown keys are ignored")
            expect(state.dict("setup").str("latency_mode") == "low", "saved settings win")
            expect(state.dict("ui")["fit"] != nil, "new keys keep their defaults")
        expect(state.dict("multi_button").str("press_release") == "Record (R key)", "old Multi button actions are migrated")
            let out = PanelState.persistable(state)
            expect(PanelState.runtimeKeys.allSatisfy { out[$0] == nil }, "runtime keys are not saved")
            expect(out["mixes"] != nil && out["setup"] != nil, "settings are saved")
        }
        print("app model tests: \(checks) checks, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
