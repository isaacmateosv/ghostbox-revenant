// Swift face of MboxKit for the engine. Owns the device handle and remembers the gain it last wrote to each
// crosspoint, so a sync after a fader move sends only what changed (2-4 requests instead of 18). Engine queue only.

import Foundation

final class MboxHardware: MboxControl {
    private var dev: OpaquePointer?  // MboxDevice*
    private var mixWritten: [UInt32: UInt16] = [:]  // (unit << 16 | control) -> hardware gain word
    private var effectWritten: EffectSettings?
    private(set) var lastWrite = Date.distantPast

    var isOpen: Bool { dev != nil }
    var secondsSinceWrite: TimeInterval { Date().timeIntervalSince(lastWrite) }

    private static func ok(_ r: Int32) -> Bool { r == Int32(MBOX_OK) }

    // MARK: - Lifetime

    func open() -> Bool {
        dev = mbox_open()
        forgetWrites()
        return dev != nil
    }

    func close() {
        if let dev { mbox_close(dev) }
        dev = nil
        forgetWrites()
    }

    /// The next writes go out even if unchanged (attach, defaults, or anything that may have changed the hardware).
    func forgetWrites() {
        mixWritten.removeAll()
        effectWritten = nil
    }

    var firmware: String {
        guard let dev else { return "-" }
        let bcd = Int(mbox_info(dev).bcdDevice)
        return String(format: "%d.%02x (0x%04x)", bcd >> 8, bcd & 0xff, bcd)
    }

    // MARK: - Mixer and effect

    private func setMix(unit: UInt16, control: UInt16, level: Double) {
        guard let dev else { return }
        var bytes: (UInt8, UInt8) = (0, 0)
        withUnsafeMutableBytes(of: &bytes) { mbox_level_to_gain(level, $0.baseAddress!.assumingMemoryBound(to: UInt8.self)) }
        let gain = UInt16(bytes.0) | UInt16(bytes.1) << 8
        let key = UInt32(unit) << 16 | UInt32(control)
        if mixWritten[key] == gain { return }  // also skips level changes too small for the hardware's 0.25 dB steps
        lastWrite = Date()
        mixWritten[key] = MboxHardware.ok(mbox_set_mix_level(dev, unit, control, level)) ? gain : nil
    }

    func write(_ crosspoints: [Crosspoint]) {
        for c in crosspoints {
            let input: Int
            switch c.source {
            case .software(let i): input = Int(MBOX_MIX_IN_SOFTWARE) + i
            case .hardware(let i): input = Int(MBOX_MIX_IN_HARDWARE) + i
            case .fxReturn: input = Int(MBOX_MIX_IN_FX_RETURN)
            }
            setMix(unit: UInt16(MBOX_UNIT_MIXER), control: mbox_mixer_control(Int32(input), Int32(c.output)), level: c.level)
        }
    }

    func writeFxSends(software: [Double], hardware: [Double]) {
        for (i, level) in software.enumerated() { setMix(unit: UInt16(MBOX_UNIT_FX_SENDS), control: mbox_fx_send_control(0, Int32(i)), level: level) }
        for (i, level) in hardware.enumerated() { setMix(unit: UInt16(MBOX_UNIT_FX_SENDS), control: mbox_fx_send_control(1, Int32(i)), level: level) }
    }

    func writeEffect(_ effect: EffectSettings) {
        guard let dev, effect != effectWritten else { return }
        lastWrite = Date()
        let r = mbox_set_effect(dev, Int32(effect.preset), Int32(effect.volume), Int32(effect.duration), Int32(effect.feedback))
        effectWritten = MboxHardware.ok(r) ? effect : nil
    }

    // MARK: - Front-panel registers and meters

    func writeRegister(_ reg: Int, _ value: UInt8) {
        guard let dev else { return }
        lastWrite = Date()
        mbox_write_reg(dev, UInt8(reg), value)
    }

    func readRegisters() -> MboxRegs? {
        guard let dev else { return nil }
        var regs = MboxRegs()
        return MboxHardware.ok(mbox_read_regs(dev, &regs)) ? regs : nil
    }

    func readMeters() -> [UInt16]? {
        guard let dev else { return nil }
        var raw = [UInt16](repeating: 0, count: Int(MBOX_METER_COUNT))
        let r = raw.withUnsafeMutableBufferPointer { mbox_read_meters(dev, $0.baseAddress) }
        return MboxHardware.ok(r) ? raw : nil
    }

    // MARK: - Clock

    func clockStatus() -> ClockStatus? {
        guard let dev else { return nil }
        var source: Int32 = 0
        var rate: UInt32 = 0
        var locked = false
        guard MboxHardware.ok(mbox_get_clock_source(dev, &source)), MboxHardware.ok(mbox_get_sample_rate(dev, &rate)) else { return nil }
        mbox_spdif_valid(dev, &locked)
        return ClockStatus(spdif: source == Int32(MBOX_CLOCK_SPDIF), rate: Int(rate), spdifLocked: locked)
    }

    func setClockSource(spdif: Bool) {
        guard let dev else { return }
        lastWrite = Date()
        mbox_set_clock_source(dev, Int32(spdif ? MBOX_CLOCK_SPDIF : MBOX_CLOCK_INTERNAL))
    }

    func setInternalRate(_ rate: Int) {
        guard let dev else { return }
        lastWrite = Date()
        mbox_set_internal_rate(dev, UInt32(rate))
    }

    /// Software replug: the Mbox drops off the bus and comes back (fixes a Mbox that ignores playback).
    func reenumerate() {
        guard let dev else { return }
        mbox_reenumerate(dev)
    }
}
