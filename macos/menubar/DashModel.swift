// macos/menubar/DashModel.swift: what the menu bar app knows about the dashboard window, without
// any UI: reading dash.lock, telling a stale lock from a live one, what "Open dashboard" does next,
// where tando-dash is, which addresses the window may show, and whether the shared cache
// (ls-all.json, written by tando-dash) is fresh enough to use instead of `tando ls --all --json`.
// Pure Foundation: test/menubar-test.sh compiles it with test/menubar-dash-model.swift.

import Foundation

// ---- dash.lock -----------------------------------------------------------------------------------

/// What tando-dash writes into dash.lock (JSON: pid, port, url, key, started). The file is emptied
/// when it exits; a crash leaves it, which is why the pid is looked at.
struct DashLock: Equatable {
    let pid: Int
    let port: Int
    let key: String

    /// nil for an empty file, garbage, a missing field, a port or pid out of range, an empty key.
    static func parse(_ data: Data?) -> DashLock? {
        guard let data = data, !data.isEmpty,
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = (o["pid"] as? NSNumber)?.intValue, pid > 1,
              let port = (o["port"] as? NSNumber)?.intValue, (1...65535).contains(port),
              let key = o["key"] as? String, !key.isEmpty else { return nil }
        return DashLock(pid: pid, port: port, key: key)
    }

    var base: URL { URL(string: "http://127.0.0.1:\(port)/")! }
    var newcodeURL: URL { URL(string: "http://127.0.0.1:\(port)/api/newcode")! }
}

// ---- what "Open dashboard" does ------------------------------------------------------------------

enum DashStep: Equatable {
    case notInstalled             // no tando-dash found: the menu says "Install dashboard…"
    case start                    // nothing runs (no lock, an empty one, or the lock's process is gone)
    case askCode(DashLock)        // one runs: ask it for a fresh one-time link
}

/// The decision tree. `alive` says whether a pid is a running process (kill(pid, 0)).
func decideDash(installed: Bool, lock: DashLock?, alive: (Int) -> Bool) -> DashStep {
    if !installed { return .notInstalled }
    guard let l = lock, alive(l.pid) else { return .start }
    return .askCode(l)
}

/// Is this pid a running process (kill(pid, 0); EPERM: it exists, it is someone else's)
func pidAlive(_ pid: Int) -> Bool {
    kill(pid_t(pid), 0) == 0 || errno == EPERM
}

/// The address the window loads: the one-time link of the running tando-dash.
func dashOpenURL(_ lock: DashLock, code: String) -> URL? {
    guard !code.isEmpty, code.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
    return URL(string: "http://127.0.0.1:\(lock.port)/open?code=\(code)")
}

/// `{"code":"...","pid":N}` from POST /api/newcode
func parseNewCode(_ data: Data?) -> String? {
    guard let data = data, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let c = o["code"] as? String, !c.isEmpty else { return nil }
    return c
}

/// Where tando-dash may be, in the order tried: the add-on's own `current` link, the link in
/// ~/.local/bin, then the PATH directories and the usual ones.
func dashCandidates(home: String, path: String) -> [String] {
    var c = [home + "/.local/lib/tando-dash/current/tando-dash", home + "/.local/bin/tando-dash"]
    for d in path.split(separator: ":") where !d.isEmpty { c.append(String(d) + "/tando-dash") }
    for d in ["/usr/local/bin", "/opt/homebrew/bin"] { c.append(d + "/tando-dash") }
    var seen = Set<String>()
    return c.filter { seen.insert($0).inserted }
}

func findDash(home: String, path: String, isExecutable: (String) -> Bool) -> String? {
    dashCandidates(home: home, path: path).first(where: isExecutable)
}

let dashInstallCommand = "tando addon install dashboard"

// ---- the window's address book -------------------------------------------------------------------

enum NavPolicy: Equatable {
    case allow       // 127.0.0.1:<port>, and about:blank (the window's own message pages)
    case external    // http(s) or mailto elsewhere: the default browser, not the window
    case block       // anything else (file:, javascript:, data:, a custom scheme)
}

/// Nothing navigates outside 127.0.0.1:<port>: other web addresses go to the default browser.
func navPolicy(_ url: URL?, port: Int) -> NavPolicy {
    guard let url = url, let scheme = url.scheme?.lowercased() else { return .block }
    switch scheme {
    case "about": return url.absoluteString == "about:blank" ? .allow : .block
    case "http":
        // user:pass@ tricks (http://127.0.0.1:1234@evil/) have another host: compare the parsed host
        if url.host == "127.0.0.1" && url.port == port && url.user == nil { return .allow }
        return .external
    case "https", "mailto": return .external
    default: return .block
    }
}

// ---- the shared cache ----------------------------------------------------------------------------

/// tando-dash writes cache/ls-all.json after each overview refresh. When it is fresher than the
/// menu bar's own interval the menu bar reads it instead of running `tando ls --all --json`.
/// A file from the future (clock set back) is not fresh.
func cacheFresh(modified: Date?, now: Date, interval: Double) -> Bool {
    guard let m = modified else { return false }
    let age = now.timeIntervalSince(m)
    return age >= 0 && age < interval
}
