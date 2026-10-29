// System facts for the panel's System page: MIDI patch files, RAM, disk sleep, volumes, versions.

import Foundation

enum Diagnostics {
    static func collect() -> [String: Any] {
        var midnam: [String] = [], middev: [String] = []
        for dir in ["/Library/Audio/MIDI Devices", "/Library/Audio/MIDI Patch Names"] {
            guard let e = FileManager.default.enumerator(atPath: dir) else { continue }
            for case let f as String in e {
                if f.hasSuffix(".midnam") { midnam.append((f as NSString).lastPathComponent) }
                if f.hasSuffix(".middev") { middev.append((f as NSString).lastPathComponent) }
            }
        }
        let info = ProcessInfo.processInfo
        return [
            "midnam_files": midnam, "middev_files": middev,
            "volumes": (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? [],
            "ram_gb": String(format: "%.1f GB", Double(info.physicalMemory) / 1_073_741_824),
            "disk_sleep": diskSleep(),
            "macos": info.operatingSystemVersionString,
            "cpu": cpuDescription(),
            "app_version": AppInfo.version,
            "driver_version": CoreAudioDriver().installedVersion ?? "not installed",
        ]
    }

    private static func diskSleep() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g"]
        let pipe = Pipe()
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return "Unknown" }
        p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return out.split(separator: "\n").first { $0.contains("disksleep") }?.trimmingCharacters(in: .whitespaces) ?? "Unknown"
    }

    private static func cpuDescription() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        var translated: Int32 = 0
        var tsize = MemoryLayout<Int32>.size
        let rosetta = sysctlbyname("sysctl.proc_translated", &translated, &tsize, nil, 0) == 0 && translated == 1
        return String(cString: buf) + (rosetta ? " (running under Rosetta)" : "")
    }
}
