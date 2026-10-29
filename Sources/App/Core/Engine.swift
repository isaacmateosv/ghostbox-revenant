// Engine: owns the panel state and keeps the Mbox in step with it.
//
// Everything runs on one serial queue; the HTTP API, the menus and the Multi button call in through `perform`.
// Every change bumps `revision`, which the panel polls to notice changes it did not make (menu bar, front panel).
//
//   poll (55 ms)   attach/reattach -> full sync; clock and driver status; front-panel buttons; meters
//   sync           MixLaw computes gains, MboxHardware writes only what changed
//   persistence    StateStore saves 0.75 s after the last change; presets

import Foundation

final class Engine {
    let queue = DispatchQueue(label: "ghostbox.engine", qos: .userInteractive)
    let store: StateStore
    private(set) var state: NSMutableDictionary
    private(set) var revision = 1
    private let hardware: MboxControl
    let driver: AudioDriverControl
    private var meters = MeterProcessor()
    private var timer: DispatchSourceTimer?
    private var tick = 0
    private var synced = false        // saved state pushed to the attached Mbox
    private var failures = 0
    private var lastMeterRequest = Date.distantPast
    private var spdifLocked = false
    private(set) var driverVersion: String?
    private(set) var driverLatency: LatencyMode?   // nil: no driver, or one without latency modes
    private var tunerReading: (reading: TunerDecoder.Reading, time: Date)?
    private var driverJob: [String: Any] = ["state": "idle", "id": 0]  // in-app driver installation
    var midi: MidiMonitor?

    static let pollInterval = DispatchTimeInterval.milliseconds(55)
    /// Without a panel asking for meters, read them only as a heartbeat (device-loss detection).
    static let meterIdleAfter: TimeInterval = 3

    init(store: StateStore, hardware: MboxControl, driver: AudioDriverControl) {
        self.store = store
        self.hardware = hardware
        self.driver = driver
        state = PanelState.makeDefault(version: AppInfo.version)
        if let saved = store.loadLastState() {
            PanelState.restore(saved, into: state)
            NSLog("Mbox3: restored last session from %@", store.stateFile.path)
        }
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: Engine.pollInterval)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    /// Run on the engine queue and wait (HTTP handlers, menu actions).
    func perform<T>(_ work: () -> T) -> T { queue.sync(execute: work) }

    func shutdown() {
        queue.sync {
            if store.hasUnsavedChanges { store.saveNow(state) }
            hardware.close()
        }
    }

    // MARK: - State access

    var setup: NSMutableDictionary { state.dict("setup") }
    var activeBus: Bus { Bus(rawValue: state.str("active_mix")) ?? .analog }
    func mix(_ bus: Bus) -> NSMutableDictionary { state.dict("mixes").dict(bus.rawValue) }
    var isConnected: Bool { state.bool("connected") }

    /// Something changed: the panel refetches the state, the session file is saved soon.
    func changed(persist: Bool = true) {
        revision += 1
        if persist { store.markDirty() }
    }

    // MARK: - Hardware sync

    func syncBus(_ bus: Bus) { hardware.write(MixLaw.crosspoints(for: mix(bus), bus: bus)) }

    func syncFx() {
        let sends = MixLaw.fxSends(state: state)
        hardware.writeFxSends(software: sends.software, hardware: sends.hardware)
        hardware.writeEffect(MixLaw.effect(state.dict("dsp")))
    }

    /// Clock source always; the rate only when the user asked for it (`userRate`) or when no Core Audio driver owns
    /// it. Pushing a saved rate on startup would switch Core Audio under a running DAW.
    func applyClock(userRate: Bool) {
        guard hardware.isOpen else { return }
        let spdif = setup.str("clock_source") == "spdif"
        hardware.setClockSource(spdif: spdif)
        guard !spdif else { return }
        let rate = Int(setup.num("sample_rate"))
        if driver.isActive {
            if userRate { driver.setSampleRate(Double(rate)) }  // the driver programs the hardware itself
        } else {
            hardware.setInternalRate(rate)
        }
    }

