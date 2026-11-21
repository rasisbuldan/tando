// macos/menubar/DashWindow.swift: the "Open dashboard" window. It finds tando-dash (the add-on:
// `tando addon install dashboard`), starts it when dash.lock shows none running, asks it for a fresh
// one-time link (POST /api/newcode with the lock's key, as a second tando-dash does) and shows
// the dashboard in one WKWebView window that is reused. The window only ever shows
// 127.0.0.1:<port>; other web addresses open in the default browser. The decisions are in
// DashModel.swift (pure, tested); this file does the process, network and window work.

import AppKit
import Foundation
import WebKit

/// $HOME when set (a LaunchAgent has it; the tests point it at a temp directory), else the account's
func dashHome() -> String {
    ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
}
func dashConfigDir() -> String {
    ProcessInfo.processInfo.environment["TANDO_CONFIG_DIR"] ?? (dashHome() + "/.config/tando")
}
func dashLockFile() -> DashLock? {
    DashLock.parse(FileManager.default.contents(atPath: dashConfigDir() + "/dash.lock"))
}
func dashBinary() -> String? {
    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    return findDash(home: dashHome(), path: path) { FileManager.default.isExecutableFile(atPath: $0) }
}

enum DashOutcome {
    case ready(URL, DashLock)   // the one-time link to load
    case notInstalled
    case failed(String)
}

/// Blocking (up to about 15 s when tando-dash has to start): call it off the main thread.
func resolveDash(tando: String) -> DashOutcome {
    guard let bin = dashBinary() else { return .notInstalled }
    var lock = dashLockFile()
    switch decideDash(installed: true, lock: lock, alive: pidAlive) {
    case .notInstalled:
        return .notInstalled
    case .start:
        if let why = startDash(bin, tando: tando) { return .failed(why) }
        lock = dashLockFile()
    case .askCode(let l):
        lock = l
    }
    guard let l = lock else { return .failed("tando-dash did not say where it listens (dash.lock)") }
    switch fetchCode(l) {
    case .failure(let e): return .failed(e.why)
    case .success(let code):
        guard let u = dashOpenURL(l, code: code) else { return .failed("tando-dash sent a link the app does not accept") }
        return .ready(u, l)
    }
}

