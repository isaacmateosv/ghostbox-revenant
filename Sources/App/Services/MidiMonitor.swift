// Listens to the Mbox's two USB MIDI ports ("External" = the 5-pin DIN jacks, "Control" = Avid's control port),
// keeps a short log for the panel's MIDI page and hands every message to `onMessage` (tuner, Multi button).

import CoreMIDI
import Foundation

final class MidiMonitor {
    struct Event { let time: Date; let port: String; let bytes: [UInt8] }

    private var client = MIDIClientRef()
    private var inPort = MIDIPortRef()
    private var connected: Set<MIDIEndpointRef> = []
    private let lock = NSLock()
    private var events: [Event] = []
    private(set) var eventCount = 0
    var onMessage: ((String, [UInt8]) -> Void)?

    init() {
        MIDIClientCreateWithBlock("GhostBox Revenant GUI" as CFString, &client) { [weak self] note in
            if note.pointee.messageID == .msgSetupChanged { DispatchQueue.main.async { self?.connectSources() } }
        }
        MIDIInputPortCreateWithProtocol(client, "Mbox 3 In" as CFString, ._1_0, &inPort) { [weak self] list, ref in
            let port = ref.map { Unmanaged<NSString>.fromOpaque($0).takeUnretainedValue() as String } ?? "?"
            for packet in list.unsafeSequence() {
                let count = Int(packet.pointee.wordCount)
                let words = withUnsafeBytes(of: packet.pointee.words) { Array($0.bindMemory(to: UInt32.self).prefix(count)) }
                for w in words where (w >> 28) == 0x2 || (w >> 28) == 0x1 {  // MIDI 1.0 channel voice / system
                    let status = UInt8((w >> 16) & 0xff), d1 = UInt8((w >> 8) & 0x7f), d2 = UInt8(w & 0x7f)
                    let len = MidiMonitor.length(status)
                    self?.record(port, Array([status, d1, d2].prefix(len)))
                }
            }
        }
        connectSources()
    }

    private static func length(_ status: UInt8) -> Int {
        switch status & 0xf0 {
        case 0xc0, 0xd0: return 2
        case 0xf0: return status == 0xf2 ? 3 : (status == 0xf1 || status == 0xf3 ? 2 : 1)
        default: return 3
        }
    }

    func connectSources() {
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            guard !connected.contains(src) else { continue }
            var entity = MIDIEntityRef(), device = MIDIDeviceRef()
            MIDIEndpointGetEntity(src, &entity)
            MIDIEntityGetDevice(entity, &device)
            var dn: Unmanaged<CFString>?, en: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(device, kMIDIPropertyName, &dn)
            MIDIObjectGetStringProperty(src, kMIDIPropertyName, &en)
            let devName = dn?.takeRetainedValue() as String? ?? "", portName = en?.takeRetainedValue() as String? ?? ""
            guard devName.hasPrefix("Mbox") else { continue }
            let label = (portName.isEmpty ? devName : portName) as NSString
            if MIDIPortConnectSource(inPort, src, Unmanaged.passRetained(label).toOpaque()) == noErr { connected.insert(src) }
        }
    }

    private func record(_ port: String, _ bytes: [UInt8]) {
        lock.lock()
        events.append(Event(time: Date(), port: port, bytes: bytes))
        if events.count > 64 { events.removeFirst(events.count - 64) }
        eventCount += 1
        lock.unlock()
        onMessage?(port, bytes)
    }

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func recent() -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        let fmt = MidiMonitor.timeFormat
        return events.reversed().map { ["time": fmt.string(from: $0.time), "port": $0.port,
                                         "bytes": $0.bytes.map { String(format: "%02X", $0) }.joined(separator: " ")] }
    }
}
