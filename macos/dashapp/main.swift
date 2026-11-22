// macos/dashapp/main.swift: "tando Dashboard.app", the dashboard as its own regular macOS app (Dock
// icon, Cmd+Tab, Spotlight, standard menus). A thin WKWebView wrapper on the system WebKit: the
// window logic is DashWindow.swift and the tando-dash handling DashCore.swift, shared with the
// menu bar app. It does nothing while its window is closed (the page is blanked, no timers).
// Usage: tando-dashboard [--tando PATH]   (the tando to run: default from menubar.conf, else PATH)

import AppKit
import Foundation

func confTando() -> String? {
    let f = dashConfigDir() + "/menubar.conf"
    guard let t = try? String(contentsOfFile: f, encoding: .utf8) else { return nil }
    for l in t.split(separator: "\n").reversed() where l.hasPrefix("tando=") { return String(l.dropFirst(6)) }
    return nil
}

var tandoPath = ""
let argv = CommandLine.arguments
if let i = argv.firstIndex(of: "--tando"), i + 1 < argv.count { tandoPath = argv[i + 1] }
else if let t = confTando(), FileManager.default.isExecutableFile(atPath: t) { tandoPath = t }

/// The Dock icon without an .icns: the dashboard's mark (a rounded square with a T) drawn once.
func appIcon() -> NSImage {
    NSImage(size: NSSize(width: 512, height: 512), flipped: false) { r in
        let box = r.insetBy(dx: 40, dy: 40)
        NSColor(calibratedWhite: 0.1, alpha: 1).setFill()
        NSBezierPath(roundedRect: box, xRadius: 100, yRadius: 100).fill()
        NSColor.white.setStroke()
        let t = NSBezierPath(); t.lineWidth = 48; t.lineCapStyle = .round
        t.move(to: NSPoint(x: 160, y: 360)); t.line(to: NSPoint(x: 352, y: 360))
        t.move(to: NSPoint(x: 256, y: 360)); t.line(to: NSPoint(x: 256, y: 150))
        t.stroke()
        return true
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let dash = DashWindowController(tando: tandoPath, regular: true)
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.applicationIconImage = appIcon()
        dash.open()
    }
    /// Dock click, Spotlight or `open` while running with no window: show it again
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { dash.open() }
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