/// Starts `tando-dash --no-open` detached (it stops by itself after its idle time) and waits for
/// dash.lock to name a live process. nil on success, else one line for the window.
func startDash(_ bin: String, tando: String) -> String? {
    let log = dashHome() + "/Library/Logs/tando-dash.log"
    try? FileManager.default.createDirectory(atPath: (log as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: log, contents: nil, attributes: [.posixPermissions: 0o600])
    let p = Process()
    p.executableURL = URL(fileURLWithPath: bin)
    p.arguments = ["--no-open"]
    var env = ProcessInfo.processInfo.environment
    if !tando.isEmpty { env["TANDO_DASH_TANDO"] = tando }
    let dir = (tando as NSString).deletingLastPathComponent
    env["PATH"] = [dir, env["PATH"] ?? "", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        .filter { !$0.isEmpty }.joined(separator: ":")
    p.environment = env
    p.standardInput = FileHandle.nullDevice
    if let h = FileHandle(forWritingAtPath: log) { p.standardOutput = h; p.standardError = h }
    do { try p.run() } catch { return "could not run \(bin): \(error.localizedDescription)" }
    let end = Date().addingTimeInterval(15)
    var exitedAt: Date? = nil
    while Date() < end {
        if let l = dashLockFile(), pidAlive(l.pid) { return nil }
        if !p.isRunning {
            // a second tando-dash exits at once after reusing the first: give the lock a moment
            if exitedAt == nil { exitedAt = Date() }
            if Date().timeIntervalSince(exitedAt!) > 1 {
                let text = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
                let last = text.split(separator: "\n").last.map(String.init) ?? ""
                return last.isEmpty ? "tando-dash stopped (exit \(p.terminationStatus))" : last
            }
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    return "tando-dash did not start within 15 s (see ~/Library/Logs/tando-dash.log)"
}

func fetchCode(_ l: DashLock) -> Result<String, CheckError> {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.timeoutIntervalForRequest = 5
    cfg.httpCookieStorage = nil
    cfg.urlCache = nil
    let session = URLSession(configuration: cfg)
    defer { session.invalidateAndCancel() }
    var r = URLRequest(url: l.newcodeURL)
    r.httpMethod = "POST"
    r.setValue("application/json", forHTTPHeaderField: "Content-Type")   // the server insists on it for every POST
    r.setValue(l.key, forHTTPHeaderField: "X-Tando-Dash-Key")
    r.setValue("tando-menubar", forHTTPHeaderField: "User-Agent")
    let sem = DispatchSemaphore(value: 0)
    var out: Result<String, CheckError> = .failure(CheckError(why: "tando-dash did not answer"))
    session.dataTask(with: r) { data, resp, err in
        if let http = resp as? HTTPURLResponse {
            if http.statusCode == 200, let c = parseNewCode(data) { out = .success(c) }
            else { out = .failure(CheckError(why: "tando-dash refused the request (HTTP \(http.statusCode))")) }
        } else if let e = err {
            out = .failure(CheckError(why: "tando-dash (pid \(l.pid)) does not answer on port \(l.port): \(e.localizedDescription)"))
        }
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + 8)
    return out
}

// ---- the window ----------------------------------------------------------------------------------

final class DashWindowController: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    private let tando: String
    private var window: NSWindow?
    private var web: WKWebView?
    private var port = 0           // the only port the window may show
    private var opening = false
    private var failed = false     // the page in the window is a message, not the dashboard

    init(tando: String) {
        self.tando = tando
        super.init()
        installMainMenu()
    }

    /// The menu item: "Open dashboard" (or the install hint when the add-on is not there).
    func open() {
        guard dashBinary() != nil else { showInstallHint(); return }
        let w = ensureWindow()
        show(w)
        if opening { return }
        // already showing a live dashboard: bring it to the front, nothing else
        if !failed, port != 0, let l = dashLockFile(), l.port == port, pidAlive(l.pid) { return }
        start()
    }

    private func start() {
        opening = true
        failed = false
        message("Starting the dashboard…", detail: "")
        let t = tando
        DispatchQueue.global(qos: .userInitiated).async {
            let r = resolveDash(tando: t)
            DispatchQueue.main.async {
                self.opening = false
                switch r {
                case .ready(let url, let l):
                    self.port = l.port
                    self.web?.load(URLRequest(url: url))
                case .notInstalled:
                    self.window?.orderOut(nil)
                    self.showInstallHint()
                case .failed(let why):
                    self.message("The dashboard did not open", detail: why + "\nPress \u{2318}R to try again.", isError: true)
                }
            }
        }
    }

    private func ensureWindow() -> NSWindow {
        if let w = window { return w }
        let cfg = WKWebViewConfiguration()
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.navigationDelegate = self
        v.uiDelegate = self
        v.allowsBackForwardNavigationGestures = false
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "tando dashboard"
        w.contentView = v
        w.contentMinSize = NSSize(width: 900, height: 600)
        w.isReleasedWhenClosed = false
        w.delegate = self
        if !w.setFrameUsingName("TandoDashboard") { w.center() }   // remembers size and place
        w.setFrameAutosaveName("TandoDashboard")
        window = w; web = v
        return w
    }

    private func show(_ w: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    /// Closing the window ends the page (no polling in a window nobody sees); the app stays.
    func windowWillClose(_ notification: Notification) {
        port = 0
        failed = false
        web?.load(URLRequest(url: URL(string: "about:blank")!))
    }

    @objc func reload(_ sender: Any?) {
        guard window?.isVisible == true else { return }
        if failed || port == 0 || web?.url == nil || web?.url?.absoluteString == "about:blank" { start(); return }
        web?.reload()
    }

    @objc func closeWindow(_ sender: Any?) { window?.performClose(nil) }

    // ---- messages in the window
    private func message(_ title: String, detail: String, isError: Bool = false) {
        failed = isError
        let esc = { (s: String) in s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;") }
        let html = """
        <!doctype html><meta charset="utf-8"><meta name="color-scheme" content="light dark">
        <body style="font:15px -apple-system,sans-serif;display:flex;height:90vh;align-items:center;justify-content:center;text-align:center">
        <div><h2 style="font-weight:600">\(esc(title))</h2><p style="opacity:.7;white-space:pre-line">\(esc(detail))</p></div>
        """
        if isError { port = 0 }
        web?.loadHTMLString(html, baseURL: nil)
    }

    private func showInstallHint() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "The dashboard is not installed"
        a.informativeText = "Run this in Terminal, then choose Open dashboard again:\n\n\(dashInstallCommand)"
        a.addButton(withTitle: "Copy command")
        a.addButton(withTitle: "OK")
        if a.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(dashInstallCommand, forType: .string)
        }
    }

    // ---- nothing leaves 127.0.0.1:<port>
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = action.request.url
        switch navPolicy(url, port: port) {
        case .allow: decisionHandler(.allow)
        case .external:
            if let u = url { NSWorkspace.shared.open(u) }
            decisionHandler(.cancel)
        case .block: decisionHandler(.cancel)
        }
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // target=_blank and window.open: the default browser, or this window for our own address
        guard let u = action.request.url else { return nil }
        switch navPolicy(u, port: port) {
        case .allow: webView.load(action.request)
        case .external: NSWorkspace.shared.open(u)
        case .block: break
        }
        return nil
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }
    private func navigationFailed(_ error: Error) {
        let e = error as NSError
        if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return }   // our own cancel of an external link
        if e.domain == "WebKitErrorDomain" && e.code == 102 { return }                // frame load interrupted
        message("The dashboard is not reachable", detail: "\(e.localizedDescription)\nPress \u{2318}R to start it again.", isError: true)
    }

    // ---- key equivalents: an accessory app has no menu bar, but a main menu still handles keys
    private func installMainMenu() {
        let main = NSMenu()
        let item = { (title: String, action: Selector?, key: String, target: AnyObject?) -> NSMenuItem in
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.target = target
            return i
        }
        let appItem = NSMenuItem(); appItem.submenu = NSMenu(title: "tando")
        main.addItem(appItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), "x", nil))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c", nil))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), "v", nil))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a", nil))
        let editItem = NSMenuItem(); editItem.submenu = edit
        main.addItem(editItem)
        let view = NSMenu(title: "View")
        view.addItem(item("Reload", #selector(reload(_:)), "r", self))
        let viewItem = NSMenuItem(); viewItem.submenu = view
        main.addItem(viewItem)
        let win = NSMenu(title: "Window")
        win.addItem(item("Close", #selector(closeWindow(_:)), "w", self))
        let winItem = NSMenuItem(); winItem.submenu = win
        main.addItem(winItem)
        NSApp.mainMenu = main
    }
}
