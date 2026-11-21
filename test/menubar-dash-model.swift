// test/menubar-dash-model.swift: checks of macos/menubar/DashModel.swift (dash.lock, stale lock, the
// "Open dashboard" decision tree, where tando-dash is, the window's address policy, the shared
// cache's freshness). Compiled with DashModel.swift by test/menubar-test.sh (copied there as
// main.swift). One PASS/FAIL line per check.

import Foundation

var failed = 0
func check(_ id: String, _ text: String, _ ok: Bool, _ got: @autoclosure () -> String = "") {
    if ok { print("PASS \(id) \(text)") } else { failed += 1; print("FAIL \(id) \(text)  (got: \(got()))") }
}
func lock(_ s: String) -> DashLock? { DashLock.parse(s.data(using: .utf8)) }
let good = #"{"pid":4242,"port":51234,"url":"http://127.0.0.1:51234/","key":"k3y","started":"2026-11-21T10:00:00Z"}"#

// D1 dash.lock parsing
check("D1a", "a lock written by tando-dash reads (pid, port, key)", lock(good) == DashLock(pid: 4242, port: 51234, key: "k3y"), "\(String(describing: lock(good)))")
check("D1b", "an emptied lock (tando-dash exited) is no lock", lock("") == nil && DashLock.parse(nil) == nil && lock("\n") == nil)
check("D1c", "garbage, a half-written file and the wrong types are no lock",
      lock("not json") == nil && lock(#"{"pid":4242,"po"#) == nil && lock(#"{"pid":"4242","port":1,"key":"k"}"#) == nil)
check("D1d", "a missing or empty key, pid 0 or 1, port 0 or above 65535 are no lock",
      lock(#"{"pid":4242,"port":80}"#) == nil && lock(#"{"pid":4242,"port":80,"key":""}"#) == nil &&
      lock(#"{"pid":0,"port":80,"key":"k"}"#) == nil && lock(#"{"pid":1,"port":80,"key":"k"}"#) == nil &&
      lock(#"{"pid":4242,"port":0,"key":"k"}"#) == nil && lock(#"{"pid":4242,"port":70000,"key":"k"}"#) == nil)
check("D1e", "the lock's address is 127.0.0.1 and its port",
      lock(good)?.newcodeURL.absoluteString == "http://127.0.0.1:51234/api/newcode" && lock(good)?.base.absoluteString == "http://127.0.0.1:51234/")

// D2 the decision tree: not installed, start, ask for a link; a stale lock (a dead pid) starts a new one
let l = lock(good)!
check("D2a", "not installed: the install hint, whatever the lock says", decideDash(installed: false, lock: l, alive: { _ in true }) == .notInstalled)
check("D2b", "installed, no lock: start tando-dash", decideDash(installed: true, lock: nil, alive: { _ in true }) == .start)
check("D2c", "installed, the lock's process is alive: ask it for a link", decideDash(installed: true, lock: l, alive: { $0 == 4242 }) == .askCode(l))
check("D2d", "installed, a lock left by a crash (pid gone): start, do not ask a dead port", decideDash(installed: true, lock: l, alive: { _ in false }) == .start)
var asked: [Int] = []
_ = decideDash(installed: true, lock: l, alive: { asked.append($0); return true })
check("D2e", "the pid asked about is the lock's", asked == [4242], "\(asked)")
asked = []
_ = decideDash(installed: true, lock: nil, alive: { asked.append($0); return true })
check("D2f", "no lock: no process is probed", asked.isEmpty)
check("D2g", "this very process is alive for the real check", pidAlive(Int(getpid())) == true && pidAlive(999_999) == false)

// D3 the one-time link
check("D3a", "the link is /open?code= on the lock's port", dashOpenURL(l, code: "abc123")?.absoluteString == "http://127.0.0.1:51234/open?code=abc123")
check("D3b", "a code with anything but letters, digits, - and _ is refused (no injected query or host)",
      dashOpenURL(l, code: "a&b=c") == nil && dashOpenURL(l, code: "a/../b") == nil && dashOpenURL(l, code: "") == nil && dashOpenURL(l, code: "a b") == nil)
check("D3c", "/api/newcode's answer gives the code", parseNewCode(Data(#"{"code":"x9","pid":4242}"#.utf8)) == "x9")
check("D3d", "an answer without a code gives none", parseNewCode(Data(#"{"error":{"code":"auth"}}"#.utf8)) == nil && parseNewCode(Data("x".utf8)) == nil && parseNewCode(nil) == nil)

// D4 where tando-dash is
let home = "/Users/x"
let c = dashCandidates(home: home, path: "/usr/bin:/opt/homebrew/bin:/usr/bin")
check("D4a", "the add-on's own link first, then ~/.local/bin, then PATH and the usual places, no duplicates",
      c.first == "/Users/x/.local/lib/tando-dash/current/tando-dash" && c[1] == "/Users/x/.local/bin/tando-dash" &&
      c.contains("/usr/bin/tando-dash") && c.contains("/usr/local/bin/tando-dash") && Set(c).count == c.count, "\(c)")
check("D4b", "the first executable one wins", findDash(home: home, path: "/usr/bin", isExecutable: { $0 == "/usr/bin/tando-dash" || $0 == "/usr/local/bin/tando-dash" }) == "/usr/bin/tando-dash")
check("D4c", "none executable: not found", findDash(home: home, path: "/usr/bin", isExecutable: { _ in false }) == nil)
check("D4d", "the install command is the one the docs say", dashInstallCommand == "tando addon install dashboard")

// D5 the window shows 127.0.0.1:<port> only
func pol(_ s: String, _ port: Int = 51234) -> NavPolicy { navPolicy(URL(string: s), port: port) }
check("D5a", "the dashboard itself (any path) is allowed", pol("http://127.0.0.1:51234/") == .allow && pol("http://127.0.0.1:51234/open?code=a") == .allow && pol("http://127.0.0.1:51234/apps/web?tab=logs#x") == .allow)
check("D5b", "another port on localhost is not the dashboard: default browser", pol("http://127.0.0.1:3000/") == .external && pol("http://localhost:51234/") == .external)
check("D5c", "an app's link (https) opens in the default browser", pol("https://shop.example.com/") == .external && pol("http://example.com/") == .external && pol("mailto:a@b.c") == .external)
check("D5d", "a user-info trick does not pass for the dashboard", pol("http://127.0.0.1:51234@evil.example.com/") == .external && pol("http://127.0.0.1:51234:x@evil.example.com/") == .external)
check("D5e", "file:, javascript:, data: and unknown schemes are blocked", pol("file:///etc/passwd") == .block && pol("javascript:alert(1)") == .block && pol("data:text/html,x") == .block && pol("tando://x") == .block)
check("D5f", "about:blank (the window's message pages) is allowed, other about: is not", pol("about:blank") == .allow && pol("about:config") == .block)
check("D5g", "no address: blocked", navPolicy(nil, port: 51234) == .block)
check("D5h", "before the first load (port 0) the dashboard is not allowed", pol("http://127.0.0.1:51234/", 0) == .external)

// D6 the shared cache
let now = Date(timeIntervalSince1970: 1_800_000_000)
check("D6a", "a cache younger than the interval is used", cacheFresh(modified: now.addingTimeInterval(-20), now: now, interval: 60))
check("D6b", "a cache as old as the interval, or older, is not", !cacheFresh(modified: now.addingTimeInterval(-60), now: now, interval: 60) && !cacheFresh(modified: now.addingTimeInterval(-600), now: now, interval: 60))
check("D6c", "no cache file: not fresh", !cacheFresh(modified: nil, now: now, interval: 60))
check("D6d", "a file from the future (clock set back) is not fresh", !cacheFresh(modified: now.addingTimeInterval(30), now: now, interval: 60))
check("D6e", "a longer interval accepts an older cache", cacheFresh(modified: now.addingTimeInterval(-100), now: now, interval: 120))

print("dash model: \(failed) failed")
exit(failed == 0 ? 0 : 1)
