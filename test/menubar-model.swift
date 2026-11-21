// test/menubar-model.swift: checks of macos/menubar/Model.swift (the badge, the menu rows, the
// notifications) on canned `tando ls --all --json` outputs in test/fixtures/menubar. Compiled with
// Model.swift by test/menubar-test.sh (copied there as main.swift). One PASS/FAIL line per check.
//
//   model-test <fixtures dir>

import Foundation

let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "test/fixtures/menubar"
var failed = 0
func check(_ id: String, _ text: String, _ ok: Bool, _ got: @autoclosure () -> String = "") {
    if ok { print("PASS \(id) \(text)") } else { failed += 1; print("FAIL \(id) \(text)  (got: \(got()))") }
}
func load(_ name: String) -> LsAll {
    guard let d = FileManager.default.contents(atPath: "\(dir)/\(name).json"), let ls = parseLsAll(d) else {
        print("FAIL load \(name).json does not parse"); exit(1)
    }
    return ls
}
// every link of the check answers, except those listed
func probes(_ m: Monitor, _ ls: LsAll, down: [String] = []) -> [String: Bool] {
    var r: [String: Bool] = [:]
    for u in m.linksToProbe(ls) { r[u.absoluteString] = !down.contains(u.absoluteString) }
    return r
}
let web = "https://web.example.com"
let ok = load("ok"), appDown = load("app-down"), unreach = load("unreachable"), firing = load("alert-firing")

// M1 all well: no badge, no notification; stopped apps are not probed, pending alerts do not count
do {
    let m = Monitor()
    let links = m.linksToProbe(ok).map { $0.absoluteString }
    check("M1a", "probes the running and static apps' links, not the stopped one",
          links == [web, "https://site.example.com", "http://api.lab.example.net:8080"], "\(links)")
    let (s, n) = m.apply(ok, probes: probes(m, ok))
    check("M1b", "all well: badge none, plain icon", s.look == .ok && s.badge == 0, "\(s.look)")
    check("M1c", "all well: no notification", n.isEmpty, "\(n)")
    check("M1d", "the menu lists both hosts and their apps", s.hosts.map { $0.name } == ["vps", "lab"] && s.hosts[0].apps.count == 3,
          describe(s))
    check("M1e", "a pending alert is not listed as firing", s.firing.isEmpty, "\(s.firing)")
}

// M2 one app down: badge 1 and one notification; back up: badge none and one "resolved"
do {
    let m = Monitor()
    _ = m.apply(ok, probes: probes(m, ok))
    let (s, n) = m.apply(appDown, probes: probes(m, appDown))
    check("M2a", "one app down: badge 1", s.look == .problems(1), "\(s.look)")
    check("M2b", "one app down: one notification naming it", n.count == 1 && n[0].body.contains("web is down"), "\(n)")
    check("M2c", "the app's row says down", s.hosts[0].apps[0].problem == "down", describe(s))
    let (s2, n2) = m.apply(appDown, probes: probes(m, appDown))
    check("M2d", "still down: no second notification", n2.isEmpty && s2.badge == 1, "\(n2)")
    let (s3, n3) = m.apply(ok, probes: probes(m, ok))
    check("M2e", "back up: badge none, one resolved notification", s3.badge == 0 && n3.count == 1 && n3[0].title.contains("resolved"), "\(n3)")
}

// M3 a link that fails: once is not a problem, twice in a row is; an answer clears it
do {
    let m = Monitor()
    let (s1, n1) = m.apply(ok, probes: probes(m, ok, down: [web]))
    check("M3a", "link failed once: no badge, no notification", s1.badge == 0 && n1.isEmpty, "\(s1.badge) \(n1)")
    let (s2, n2) = m.apply(ok, probes: probes(m, ok, down: [web]))
    check("M3b", "link failed twice in a row: badge 1, one notification", s2.badge == 1 && n2.count == 1 && n2[0].body.contains(web), "\(n2)")
    let (s3, n3) = m.apply(ok, probes: probes(m, ok))
    check("M3c", "link answers again: badge none, resolved once", s3.badge == 0 && n3.count == 1 && n3[0].title.contains("resolved"), "\(n3)")
    _ = m.apply(ok, probes: probes(m, ok, down: [web]))
    let (s4, _) = m.apply(ok, probes: probes(m, ok))
    _ = m.apply(ok, probes: probes(m, ok, down: [web]))
    check("M3d", "fail, answer, fail is not twice in a row", s4.badge == 0 && m.last.badge == 0, "\(m.last.badge)")
}

