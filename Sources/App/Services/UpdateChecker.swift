// Looks for a newer release of this project on GitHub and, when the owner asks, downloads its installer package,
// checks it against the release's SHA256SUMS.txt and opens it in Installer. Nothing is installed silently.
//
// Network: the release list from api.github.com (automatically at most once a day, see Setup > Advanced) and, when
// asked, the release's own downloads (github.com, redirected to GitHub's asset hosts). Nothing about the user or
// the Mbox is sent. The list and the time of the last check are kept in update_check.json in the settings folder.

import CryptoKit
import Foundation

/// The network side; the tests swap in a fake.
protocol UpdateTransport {
    func fetch(_ url: URL, completion: @escaping (Result<Data, Error>) -> Void)
    /// Downloads to a temporary file that the caller moves or deletes.
    func download(_ url: URL, completion: @escaping (Result<URL, Error>) -> Void)
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

final class UpdateChecker {
    /// Setup > Advanced, read at every decision: automatic checks on/off, release candidates auto/on/off.
    var settings: () -> (autoCheck: Bool, prereleases: String) = { (true, "auto") }
    /// What the panel shows (info.update), published on every change.
    var onChange: ([String: Any]) -> Void = { _ in }
    /// Opens the verified package (Installer.app).
    var open: (URL) -> Void = { _ in }

    let current: SemVer?  // nil for a build without a release version: nothing is offered
    private let transport: UpdateTransport
    private let stateFile: URL
    private let downloads: URL
    private let queue = DispatchQueue(label: "ghostbox.updates")
    private var releases: [Release] = []
    private var lastCheck: Date?, lastAttempt: Date?
    private var offered: Release?
    private var phase = "idle"  // idle | checking | current | available | downloading | ready | error
    private var message = "", messageIsError = false
    private var file: URL?
    private var id = 0          // bumped with each message worth a toast
    private var timer: DispatchSourceTimer?

    init(currentVersion: String, transport: UpdateTransport, stateFile: URL, downloads: URL) {
        current = SemVer(currentVersion)
        self.transport = transport
        self.stateFile = stateFile
        self.downloads = downloads
        loadState()
    }

    /// Publishes what the last check found, then checks automatically: shortly after launch and every half hour
    /// whenever a check is due.
    func start() {
        queue.async { [self] in
            evaluate()
            publish()
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 15, repeating: 1800)
            t.setEventHandler { [weak self] in self?.check(force: false) }
            t.resume()
            timer = t
        }
    }

    /// Setup > Advanced changed: pick the offer again from the list already fetched, and check if one is now due.
    func settingsChanged() {
        queue.async { [self] in
            evaluate()
            publish()
        }
        check(force: false)
    }

    /// Looks for a newer release: always when asked (About > Check for Updates), otherwise only when automatic
    /// checks are on and one is due.
    func check(force: Bool) {
        queue.async { [self] in
            guard phase != "checking", phase != "downloading" else { return }
            if !force {
                guard settings().autoCheck, Releases.isDue(lastCheck: lastCheck, lastAttempt: lastAttempt, now: Date()) else { return }
            }
            let previous = phase
            lastAttempt = Date()
            if force {
                phase = "checking"
                (message, messageIsError) = ("", false)
                publish()
            }
            transport.fetch(Releases.listURL) { result in
                self.queue.async { self.finishCheck(result, force: force, previous: previous) }
            }
        }
    }

    /// Downloads the offered package and its checksum list, verifies the package and opens it in Installer.
    func download() {
        queue.async { [self] in
            guard phase != "checking", phase != "downloading" else { return }
            guard let release = offered, let package = release.package else { return fail("There is no update to download.") }
            guard let sums = release.checksums else {
                return fail("Release \(release.version) has no SHA256SUMS.txt, so its package cannot be checked. Download it from the release page instead.")
            }
            phase = "downloading"
            (message, messageIsError) = ("", false)
            publish()
            transport.fetch(sums.url) { result in
                self.queue.async {
                    guard case .success(let data) = result, let list = String(data: data, encoding: .utf8),
                          let expected = Releases.checksum(for: package.name, in: list) else {
                        return self.fail("Could not read the checksum list of release \(release.version).")
                    }
                    self.transport.download(package.url) { result in
                        self.queue.async { self.finishDownload(result, expected: expected, release: release) }
                    }
                }
            }
        }
    }

