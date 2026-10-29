// What the engine needs from the outside world. Production: MboxHardware (the USB control path through MboxKit)
// and CoreAudioDriver (the HAL client). Tests drive the engine with fakes (Tests/EngineTests.swift).

import Foundation

struct ClockStatus {
    let spdif: Bool
    let rate: Int
    let spdifLocked: Bool  // only meaningful while the S/PDIF clock is selected
}

/// The Mbox's control path. Writes of unchanged values may be skipped until `forgetWrites`.
protocol MboxControl: AnyObject {
    var isOpen: Bool { get }
    var secondsSinceWrite: TimeInterval { get }
    var firmware: String { get }
    func open() -> Bool
    func close()
    func forgetWrites()
    func write(_ crosspoints: [Crosspoint])
    func writeFxSends(software: [Double], hardware: [Double])
    func writeEffect(_ effect: EffectSettings)
    func writeRegister(_ reg: Int, _ value: UInt8)
    func readRegisters() -> MboxRegs?
    func readMeters() -> [UInt16]?
    func clockStatus() -> ClockStatus?
    func setClockSource(spdif: Bool)
    func setInternalRate(_ rate: Int)
    func reenumerate()
}

enum LatencyMode: Int32, CaseIterable {
    case safe = 0, balanced, low

    var name: String { PanelState.latencyModes[Int(rawValue)] }
    init?(name: String) {
        guard let i = PanelState.latencyModes.firstIndex(of: name) else { return nil }
        self.init(rawValue: Int32(i))
    }
}

/// The Mbox 3 Core Audio driver as seen through the HAL.
protocol AudioDriverControl {
    /// The driver is installed and Core Audio lists the Mbox.
    var isActive: Bool { get }
    /// Version of the installed driver bundle, nil when it is not installed.
    var installedVersion: String? { get }
    /// nil without the driver, or with an older driver that has no latency modes.
    func latencyMode() -> LatencyMode?
    func setLatencyMode(_ mode: LatencyMode)
    @discardableResult func setSampleRate(_ rate: Double) -> Bool
}
