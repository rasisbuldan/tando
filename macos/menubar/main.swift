// macos/menubar/main.swift: the tando menu bar app (built by `tando menubar install`, see
// docs/COMMANDS.md). Every check runs the tando CLI the user already set up (`tando ls --all
// --json`: one ssh connection per server), then requests each running app's link from the laptop.
// It stores no credentials, opens no listening socket, and runs at most one check at a time.
//
//   tando-menubar                          the menu bar app (the LaunchAgent starts it this way)
//   tando-menubar --once [--checks N]      run N checks (default 1) and print the menu as text
//   tando-menubar --dash-url               what "Open dashboard" does, without the window: starts
//                                          tando-dash if needed and prints the one-time link
//   --tando PATH  --interval SECONDS  --timeout SECONDS   override menubar.conf
//
// Settings: $TANDO_CONFIG_DIR/menubar.conf (default ~/.config/tando/menubar.conf), key=value lines:
//   tando=/path/to/bin/tando   interval=60   timeout=45   notify=auto|osascript|off

import AppKit
import Foundation
import Network
import UserNotifications

// ---- settings ------------------------------------------------------------------------------------

struct Settings {
    var tando = ""
    var interval: Double = 60
    var timeout: Double = 45
    var notify = "auto"
    var once = false
    var dashURL = false
    var checks = 1

    static func load() -> Settings {
        var s = Settings()
        let env = ProcessInfo.processInfo.environment
        let dir = env["TANDO_CONFIG_DIR"] ?? (NSHomeDirectory() + "/.config/tando")
        if let text = try? String(contentsOfFile: dir + "/menubar.conf", encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let l = line.trimmingCharacters(in: .whitespaces)
                guard !l.hasPrefix("#"), let eq = l.firstIndex(of: "=") else { continue }
                s.set(String(l[..<eq]).trimmingCharacters(in: .whitespaces), String(l[l.index(after: eq)...]).trimmingCharacters(in: .whitespaces))
            }
        }
        var args = Array(CommandLine.arguments.dropFirst())
        while !args.isEmpty {
            let a = args.removeFirst()
            switch a {
            case "--once": s.once = true
            case "--dash-url": s.dashURL = true
            case "--tando", "--interval", "--timeout", "--checks", "--notify":
                guard !args.isEmpty else { fail("\(a) needs a value") }
                s.set(String(a.dropFirst(2)), args.removeFirst())
            default: fail("unknown argument: \(a)")
            }
        }
        if s.tando.isEmpty {   // no setting: the shell's PATH is not ours under launchd; try the usual places
            for p in [NSHomeDirectory() + "/.local/bin/tando", "/usr/local/bin/tando", "/opt/homebrew/bin/tando"]
            where FileManager.default.isExecutableFile(atPath: p) { s.tando = p; break }
        }
        return s
    }
    mutating func set(_ k: String, _ v: String) {
        switch k {
        case "tando": tando = v
        case "interval": if let n = Double(v), n >= 10 { interval = n }
        case "timeout": if let n = Double(v), n >= 5 { timeout = n }
        case "checks": if let n = Int(v), n >= 1 { checks = n }
        case "notify": notify = v
        default: break
        }
    }
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write("tando-menubar: \(msg)\n".data(using: .utf8)!)
    exit(2)
}

// ---- running tando -------------------------------------------------------------------------------