// M4 a host the laptop cannot reach: shown at once, counted and notified from the second check in a
// row (like a link: one slow or dropped ssh answer is not an outage), resolved once
do {
    let m = Monitor()
    _ = m.apply(ok, probes: probes(m, ok))
    let (s0, n0) = m.apply(unreach, probes: probes(m, unreach))
    check("M4e", "unreachable once: shown in the menu, no badge, no notification", s0.hosts[0].error == "no answer" && s0.badge == 0 && n0.isEmpty, "\(s0.badge) \(n0)")
    let (sb, nb) = m.apply(ok, probes: probes(m, ok))
    check("M4f", "a single miss, then an answer: nothing was raised, nothing resolved", sb.badge == 0 && nb.isEmpty, "\(nb)")
    _ = m.apply(unreach, probes: probes(m, unreach))
    let (s, n) = m.apply(unreach, probes: probes(m, unreach))
    check("M4a", "unreachable twice in a row: badge 1 (not grey: the other host answered)", s.look == .problems(1), "\(s.look)")
    check("M4b", "unreachable twice in a row: one notification with the reason", n.count == 1 && n[0].body.contains("vps") && n[0].body.contains("no answer"), "\(n)")
    check("M4c", "the menu shows the host as unreachable", s.hosts[0].error == "no answer", describe(s))
    let (s2, n2) = m.apply(ok, probes: probes(m, ok))
    check("M4d", "reachable again: resolved once", s2.badge == 0 && n2.count == 1 && n2[0].body.contains("cannot reach"), "\(n2)")
}

// M5 alerts firing, then resolved: one notification each way, no repeats in between
do {
    let m = Monitor()
    _ = m.apply(ok, probes: probes(m, ok))
    let (s, n) = m.apply(firing, probes: probes(m, firing))
    check("M5a", "two firing alerts (an app's and a host's): badge 2", s.badge == 2, "\(s.badge)")
    check("M5b", "two new firing alerts: two notifications", n.count == 2, "\(n)")
    check("M5c", "the menu lists the firing alerts", s.firing.count == 2 && s.firing[1].contains("disk") && s.firing[1].contains("91% used"), "\(s.firing)")
    let (_, n2) = m.apply(firing, probes: probes(m, firing))
    check("M5d", "still firing: no new notification", n2.isEmpty, "\(n2)")
    let (s3, n3) = m.apply(ok, probes: probes(m, ok))
    check("M5e", "resolved: badge none, two resolved notifications", s3.badge == 0 && n3.count == 2 && n3.allSatisfy { $0.title.contains("resolved") }, "\(n3)")
}

// M6 an app down with its link failing and a down alert counts once
do {
    let m = Monitor()
    let down = LsAll(hosts: [HostRow(host: "vps", apps: [AppRow(app: "web", state: "running", link: web)],
                                 alerts: [AlertRow(app: "web", check: "down", state: "firing", since: 1, detail: nil)], error: nil)])
    _ = m.apply(down, probes: probes(m, down, down: [web]))
    let (s, _) = m.apply(down, probes: probes(m, down, down: [web]))
    check("M6", "one app with a failing link and a firing alert: badge 1", s.badge == 1, "\(s.badge) \(s.issues)")
}

// M7 a host that drops out while an alert fires: the alert is neither resolved nor new
do {
    let m = Monitor()
    _ = m.apply(firing, probes: probes(m, firing))
    let (_, n1) = m.apply(unreach, probes: probes(m, unreach))
    check("M7d", "host unreachable once during an alert: the alert is not reported resolved", n1.isEmpty, "\(n1)")
    let (s, n) = m.apply(unreach, probes: probes(m, unreach))
    check("M7a", "host unreachable during an alert: only the host is notified", n.count == 1 && n[0].body.contains("cannot reach"), "\(n)")
    check("M7b", "host unreachable: badge counts the host only", s.badge == 1, "\(s.badge)")
    let (_, n2) = m.apply(firing, probes: probes(m, firing))
    check("M7c", "back, alerts still firing: only the host's recovery", n2.count == 1 && n2[0].body.contains("cannot reach"), "\(n2)")
}

// M8 nothing could be checked: grey, the last menu kept, no notification, no false recovery
do {
    let m = Monitor()
    _ = m.apply(appDown, probes: probes(m, appDown))
    let s = m.failed("tando did not answer within 45 s")
    check("M8a", "tando failed: grey", s.look == .grey && s.hosts.count == 2, "\(s.look)")
    let (s2, n2) = m.apply(appDown, probes: probes(m, appDown))
    check("M8b", "after a grey check the same problem is not notified again", n2.isEmpty && s2.look == .problems(1), "\(n2)")
}

// M9 inputs: an older client without "alerts", garbage, many problems at once
do {
    let m = Monitor()
    let old = load("old-client")
    let (s, _) = m.apply(old, probes: probes(m, old))
    check("M9a", "ls --json without alerts (older tando) still reads", s.look == .ok && s.hosts[0].apps.count == 1, "\(s.look)")
    check("M9b", "output that is not the JSON is refused", parseLsAll(Data("tando: no hosts registered".utf8)) == nil)
    let (s2, n2) = Monitor().apply(load("many-down"), probes: [:])
    check("M9c", "four apps down: badge 4, one summary notification", s2.badge == 4 && n2.count == 1 && n2[0].title.contains("4 new problems"), "\(n2)")
}

print("model: \(failed) failed")
exit(failed == 0 ? 0 : 1)
