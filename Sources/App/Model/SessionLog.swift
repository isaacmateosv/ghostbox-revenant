// The session log: what the meters saw since it was last cleared. Highest peak and clip count per channel (so a clip
// during a take is never missed while you look away) and a one-second peak history of Out 1/2 for the last 10 minutes.
// Fed with the Mbox's raw meter block (15 words, full scale 32767); reads only, never writes to the Mbox.

import Foundation

struct SessionLog {
    /// Channels and their words in the meter block (MBOX_METER_*), in panel order.
    static let channels: [(name: String, word: Int)] = [
        ("Input 1", 0), ("Input 2", 1), ("S/PDIF In L", 2), ("S/PDIF In R", 3),
        ("DAW Ret 1", 4), ("DAW Ret 2", 5), ("DAW Ret 3", 6), ("DAW Ret 4", 7),
        ("Out 1", 8), ("Out 2", 9), ("Out 3", 10), ("Out 4", 11),
    ]
    /// Channels whose clips raise an alert: the inputs, where a clip ruins a take and only the gain knob helps.
    static let alertChannels = 0..<4
    static let historySeconds = 600
    static let outWords = (8, 9)

    private(set) var since = Date()
    private(set) var peaks = [UInt16](repeating: 0, count: SessionLog.channels.count)
    private(set) var clips = [Int](repeating: 0, count: SessionLog.channels.count)
    private(set) var lastClip = [Date?](repeating: nil, count: SessionLog.channels.count)
    private var clipping = [Bool](repeating: false, count: SessionLog.channels.count)
    /// Out 1/2 peak per second, oldest first: (second, L raw, R raw)
    private(set) var history: [(second: Int, l: UInt16, r: UInt16)] = []

    /// One meter read. Returns the alert channels that started clipping with this read (a clip held over several
    /// reads counts once).
    mutating func record(_ raw: [UInt16], now: Date) -> [String] {
        guard raw.count >= 12 else { return [] }
        var started: [String] = []
        for (i, ch) in SessionLog.channels.enumerated() {
            let v = raw[ch.word]
            peaks[i] = max(peaks[i], v)
            let over = v >= MeterProcessor.clipRaw
            if over && !clipping[i] {
                clips[i] += 1
                lastClip[i] = now
                if SessionLog.alertChannels.contains(i) { started.append(ch.name) }
            }
            clipping[i] = over
        }
        let second = Int(now.timeIntervalSince1970.rounded(.down))
        let l = raw[SessionLog.outWords.0], r = raw[SessionLog.outWords.1]
        if let last = history.last, last.second == second {
            history[history.count - 1] = (second, max(last.l, l), max(last.r, r))
        } else {
            history.append((second, l, r))
            if let first = history.first, second - first.second >= SessionLog.historySeconds {
                history.removeAll { second - $0.second >= SessionLog.historySeconds }
            }
        }
        return started
    }

    mutating func clear(now: Date) { self = SessionLog(); since = now }

    /// dBFS of a raw meter value, one decimal; nil for silence.
    static func dbfs(_ raw: UInt16) -> Double? {
        guard raw > 0 else { return nil }
        return (20 * log10(min(1, Double(raw) / 32767.0)) * 10).rounded() / 10
    }

    /// The log for the panel (GET /api/session). History seconds with no reading (device away) are left out; `t` is
    /// seconds before `now`.
    func json(now: Date) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        let chans: [[String: Any]] = SessionLog.channels.enumerated().map { i, ch in
            ["name": ch.name, "peak_db": SessionLog.dbfs(peaks[i]) ?? NSNull(), "clips": clips[i],
             "last_clip": lastClip[i].map { iso.string(from: $0) } ?? NSNull()]
        }
        let nowSecond = Int(now.timeIntervalSince1970.rounded(.down))
        let points: [[Any]] = history.map { p in
            [nowSecond - p.second, SessionLog.dbfs(p.l) ?? NSNull(), SessionLog.dbfs(p.r) ?? NSNull()]
        }
        return ["since": iso.string(from: since), "channels": chans, "history": points,
                "history_seconds": SessionLog.historySeconds]
    }
}
