// needt — privileged helper for non-TCC permission stores (runs as root via
// `do shell script ... with administrator privileges`).
//
//   needt ne-set   <signingID> allow|deny   Local Network decision for an app
//   needt ne-reset <signingID>              clear explicit decision (reprompt)
//   needt loc-dump                          dump /var/db/locationd plists as JSON
//   needt loc-set  <key> allow|deny         Location Services authorization
//   needt loc-remove <key>                  delete a locationd client record
//   needt btm-remove <identifier>           delete a BTM ItemRecord (.btm surgery)
//   needt btm-set <identifier> 0|1          flip the record's enabled disposition bit
//   needt gk <spctl args...>                Gatekeeper ops via /usr/sbin/spctl
import Foundation
import SystemConfiguration

let args = Array(CommandLine.arguments.dropFirst())
func fail(_ m: String) -> Never { FileHandle.standardError.write("ERR: \(m)\n".data(using: .utf8)!); exit(1) }
guard let cmd = args.first else { fail("usage") }

/// SIGKILL a daemon that caches its store in memory. TERM lets it flush a
/// stale copy on the way out — resurrecting records we just removed.
func sigkill(_ name: String) {
    let k = Process()
    k.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
    k.arguments = ["-9", name]
    try? k.run()
    k.waitUntilExit()
}

func commitNE(_ objects: NSMutableArray) throws {
    guard let prefs = SCPreferencesCreate(nil, "needt" as CFString,
                                          NEPlist.filePath as CFString) else {
        throw NSError(domain: "needt", code: 2, userInfo: [NSLocalizedDescriptionKey: "SCPreferencesCreate failed"])
    }
    guard SCPreferencesLock(prefs, true) else {
        throw NSError(domain: "needt", code: 3, userInfo: [NSLocalizedDescriptionKey: "SCPreferencesLock failed"])
    }
    defer { SCPreferencesUnlock(prefs) }
    if !SCPreferencesSetValue(prefs, "$objects" as CFString, objects) {
        throw NSError(domain: "needt", code: 4, userInfo: [NSLocalizedDescriptionKey: "SCPreferencesSetValue failed"])
    }
    if !SCPreferencesCommitChanges(prefs) {
        throw NSError(domain: "needt", code: 5, userInfo: [NSLocalizedDescriptionKey: "SCPreferencesCommitChanges failed"])
    }
    SCPreferencesApplyChanges(prefs)
    // nehelper keeps the parsed archive in memory and re-flushes it on
    // unrelated events — resurrecting rules we just edited/removed. SIGKILL
    // (not TERM, which could trigger a graceful-exit flush) forces a reload
    // from disk.
    sigkill("nehelper")
}

func mutableObjects() throws -> NSMutableArray {
    guard let data = FileManager.default.contents(atPath: NEPlist.filePath),
          let plist = try PropertyListSerialization.propertyList(
              from: data, options: [.mutableContainers], format: nil) as? NSMutableDictionary,
          let objects = plist["$objects"] as? NSMutableArray else {
        throw NSError(domain: "needt", code: 6, userInfo: [NSLocalizedDescriptionKey: "cannot parse archive"])
    }
    return objects
}