    func applyPanelRegisters() {
        hardware.writeRegister(Int(MBOX_REG_LLM), 0)  // LLM is a Pro Tools mode; Avid documents it muting inputs
        hardware.writeRegister(Int(MBOX_REG_LED_DIM), setup.bool("dim_leds_off_state") ? 1 : 0)
        hardware.writeRegister(Int(MBOX_REG_HOLD), PanelState.holdCodes[Int(setup.num("hold_duration"))] ?? UInt8(MBOX_HOLD_500MS))
    }

    func writeGlobal(_ feature: String) {
        let reg = feature == "mono" ? MBOX_REG_MONO : feature == "dim" ? MBOX_REG_DIM : MBOX_REG_TUNER
        hardware.writeRegister(Int(reg), state.bool(feature) ? 1 : 0)
    }

    /// Pushes the whole state to the Mbox, unchanged values included.
    func fullSync() {
        guard hardware.isOpen else { return }
        hardware.forgetWrites()
        applyClock(userRate: false)
        applyPanelRegisters()
        writeGlobal("mono")
        writeGlobal("dim")
        state["tuner"] = false
        writeGlobal("tuner")
        Bus.allCases.forEach(syncBus)
        syncFx()
    }

    /// Software replug of the Mbox (also used after driver installs).
    func reenumerate() { hardware.reenumerate() }

    // MARK: - Polling

    /// One poll (the timer calls it every 55 ms; tests call it directly).
    func poll() {
        tick += 1
        if tick % 18 == 2 { refreshDriverInfo() }
        if !hardware.isOpen, tick % 18 == 1, hardware.open() {
            synced = false
            failures = 0
            NSLog("Mbox3: device attached")
        }
        guard hardware.isOpen else {
            if state.bool("connected") { setDisconnected() }
            store.saveIfDue(state)
            return
        }
        if !synced {
            state["connected"] = true
            state["firmware"] = hardware.firmware
            NSLog("Mbox3: restoring saved mix")
            fullSync()
            synced = true
            changed(persist: false)
        }
        if tick % 18 == 2 { refreshStatus() }
        if tick % 9 == 3, hardware.secondsSinceWrite > 1.0 { followFrontPanel() }
        let watched = Date().timeIntervalSince(lastMeterRequest) < Engine.meterIdleAfter
        if watched || tick % 9 == 0 { readMeters() }
        store.saveIfDue(state)
    }

    private func setDisconnected() {
        state["connected"] = false
        state["streaming"] = false
        changed(persist: false)
    }

    /// Follows the hardware clock (a DAW may change the rate through Core Audio). Observed values are not saved:
    /// only the user's own choices are.
    private func refreshStatus() {
        guard let clock = hardware.clockStatus() else { return }
        let source = clock.spdif ? "spdif" : "internal"
        if PanelState.sampleRates.contains(clock.rate), Int(setup.num("sample_rate")) != clock.rate {
            setup["sample_rate"] = clock.rate
            changed(persist: false)
        }
        if setup.str("clock_source") != source { setup["clock_source"] = source; changed(persist: false) }
        spdifLocked = clock.spdifLocked
    }

    private func refreshDriverInfo() {
        let active = driver.isActive
        if state.bool("coreaudio") != active { state["coreaudio"] = active; changed(persist: false) }
        let version = driver.installedVersion, latency = active ? driver.latencyMode() : nil
        if version != driverVersion || latency != driverLatency {
            let driverAppeared = driverLatency == nil && latency != nil  // app start, or a driver just installed
            driverVersion = version
            driverLatency = latency
            changed(persist: false)
            if driverAppeared { syncDriverLatency() }
        }
    }

    // MARK: - Driver installation (Services/DriverInstaller.swift)

    var isInstallingDriver: Bool { driverJob["state"] as? String == "running" }

    func setDriverJob(_ state: String, message: String = "") {
        driverJob = ["state": state, "message": message, "id": (driverJob["id"] as? Int ?? 0) + 1]
        changed(persist: false)
    }

    /// Follows the front-panel soft buttons (Mono, Dim, Dim+Mono = tuner) and the hold time.
    private func followFrontPanel() {
        guard let regs = hardware.readRegisters(), hardware.secondsSinceWrite > 1.0 else { return }
        for (key, v) in [("mono", regs.mono), ("dim", regs.dim), ("tuner", regs.tuner)] where v >= 0 {
            if state.bool(key) != (v != 0) {
                state[key] = v != 0
                changed(persist: key != "tuner")
            }
        }
        if let ms = PanelState.holdMs[regs.hold], Int(setup.num("hold_duration")) != ms {
            setup["hold_duration"] = ms
            state.dict("multi_button")["hold_duration"] = ms
            changed(persist: false)
        }
    }

