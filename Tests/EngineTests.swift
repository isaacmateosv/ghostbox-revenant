// Tests for the engine (Sources/App/Core) against a fake Mbox and a fake Core Audio driver: attach and restore,
// actions, front-panel following, device loss, clock and latency routing, saving, presets. Nothing touches the
// real Mbox or the Mac's audio settings. Run with ./build.sh test.

import Foundation

final class FakeMbox: MboxControl {
    var present = true
    var isOpen = false
    var secondsSinceWrite: TimeInterval = 10
    let firmware = "1.08 (0x0108)"
    var regs = MboxRegs(llm: 0, mono: 0, dim: 0, tuner: 0, ledDim: 0, hold: 5)
    var meters: [UInt16]? = Array(repeating: 0, count: 15)
    var clock = ClockStatus(spdif: false, rate: 48000, spdifLocked: false)

    var levels: [Crosspoint] = []          // every crosspoint written, in order
    var sends: [([Double], [Double])] = []
    var effects: [EffectSettings] = []
    var registers: [(Int, UInt8)] = []
    var clockSources: [Bool] = []
    var internalRates: [Int] = []
    var forgets = 0, closes = 0, replugs = 0

    func open() -> Bool { isOpen = present; return isOpen }
    func close() { isOpen = false; closes += 1 }
    func forgetWrites() { forgets += 1 }
    func write(_ crosspoints: [Crosspoint]) { levels += crosspoints }
    func writeFxSends(software: [Double], hardware: [Double]) { sends.append((software, hardware)) }
    func writeEffect(_ effect: EffectSettings) { effects.append(effect) }
    func writeRegister(_ reg: Int, _ value: UInt8) { registers.append((reg, value)) }
    func readRegisters() -> MboxRegs? { regs }
    func readMeters() -> [UInt16]? { meters }
    func clockStatus() -> ClockStatus? { clock }
    func setClockSource(spdif: Bool) { clockSources.append(spdif) }
    func setInternalRate(_ rate: Int) { internalRates.append(rate) }
    func reenumerate() { replugs += 1 }

    /// The latest level written for a crosspoint.
    func level(_ source: MixSource, _ output: Int) -> Double? { levels.last { $0.source == source && $0.output == output }?.level }
    func lastRegister<T: BinaryInteger>(_ reg: T) -> UInt8? { registers.last { $0.0 == Int(reg) }?.1 }
}

final class FakeDriver: AudioDriverControl {
    var isActive = true
    var installedVersion: String? = "1.0.0"
    var mode: LatencyMode? = .safe
    var rates: [Double] = []
    var modesSet: [LatencyMode] = []

    func latencyMode() -> LatencyMode? { mode }
    func setLatencyMode(_ m: LatencyMode) { modesSet.append(m); if mode != nil { mode = m } }
    func setSampleRate(_ rate: Double) -> Bool { rates.append(rate); return true }
}

var checks = 0, failures = 0

func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    checks += 1
    if !condition() { failures += 1; print("  FAIL EngineTests.swift:\(line)  \(message)") }
}

func test(_ name: String, _ body: () -> Void) {
    let before = failures
    body()
    print("\(failures == before ? "ok  " : "FAIL") \(name)")
}

struct Rig {
    let dir: URL
    let mbox = FakeMbox()
    let driver = FakeDriver()
    let engine: Engine

    init(saved: [String: Any]? = nil) {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mbox3-engine-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let saved { try? StateTree.json(saved).write(to: dir.appendingPathComponent("last_state.json")) }
        engine = Engine(store: StateStore(directory: dir), hardware: mbox, driver: driver)
    }

    func poll(_ n: Int = 1) { for _ in 0..<n { engine.poll() } }
    func act(_ body: [String: Any]) { engine.handle(action: body as NSDictionary) }
    var state: NSMutableDictionary { engine.state }
    func cleanUp() { try? FileManager.default.removeItem(at: dir) }
}

