// The Mbox's hardware tuner reports pitch as MIDI Poly Aftertouch (0xAn note cents) on its Control port while
// tuner mode is on. Decoding as Avid's panel does it: cents are signed 7-bit, clamped to +-50.

import Foundation

enum TunerDecoder {
    struct Reading: Equatable {
        let note: String
        let cents: Int
    }

    static func decode(_ bytes: [UInt8]) -> Reading? {
        guard bytes.count == 3, bytes[0] & 0xF0 == 0xA0 else { return nil }
        let raw = Int(bytes[2] & 0x7F)
        let cents = max(-50, min(50, raw >= 64 ? raw - 128 : raw))
        return Reading(note: noteName(Int(bytes[1] & 0x7F)), cents: cents)
    }

    /// Values 0-11 count from A (Avid's TUNER_NOTE_A ordering); larger values are MIDI note numbers.
    static func noteName(_ note: Int) -> String {
        let fromA = ["A", "A#", "B", "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#"]
        let fromC = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        return note < 12 ? fromA[max(0, note)] : fromC[note % 12] + String(note / 12 - 1)
    }
}