    private func readMeters() {
        let raw = hardware.readMeters()
        if raw == nil {
            failures += 1
            if failures >= 3 {
                // Unplugged (or replugged: the old handle is dead). Reopen on the next attach poll.
                NSLog("Mbox3: device lost")
                hardware.close()
                synced = false
                setDisconnected()
                return
            }
        } else {
            failures = 0
        }
        let post = setup.str("meter_mode") == "post"
        let frame = meters.process(raw, gains: post ? MixLaw.meterGains(for: mix(activeBus)) : [:], now: Date())
        state["meters"] = frame.levels
        state["clips"] = frame.clips
        state["streaming"] = (frame.levels["sw"] ?? []).contains { $0 > 0.05 }
    }

    // MARK: - Tuner

    func setTunerReading(_ reading: TunerDecoder.Reading) { tunerReading = (reading, Date()) }

    // MARK: - Snapshots for the API

    /// Runtime facts the panel shows but never saves.
    private func info() -> [String: Any] {
        ["app_version": AppInfo.version, "data_dir": store.directory.path, "spdif_locked": spdifLocked,
         "driver_version": driverVersion ?? NSNull(), "driver_latency": driverLatency?.name ?? NSNull(),
         "bundled_driver_version": DriverInstaller.bundledVersion ?? NSNull(), "driver_job": driverJob,
         "multi_actions": PanelState.multiButtonActions]
    }

    func stateJSON() -> Data { StateTree.json(["ok": true, "state": state, "rev": revision, "info": info()]) }

    func metersJSON() -> Data {
        lastMeterRequest = Date()
        var panel: [String: Any] = ["mono": state.bool("mono"), "dim": state.bool("dim"), "tuner": state.bool("tuner"),
                                    "firmware": state.str("firmware"), "clock_source": setup.str("clock_source"),
                                    "sample_rate": setup.num("sample_rate"), "coreaudio": state.bool("coreaudio"),
                                    "spdif_locked": spdifLocked]
        if let midi { panel["midi_events"] = midi.eventCount }
        if let t = tunerReading, state.bool("tuner"), Date().timeIntervalSince(t.time) < 0.6 {
            panel["tuner_note"] = t.reading.note
            panel["tuner_cents"] = t.reading.cents
        }
        return StateTree.json(["ok": true, "connected": state.bool("connected"), "streaming": state.bool("streaming"),
                               "meters": state["meters"] ?? [:], "clips": state["clips"] ?? [:], "panel": panel, "rev": revision])
    }

    // MARK: - Presets

    func presetNames() -> [String] { store.presetNames() }

    func savePreset(_ name: String) -> Bool { store.savePreset(name, state: state) }

    func deletePreset(_ name: String) -> Bool { store.deletePreset(name) }

    /// Mixes, sends and effect; clock and latency too when Setup says so.
    func loadPreset(_ name: String) -> Bool {
        guard let loaded = store.loadPreset(name) else { return false }
        for key in ["mixes", "fx_sends", "dsp"] { if let v = loaded[key] { state[key] = v } }
        let withClock = setup.bool("load_latency_clock")
        let oldLatency = setup.str("latency_mode")
        if withClock, let s = loaded["setup"] as? NSDictionary {
            for key in ["clock_source", "sample_rate", "latency_mode"] { if let v = s[key] { setup[key] = v } }
        }
        Bus.allCases.forEach(syncBus)
        syncFx()
        if withClock {
            applyClock(userRate: true)
            if setup.str("latency_mode") != oldLatency, let mode = LatencyMode(name: setup.str("latency_mode")) {
                driver.setLatencyMode(mode)
            }
        }
        changed()
        return true
    }

    /// Keeps the driver in step with the saved latency setting (the driver remembers it too; this covers a fresh
    /// driver install or a session restored from another Mac). Runs whenever a driver with latency modes appears.
    func syncDriverLatency() {
        guard let wanted = LatencyMode(name: setup.str("latency_mode")),
              let current = driver.latencyMode(), current != wanted else { return }
        driver.setLatencyMode(wanted)
    }
}
