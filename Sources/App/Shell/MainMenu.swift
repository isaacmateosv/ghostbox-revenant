// The app's menu bar. Items target AppDelegate through the responder chain (nil target); AppDelegate validates
// them to show checkmarks and disable what needs the Mbox.

import AppKit

enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu("GhostBox Revenant GUI", [
            item("About GhostBox Revenant GUI", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Settings…", #selector(AppDelegate.showSetup(_:)), ","),
            item("Launch at Login", #selector(AppDelegate.toggleLaunchAtLogin(_:))),
            .separator(),
            item("Uninstall GhostBox Revenant…", #selector(AppDelegate.uninstall(_:))),
            .separator(),
            item("Hide GhostBox Revenant GUI", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit GhostBox Revenant GUI", #selector(NSApplication.terminate(_:)), "q"),
        ]))
        main.addItem(submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "Z"),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ]))
        main.addItem(submenu("View", [
            item("Fit to Window", #selector(AppDelegate.toggleFit(_:)), "9"),
            item("Show Tools Panel", #selector(AppDelegate.toggleTools(_:)), "t", [.command, .option]),
            .separator(),
            layoutItem("Horizontal", "horizontal", "1"),
            layoutItem("Horizontal, Meters Only", "horizontal_meters", "2"),
            layoutItem("Vertical", "vertical", "3"),
            layoutItem("Vertical, Meters Only", "vertical_meters", "4"),
            .separator(),
            item("Reload Panel", #selector(AppDelegate.reloadPanel(_:)), "r"),
        ]))
        main.addItem(submenu("Mixer", [
            busItem("Analog 1/2 Mix", .analog, "1"),
            busItem("S/PDIF L/R Mix", .spdif, "2"),
            .separator(),
            item("Mono", #selector(AppDelegate.toggleMono(_:)), "m", [.command, .shift]),
            item("Dim", #selector(AppDelegate.toggleDim(_:)), "d", [.command, .shift]),
            item("Tuner", #selector(AppDelegate.toggleTuner(_:)), "t"),
            .separator(),
            item("Clear Solos", #selector(AppDelegate.clearSolos(_:)), "s", [.command, .option]),
            item("Clear Clip Indicators", #selector(AppDelegate.clearClips(_:)), "k"),
            .separator(),
            item("Reset USB Connection", #selector(AppDelegate.resetUSB(_:))),
            item("Initialize Defaults…", #selector(AppDelegate.initializeDefaults(_:))),
        ]))
        let window = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ])
        main.addItem(window)
        NSApp.windowsMenu = window.submenu
        return main
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        holder.submenu = menu
        return holder
    }

    private static func item(_ title: String, _ action: Selector, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = modifiers
        return i
    }

    private static func layoutItem(_ title: String, _ layout: String, _ key: String) -> NSMenuItem {
        let i = item(title, #selector(AppDelegate.selectLayout(_:)), key, [.command, .option])
        i.representedObject = layout
        return i
    }

    private static func busItem(_ title: String, _ bus: Bus, _ key: String) -> NSMenuItem {
        let i = item(title, #selector(AppDelegate.selectMix(_:)), key)
        i.representedObject = bus.rawValue
        return i
    }
}