switch cmd {
case "ne-set":
    guard args.count == 3, let id = args.dropFirst().first else { fail("args") }
    let allow = args[2] == "allow"
    // Kill before reading too: a dirty in-memory copy flushed between our
    // parse and commit would silently resurrect the record.
    sigkill("nehelper")
    let objects = try mutableObjects()
    let n = NEPlist.setRule(in: objects, signingID: id, deny: !allow, preferenceSet: true)
    guard n > 0 else { fail("no rule for \(id)") }
    try commitNE(objects)
    print("OK modified \(n) rule(s)")

case "ne-reset":
    guard args.count == 2 else { fail("args") }
    sigkill("nehelper")
    let objects = try mutableObjects()
    let n = NEPlist.setRule(in: objects, signingID: args[1], deny: true, preferenceSet: false)
    guard n > 0 else { fail("no rule for \(args[1])") }
    try commitNE(objects)
    print("OK reset \(n) rule(s)")

case "ne-remove":
    guard args.count == 2 else { fail("args") }
    sigkill("nehelper")
    let objects = try mutableObjects()
    let n = NEPlist.removeRule(in: objects, signingID: args[1])
    if n == 0 {
        // Idempotent: the desired end state (record absent) already holds.
        print("OK already absent")
    } else {
        try commitNE(objects)
        print("OK removed \(n) rule ref(s)")
    }

case "loc-dump":
    // locationd plists embed NSData (requirement blobs) and NSDate — neither is
    // JSON-encodable, and JSONSerialization raises an uncatchable NSException
    // rather than a Swift error. Sanitize recursively before encoding.
    func jsonSafe(_ v: Any) -> Any {
        switch v {
        case let d as Data: return d.base64EncodedString()
        case let d as Date: return ISO8601DateFormatter().string(from: d)
        case let dict as [String: Any]: return dict.mapValues(jsonSafe)
        case let arr as [Any]: return arr.map(jsonSafe)
        case is NSString, is NSNumber, is NSNull: return v
        default: return String(describing: v)
        }
    }
    let dir = "/var/db/locationd"
    let fm = FileManager.default
    var out: [String: Any] = [:]
    for f in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where f.hasSuffix(".plist") {
        let p = "\(dir)/\(f)"
        if let d = fm.contents(atPath: p),
           let obj = try? PropertyListSerialization.propertyList(from: d, format: nil) {
            out[f] = jsonSafe(obj)
        }
    }
    let j = try JSONSerialization.data(withJSONObject: out, options: .prettyPrinted)
    FileHandle.standardOutput.write(j)

case "loc-set":
    guard args.count == 3 else { fail("args") }
    let allow = args[2] == "allow"
    // locationd caches its client registry and rewrites the plists on
    // unrelated events — kill it before and after, like nehelper.
    sigkill("locationd")
    var changed = false
    for name in ["clients.plist", "clients-b.plist"] {
        let p = "/var/db/locationd/\(name)"
        guard let dict = NSMutableDictionary(contentsOfFile: p) else { continue }
        if var entry = dict[args[1]] as? [String: Any] {
            entry["Authorized"] = allow
            dict[args[1]] = entry
            dict.write(toFile: p, atomically: true)
            changed = true
        }
    }
    guard changed else { fail("client not found in locationd stores") }
    sigkill("locationd")
    print("OK")

case "loc-remove":
    guard args.count == 2 else { fail("args") }
    sigkill("locationd")
    var changed = false
    for name in ["clients.plist", "clients-b.plist"] {
        let p = "/var/db/locationd/\(name)"
        guard let dict = NSMutableDictionary(contentsOfFile: p),
              dict[args[1]] != nil else { continue }
        dict.removeObject(forKey: args[1])
        dict.write(toFile: p, atomically: true)
        changed = true
    }
    guard changed else { fail("client not found in locationd stores") }
    sigkill("locationd")
    print("OK removed client")

case "btm-remove":
    // Delete a BTM ItemRecord by its identifier ("2.com.foo.bar") from every
    // BackgroundItems-*.btm archive. Records are single-referenced — dropping
    // the UID from the NS.objects array removes the record. Then SIGKILL
    // backgroundtaskmanagementd so it re-reads instead of flushing a stale copy.
    guard args.count == 2 else { fail("args") }
    let target = args[1]
    var removed = 0
    sigkill("backgroundtaskmanagementd")
    let dir = "/var/db/com.apple.backgroundtaskmanagement"
    for f in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
             where f.hasSuffix(".btm") {
        let p = "\(dir)/\(f)"
        guard let data = FileManager.default.contents(atPath: p),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [.mutableContainers], format: nil)
                      as? NSMutableDictionary,
              let objects = plist["$objects"] as? NSMutableArray else { continue }
        var changed = false
        for i in 0..<objects.count {
            guard let arr = objects[i] as? NSMutableDictionary,
                  let list = arr["NS.objects"] as? NSMutableArray else { continue }
            var j = 0
            while j < list.count {
                if let uid = NEPlist.uidIndex(list[j]), uid > 0, uid < objects.count,
                   let rec = objects[uid] as? [String: Any],
                   let iuid = NEPlist.uidIndex(rec["identifier"]), iuid < objects.count,
                   (objects[iuid] as? String) == target {
                    list.removeObject(at: j)
                    removed += 1
                    changed = true
                } else { j += 1 }
            }
        }
        if changed {
            let out = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .binary, options: 0)
            try out.write(to: URL(fileURLWithPath: p))
        }
    }
    sigkill("backgroundtaskmanagementd")
    print(removed == 0 ? "OK already absent" : "OK removed \(removed) record(s)")

