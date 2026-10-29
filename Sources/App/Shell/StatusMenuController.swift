// The menu bar item: connection state and the everyday switches, rebuilt each time it opens.

import AppKit
import ServiceManagement

final class StatusMenuController: NSObject, NSMenuDelegate {
    private let engine: Engine
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    init(engine: Engine) {
        self.engine = engine
        super.init()
        statusItem.button?.image = NSImage(systemSymbolName: "slider.vertical.3", accessibilityDescription: "Mbox 3")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let (connected, mono, dim, tuner, latency, driverLatency, solo) = engine.perform {
            (engine.isConnected, engine.state.bool("mono"), engine.state.bool("dim"), engine.state.bool("tuner"),
             engine.setup.str("latency_mode"), engine.driverLatency, engine.hasSolo)
        }
        menu.removeAllItems()
        let status = NSMenuItem(title: connected ? "Mbox 3 connected" : "Mbox 3 not connected", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if solo { menu.addItem(toggle("Clear Solos (a solo is silencing other channels)", #selector(AppDelegate.clearSolos(_:)), on: false, enabled: true)) }
        menu.addItem(.separator())
        menu.addItem(toggle("Open Control Panel", #selector(AppDelegate.showPanel(_:)), on: false, enabled: true))
        menu.addItem(.separator())
        menu.addItem(toggle("Mono", #selector(AppDelegate.toggleMono(_:)), on: mono, enabled: connected))
        menu.addItem(toggle("Dim", #selector(AppDelegate.toggleDim(_:)), on: dim, enabled: connected))
        menu.addItem(toggle("Tuner", #selector(AppDelegate.toggleTuner(_:)), on: tuner, enabled: connected))
        menu.addItem(.separator())

        let latencyItem = NSMenuItem(title: "Driver Latency", action: nil, keyEquivalent: "")
        let latencyMenu = NSMenu()
        for mode in LatencyMode.allCases {
            let i = toggle(mode.name.capitalized, #selector(AppDelegate.selectLatency(_:)), on: latency == mode.name, enabled: driverLatency != nil)
            i.representedObject = mode.name
            latencyMenu.addItem(i)
        }
        if driverLatency == nil {
            let note = NSMenuItem(title: "Needs the Mbox 3 driver 1.0 or later", action: nil, keyEquivalent: "")
            note.isEnabled = false
            latencyMenu.addItem(note)
        }
        latencyItem.submenu = latencyMenu
        menu.addItem(latencyItem)
        menu.addItem(.separator())
        menu.addItem(toggle("Reset USB Connection", #selector(AppDelegate.resetUSB(_:)), on: false, enabled: connected))
        menu.addItem(toggle("Initialize Defaults…", #selector(AppDelegate.initializeDefaults(_:)), on: false, enabled: connected))
        menu.addItem(toggle("Launch at Login", #selector(AppDelegate.toggleLaunchAtLogin(_:)), on: SMAppService.mainApp.status == .enabled, enabled: true))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.target = NSApp
        menu.addItem(quit)
    }

    private func toggle(_ title: String, _ action: Selector, on: Bool, enabled: Bool) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
        i.target = NSApp.delegate  // works while another app is frontmost (no key window to start the chain)
        i.state = on ? .on : .off
        return i
    }
}