@main
enum EngineTests {
    static func main() {
        test("attach pushes the saved mix") {
            var saved = PanelState.makeDefault(version: "test") as! [String: Any]
            var mixes = saved["mixes"] as! [String: Any], analog = mixes["analog"] as! [String: Any]
            var hw = analog["hw"] as! [[String: Any]]
            hw[0]["fader"] = 85; hw[0]["pan"] = 0
            analog["hw"] = hw; mixes["analog"] = analog; saved["mixes"] = mixes
            let rig = Rig(saved: saved)
            rig.poll()
            expect(rig.mbox.isOpen && rig.state.bool("connected"), "connected after the first poll")
            expect(rig.state.str("firmware") == "1.08 (0x0108)", "firmware recorded")
            expect(rig.mbox.forgets >= 1, "a full sync forgets the write cache")
            expect(rig.mbox.levels.count == 36, "both mixes written (18 crosspoints each), got \(rig.mbox.levels.count)")
            expect(rig.mbox.level(.hardware(0), 0) == 100 && rig.mbox.level(.hardware(0), 1) == 100, "saved Input 1 level restored")
            expect(rig.mbox.lastRegister(MBOX_REG_LLM) == 0, "Low Latency Monitoring kept off")
            expect(rig.mbox.lastRegister(MBOX_REG_TUNER) == 0, "tuner off after attach")
            expect(rig.mbox.clockSources == [false], "internal clock selected")
            expect(rig.mbox.internalRates.isEmpty && rig.driver.rates.isEmpty, "the saved rate is not pushed at startup")
            rig.cleanUp()
        }

        test("channel moves reach the crosspoints, links included") {
            let rig = Rig()
            rig.poll()
            let ch: NSMutableDictionary = ["label": "Ret 3", "fader": 42.5, "pan": -50, "mute": false, "solo": false]
            rig.act(["action": "update_channel", "bus": "analog", "kind": "sw", "idx": 2, "ch": ch, "sibling_val": 42.5])
            expect(rig.mbox.level(.software(2), 0) == 50 && rig.mbox.level(.software(2), 1) == 0, "Return 3 at half level, panned left")
            expect(rig.mbox.level(.software(3), 1) == 50, "linked Return 4 follows")
            expect(rig.state.dict("mixes").dict("analog").array("sw").dicts[3].num("fader") == 42.5, "sibling value kept exactly")
            rig.act(["action": "update_channel", "bus": "spdif", "kind": "hw", "idx": 0,
                     "ch": ["label": "In 1", "fader": 85, "pan": 0, "mute": false, "solo": false] as NSMutableDictionary])
            expect(rig.mbox.level(.hardware(0), 2) == 100 && rig.mbox.level(.hardware(0), 3) == 100, "the S/PDIF mix writes outputs 3/4")
            rig.cleanUp()
        }

        test("clear solos, dim and mono") {
            let rig = Rig()
            rig.poll()
            rig.state.dict("mixes").dict("analog").array("hw").dicts[0]["solo"] = true
            rig.state.dict("mixes").dict("spdif").dict("fx_ret")["solo_l"] = true
            expect(rig.engine.hasSolo, "solo detected")
            rig.act(["action": "clear_solos"])
            expect(!rig.engine.hasSolo, "every solo cleared")
            rig.act(["action": "set_global", "feature": "dim", "on": true])
            expect(rig.state.bool("dim") && rig.mbox.lastRegister(MBOX_REG_DIM) == 1, "dim on")
            rig.act(["action": "set_global", "feature": "dim", "on": true])
            expect(rig.state.bool("dim"), "set_global is idempotent")
            rig.act(["action": "toggle_global", "feature": "mono"])
            expect(rig.state.bool("mono") && rig.mbox.lastRegister(MBOX_REG_MONO) == 1, "mono toggled")
            rig.cleanUp()
        }

        test("front-panel buttons are followed") {
            let rig = Rig()
            rig.poll()
            rig.engine.store.saveNow(rig.state)
            let rev = rig.engine.revision
            rig.mbox.regs.tuner = 1
            rig.poll(12)
            expect(rig.state.bool("tuner"), "tuner mode from Dim + Mono")
            expect(rig.engine.revision > rev, "revision bumped so the panel refetches")
            expect(!rig.engine.store.hasUnsavedChanges, "tuner state is not saved")
            rig.mbox.regs.mono = 1
            rig.poll(9)
            expect(rig.state.bool("mono") && rig.engine.store.hasUnsavedChanges, "mono from the front panel, saved")
            rig.mbox.secondsSinceWrite = 0.2
            rig.mbox.regs.mono = 0
            rig.poll(9)
            expect(rig.state.bool("mono"), "registers are not read right after a write")
            rig.cleanUp()
        }

        test("device loss and return") {
            let rig = Rig()
            rig.poll()
            _ = rig.engine.metersJSON()  // a panel is watching: meters every poll
            rig.mbox.meters = nil
            rig.poll(3)
            expect(!rig.mbox.isOpen && rig.mbox.closes == 1, "closed after three failed reads")
            expect(!rig.state.bool("connected"), "shown as disconnected")
            rig.mbox.meters = Array(repeating: 0, count: 15)
            let before = rig.mbox.levels.count
            rig.poll(18)
            expect(rig.mbox.isOpen && rig.state.bool("connected"), "reattached")
            expect(rig.mbox.levels.count == before + 36, "mix pushed again on reattach")
            rig.cleanUp()
        }

        test("clock and latency go through the right owner") {
            let rig = Rig()
            rig.poll()
            rig.act(["action": "update_setup", "setup": ["sample_rate": 96000] as NSDictionary])
            expect(rig.driver.rates == [96000] && rig.mbox.internalRates.isEmpty, "with the driver, Core Audio sets the rate")
            rig.driver.isActive = false
            rig.act(["action": "update_setup", "setup": ["sample_rate": 44100] as NSDictionary])
            expect(rig.mbox.internalRates == [44100], "without the driver, the hardware clock is set directly")
            rig.act(["action": "update_setup", "setup": ["latency_mode": "low"] as NSDictionary])
            expect(rig.driver.modesSet == [.low], "latency mode handed to the driver")
            rig.mbox.clock = ClockStatus(spdif: false, rate: 88200, spdifLocked: false)
            rig.engine.store.saveNow(rig.state)
            rig.poll(18)
            expect(rig.engine.setup.num("sample_rate") == 88200, "a rate set from a DAW is followed")
            expect(!rig.engine.store.hasUnsavedChanges, "observed rates are not saved")
            rig.cleanUp()
        }

        test("a newly installed driver gets the saved latency") {
            var saved = PanelState.makeDefault(version: "test") as! [String: Any]
            var setup = saved["setup"] as! [String: Any]
            setup["latency_mode"] = "balanced"
            saved["setup"] = setup
            let rig = Rig(saved: saved)
            rig.driver.mode = nil  // an older driver without latency modes
            rig.poll(2)
            expect(rig.driver.modesSet.isEmpty, "nothing to set on the old driver")
            rig.driver.mode = .safe  // the new driver arrives (fresh install starts in Safe)
            rig.poll(18)
            expect(rig.driver.modesSet == [.balanced], "the saved mode is applied once")
            rig.cleanUp()
        }

        test("saving, presets and defaults") {
            let rig = Rig()
            rig.poll()
            rig.act(["action": "update_master", "bus": "analog",
                     "master": ["fader": 60, "balance": 0, "width": 100, "mute_l": false, "mute_r": false, "swap": false] as NSMutableDictionary])
            expect(rig.engine.store.hasUnsavedChanges, "a change marks the session dirty")
            expect(rig.engine.savePreset("Test"), "preset saved")
            rig.act(["action": "reset_defaults"])
            expect(rig.engine.mix(.analog).dict("master").num("fader") == 85, "defaults restored")
            expect(rig.engine.loadPreset("Test") && rig.engine.mix(.analog).dict("master").num("fader") == 60, "preset loaded")
            expect(rig.engine.presetNames() == ["Test"] && rig.engine.deletePreset("Test") && rig.engine.presetNames().isEmpty, "preset deleted")
            rig.engine.shutdown()
            let file = StateTree.parse((try? Data(contentsOf: rig.dir.appendingPathComponent("last_state.json"))) ?? Data())
            expect(file?.dict("mixes").dict("analog").dict("master").num("fader") == 60, "session saved on quit")
            expect(file.map { d in PanelState.runtimeKeys.allSatisfy { d[$0] == nil } } ?? false, "no runtime keys in the file")
            rig.cleanUp()
        }

        print("engine tests: \(checks) checks, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
