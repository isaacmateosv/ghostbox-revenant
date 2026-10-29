// Saves the panel state (debounced) and the user's presets in ~/Library/Application Support/GhostBox Revenant.

import Foundation

final class StateStore {
    let directory: URL
    var presetsDirectory: URL { directory.appendingPathComponent("presets", isDirectory: true) }
    var stateFile: URL { directory.appendingPathComponent("last_state.json") }
    private var dirtySince: Date?
    static let debounce: TimeInterval = 0.75

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: presetsDirectory, withIntermediateDirectories: true)
    }

    func loadLastState() -> NSMutableDictionary? {
        guard let data = try? Data(contentsOf: stateFile) else { return nil }
        return StateTree.parse(data)
    }

    /// Saves 0.75 s after the last change (a fader drag writes the file once, when it ends).
    func markDirty() { dirtySince = Date() }

    func saveIfDue(_ state: NSDictionary) {
        if let since = dirtySince, Date().timeIntervalSince(since) > StateStore.debounce { saveNow(state) }
    }

    func saveNow(_ state: NSDictionary) {
        let data = StateTree.json(PanelState.persistable(state))
        let tmp = stateFile.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp)
            _ = try FileManager.default.replaceItemAt(stateFile, withItemAt: tmp)
            dirtySince = nil
        } catch {
            if (try? data.write(to: stateFile)) != nil { dirtySince = nil }
        }
    }

    var hasUnsavedChanges: Bool { dirtySince != nil }

    // MARK: - Presets

    func presetNames() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: presetsDirectory.path)) ?? []
        return files.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }

    private func presetURL(_ name: String) -> URL? {
        let clean = name.components(separatedBy: CharacterSet(charactersIn: "/\\:\0")).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty || clean.hasPrefix(".") ? nil : presetsDirectory.appendingPathComponent(clean + ".json")
    }

    func savePreset(_ name: String, state: NSDictionary) -> Bool {
        guard let url = presetURL(name) else { return false }
        return (try? StateTree.json(PanelState.persistable(state)).write(to: url)) != nil
    }

    func loadPreset(_ name: String) -> NSMutableDictionary? {
        guard let url = presetURL(name), let data = try? Data(contentsOf: url) else { return nil }
        return StateTree.parse(data)
    }

    func deletePreset(_ name: String) -> Bool {
        guard let url = presetURL(name) else { return false }
        return (try? FileManager.default.removeItem(at: url)) != nil
    }
}