    /// Waits for queued work, transport replies included (tests).
    func waitUntilIdle() { for _ in 0..<6 { queue.sync {} } }

    // MARK: - Steps (on `queue`)

    private func finishCheck(_ result: Result<Data, Error>, force: Bool, previous: String) {
        if phase == "checking" { phase = previous }
        switch result {
        case .success(let data):
            guard let list = Releases.parse(data) else { return checkFailed("GitHub sent a reply this app does not understand.", force: force) }
            releases = list
            lastCheck = Date()
            saveState(data)
        case .failure(let error):
            return checkFailed(error.localizedDescription, force: force)
        }
        guard phase != "downloading" else { return }  // a download started meanwhile publishes when it ends
        if phase == "error" { phase = "idle" }
        evaluate()
        if force {
            say(offered.map { "GhostBox Revenant \($0.version) is available." }
                ?? "GhostBox Revenant \(current?.description ?? "") is up to date.", error: false)
        }
        publish()
    }

    /// Automatic checks fail quietly and try again an hour later; a check the owner asked for reports why.
    private func checkFailed(_ reason: String, force: Bool) {
        NSLog("GhostBox Revenant: update check failed: %@", reason)
        guard force else { return }
        evaluate()
        if offered == nil { phase = "error" }
        say("Could not check for updates: \(reason)", error: true)
        publish()
    }

    private func finishDownload(_ result: Result<URL, Error>, expected: String, release: Release) {
        let fm = FileManager.default
        let tmp: URL
        switch result {
        case .success(let url): tmp = url
        case .failure(let error): return fail("The download failed: \(error.localizedDescription)")
        }
        defer { try? fm.removeItem(at: tmp) }
        guard let data = try? Data(contentsOf: tmp) else { return fail("The downloaded package could not be read.") }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == expected else {
            return fail("The download does not match the release's SHA256SUMS.txt, so it was deleted.")
        }
        let target = downloads.appendingPathComponent("GhostBoxRevenant-\(release.version).pkg")
        do {
            try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
            for old in (try? fm.contentsOfDirectory(at: downloads, includingPropertiesForKeys: nil)) ?? [] where old.pathExtension == "pkg" {
                try? fm.removeItem(at: old)
            }
            try data.write(to: target, options: .atomic)
        } catch {
            return fail("The package could not be saved: \(error.localizedDescription)")
        }
        file = target
        phase = "ready"
        say("The \(release.version) installer is open. Pause any audio before you install: it restarts Core Audio.", error: false)
        publish()
        open(target)
    }

    /// A download problem: the offer stays, the reason is shown.
    private func fail(_ reason: String) {
        NSLog("GhostBox Revenant: update: %@", reason)
        phase = offered != nil ? "available" : "error"
        say(reason, error: true)
        publish()
    }

    /// Picks the release to offer from the list already fetched (no network).
    private func evaluate() {
        guard phase != "checking", phase != "downloading" else { return }
        let next = current.flatMap { cur in
            Releases.offer(releases, current: cur, includePrereleases: Releases.includesPrereleases(settings().prereleases, current: cur))
        }
        if phase == "ready", let o = offered, next?.version == o.version { return }  // downloaded and open in Installer
        offered = next
        if next != nil { phase = "available" }
        else if phase != "error" { phase = lastCheck == nil ? "idle" : "current" }
    }

    private func say(_ text: String, error: Bool) {
        message = text
        messageIsError = error
        id += 1
    }