case "btm-set":
    // Mirror System Settings' Background App Activity toggle. Observed write
    // semantics: ON sets enabled+allowed (0x3); OFF clears only 'allowed'
    // (0x2) — enabled/notified persist (0x9 = enabled+disallowed+notified is
    // a normal off-state). The toggle also cascades to child records whose
    // 'container' is the parent's identifier. Same store surgery as
    // btm-remove: SIGKILL the daemon on both sides so it can't flush a stale
    // in-memory copy over the edit.
    guard args.count == 3, let en = Int(args[2]), en == 0 || en == 1
    else { fail("args") }
    let target = args[1]
    var touched = 0
    sigkill("backgroundtaskmanagementd")
    let dir = "/var/db/com.apple.backgroundtaskmanagement"
    for f in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
             where f.hasSuffix(".btm") {
        let p = "\(dir)/\(f)"
        guard let data = FileManager.default.contents(atPath: p),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [.mutableContainers], format: nil)
                      as? NSMutableDictionary,
              let objects = plist["$objects"] as? NSMutableArray else { continue }
        var changed = false
        // Family root: the target's own `container` when it's a child record,
        // else the target itself. Settings' switch is family-wide — every
        // member moves together no matter which one is toggled.
        var root = target
        for i in 0..<objects.count {
            guard let rec = objects[i] as? NSMutableDictionary,
                  let iuid = NEPlist.uidIndex(rec["identifier"]), iuid < objects.count,
                  (objects[iuid] as? String) == target,
                  let cuid = NEPlist.uidIndex(rec["container"]), cuid < objects.count,
                  let c = objects[cuid] as? String, c != "$null" else { continue }
            root = c
        }
        // Family = root + all descendants (fixpoint covers deeper nesting).
        var family: Set<String> = [root]
        var grew = true
        while grew {
            grew = false
            for i in 0..<objects.count {
                guard let rec = objects[i] as? NSMutableDictionary,
                      let iuid = NEPlist.uidIndex(rec["identifier"]), iuid < objects.count,
                      let ident = objects[iuid] as? String, !family.contains(ident),
                      let cuid = NEPlist.uidIndex(rec["container"]), cuid < objects.count,
                      let c = objects[cuid] as? String, family.contains(c)
                else { continue }
                family.insert(ident)
                grew = true
            }
        }
        for i in 0..<objects.count {
            guard let rec = objects[i] as? NSMutableDictionary,
                  let iuid = NEPlist.uidIndex(rec["identifier"]), iuid < objects.count,
                  let ident = objects[iuid] as? String, family.contains(ident),
                  let disp = rec["disposition"] as? Int else { continue }
            let newDisp = en == 1 ? disp | 0x3 : disp & ~0x2
            guard newDisp != disp else { continue }
            rec["disposition"] = newDisp
            if let g = rec["generation"] as? Int { rec["generation"] = g + 1 }
            rec["modificationDate"] = Date().timeIntervalSinceReferenceDate
            touched += 1
            changed = true
        }
        if changed {
            let out = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .binary, options: 0)
            try out.write(to: URL(fileURLWithPath: p))
        }
    }
    sigkill("backgroundtaskmanagementd")
    print(touched == 0 ? "OK no change" : "OK updated \(touched) record(s)")

case "gk":
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/sbin/spctl")
    proc.arguments = Array(args.dropFirst())
    try proc.run()
    proc.waitUntilExit()
    exit(proc.terminationStatus)

default:
    fail("unknown command \(cmd)")
}
