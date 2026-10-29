// The actions the panel UI posts to /api/state (and the menus and Multi button reuse). Engine queue only.

import Foundation

extension Engine {
    func handle(action body: NSDictionary) {
        let act = body["action"] as? String ?? ""
        let bus = (body["bus"] as? String).flatMap(Bus.init(rawValue:)) ?? activeBus
        let mix = self.mix(bus)
        switch act {
        case "update_channel":
            guard let kind = body["kind"] as? String, kind == "hw" || kind == "sw", let idx = (body["idx"] as? NSNumber)?.intValue,
                  let ch = body["ch"] as? NSMutableDictionary, idx >= 0, mix.array(kind).count > idx else { return }
            let chans = mix.array(kind)
            chans[idx] = ch
            if let sib = body["sibling_val"] as? NSNumber {
                let s = idx % 2 == 0 ? idx + 1 : idx - 1
                if s < chans.count { chans.dicts[s]["fader"] = sib }
            }
            syncBus(bus)
            if setup.str("fx_send_mode") == "post" { syncFx() }
        case "update_channel_pair":
            guard let kind = body["kind"] as? String, kind == "hw" || kind == "sw", let chans = body["channels"] as? NSMutableArray else { return }
            mix[kind] = chans
            syncBus(bus)
        case "update_links":
            guard let links = body["links"] as? NSMutableDictionary else { return }
            mix["links"] = links
        case "update_fx_sends":
            guard let sends = body["fx_sends"] as? NSMutableDictionary else { return }
            state["fx_sends"] = sends
            syncFx()
        case "update_fx_ret":
            guard let fx = body["fx_ret"] as? NSMutableDictionary else { return }
            mix["fx_ret"] = fx
            syncBus(bus)
        case "update_dsp":
            guard let dsp = body["dsp"] as? NSMutableDictionary else { return }
            state["dsp"] = dsp
            syncFx()
        case "update_master":
            guard let master = body["master"] as? NSMutableDictionary else { return }
            mix["master"] = master
            syncBus(bus)
        case "switch_bus":
            state["active_mix"] = bus.rawValue
        case "copy_mix":
            guard let from = (body["from"] as? String).flatMap(Bus.init(rawValue:)),
                  let to = (body["to"] as? String).flatMap(Bus.init(rawValue:)), from != to else { return }
            state.dict("mixes")[to.rawValue] = StateTree.deepCopy(self.mix(from))
            syncBus(to)
        case "clear_solos":
            clearSolos()
        case "set_layout":
            guard let layout = body["layout"] as? String, PanelState.layouts.contains(layout) else { return }
            state["layout"] = layout
        case "update_ui":
            guard let ui = body["ui"] as? NSDictionary else { return }
            for (k, v) in ui { if let key = k as? String { state.dict("ui")[key] = v } }
        case "toggle_global":
            guard let feature = body["feature"] as? String, feature == "mono" || feature == "dim" else { return }
            state[feature] = !state.bool(feature)
            writeGlobal(feature)
        case "set_global":
            guard let feature = body["feature"] as? String, feature == "mono" || feature == "dim",
                  let on = (body["on"] as? NSNumber)?.boolValue else { return }
            state[feature] = on
            writeGlobal(feature)
        case "set_tuner":
            state["tuner"] = (body["tuner"] as? NSNumber)?.boolValue ?? false
            writeGlobal("tuner")
            changed(persist: false)
            return
        case "update_setup":
            guard let s = body["setup"] as? NSDictionary else { return }
            updateSetup(s)
        case "update_multi_cfg":
            let mb = state.dict("multi_button")
            for key in ["press_release", "press_hold"] { if let v = body[key] { mb[key] = v } }
        case "midi_learn":
            state.dict("multi_button")["learning"] = true
        case "midi_forget":
            state.dict("multi_button")["trigger"] = ""
            state.dict("multi_button")["learning"] = false
        case "reset_defaults":
            resetToDefaults()
        default:
            return
        }
        changed()
    }

    private func updateSetup(_ s: NSDictionary) {
        let oldLatency = setup.str("latency_mode")
        let oldRate = setup.num("sample_rate"), oldSource = setup.str("clock_source")
        for (k, v) in s { if let key = k as? String { setup[key] = v } }
        if setup.num("sample_rate") != oldRate || setup.str("clock_source") != oldSource { applyClock(userRate: true) }
        applyPanelRegisters()
        syncFx()
        if setup.str("latency_mode") != oldLatency, let mode = LatencyMode(name: setup.str("latency_mode")) {
            driver.setLatencyMode(mode)
        }
    }

    /// Clears every solo in both mixes (a forgotten solo silences everything else).
    func clearSolos() {
        for bus in Bus.allCases {
            let mix = self.mix(bus)
            for kind in ["hw", "sw"] { for ch in mix.array(kind).dicts { ch["solo"] = false } }
            mix.dict("fx_ret")["solo_l"] = false
            mix.dict("fx_ret")["solo_r"] = false
            syncBus(bus)
        }
    }

    private func resetToDefaults() {
        let fresh = PanelState.makeDefault(version: AppInfo.version)
        for (k, v) in fresh { if let key = k as? String, !PanelState.runtimeKeys.contains(key) { state[key] = v } }
        fullSync()
    }

    var hasSolo: Bool {
        Bus.allCases.contains { bus in
            let mix = self.mix(bus), fx = mix.dict("fx_ret")
            return (mix.array("hw").dicts + mix.array("sw").dicts).contains { $0.bool("solo") } || fx.bool("solo_l") || fx.bool("solo_r")
        }
    }
}
