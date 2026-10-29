// The panel state is a JSON-shaped tree of mutable Foundation containers, the same shape the panel UI reads and
// writes. These helpers give it tolerant, Python-like access: a missing or mistyped value reads as 0/false/"",
// and a missing container is created on first access.

import Foundation

enum StateTree {
    static func deepCopy(_ obj: Any) -> NSMutableDictionary {
        parse(json(obj)) ?? NSMutableDictionary()
    }

    /// Saved values over defaults key by key, so keys added in newer versions keep their defaults.
    static func merge(_ src: NSDictionary, into dst: NSMutableDictionary) {
        for (k, v) in src {
            guard let key = k as? String, dst[key] != nil else { continue }
            if let sub = dst[key] as? NSMutableDictionary, let subSrc = v as? NSDictionary {
                merge(subSrc, into: sub)
            } else {
                dst[key] = v
            }
        }
    }

    static func json(_ obj: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
    }

    static func parse(_ data: Data) -> NSMutableDictionary? {
        (try? JSONSerialization.jsonObject(with: data, options: .mutableContainers)) as? NSMutableDictionary
    }
}

extension NSMutableDictionary {
    /// The container at `k`; an immutable one (a Swift value stored here) is replaced by a mutable copy, never dropped.
    func dict(_ k: String) -> NSMutableDictionary {
        if let d = self[k] as? NSMutableDictionary { return d }
        let d = (self[k] as? NSDictionary)?.mutableCopy() as? NSMutableDictionary ?? NSMutableDictionary()
        self[k] = d
        return d
    }
    func array(_ k: String) -> NSMutableArray {
        if let a = self[k] as? NSMutableArray { return a }
        let a = (self[k] as? NSArray)?.mutableCopy() as? NSMutableArray ?? NSMutableArray()
        self[k] = a
        return a
    }
    func num(_ k: String) -> Double { (self[k] as? NSNumber)?.doubleValue ?? 0 }
    func bool(_ k: String) -> Bool { (self[k] as? NSNumber)?.boolValue ?? false }
    func str(_ k: String) -> String { self[k] as? String ?? "" }
}

extension NSMutableArray {
    var dicts: [NSMutableDictionary] { compactMap { $0 as? NSMutableDictionary } }
    var numbers: [Double] { compactMap { ($0 as? NSNumber)?.doubleValue } }
    func num(_ i: Int) -> Double { i >= 0 && i < count ? ((self[i] as? NSNumber)?.doubleValue ?? 0) : 0 }
}
