// The Mbox 3 Core Audio driver as seen from the app, through MboxKit's HAL client calls.

import Foundation

struct CoreAudioDriver: AudioDriverControl {
    var isActive: Bool { mbox_coreaudio_present() }

    var installedVersion: String? {
        var buf = [CChar](repeating: 0, count: 64)
        return mbox_driver_version(&buf, buf.count) == Int32(MBOX_OK) ? String(cString: buf) : nil
    }

    func latencyMode() -> LatencyMode? {
        var mode: Int32 = 0
        return mbox_coreaudio_get_latency_mode(&mode) == Int32(MBOX_OK) ? LatencyMode(rawValue: mode) : nil
    }

    func setLatencyMode(_ mode: LatencyMode) {
        let r = mbox_coreaudio_set_latency_mode(mode.rawValue)
        if r != Int32(MBOX_OK) && r != Int32(MBOX_ERR_UNSUPPORTED) && r != Int32(MBOX_ERR_NOT_FOUND) {
            NSLog("Mbox3: could not set driver latency mode (%d)", r)
        }
    }

    @discardableResult
    func setSampleRate(_ rate: Double) -> Bool { mbox_coreaudio_set_rate(rate) == Int32(MBOX_OK) }
}
