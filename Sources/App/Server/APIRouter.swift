// The panel's local API and static files.
//
// Only this Mac's panel may drive the Mbox: requests must be addressed to 127.0.0.1/localhost (blocks
// DNS rebinding), browser requests must come from our own origin, and anything that changes state is a JSON POST
// (so another website cannot trigger it with a simple form, image or fetch).
//
//   GET  /                     panel (index.html); /css/*, /js/*, /img/* static files
//   GET  /api/state            {state, rev, info}
//   GET  /api/meters           meters, clips, front panel, tuner reading, rev (polled ~16x/s)
//   GET  /api/midi             recent MIDI from the Mbox
//   GET  /api/diagnostics      MIDI patch files, RAM, disk sleep, volumes
//   GET  /api/presets/list
//   POST /api/state            {action, ...} (see EngineActions.swift)
//   POST /api/presets/save|load|delete  {name}
//   POST /api/init             initialize defaults
//   POST /api/reenumerate      software replug
//   POST /api/open-ams         open Audio MIDI Setup
//   POST /api/reveal-data      show the settings folder in Finder
//   POST /api/install-driver   install the bundled driver (macOS password prompt); progress in info.driver_job

import AppKit
import Foundation

final class APIRouter {
    private let engine: Engine
    private let uiDirectory: URL
    private let midi: MidiMonitor

    init(engine: Engine, uiDirectory: URL, midi: MidiMonitor) {
        self.engine = engine
        self.uiDirectory = uiDirectory.standardizedFileURL
        self.midi = midi
    }

    func handle(_ r: HTTPRequest) -> HTTPResponse {
        if let refusal = refuse(r) { return refusal }
        if r.method == "GET", !r.path.hasPrefix("/api/") { return staticFile(r.path) }
        let body = r.method == "POST" ? (StateTree.parse(r.body) ?? NSMutableDictionary()) : NSMutableDictionary()
        switch (r.method, r.path) {
        case ("GET", "/api/state"):
            return .jsonData(engine.perform { engine.stateJSON() })
        case ("GET", "/api/meters"):
            return .jsonData(engine.perform { engine.metersJSON() })
        case ("GET", "/api/midi"):
            return .json(["ok": true, "events": midi.recent()])
        case ("GET", "/api/diagnostics"):
            return .json(["ok": true, "diagnostics": Diagnostics.collect()])
        case ("GET", "/api/presets/list"):
            return .json(["ok": true, "presets": engine.perform { engine.presetNames() }])
        case ("POST", "/api/state"):
            return .jsonData(engine.perform { engine.handle(action: body); return engine.stateJSON() })
        case ("POST", "/api/presets/save"):
            let name = body["name"] as? String ?? "Preset"
            return .json(["ok": engine.perform { engine.savePreset(name) }])
        case ("POST", "/api/presets/load"):
            let name = body["name"] as? String ?? ""
            return .jsonData(engine.perform { _ = engine.loadPreset(name); return engine.stateJSON() })
        case ("POST", "/api/presets/delete"):
            let name = body["name"] as? String ?? ""
            return .json(["ok": engine.perform { engine.deletePreset(name) }])
        case ("POST", "/api/init"):
            return .jsonData(engine.perform { engine.handle(action: ["action": "reset_defaults"]); return engine.stateJSON() })
        case ("POST", "/api/reenumerate"):
            engine.perform { engine.reenumerate() }
            return .json(["ok": true])
        case ("POST", "/api/open-ams"):
            DispatchQueue.main.async {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app"))
            }
            return .json(["ok": true])
        case ("POST", "/api/install-driver"):
            let engine = self.engine
            let started = engine.perform { () -> Bool in
                guard !engine.isInstallingDriver else { return false }
                engine.setDriverJob("running")
                return true
            }
            guard started else { return .error(409, "already installing") }
            DispatchQueue.main.async {
                let outcome = DriverInstaller.install()
                engine.perform {
                    switch outcome {
                    case .installed: engine.setDriverJob("installed", message: "Driver installed. Core Audio restarted; the Mbox reconnects in a few seconds.")
                    case .cancelled: engine.setDriverJob("cancelled", message: "Driver installation cancelled.")
                    case .failed(let message): engine.setDriverJob("failed", message: message)
                    }
                }
            }
            return .json(["ok": true, "started": true])
        case ("POST", "/api/reveal-data"):
            let dir = engine.store.directory
            DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([dir]) }
            return .json(["ok": true])
        case (_, let path) where path.hasPrefix("/api/"):
            return .error(r.method == "GET" || r.method == "POST" ? 404 : 405, "not found")
        default:
            return .error(405, "method not allowed")
        }
    }

    // MARK: - Request checks

    private func refuse(_ r: HTTPRequest) -> HTTPResponse? {
        // Host names this Mac (a rebinding attack would carry the attacker's domain); a browser request's Origin
        // must be that same host and port.
        guard let host = r.header("host")?.lowercased(),
              host.hasPrefix("127.0.0.1:") || host.hasPrefix("localhost:") else { return .error(403, "wrong host") }
        if let origin = r.header("origin"), origin.lowercased() != "http://\(host)" { return .error(403, "foreign origin") }
        if r.method == "POST", !(r.header("content-type") ?? "").lowercased().hasPrefix("application/json") {
            return .error(415, "JSON body required")
        }
        return nil
    }

    // MARK: - Static files

    private static let contentTypes = ["html": "text/html; charset=utf-8", "css": "text/css; charset=utf-8",
                                       "js": "text/javascript; charset=utf-8", "svg": "image/svg+xml",
                                       "png": "image/png", "json": "application/json", "ico": "image/x-icon"]

    private func staticFile(_ path: String) -> HTTPResponse {
        let relative = path == "/" ? "index.html" : String(path.dropFirst())
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./"))
        guard !relative.contains(".."), relative.unicodeScalars.allSatisfy(allowed.contains) else { return .error(404, "not found") }
        let url = uiDirectory.appendingPathComponent(relative).standardizedFileURL
        guard url.path.hasPrefix(uiDirectory.path + "/"), let data = try? Data(contentsOf: url),
              let type = APIRouter.contentTypes[url.pathExtension.lowercased()] else { return .error(404, "not found") }
        return HTTPResponse(status: 200, contentType: type, body: data)
    }
}