    private func publish() {
        var info: [String: Any] = ["state": phase, "current": current?.description ?? "", "message": message,
                                   "error": messageIsError, "id": id]
        if let lastCheck { info["checked_at"] = Int(lastCheck.timeIntervalSince1970) }
        if let r = offered {
            info["latest"] = r.version.description
            info["prerelease"] = r.isPrerelease
            info["page"] = r.page.absoluteString
            info["published"] = r.published
            info["notes"] = r.notes
            info["size"] = r.package?.size ?? 0
        }
        if let file, phase == "ready" { info["file"] = file.path }
        onChange(info)
    }

    // MARK: - update_check.json

    private func loadState() {
        guard let data = try? Data(contentsOf: stateFile),
              let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if let t = saved["checked_at"] as? NSNumber { lastCheck = Date(timeIntervalSince1970: t.doubleValue) }
        if let list = saved["releases"], let raw = try? JSONSerialization.data(withJSONObject: list) {
            releases = Releases.parse(raw) ?? []
        }
    }

    /// Keeps only what Releases.parse reads.
    private func saveState(_ reply: Data) {
        guard let list = (try? JSONSerialization.jsonObject(with: reply)) as? [[String: Any]] else { return }
        let fields = ["tag_name", "draft", "prerelease", "html_url", "body", "published_at"]
        let kept: [[String: Any]] = list.map { r in
            var out = r.filter { fields.contains($0.key) }
            out["assets"] = (r["assets"] as? [[String: Any]] ?? []).map { $0.filter { ["name", "browser_download_url", "size"].contains($0.key) } }
            return out
        }
        let saved: [String: Any] = ["checked_at": Int(Date().timeIntervalSince1970), "releases": kept]
        if let data = try? JSONSerialization.data(withJSONObject: saved) { try? data.write(to: stateFile, options: .atomic) }
    }
}

/// URLSession against GitHub: ephemeral (no cookies, no cache on disk), HTTPS to GitHub's own hosts only, redirects
/// included.
final class GitHubTransport: NSObject, UpdateTransport, URLSessionTaskDelegate {
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        config.httpAdditionalHeaders = ["User-Agent": "GhostBoxRevenant/\(AppInfo.version)"]
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    static func isAllowed(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "api.github.com" || host == "github.com" || host.hasSuffix(".githubusercontent.com")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(GitHubTransport.isAllowed(request.url) ? request : nil)
    }

    func fetch(_ url: URL, completion: @escaping (Result<Data, Error>) -> Void) {
        guard GitHubTransport.isAllowed(url) else { return completion(.failure(UpdateError("not a GitHub address"))) }
        session.dataTask(with: GitHubTransport.request(url)) { data, response, error in
            if let problem = GitHubTransport.problem(response, error) { return completion(.failure(problem)) }
            completion(.success(data ?? Data()))
        }.resume()
    }

    func download(_ url: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        guard GitHubTransport.isAllowed(url) else { return completion(.failure(UpdateError("not a GitHub address"))) }
        session.downloadTask(with: GitHubTransport.request(url)) { tmp, response, error in
            if let problem = GitHubTransport.problem(response, error) { return completion(.failure(problem)) }
            guard let tmp else { return completion(.failure(UpdateError("no file arrived"))) }
            // URLSession deletes its file when this handler returns
            let kept = FileManager.default.temporaryDirectory.appendingPathComponent("ghostbox-update-\(UUID().uuidString).pkg")
            do {
                try FileManager.default.moveItem(at: tmp, to: kept)
                completion(.success(kept))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    private static func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        if url.host == "api.github.com" {
            r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        }
        return r
    }

    private static func problem(_ response: URLResponse?, _ error: Error?) -> Error? {
        if let error { return error }
        guard let http = response as? HTTPURLResponse, isAllowed(http.url) else { return UpdateError("no reply from GitHub") }
        switch http.statusCode {
        case 200..<300: return nil
        case 403, 429: return UpdateError("GitHub's rate limit was reached; try again in an hour")
        default: return UpdateError("GitHub answered with status \(http.statusCode)")
        }
    }
}
