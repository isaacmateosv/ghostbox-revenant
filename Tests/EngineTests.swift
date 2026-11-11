// Tests for the engine (Sources/App/Core) against a fake Mbox and a fake Core Audio driver: attach and restore,
// actions, front-panel following, device loss, clock and latency routing, saving, presets. Nothing touches the
// real Mbox or the Mac's audio settings. Run with ./build.sh test.

import CryptoKit
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
    func setClockSource(spdif: Bool) {
        clockSources.append(spdif)
        clock = ClockStatus(spdif: spdif, rate: clock.rate, spdifLocked: clock.spdifLocked)
    }
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

/// GitHub for the update checker: replies by URL, nothing reaches the network.
final class FakeTransport: UpdateTransport {
    var replies: [String: Data] = [:]
    var files: [String: Data] = [:]
    var requests: [String] = []

    func fetch(_ url: URL, completion: @escaping (Result<Data, Error>) -> Void) {
        requests.append(url.absoluteString)
        completion(replies[url.absoluteString].map { .success($0) } ?? .failure(UpdateError("offline")))
    }

    func download(_ url: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        requests.append(url.absoluteString)
        guard let data = files[url.absoluteString] else { return completion(.failure(UpdateError("offline"))) }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ghostbox-fake-\(UUID().uuidString).pkg")
        try? data.write(to: tmp)
        completion(.success(tmp))
    }
}

let releasesURL = Releases.listURL.absoluteString
let download = "https://github.com/isaacmateosv/ghostbox-revenant/releases/download"
let updateFixture = """
[{"tag_name": "v1.1.0-rc.1", "draft": false, "prerelease": true, "html_url": "https://github.com/isaacmateosv/ghostbox-revenant/releases/tag/v1.1.0-rc.1",
  "assets": [{"name": "GhostBoxRevenant-1.1.0.pkg", "size": 13, "browser_download_url": "\(download)/v1.1.0-rc.1/GhostBoxRevenant-1.1.0.pkg"},
             {"name": "SHA256SUMS.txt", "size": 100, "browser_download_url": "\(download)/v1.1.0-rc.1/SHA256SUMS.txt"}]},
 {"tag_name": "v1.0.0", "draft": false, "prerelease": false, "html_url": "https://github.com/isaacmateosv/ghostbox-revenant/releases/tag/v1.0.0",
  "assets": [{"name": "GhostBoxRevenant-1.0.0.pkg", "size": 13, "browser_download_url": "\(download)/v1.0.0/GhostBoxRevenant-1.0.0.pkg"},
             {"name": "SHA256SUMS.txt", "size": 100, "browser_download_url": "\(download)/v1.0.0/SHA256SUMS.txt"}]}]
"""

final class UpdateRig {
    let dir: URL
    let transport = FakeTransport()
    let checker: UpdateChecker
    var settings: (autoCheck: Bool, prereleases: String) = (true, "auto")
    var infos: [[String: Any]] = []
    var opened: [URL] = []

    init(current: String, dir existing: URL? = nil) {
        dir = existing ?? FileManager.default.temporaryDirectory.appendingPathComponent("ghostbox-update-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        checker = UpdateChecker(currentVersion: current, transport: transport, stateFile: dir.appendingPathComponent("update_check.json"),
                                downloads: dir.appendingPathComponent("updates"))
        checker.settings = { [unowned self] in self.settings }
        checker.onChange = { [unowned self] in self.infos.append($0) }
        checker.open = { [unowned self] in self.opened.append($0) }
    }

    var last: [String: Any] { infos.last ?? [:] }
    var phase: String { last["state"] as? String ?? "" }
    func run(_ work: (UpdateChecker) -> Void) { work(checker); checker.waitUntilIdle() }
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
            expect(rig.mbox.clockSources.isEmpty, "the clock selector is not rewritten when it already matches")
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