/// Runs tando with args, at most `timeout` seconds; stdout on success, a short reason otherwise.
/// Blocking: call it off the main thread.
func runTando(_ path: String, _ args: [String], timeout: Double) -> Result<Data, CheckError> {
    guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else {
        return .failure(CheckError(why: "tando not found (run tando menubar install again)"))
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    var env = ProcessInfo.processInfo.environment
    // a LaunchAgent gets a minimal PATH: add tando's own directory and the usual ones (ssh, rsync)
    let dir = (path as NSString).deletingLastPathComponent
    env["PATH"] = [dir, env["PATH"] ?? "", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        .filter { !$0.isEmpty }.joined(separator: ":")
    env["TANDO_NO_BROWSER"] = "1"
    env["NO_COLOR"] = "1"
    p.environment = env
    p.standardInput = FileHandle.nullDevice
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    let lock = NSLock()
    var data = Data(), errData = Data()
    let eof = DispatchGroup()
    for (pipe, isErr) in [(out, false), (err, true)] {
        eof.enter()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; eof.leave(); return }
            lock.lock(); if isErr { errData.append(d) } else { data.append(d) }; lock.unlock()
        }
    }
    let done = DispatchSemaphore(value: 0)
    p.terminationHandler = { _ in done.signal() }
    do { try p.run() } catch { return .failure(CheckError(why: "could not run \(path): \(error.localizedDescription)")) }
    if done.wait(timeout: .now() + timeout) == .timedOut {
        p.terminate()
        _ = done.wait(timeout: .now() + 3)
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        return .failure(CheckError(why: "tando did not answer within \(Int(timeout)) s"))
    }
    _ = eof.wait(timeout: .now() + 3)   // the rest of the output (a child that keeps the pipe: give up)
    lock.lock(); defer { lock.unlock() }
    if p.terminationStatus != 0 {
        let msg = String(decoding: errData, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
        return .failure(CheckError(why: msg.isEmpty ? "tando exited with \(p.terminationStatus)" : msg))
    }
    return .success(data)
}

/// Requests each link once (GET, short timeout, nothing stored). Answered = any HTTP status below 500.
func probe(_ urls: [URL], timeout: Double = 8) -> [String: Bool] {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.timeoutIntervalForRequest = timeout
    cfg.timeoutIntervalForResource = timeout
    cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
    cfg.httpCookieStorage = nil
    cfg.urlCache = nil
    let session = URLSession(configuration: cfg)
    let lock = NSLock()
    var res: [String: Bool] = [:]
    let g = DispatchGroup()
    for u in urls {
        g.enter()
        var r = URLRequest(url: u)
        r.httpMethod = "GET"
        r.setValue("tando-menubar", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: r) { _, resp, _ in
            let ok = (resp as? HTTPURLResponse).map { $0.statusCode < 500 } ?? false
            lock.lock(); res[u.absoluteString] = ok; lock.unlock()
            g.leave()
        }.resume()
    }
    _ = g.wait(timeout: .now() + timeout + 2)
    session.invalidateAndCancel()
    lock.lock(); defer { lock.unlock() }
    for u in urls where res[u.absoluteString] == nil { res[u.absoluteString] = false }
    return res
}

/// Where the last check got its list: "cache" (tando-dash's ls-all.json, fresh) or "tando".
var lastSource = "tando"

/// tando-dash writes cache/ls-all.json at each overview refresh; when it is fresher than this
/// app's own interval, use it instead of running `tando ls --all --json` (one ssh per server).
func freshCache(interval: Double) -> LsAll? {
    let path = dashConfigDir() + "/cache/ls-all.json"
    let mod = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    guard cacheFresh(modified: mod, now: Date(), interval: interval),
          let d = FileManager.default.contents(atPath: path) else { return nil }
    return parseLsAll(d)
}

/// One whole check: the list (the shared cache or tando), then the links. Returns the new snapshot and the notifications.
func check(_ s: Settings, _ m: Monitor) -> (Snapshot, [Note]) {
    if let ls = freshCache(interval: s.interval) {
        lastSource = "cache"
        return m.apply(ls, probes: probe(m.linksToProbe(ls)))
    }
    lastSource = "tando"
    switch runTando(s.tando, ["ls", "--all", "--json"], timeout: s.timeout) {
    case .failure(let e):
        return (m.failed(e.why), [])
    case .success(let data):
        guard let ls = parseLsAll(data) else {
            return (m.failed("tando ls --all --json gave no JSON (tando host add a server first?)"), [])
        }
        return m.apply(ls, probes: probe(m.linksToProbe(ls)))
    }
}

// ---- --once: no UI, the menu as text -------------------------------------------------------------

let settings = Settings.load()
if settings.dashURL {
    switch resolveDash(tando: settings.tando) {
    case .ready(let url, _): print("dash: open \(url.absoluteString)"); exit(0)
    case .notInstalled: print("dash: not installed (\(dashInstallCommand))"); exit(1)
    case .failed(let why): print("dash: failed: \(why)"); exit(1)
    }
}
if settings.once {
    let m = Monitor()
    var last = Snapshot()
    for i in 1...settings.checks {
        let (snap, notes) = check(settings, m)
        for n in notes { print("notify: \(n.title): \(n.body.replacingOccurrences(of: "\n", with: " / "))") }
        last = snap
        if i < settings.checks { Thread.sleep(forTimeInterval: 0.2) }
    }
    print("source: \(lastSource)")
    print(describe(last))
    exit(last.grey == nil ? 0 : 1)
}

// ---- notifications -------------------------------------------------------------------------------

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private var useCenter = false
    private let mode: String
    init(mode: String) {
        self.mode = mode
        super.init()
        guard mode == "auto", Bundle.main.bundleIdentifier != nil else { return }
        waiting = []   // notes of the first check wait for the answer to the permission request
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        c.requestAuthorization(options: [.alert, .sound]) { granted, error in
            // granted: the system's notifications. An error (e.g. a bundle the system will not
            // register) falls back to osascript; a "no" from the user is respected (nothing shown).
            DispatchQueue.main.async {
                self.useCenter = granted
                self.denied = !granted && error == nil
                let w = self.waiting ?? []
                self.waiting = nil
                w.forEach(self.post)
            }
        }
    }
    private var denied = false
    private var waiting: [Note]? = nil
    func post(_ n: Note) {
        if mode == "off" || denied { return }
        if waiting != nil { waiting?.append(n); return }
        if useCenter {
            let c = UNMutableNotificationContent()
            c.title = n.title
            c.body = n.body
            c.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
            return
        }
        // fallback: AppleScript's notification (shown as from Script Editor)
        let esc = { (t: String) in t.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "display notification \"\(esc(n.body))\" with title \"\(esc(n.title))\""]
        try? p.run()
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
}

// ---- the menu bar item ---------------------------------------------------------------------------

final class Controller: NSObject, NSMenuDelegate {
    let s: Settings
    let monitor = Monitor()
    let notifier: Notifier
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var snap = Snapshot()
    var running = false
    var offline = false
    var timer: Timer?
    lazy var dash = DashWindowController(tando: s.tando)
    let path = NWPathMonitor()
    let tf: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()

    init(_ s: Settings) {
        self.s = s
        notifier = Notifier(mode: s.notify)
        super.init()
        render()
        path.pathUpdateHandler = { [weak self] p in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let was = self.offline
                self.offline = p.status != .satisfied
                if was && !self.offline { self.refresh() }   // back online: check at once
            }
        }
        path.start(queue: .global(qos: .utility))
        timer = Timer.scheduledTimer(withTimeInterval: s.interval, repeats: true) { [weak self] _ in self?.refresh() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self?.refresh() }   // the network comes back a little later
        }
        refresh()
    }

    @objc func refresh() {
        if running { return }   // never two checks at once
        if offline {
            snap = monitor.failed("the laptop is offline: nothing checked")
            render(); return
        }
        running = true
        render()
        let s = self.s, m = monitor
        DispatchQueue.global(qos: .utility).async {
            let (snap, notes) = check(s, m)
            DispatchQueue.main.async {
                self.running = false
                self.snap = snap
                notes.forEach(self.notifier.post)
                self.render()
            }
        }
    }

    func render() {
        if let b = item.button {
            let img = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "tando")
            img?.isTemplate = true
            b.image = img
            b.imagePosition = .imageLeft
            b.appearsDisabled = snap.look == .grey
            switch snap.look {
            case .problems(let n):
                let a = NSTextAttachment()
                a.image = badgeImage(n)
                b.attributedTitle = NSAttributedString(attachment: a)
                b.toolTip = "tando: \(n) problem\(n == 1 ? "" : "s")"
            case .grey:
                b.title = ""
                b.toolTip = "tando: cannot check (\(snap.grey ?? ""))"
            case .ok:
                b.title = ""
                b.toolTip = snap.checkedAt == nil ? "tando: checking" : "tando: all well"
            }
        }
        item.menu = buildMenu()
        item.menu?.delegate = self
    }

    /// The add-on may be installed (or removed) while the menu bar app runs: the first row follows.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if let d = menu.items.first(where: { $0.action == #selector(openDashboard) }) {
            d.title = dashBinary() == nil ? "Install dashboard…" : "Open dashboard"
        }
    }

    func badgeImage(_ n: Int) -> NSImage {
        let text = n > 99 ? "99+" : "\(n)"
        let font = NSFont.systemFont(ofSize: 10, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let ts = (text as NSString).size(withAttributes: attrs)
        let h: CGFloat = 15, w = max(h, ts.width + 8)
        return NSImage(size: NSSize(width: w, height: h), flipped: false) { r in
            NSColor.systemRed.setFill()
            NSBezierPath(roundedRect: r, xRadius: h / 2, yRadius: h / 2).fill()
            (text as NSString).draw(at: NSPoint(x: (w - ts.width) / 2, y: (h - ts.height) / 2), withAttributes: attrs)
            return true
        }
    }

    func label(_ t: String, bold: Bool = false) -> NSMenuItem {
        let i = NSMenuItem(title: t, action: nil, keyEquivalent: "")
        i.isEnabled = false
        if bold { i.attributedTitle = NSAttributedString(string: t, attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]) }
        return i
    }

    func dot(_ color: NSColor, _ t: String) -> NSAttributedString {
        let s = NSMutableAttributedString(string: "● ", attributes: [.foregroundColor: color])
        s.append(NSAttributedString(string: t, attributes: [.foregroundColor: NSColor.labelColor]))
        return s
    }

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if running && snap.checkedAt == nil { menu.addItem(label("Checking…")) }
        else if let t = snap.checkedAt { menu.addItem(label("Last check \(tf.string(from: t))\(running ? " (checking…)" : "")")) }
        if let g = snap.grey { menu.addItem(label("Cannot check: \(g)")) }
        switch snap.look {
        case .problems(let n): menu.addItem(label("\(n) problem\(n == 1 ? "" : "s")"))
        case .ok where snap.checkedAt != nil: menu.addItem(label("All well"))
        default: break
        }
        for h in snap.hosts {
            menu.addItem(.separator())
            if let e = h.error {
                let i = label(h.name)
                i.attributedTitle = dot(.systemRed, "\(h.name)\(h.target.map { " (\($0))" } ?? ""): cannot reach (\(e))")
                menu.addItem(i)
                continue
            }
            menu.addItem(label(h.name, bold: true))
            if let t = h.target { menu.addItem(label("  \(t)")) }
            if h.apps.isEmpty { menu.addItem(label("  no apps")) }
            for a in h.apps {
                let color: NSColor = a.problem != nil ? .systemRed : (probedStates.contains(a.state) ? .systemGreen : .systemGray)
                let i = NSMenuItem(title: a.name, action: nil, keyEquivalent: "")
                i.attributedTitle = dot(color, "\(a.name)   \(a.problem ?? a.state)")
                let sub = NSMenu()
                if let u = probeURL(a.link) {
                    let o = NSMenuItem(title: "Open \(u.absoluteString)", action: #selector(openLink(_:)), keyEquivalent: "")
                    o.target = self; o.representedObject = u
                    sub.addItem(o)
                }
                let st = NSMenuItem(title: "Open status in Terminal", action: #selector(openStatus(_:)), keyEquivalent: "")
                st.target = self; st.representedObject = ["status", a.name, "-H", h.name, "--follow"]
                sub.addItem(st)
                i.submenu = sub
                menu.addItem(i)
            }
        }
        menu.addItem(.separator())
        if snap.firing.isEmpty { if snap.checkedAt != nil && snap.grey == nil { menu.addItem(label("No firing alerts")) } }
        else {
            menu.addItem(label("Firing alerts", bold: true))
            for f in snap.firing { let i = label(f); i.attributedTitle = dot(.systemRed, f); menu.addItem(i) }
        }
        menu.addItem(.separator())
        let d = NSMenuItem(title: dashBinary() == nil ? "Install dashboard…" : "Open dashboard", action: #selector(openDashboard), keyEquivalent: "d")
        d.target = self
        menu.addItem(d)
        let r = NSMenuItem(title: "Refresh now", action: #selector(refresh), keyEquivalent: "r")
        r.target = self; r.isEnabled = !running
        menu.addItem(r)
        let st = NSMenuItem(title: "Open status in Terminal", action: #selector(openStatus(_:)), keyEquivalent: "t")
        st.target = self; st.representedObject = ["ls", "--all", "--watch", "5"]
        menu.addItem(st)
        menu.addItem(.separator())
        let q = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(q)
        return menu
    }

    /// The dashboard is its own app (~/Applications/tando Dashboard.app, installed with this one):
    /// launch or activate it. Without it, the fallback window of this app.
    @objc func openDashboard() {
        let url = URL(fileURLWithPath: dashHome() + "/Applications/tando Dashboard.app")
        if FileManager.default.fileExists(atPath: url.path) {
            let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, err in
                if err != nil { DispatchQueue.main.async { self.dash.open() } }
            }
        } else { dash.open() }
    }

    @objc func openLink(_ sender: NSMenuItem) {
        if let u = sender.representedObject as? URL { NSWorkspace.shared.open(u) }
    }

    /// Opens Terminal on `tando <args>` through a .command file (no Apple Events permission needed).
    /// The menu's commands are live views that refresh until Ctrl-C, like `top` (an app's status
    /// `--follow`: pushed every 5 s over one ssh session; every server's list `--watch 5`),
    /// not one print that goes stale while the window stays open.
    @objc func openStatus(_ sender: NSMenuItem) {
        guard let args = sender.representedObject as? [String] else { return }
        let q = { (t: String) in "'" + t.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let dir = NSTemporaryDirectory() + "tando-menubar"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let f = dir + "/tando-\(args.joined(separator: "-").filter { $0.isLetter || $0.isNumber || $0 == "-" }).command"
        let body = "#!/bin/bash\nclear\n\(q(s.tando)) \(args.map(q).joined(separator: " "))\n"
        do {
            try body.write(toFile: f, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f)
            NSWorkspace.shared.open(URL(fileURLWithPath: f))
        } catch { notifier.post(Note(title: "tando", body: "could not open Terminal: \(error.localizedDescription)")) }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no Dock icon (Info.plist says LSUIElement too)
let controller = Controller(settings)
app.run()
