// This project's GitHub releases and the update decision. Pure (Foundation only): the network side is
// Services/UpdateChecker.swift.

import Foundation

/// MAJOR.MINOR.PATCH[-PRERELEASE][+BUILD], ordered by Semantic Versioning precedence:
/// 1.0.0-rc.2 < 1.0.0-rc.10 < 1.0.0 < 1.0.1-rc.1.
struct SemVer: Comparable, CustomStringConvertible {
    let major: Int, minor: Int, patch: Int
    let prerelease: [String]  // ["rc", "2"]; empty for a finished release

    init?(_ text: String) {
        var s = Substring(text.trimmingCharacters(in: .whitespaces))
        if s.first == "v" || s.first == "V" { s = s.dropFirst() }
        if let plus = s.firstIndex(of: "+") { s = s[..<plus] }  // build metadata does not count
        var core = s, ids: [String] = []
        if let dash = s.firstIndex(of: "-") {
            core = s[..<dash]
            ids = s[s.index(after: dash)...].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            if ids.contains(where: \.isEmpty) { return nil }
        }
        let numbers = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard numbers.count == 3, let a = numbers[0], let b = numbers[1], let c = numbers[2], a >= 0, b >= 0, c >= 0 else { return nil }
        (major, minor, patch, prerelease) = (a, b, c, ids)
    }

    var isPrerelease: Bool { !prerelease.isEmpty }
    var description: String { "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: ".")) }

    static func < (a: SemVer, b: SemVer) -> Bool {
        if a.major != b.major { return a.major < b.major }
        if a.minor != b.minor { return a.minor < b.minor }
        if a.patch != b.patch { return a.patch < b.patch }
        if a.prerelease.isEmpty != b.prerelease.isEmpty { return a.isPrerelease }  // a release candidate precedes its release
        for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
            switch (Int(x), Int(y)) {
            case let (i?, j?): return i < j
            case (.some, nil): return true    // numeric identifiers sort before alphanumeric ones
            case (nil, .some): return false
            case (nil, nil): return x < y
            }
        }
        return a.prerelease.count < b.prerelease.count
    }
}

struct Release {
    struct Asset { let name: String; let url: URL; let size: Int }

    let version: SemVer
    let tag: String
    let isPrerelease: Bool
    let notes: String
    let page: URL
    let published: String
    let assets: [Asset]

    /// The installer package (GhostBoxRevenant-<version>.pkg) and the checksum list published with it.
    var package: Asset? { assets.first { $0.name.hasPrefix("GhostBoxRevenant-") && $0.name.hasSuffix(".pkg") } }
    var checksums: Asset? { assets.first { $0.name == "SHA256SUMS.txt" } }
}

enum Releases {
    static let repository = "isaacmateosv/ghostbox-revenant"
    static let listURL = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=20")!
    static let pagePrefix = "https://github.com/\(repository)/releases/"
    static let downloadPrefix = "https://github.com/\(repository)/releases/download/"
    /// Automatic checks: at most once a day, and an hour apart after a failed attempt (offline, rate limit).
    static let checkInterval: TimeInterval = 24 * 3600
    static let retryInterval: TimeInterval = 3600

    /// GitHub's release list. Drafts, tags that are not versions and links outside this repository's releases are
    /// left out, so a reply can never point the app anywhere else.
    static func parse(_ data: Data) -> [Release]? {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        return list.compactMap { r in
            guard r["draft"] as? Bool != true, let tag = r["tag_name"] as? String, let version = SemVer(tag),
                  let pageText = r["html_url"] as? String, pageText.hasPrefix(pagePrefix), let page = URL(string: pageText) else { return nil }
            let assets: [Release.Asset] = (r["assets"] as? [[String: Any]] ?? []).compactMap { a in
                guard let name = a["name"] as? String, let link = a["browser_download_url"] as? String,
                      link.hasPrefix(downloadPrefix), let url = URL(string: link) else { return nil }
                return Release.Asset(name: name, url: url, size: (a["size"] as? NSNumber)?.intValue ?? 0)
            }
            return Release(version: version, tag: tag, isPrerelease: r["prerelease"] as? Bool == true || version.isPrerelease,
                           notes: r["body"] as? String ?? "", page: page, published: r["published_at"] as? String ?? "", assets: assets)
        }
    }

    /// The release to offer: the newest one above `current` that has an installer package, and a finished release
    /// unless release candidates are included.
    static func offer(_ releases: [Release], current: SemVer, includePrereleases: Bool) -> Release? {
        releases.filter { $0.version > current && $0.package != nil && (includePrereleases || !$0.isPrerelease) }
            .max { $0.version < $1.version }
    }

    /// Advanced > Release candidates: "on", "off", or "auto" (offered while the running build is one itself).
    static func includesPrereleases(_ choice: String, current: SemVer) -> Bool {
        choice == "on" || (choice != "off" && current.isPrerelease)
    }

    /// Whether an automatic check may run. A clock set backwards counts as due.
    static func isDue(lastCheck: Date?, lastAttempt: Date?, now: Date) -> Bool {
        func elapsed(_ d: Date?, _ interval: TimeInterval) -> Bool {
            guard let d else { return true }
            let t = now.timeIntervalSince(d)
            return t >= interval || t < 0
        }
        return elapsed(lastCheck, checkInterval) && elapsed(lastAttempt, retryInterval)
    }

    /// The SHA-256 (lowercase hex) that a SHA256SUMS.txt lists for `file`: lines "<hash>  <name>" as written by
    /// `shasum -a 256`, with "*" before the name in binary mode.
    static func checksum(for file: String, in list: String) -> String? {
        for line in list.split(whereSeparator: \.isNewline) {
            let fields = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 2 else { continue }
            let hash = fields[0].lowercased()
            var name = fields[1].trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("*") { name.removeFirst() }
            if name == file, hash.count == 64, hash.allSatisfy(\.isHexDigit) { return hash }
        }
        return nil
    }
}
