// macos/menubar/Model.swift: what the tando menu bar app knows, without any UI. It reads the output
// of `tando ls --all --json`, takes the results of the link probes, and decides the badge, the
// menu rows and the notifications. Pure Foundation: test/menubar-test.sh compiles it with canned
// JSON and checks it without a window server.

import Foundation

// ---- `tando ls --all --json` ---------------------------------------------------------------------

struct LsAll: Decodable { let hosts: [HostRow] }
struct HostRow: Decodable {
    let host: String
    let apps: [AppRow]?
    let alerts: [AlertRow]?   // since tando 0.2.2; an older client leaves it out
    let error: String?
}
struct AppRow: Decodable {
    let app: String
    let state: String?
    let link: String?
}
struct AlertRow: Decodable {
    let app: String?
    let check: String?
    let state: String?
    let since: Double?
    let detail: String?
}

func parseLsAll(_ data: Data) -> LsAll? { try? JSONDecoder().decode(LsAll.self, from: data) }

// ---- what the menu shows -------------------------------------------------------------------------

struct Issue: Equatable {
    let key: String       // what a notification is about: "host:vps", "link:vps/web", "alert:vps/web/down", "app:vps/web"
    let subject: String   // what the badge counts: "host:vps", "app:vps/web", "alert:vps/host/disk"
    let text: String      // one line for the menu and the notification
}
struct AppView: Equatable {
    let name: String
    let state: String
    let link: String?
    let problem: String?  // nil when all is well
}
struct HostView: Equatable {
    let name: String
    let error: String?    // set: the laptop could not reach it over ssh
    let apps: [AppView]
}
struct Note: Equatable { let title: String; let body: String }

enum Look: Equatable { case ok, problems(Int), grey }

struct Snapshot {
    var hosts: [HostView] = []
    var firing: [String] = []       // "vps: web down (since 12:03)"
    var issues: [Issue] = []
    var badge: Int = 0
    var grey: String? = nil         // set: nothing could be checked (laptop offline, tando failed)
    var checkedAt: Date? = nil
    var look: Look { grey != nil ? .grey : (badge > 0 ? .problems(badge) : .ok) }
}

// a link worth requesting: http(s) only
func probeURL(_ link: String?) -> URL? {
    guard let l = link, l.hasPrefix("http://") || l.hasPrefix("https://"), let u = URL(string: l) else { return nil }
    return u
}
let problemStates: Set<String> = ["down", "failed"]
let probedStates: Set<String> = ["running", "static"]

// ---- the state between checks --------------------------------------------------------------------

final class Monitor {
    var failsToAlert = 2                    // a link that fails this many checks in a row is a problem
    private(set) var linkFails: [String: Int] = [:]
    private(set) var hostFails: [String: Int] = [:]   // checks in a row a host did not answer
    private var known: [String: Issue] = [:]  // issues already notified, by key
    private(set) var last = Snapshot()

    /// The links of this check that the app should request (running apps with an http(s) link).
    func linksToProbe(_ ls: LsAll) -> [URL] {
        var out: [URL] = []
        for h in ls.hosts where h.error == nil {
            for a in h.apps ?? [] where probedStates.contains(a.state ?? "") {
                if let u = probeURL(a.link), !out.contains(u) { out.append(u) }
            }
        }
        return out
    }

