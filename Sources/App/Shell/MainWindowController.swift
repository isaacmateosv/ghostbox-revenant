// The panel window: a WKWebView showing the local panel, with native dialogs and permission handling.

import AppKit
import WebKit

final class MainWindowController: NSObject, WKUIDelegate, WKNavigationDelegate {
    let window: NSWindow
    let webView: WKWebView
    private var url: URL?

    override init() {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 860),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        webView.uiDelegate = self
        webView.navigationDelegate = self
        window.title = "GhostBox Revenant GUI"
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true  // the title bar takes the panel's background colour
        window.backgroundColor = NSColor(red: 0.071, green: 0.075, blue: 0.086, alpha: 1)
        window.minSize = NSSize(width: 600, height: 420)
        window.contentView = webView
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("GhostBoxRevenantWindow")
    }

    func load(_ url: URL) {
        self.url = url
        webView.load(URLRequest(url: url))
    }

    func reload() { if let url { webView.load(URLRequest(url: url)) } }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Runs a panel command (window.mbox.command in Sources/UI/js/app.js), e.g. "setup" or "clearClips".
    func run(_ command: String) {
        guard command.allSatisfy({ $0.isLetter || $0.isNumber }) else { return }
        webView.evaluateJavaScript("window.mbox && window.mbox.command('\(command)')")
    }

    // MARK: - WKUIDelegate / WKNavigationDelegate

    private func isPanel(_ url: URL?) -> Bool { url?.host == "127.0.0.1" || url?.host == "localhost" }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(origin.host == "127.0.0.1" ? .grant : .deny)  // microphone fallback for the tuner
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { NSWorkspace.shared.open(url) }
        return nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = action.request.url, url.scheme?.hasPrefix("http") == true, !isPanel(url) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.beginSheetModal(for: window) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = prompt
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }
}
