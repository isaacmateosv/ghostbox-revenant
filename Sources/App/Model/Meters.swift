// Meter ballistics for the panel: dB-scaled levels with a release, clip indicators held briefly, optional
// post-fader scaling. Input is the Mbox's raw meter block (15 words, full scale 32767).

import Foundation

struct MeterFrame {
    var levels: [String: [Double]]  // 0...1 over -60...0 dBFS
    var clips: [String: [Bool]]
}

struct MeterProcessor {
    /// Panel meter groups and their words in the meter block (MBOX_METER_*)
    static let layout: [(key: String, words: [Int])] = [("hw", [0, 1, 2, 3]), ("sw", [4, 5, 6, 7]), ("out12", [8, 9]),
                                                        ("out34", [10, 11]), ("fx", [13, 14])]
    static let fxInputWord = 12
    static let clipRaw: UInt16 = 32700
    static let floorDb = -60.0
    static let release = 0.82          // per poll
    static let clipHold: TimeInterval = 0.35

    private var held: [String: [Double]] = [:]
    private var clipUntil: [String: [Date]] = [:]

    init() {
        for (key, words) in MeterProcessor.layout {
            held[key] = Array(repeating: 0, count: words.count)
            clipUntil[key] = Array(repeating: .distantPast, count: words.count)
        }
    }

    /// dBFS mapped to 0...1 over the meter's range.
    static func level(_ raw: Double) -> Double {
        guard raw > 0 else { return 0 }
        let db = 20 * log10(min(1, raw / 32767.0))
        return max(0, min(1, (db - floorDb) / -floorDb))
    }

    /// One poll. `raw` is nil when the read failed (meters fall back); `gains` scales strips for post-fader metering.
    mutating func process(_ raw: [UInt16]?, gains: [String: [Double]], now: Date) -> MeterFrame {
        var frame = MeterFrame(levels: [:], clips: [:])
        for (key, words) in MeterProcessor.layout {
            var levels = [Double](), clips = [Bool]()
            for (j, word) in words.enumerated() {
                let r = raw.map { $0[word] } ?? 0
                let clipping = r >= MeterProcessor.clipRaw ||
                    (key == "fx" && (raw.map { $0[MeterProcessor.fxInputWord] } ?? 0) >= MeterProcessor.clipRaw)
                if clipping { clipUntil[key]![j] = now.addingTimeInterval(MeterProcessor.clipHold) }
                clips.append(now < clipUntil[key]![j])
                var v = Double(r)
                if let g = gains[key], j < g.count { v *= g[j] }
                let lvl = MeterProcessor.level(v)
                let h = lvl >= held[key]![j] ? lvl : held[key]![j] * MeterProcessor.release
                held[key]![j] = h
                levels.append((h * 1000).rounded() / 1000)
            }
            frame.levels[key] = levels
            frame.clips[key] = clips
        }
        return frame
    }
}
