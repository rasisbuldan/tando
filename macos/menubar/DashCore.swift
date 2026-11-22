// macos/menubar/DashCore.swift: finding, starting and asking tando-dash (no UI). Shared by the menu
// bar app (--dash-url, and its fallback window) and the dashboard app (macos/dashapp). It finds
// tando-dash (the add-on: `tando addon install dashboard`), starts it when dash.lock shows none
// running, and asks it for a fresh one-time link (POST /api/newcode with the lock's key, as a
// second tando-dash does). The decisions are in DashModel.swift (pure, tested).

import Foundation

struct CheckError: Error { let why: String }

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
