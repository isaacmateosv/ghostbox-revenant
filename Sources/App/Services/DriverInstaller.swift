// Installs the Core Audio driver bundled in the app (Resources/GhostBoxRevenant.driver) through the macOS administrator
// prompt, using Resources/install-driver.sh (the same script as ./build.sh install-driver). The script restarts
// Core Audio, replugs the Mbox in software and leaves a 3-minute watchdog running that removes the driver again
// if Core Audio pins the CPU.

import Foundation

enum DriverInstaller {
    enum Outcome {
        case installed, cancelled, failed(String)
    }

    static var bundledDriver: URL? { Bundle.main.url(forResource: "GhostBoxRevenant", withExtension: "driver") }

    /// Version of the driver inside the app, compared with the installed one to offer an update.
    static let bundledVersion: String? = {
        guard let plist = bundledDriver?.appendingPathComponent("Contents/Info.plist"),
              let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return info["CFBundleShortVersionString"] as? String
    }()

    private static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Main thread: blocks while macOS shows the password prompt and the script runs (a few seconds).
    static func install() -> Outcome {
        guard let driver = bundledDriver, let script = Bundle.main.url(forResource: "install-driver", withExtension: "sh") else {
            return .failed("This copy of the app has no bundled driver.")
        }
        let command = "/bin/sh \(shellQuote(script.path)) install \(shellQuote(driver.path)) --watch-background"
        let source = "do shell script \(appleScriptString(command)) with administrator privileges " +
            "with prompt \"GhostBox Revenant GUI wants to install its Core Audio driver for the Mbox 3.\""
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard let error else { return .installed }
        if (error[NSAppleScript.errorNumber] as? Int) == -128 { return .cancelled }  // the user cancelled the prompt
        return .failed(error[NSAppleScript.errorMessage] as? String ?? "The installation failed.")
    }
}