    /// One check: the CLI's answer and the probe results (link -> answered). Returns what to show and
    /// the notifications to raise (new problems and recoveries, each once).
    func apply(_ ls: LsAll, probes: [String: Bool], now: Date = Date()) -> (Snapshot, [Note]) {
        var snap = Snapshot()
        snap.checkedAt = now
        var issues: [Issue] = []
        var carried: Set<String> = []       // keys of an unreachable host: unknown, neither new nor recovered
        var seenLinks: Set<String> = []
        let tf = DateFormatter(); tf.dateFormat = "HH:mm"

        for h in ls.hosts {
            if let err = h.error {
                // like a link: a problem from the second check in a row (a single slow or dropped
                // ssh answer is not an outage, and turned the badge red once in a real use); the
                // menu shows the error at once
                hostFails[h.host, default: 0] += 1
                if hostFails[h.host, default: 0] >= failsToAlert {
                    issues.append(Issue(key: "host:\(h.host)", subject: "host:\(h.host)", text: "\(h.host): cannot reach the server (\(err))"))
                } else if known["host:\(h.host)"] != nil {
                    carried.insert("host:\(h.host)")
                }
                for k in known.keys where k.hasPrefix("link:\(h.host)/") || k.hasPrefix("alert:\(h.host)/") || k.hasPrefix("app:\(h.host)/") {
                    carried.insert(k)
                }
                for k in linkFails.keys where k.hasPrefix("\(h.host)/") { seenLinks.insert(k) }  // keep counts
                snap.hosts.append(HostView(name: h.host, error: err, apps: []))
                continue
            }
            hostFails[h.host] = nil
            let firing = (h.alerts ?? []).filter { $0.state == "firing" }
            var apps: [AppView] = []
            for a in h.apps ?? [] {
                let id = "\(h.host)/\(a.app)"
                let state = a.state ?? "unknown"
                var problem: String? = nil
                if problemStates.contains(state) {
                    problem = state
                    issues.append(Issue(key: "app:\(id)", subject: "app:\(id)", text: "\(h.host): \(a.app) is \(state)"))
                }
                if probedStates.contains(state), let u = probeURL(a.link) {
                    seenLinks.insert(id)
                    if probes[u.absoluteString] == false {
                        linkFails[id, default: 0] += 1
                    } else if probes[u.absoluteString] == true {
                        linkFails[id] = 0
                    }
                    if linkFails[id, default: 0] >= failsToAlert {
                        problem = problem ?? "link fails"
                        issues.append(Issue(key: "link:\(id)", subject: "app:\(id)",
                                            text: "\(h.host): \(a.app) does not answer at \(u.absoluteString)"))
                    }
                }
                for al in firing where al.app == a.app { problem = problem ?? (al.check ?? "alert") }
                apps.append(AppView(name: a.app, state: state, link: a.link, problem: problem))
            }
            for al in firing {
                let app = al.app ?? "host", check = al.check ?? "?"
                // an alert of an app counts with the app; a host check (app "host") on its own
                let subject = apps.contains { $0.name == app } ? "app:\(h.host)/\(app)" : "alert:\(h.host)/\(app)/\(check)"
                var line = "\(h.host): \(app) \(check)"
                if let d = al.detail, !d.isEmpty { line += " (\(d))" }
                if let s = al.since, s > 0 { line += " since \(tf.string(from: Date(timeIntervalSince1970: s)))" }
                snap.firing.append(line)
                issues.append(Issue(key: "alert:\(h.host)/\(app)/\(check)", subject: subject, text: line))
            }
            snap.hosts.append(HostView(name: h.host, error: nil, apps: apps))
        }
        // forget the counts of apps that are gone or no longer probed
        for k in linkFails.keys where !seenLinks.contains(k) { linkFails[k] = nil }

        snap.issues = issues
        snap.badge = Set(issues.map { $0.subject }).count

        var notes: [Note] = []
        let current = Dictionary(issues.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let fresh = issues.filter { known[$0.key] == nil }
        let healed = known.values.filter { current[$0.key] == nil && !carried.contains($0.key) }
            .sorted { $0.key < $1.key }
        if fresh.count > 3 {
            notes.append(Note(title: "tando: \(fresh.count) new problems", body: fresh.prefix(3).map { $0.text }.joined(separator: "\n")))
        } else {
            for i in fresh { notes.append(Note(title: "tando: problem", body: i.text)) }
        }
        if healed.count > 3 {
            notes.append(Note(title: "tando: \(healed.count) problems resolved", body: healed.prefix(3).map { $0.text }.joined(separator: "\n")))
        } else {
            for i in healed { notes.append(Note(title: "tando: resolved", body: i.text)) }
        }
        var next = current
        for k in carried { next[k] = known[k] }
        known = next
        last = snap
        return (snap, notes)
    }

    /// A check that could not run at all (tando missing, timed out, unreadable output, laptop offline):
    /// grey, the last host list kept, no notification, nothing counted as new or resolved.
    func failed(_ reason: String, now: Date = Date()) -> Snapshot {
        var s = last
        s.grey = reason
        s.checkedAt = now
        last = s
        return s
    }
}

// ---- the menu as text (the app's --once mode, and the tests) -------------------------------------

func describe(_ s: Snapshot) -> String {
    var out: [String] = []
    switch s.look {
    case .ok: out.append("badge: none (all well)")
    case .problems(let n): out.append("badge: \(n)")
    case .grey: out.append("badge: grey (\(s.grey ?? ""))")
    }
    for h in s.hosts {
        if let e = h.error { out.append("host \(h.name): unreachable (\(e))"); continue }
        out.append("host \(h.name)")
        for a in h.apps {
            out.append("  \(a.name)  \(a.state)\(a.problem.map { "  PROBLEM: \($0)" } ?? "")  \(a.link ?? "-")")
        }
    }
    for f in s.firing { out.append("alert \(f)") }
    return out.joined(separator: "\n")
}
