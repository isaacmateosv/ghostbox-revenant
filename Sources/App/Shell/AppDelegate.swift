// GhostBox Revenant GUI: the composition root. Builds the engine, the MIDI services, the local panel server, the window
// and the menus, and handles the menu commands.
//
//   Model/      pure state, mixer law, meters, tuner decoding (unit tested: Tests/AppModelTests.swift)
//   Hardware/   MboxKit (USB control path) and Core Audio driver access
//   Core/       Engine: state owner, hardware sync, polling, actions
//   Services/   persistence, MIDI monitor, Multi button, diagnostics
//   Server/     localhost HTTP server and the panel API
//   Shell/      this file, the window and the menus

import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var engine: Engine!
    private var midi: MidiMonitor!
    private var multiButton: MultiButtonController!
    private var router: APIRouter!
    private var server: HTTPServer!
    private var statusMenu: StatusMenuController!
    private let panel = MainWindowController()

    static let defaultPort: UInt16 = 18080

    /// ~/Library/Application Support/GhostBox Revenant, or GHOSTBOX_DATA_DIR (development and tests). On first launch
    /// after the rename, the settings saved under the old name ("Mbox3 Control") are copied over; the old folder stays.
    private static func dataDirectory() -> URL {
        if let custom = ProcessInfo.processInfo.environment["GHOSTBOX_DATA_DIR"] { return URL(fileURLWithPath: custom, isDirectory: true) }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("GhostBox Revenant", isDirectory: true)
        let legacy = support.appendingPathComponent("Mbox3 Control", isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path), fm.fileExists(atPath: legacy.path) {
            do {
                try fm.copyItem(at: legacy, to: dir)
                NSLog("GhostBox Revenant: copied your settings from %@", legacy.path)
            } catch {
                NSLog("GhostBox Revenant: could not copy settings from %@: %@", legacy.path, error.localizedDescription)
            }
        }
        return dir
    }

    /// The bundled panel, or GHOSTBOX_UI_DIR to work on Sources/UI without rebuilding.
    private static func uiDirectory() -> URL {
        if let custom = ProcessInfo.processInfo.environment["GHOSTBOX_UI_DIR"] { return URL(fileURLWithPath: custom, isDirectory: true) }
        return Bundle.main.resourceURL?.appendingPathComponent("UI", isDirectory: true)
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("UI")
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.mainMenu = MainMenu.build()
        engine = Engine(store: StateStore(directory: AppDelegate.dataDirectory()), hardware: MboxHardware(), driver: CoreAudioDriver())
        midi = MidiMonitor()
        engine.midi = midi
        multiButton = MultiButtonController(engine: engine)
        midi.onMessage = { [weak self] port, bytes in DispatchQueue.main.async { self?.handleMidi(port, bytes) } }
        engine.start()
        statusMenu = StatusMenuController(engine: engine)

        router = APIRouter(engine: engine, uiDirectory: AppDelegate.uiDirectory(), midi: midi)
        server = HTTPServer { [router] request in router!.handle(request) }
        let preferred = UInt16(ProcessInfo.processInfo.environment["GHOSTBOX_PORT"] ?? "") ?? AppDelegate.defaultPort
        server.start(preferredPort: preferred) { [weak self] port in
            guard let self else { return }
            let url = URL(string: "http://127.0.0.1:\(port)/")!
            NSLog("GhostBox Revenant: panel at %@", url.absoluteString)
            self.panel.load(url)
        }
        panel.show()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
        panel.show()
        return true
    }

    func applicationWillTerminate(_ note: Notification) { engine?.shutdown() }

    /// MIDI from the Mbox: on the Control port, tuner readings and the Multi button.
    private func handleMidi(_ port: String, _ bytes: [UInt8]) {
        guard port.localizedCaseInsensitiveContains("Control") else { return }
        if let reading = TunerDecoder.decode(bytes) {
            engine.perform { engine.setTunerReading(reading) }
        } else {
            multiButton.handle(bytes)
        }
    }

    private func act(_ body: [String: Any]) { engine.perform { engine.handle(action: body as NSDictionary) } }

    // MARK: - Menu commands

    @objc func showPanel(_ sender: Any?) { panel.show() }
    @objc func reloadPanel(_ sender: Any?) { panel.reload() }
    @objc func showSetup(_ sender: Any?) { panel.show(); panel.run("setup") }
    @objc func clearClips(_ sender: Any?) { panel.run("clearClips") }

    @objc func toggleFit(_ sender: Any?) {
        act(["action": "update_ui", "ui": ["fit": !engine.perform { engine.state.dict("ui").bool("fit") }]])
    }

    @objc func toggleTools(_ sender: Any?) {
        act(["action": "update_ui", "ui": ["tools_open": !engine.perform { engine.state.dict("ui").bool("tools_open") }]])
    }

    @objc func selectLayout(_ sender: NSMenuItem) {
        if let layout = sender.representedObject as? String { act(["action": "set_layout", "layout": layout]) }
    }

    @objc func selectMix(_ sender: NSMenuItem) {
        if let bus = sender.representedObject as? String { act(["action": "switch_bus", "bus": bus]) }
    }

    @objc func selectLatency(_ sender: NSMenuItem) {
        if let mode = sender.representedObject as? String { act(["action": "update_setup", "setup": ["latency_mode": mode]]) }
    }

    @objc func toggleMono(_ sender: Any?) { act(["action": "toggle_global", "feature": "mono"]) }
    @objc func toggleDim(_ sender: Any?) { act(["action": "toggle_global", "feature": "dim"]) }
    @objc func toggleTuner(_ sender: Any?) {
        act(["action": "set_tuner", "tuner": !engine.perform { engine.state.bool("tuner") }])
    }
    @objc func clearSolos(_ sender: Any?) { act(["action": "clear_solos"]) }
    @objc func resetUSB(_ sender: Any?) { engine.perform { engine.reenumerate() } }

    @objc func initializeDefaults(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Initialize Mbox 3 defaults?"
        alert.informativeText = "This resets the mixer, effect and setup to factory defaults and replaces your saved session. Presets are kept."
        alert.addButton(withTitle: "Initialize")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        act(["action": "reset_defaults"])
    }

    @objc func toggleLaunchAtLogin(_ sender: Any?) {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc func uninstall(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Uninstall GhostBox Revenant?"
        alert.informativeText = "Removes the Core Audio driver and GhostBox Revenant GUI, then restarts Core Audio. Your saved mixes and presets in ~/Library/Application Support/GhostBox Revenant are kept."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let appPath = Bundle.main.bundlePath.replacingOccurrences(of: "'", with: "")
        let paths = "/Library/Audio/Plug-Ins/HAL/GhostBoxRevenant.driver /Library/Audio/Plug-Ins/HAL/Mbox3.driver '\(appPath)'"
        let script = "do shell script \"rm -rf \(paths); killall coreaudiod\" with administrator privileges"
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        if err == nil { NSApp.terminate(nil) }
    }

    // MARK: - Menu validation

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let engine else { return true }
        let (ui, layout, bus, mono, dim, tuner, connected) = engine.perform {
            (engine.state.dict("ui").copy() as? NSDictionary ?? [:], engine.state.str("layout"), engine.activeBus,
             engine.state.bool("mono"), engine.state.bool("dim"), engine.state.bool("tuner"), engine.isConnected)
        }
        func check(_ on: Bool) { item.state = on ? .on : .off }
        switch item.action {
        case #selector(toggleFit(_:)): check((ui["fit"] as? Bool) ?? false)
        case #selector(toggleTools(_:)): check((ui["tools_open"] as? Bool) ?? true)
        case #selector(selectLayout(_:)): check(item.representedObject as? String == layout)
        case #selector(selectMix(_:)): check(item.representedObject as? String == bus.rawValue)
        case #selector(toggleMono(_:)): check(mono); return connected
        case #selector(toggleDim(_:)): check(dim); return connected
        case #selector(toggleTuner(_:)): check(tuner); return connected
        case #selector(resetUSB(_:)), #selector(initializeDefaults(_:)): return connected
        case #selector(toggleLaunchAtLogin(_:)): check(SMAppService.mainApp.status == .enabled)
        default: break
        }
        return true
    }
}