        test("the clock selector is written only when it changes") {
            let rig = Rig()
            rig.mbox.clock = ClockStatus(spdif: true, rate: 48000, spdifLocked: false)  // powered up on S/PDIF
            rig.poll()
            expect(rig.mbox.clockSources == [false], "attach switches a Mbox on S/PDIF to the saved internal clock")
            rig.act(["action": "update_setup", "setup": ["sample_rate": 96000] as NSDictionary])
            expect(rig.mbox.clockSources == [false], "a rate change leaves the selector alone (a rewrite silences the stream)")
            rig.act(["action": "update_setup", "setup": ["clock_source": "spdif"] as NSDictionary])
            expect(rig.mbox.clockSources == [false, true], "choosing S/PDIF writes it")
            rig.mbox.close()
            rig.poll(18)
            expect(rig.mbox.clockSources == [false, true], "a re-attach with the selector already right writes nothing")
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

        test("A/B swap, talkback, next preset, clip alerts") {
            let rig = Rig()
            rig.poll()
            func fader() -> Double { rig.engine.mix(.analog).dict("master").num("fader") }
            rig.act(["action": "ab_swap", "bus": "analog"])
            expect(rig.state.dict("ab").dict("analog").str("slot") == "B" && fader() == 85, "first swap: B is a copy, nothing changes")
            rig.act(["action": "update_master", "bus": "analog",
                     "master": ["fader": 50, "balance": 0, "width": 100, "mute_l": false, "mute_r": false, "swap": false] as NSMutableDictionary])
            rig.act(["action": "ab_swap", "bus": "analog"])
            expect(rig.state.dict("ab").dict("analog").str("slot") == "A" && fader() == 85, "back to A")
            rig.act(["action": "ab_swap", "bus": "analog"])
            expect(fader() == 50 && rig.mbox.level(.software(0), 0).map { abs($0 - 50.0 / 85 * 100) < 0.01 } == true, "B again, written to the Mbox")

            rig.act(["action": "set_talkback", "on": true, "bus": "analog"])
            expect(rig.state.str("talkback") == "analog" && rig.mbox.level(.hardware(0), 0) == rig.mbox.level(.hardware(0), 1), "talkback opens Input 1")
            expect((rig.mbox.level(.hardware(0), 0) ?? 0) > 0, "at a level")
            rig.act(["action": "set_advanced", "settings": ["talkback_input": 1]])
            expect(rig.mbox.level(.hardware(1), 0) ?? 0 > 0 && rig.mbox.level(.hardware(0), 0) == 0, "talkback input moves to Input 2")
            rig.act(["action": "toggle_talkback"])
            expect(rig.state.str("talkback") == "" && rig.mbox.level(.hardware(1), 0) == 0, "closed again")

            rig.act(["action": "next_preset"])
            expect(rig.state.str("last_preset") == "", "no presets: nothing happens")
            _ = rig.engine.savePreset("A one"); _ = rig.engine.savePreset("B two")
            rig.act(["action": "next_preset"])
            expect(rig.state.str("last_preset") == "A one", "first preset")
            rig.act(["action": "next_preset"]); rig.act(["action": "next_preset"])
            expect(rig.state.str("last_preset") == "A one", "wraps around")

            func clipEvent() -> [String: Any] {
                let d = StateTree.parse(rig.engine.metersJSON()) ?? [:]
                return (d.dict("panel")["clip_event"] as? [String: Any]) ?? [:]
            }
            let id0 = clipEvent()["id"] as? Int ?? -1
            rig.mbox.meters?[1] = 32767
            rig.poll(9)
            expect(clipEvent()["id"] as? Int == id0 + 1 && clipEvent()["channels"] as? [String] == ["Input 2"], "a clip raises one alert")
            let session = StateTree.parse(rig.engine.sessionJSON())?.dict("session")
            expect((session?.array("channels").dicts[1].num("clips") ?? 0) == 1, "and lands in the session log")
            rig.act(["action": "clear_session"])
            expect((StateTree.parse(rig.engine.sessionJSON())?.dict("session").array("channels").dicts[1].num("clips") ?? 1) == 0, "cleared")
            rig.act(["action": "set_advanced", "settings": ["clip_alerts": false]])
            rig.mbox.meters?[1] = 0; rig.poll(9); rig.mbox.meters?[1] = 32767; rig.poll(9)
            expect(clipEvent()["id"] as? Int == id0 + 1, "alerts can be turned off")
            rig.cleanUp()
        }

        test("advanced settings never write to the Mbox") {
            let rig = Rig()
            rig.poll()
            func writes() -> [Int] { [rig.mbox.levels.count, rig.mbox.effects.count, rig.mbox.registers.count, rig.mbox.sends.count, rig.mbox.clockSources.count] }
            let before = writes()
            var told = 0
            rig.engine.onAdvancedChanged = { told += 1 }
            rig.act(["action": "set_advanced", "settings": ["update_check": false, "update_prereleases": "on"]])
            expect(!rig.state.dict("advanced").bool("update_check") && rig.state.dict("advanced").str("update_prereleases") == "on", "settings applied")
            expect(told == 1 && rig.engine.store.hasUnsavedChanges, "the update checker is told and the choice is saved")
            expect(writes() == before, "nothing written to the Mbox")
            rig.act(["action": "set_advanced", "settings": ["update_check": "yes", "update_prereleases": "sometimes"]])
            expect(!rig.state.dict("advanced").bool("update_check") && rig.state.dict("advanced").str("update_prereleases") == "on", "invalid values ignored")
            rig.act(["action": "reset_defaults"])
            expect(rig.state.dict("advanced").str("update_prereleases") == "on", "Initialize keeps the app's own options")
            rig.engine.setUpdateInfo(["state": "available", "latest": "1.0.1", "id": 1])
            let json = StateTree.parse(rig.engine.stateJSON())
            expect(json?.dict("info").dict("update").str("latest") == "1.0.1", "info.update reaches the panel")
            rig.cleanUp()
        }

        test("update check: offer, memory, daily limit") {
            let rig = UpdateRig(current: "1.0.0-rc.2")
            rig.transport.replies[releasesURL] = Data(updateFixture.utf8)
            rig.run { $0.check(force: true) }
            expect(rig.infos.contains { $0["state"] as? String == "checking" }, "the panel sees the check running")
            expect(rig.phase == "available" && rig.last["latest"] as? String == "1.1.0-rc.1", "a release candidate is offered its successor")
            expect(rig.last["message"] as? String == "GhostBox Revenant 1.1.0-rc.1 is available." && rig.last["error"] as? Bool == false, "the result is reported")
            rig.settings = (true, "off")
            rig.run { $0.settingsChanged() }
            expect(rig.phase == "available" && rig.last["latest"] as? String == "1.0.0", "Don't offer: the finished release instead")
            expect(rig.transport.requests == [releasesURL], "a settings change uses the list already fetched")
            let again = UpdateRig(current: "1.0.0-rc.2", dir: rig.dir)
            again.run { $0.settingsChanged() }
            expect(again.phase == "available" && again.transport.requests.isEmpty, "the last list is kept, and no automatic check within a day")
            let off = UpdateRig(current: "1.0.0")
            off.settings = (false, "auto")
            off.run { $0.check(force: false) }
            expect(off.transport.requests.isEmpty, "no automatic check when it is turned off")
            off.run { $0.check(force: true) }
            expect(off.transport.requests.count == 1 && off.phase == "error" && off.last["error"] as? Bool == true, "an asked-for check reports the failure")
            off.transport.replies[releasesURL] = Data(updateFixture.utf8)
            off.run { $0.check(force: true) }
            expect(off.phase == "current" && off.last["message"] as? String == "GhostBox Revenant 1.0.0 is up to date.", "up to date")
            rig.cleanUp(); off.cleanUp()
        }

        test("update download is verified before it opens") {
            func rig(package: Data) -> UpdateRig {
                let r = UpdateRig(current: "1.0.0")
                r.settings = (true, "on")
                let genuine = Data("package bytes".utf8)
                let hash = SHA256.hash(data: genuine).map { String(format: "%02x", $0) }.joined()
                r.transport.replies[releasesURL] = Data(updateFixture.utf8)
                r.transport.replies["\(download)/v1.1.0-rc.1/SHA256SUMS.txt"] = Data("\(hash)  GhostBoxRevenant-1.1.0.pkg\n".utf8)
                r.transport.files["\(download)/v1.1.0-rc.1/GhostBoxRevenant-1.1.0.pkg"] = package
                r.run { $0.check(force: true) }
                r.run { $0.download() }
                return r
            }
            let good = rig(package: Data("package bytes".utf8))
            let saved = good.dir.appendingPathComponent("updates/GhostBoxRevenant-1.1.0-rc.1.pkg")
            expect(good.infos.contains { $0["state"] as? String == "downloading" }, "the panel sees the download")
            expect(good.phase == "ready" && good.last["file"] as? String == saved.path, "verified and kept")
            expect(good.opened == [saved] && (try? Data(contentsOf: saved)) == Data("package bytes".utf8), "opened in Installer")
            let bad = rig(package: Data("tampered bytes".utf8))
            expect(bad.opened.isEmpty && bad.phase == "available" && bad.last["error"] as? Bool == true, "a mismatch is refused, the offer stays")
            expect((bad.last["message"] as? String ?? "").contains("does not match"), "and says why")
            expect(!FileManager.default.fileExists(atPath: bad.dir.appendingPathComponent("updates/GhostBoxRevenant-1.1.0-rc.1.pkg").path), "nothing kept")
            good.cleanUp(); bad.cleanUp()
        }

        print("engine tests: \(checks) checks, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
