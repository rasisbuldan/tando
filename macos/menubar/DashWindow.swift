// macos/menubar/DashWindow.swift: the dashboard window: one WKWebView window that is reused. The
// dashboard app (macos/dashapp) is its home; the menu bar app uses it only as a fallback when that
// app is not installed. It only ever shows 127.0.0.1:<port>; other web addresses open in the
// default browser. Finding and starting tando-dash is DashCore.swift; the decisions DashModel.swift.

import AppKit
import Foundation
import WebKit

// ---- the window ----------------------------------------------------------------------------------

final class DashWindowController: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    private let tando: String
    private var window: NSWindow?
    private var web: WKWebView?
    private var port = 0           // the only port the window may show
    private var opening = false
    private var failed = false     // the page in the window is a message, not the dashboard

    private let regular: Bool      // the dashboard app: a full main menu (app, Edit, View, Window)

    init(tando: String, regular: Bool = false) {
        self.tando = tando
        self.regular = regular
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

    // ---- the main menu: in the dashboard app it is the menu bar (app, Edit with copy and paste,
    // View, Window); in the menu bar app's fallback only the key equivalents work
    private func installMainMenu() {
        let main = NSMenu()
        let item = { (title: String, action: Selector?, key: String, target: AnyObject?, mods: NSEvent.ModifierFlags) -> NSMenuItem in
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.target = target
            i.keyEquivalentModifierMask = mods
            return i
        }
        let cmd = NSEvent.ModifierFlags.command
        let add = { (menu: NSMenu) in
            let i = NSMenuItem(); i.submenu = menu; main.addItem(i)
        }
        let name = regular ? "tando Dashboard" : "tando"
        let appMenu = NSMenu(title: name)
        if regular {
            appMenu.addItem(item("About \(name)", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "", nil, cmd))
            appMenu.addItem(.separator())
            appMenu.addItem(item("Hide \(name)", #selector(NSApplication.hide(_:)), "h", nil, cmd))
            appMenu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", nil, [.command, .option]))
            appMenu.addItem(.separator())
            appMenu.addItem(item("Quit \(name)", #selector(NSApplication.terminate(_:)), "q", nil, cmd))
        }
        add(appMenu)
        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Undo", Selector(("undo:")), "z", nil, cmd))
        edit.addItem(item("Redo", Selector(("redo:")), "z", nil, [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), "x", nil, cmd))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c", nil, cmd))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), "v", nil, cmd))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a", nil, cmd))
        add(edit)
        let view = NSMenu(title: "View")
        view.addItem(item("Reload", #selector(reload(_:)), "r", self, cmd))
        add(view)
        let win = NSMenu(title: "Window")
        win.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", nil, cmd))
        win.addItem(item("Close", #selector(closeWindow(_:)), "w", self, cmd))
        add(win)
        NSApp.mainMenu = main
        if regular { NSApp.windowsMenu = win }
    }
}
