// The Multi button: the Mbox sends a MIDI message on its Control port; once learned, it triggers an action.

import AppKit
import CoreMIDI

final class MultiButtonController {
    private let engine: Engine
    private let forward = VirtualMIDISource(name: "Mbox 3 Multi Button")

    init(engine: Engine) {
        self.engine = engine
    }

    /// A message from the Control port (main queue).
    func handle(_ bytes: [UInt8]) {
        let key = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        let (learning, trigger, action) = engine.perform { () -> (Bool, String, String) in
            let mb = engine.state.dict("multi_button")
            return (mb.bool("learning"), mb.str("trigger"), mb.str("press_release"))
        }
        if learning {
            engine.perform {
                let mb = engine.state.dict("multi_button")
                mb["trigger"] = key
                mb["learning"] = false
                engine.changed()
            }
            return
        }
        guard !trigger.isEmpty, key == trigger else { return }
        engine.perform {
            engine.state.dict("multi_button")["last_triggered"] = action
            engine.changed(persist: false)
        }
        run(action, bytes)
    }

    private func run(_ action: String, _ bytes: [UInt8]) {
        switch action {
        case "Toggle Dim": engine.perform { engine.handle(action: ["action": "toggle_global", "feature": "dim"]) }
        case "Toggle Mono": engine.perform { engine.handle(action: ["action": "toggle_global", "feature": "mono"]) }
        case "Forward to DAW (MIDI)": forward.send(bytes)
        case "Play/Pause": KeySender.mediaPlayPause()
        case "Space Bar": KeySender.key(49)
        case "Record (R key)": KeySender.key(15)
        default: break
        }
    }
}

/// Virtual MIDI source the Multi button can forward to (map it in your DAW's controller assignments).
final class VirtualMIDISource {
    private var client = MIDIClientRef(), source = MIDIEndpointRef()

    init(name: String) {
        MIDIClientCreateWithBlock("Mbox 3 Multi" as CFString, &client, nil)
        MIDISourceCreateWithProtocol(client, name as CFString, ._1_0, &source)
    }

    func send(_ bytes: [UInt8]) {
        guard source != 0, !bytes.isEmpty else { return }
        var list = MIDIEventList()
        let packet = MIDIEventListInit(&list, ._1_0)
        var word = 0x2000_0000 | (UInt32(bytes[0]) << 16) | (UInt32(bytes.count > 1 ? bytes[1] : 0) << 8) | UInt32(bytes.count > 2 ? bytes[2] : 0)
        _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, 0, 1, &word)
        MIDIReceivedEventList(source, &list)
    }
}

/// Keyboard and media-key events for Multi button actions (macOS asks for Accessibility permission once).
enum KeySender {
    static func trusted() -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    static func key(_ code: CGKeyCode) {
        guard trusted() else { return }
        CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
    }

    static func mediaPlayPause() {
        guard trusted() else { return }
        for down in [true, false] {
            let data1 = (16 << 16) | ((down ? 0xa : 0xb) << 8)  // NX_KEYTYPE_PLAY
            let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00),
                                        timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)
            ev?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}
