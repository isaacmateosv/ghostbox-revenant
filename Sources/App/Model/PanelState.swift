// The panel's state: defaults, what is saved, and the vocabulary shared with the panel UI (Sources/UI/js/store.js).

import Foundation

/// The two stereo mixes of the hardware mixer.
enum Bus: String, CaseIterable {
    case analog  // Out 1/2 and headphones
    case spdif   // Out 3/4 (S/PDIF out)

    /// First hardware output of the pair (L; R is the next one).
    var firstOutput: Int { self == .analog ? 0 : 2 }
}

enum PanelState {
    /// Live device information: never saved, never restored.
    static let runtimeKeys: Set<String> = ["connected", "streaming", "firmware", "package", "tuner", "meters", "clips", "coreaudio"]

    static let sampleRates = [44100, 48000, 88200, 96000]
    static let multiButtonActions = ["None", "Toggle Dim", "Toggle Mono", "Play/Pause", "Space Bar", "Record (R key)", "Forward to DAW (MIDI)"]
    static let layouts = ["horizontal", "horizontal_meters", "vertical", "vertical_meters"]
    static let latencyModes = ["safe", "balanced", "low"]

    /// Long-press time in ms <-> the hardware's code (MBOX_HOLD_*)
    static let holdCodes: [Int: UInt8] = [250: 0x03, 500: 0x05, 750: 0x08, 1000: 0x0a]
    static let holdMs: [Int16: Int] = [0x03: 250, 0x05: 500, 0x08: 750, 0x0a: 1000]

    static func defaultMix(spdif: Bool) -> [String: Any] {
        func ch(_ label: String, _ fader: Int, _ pan: Int) -> [String: Any] {
            ["label": label, "fader": fader, "pan": pan, "mute": false, "solo": false]
        }
        return [
            "hw": [ch("Input 1 (Mic/DI)", 0, -50), ch("Input 2 (Mic/DI)", 0, 50), ch("S/PDIF In L", 0, -50), ch("S/PDIF In R", 0, 50)],
            "sw": [ch("DAW Ret 1", spdif ? 0 : 85, -50), ch("DAW Ret 2", spdif ? 0 : 85, 50),
                   ch("DAW Ret 3", spdif ? 85 : 0, -50), ch("DAW Ret 4", spdif ? 85 : 0, 50)],
            "links": ["hw12": true, "hw34": true, "sw12": true, "sw34": true, "fxret": true, "master": true],
            "fx_ret": ["l": 0, "r": 0, "mute_l": false, "mute_r": false, "solo_l": false, "solo_r": false],
            "master": ["fader": 85, "balance": 0, "width": 100, "mute_l": false, "mute_r": false, "swap": false],
        ]
    }

    static func makeDefault(version: String) -> NSMutableDictionary {
        let s: [String: Any] = [
            "connected": false, "streaming": false, "firmware": "-", "package": version, "coreaudio": false,
            "layout": "horizontal", "active_mix": "analog", "tuner": false, "mono": false, "dim": false,
            "ui": ["fit": false, "tools_open": true, "tools_tab": "hardware"],
            "setup": ["clock_source": "internal", "sample_rate": 48000, "hold_duration": 500,
                      "dim_leds_off_state": false, "hold_clip_indicators": true, "load_latency_clock": false,
                      "meter_mode": "post", "fx_send_mode": "post", "latency_mode": "safe"],
            "multi_button": ["press_release": "None", "press_hold": "None", "hold_duration": 500,
                             "last_triggered": "None", "trigger": "", "learning": false],
            "fx_sends": ["hw": [0, 0, 0, 0], "sw": [0, 0, 0, 0]],
            "dsp": ["effect": 0, "duration": 50, "feedback": 40, "volume": 0],
            "mixes": ["analog": defaultMix(spdif: false), "spdif": defaultMix(spdif: true)],
            "clips": ["hw": [false, false, false, false], "sw": [false, false, false, false],
                      "out12": [false, false], "out34": [false, false], "fx": [false, false]],
            "meters": ["hw": [0.0, 0.0, 0.0, 0.0], "sw": [0.0, 0.0, 0.0, 0.0], "fx": [0.0, 0.0],
                       "out12": [0.0, 0.0], "out34": [0.0, 0.0]],
        ]
        return StateTree.deepCopy(s)
    }

    /// The state without runtime keys, for the state file and presets.
    static func persistable(_ state: NSDictionary) -> NSMutableDictionary {
        let out = NSMutableDictionary()
        for (k, v) in state { if let key = k as? String, !runtimeKeys.contains(key) { out[key] = v } }
        return out
    }

    /// Restores a saved session over `state` (defaults), ignoring runtime keys and unknown keys.
    static func restore(_ saved: NSMutableDictionary, into state: NSMutableDictionary) {
        for key in runtimeKeys { saved.removeObject(forKey: key) }
        StateTree.merge(saved, into: state)
        migrate(state)
    }

    /// Values saved by older versions (the Python panel offered Pro Tools commands for the Multi button).
    static func migrate(_ state: NSMutableDictionary) {
        let mb = state.dict("multi_button")
        let action = mb.str("press_release")
        if !multiButtonActions.contains(action) {
            mb["press_release"] = action.contains("Record") ? "Record (R key)" : action.contains("Play") ? "Play/Pause" : "None"
        }
        if !layouts.contains(state.str("layout")) { state["layout"] = "horizontal" }
    }
}
