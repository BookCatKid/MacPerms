// needt — privileged helper for non-TCC permission stores (runs as root via
// `do shell script ... with administrator privileges`).
//
//   needt ne-set   <signingID> allow|deny   Local Network decision for an app
//   needt ne-reset <signingID>              clear explicit decision (reprompt)
//   needt loc-dump                          dump /var/db/locationd plists as JSON
//   needt loc-set  <bundleID> allow|deny    Location Services authorization
//   needt gk <spctl args...>                Gatekeeper ops via /usr/sbin/spctl
import Foundation
import SystemConfiguration

let args = Array(CommandLine.arguments.dropFirst())
func fail(_ m: String) -> Never { FileHandle.standardError.write("ERR: \(m)\n".data(using: .utf8)!); exit(1) }
guard let cmd = args.first else { fail("usage") }

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
    let objects = try mutableObjects()
    let n = NEPlist.setRule(in: objects, signingID: id, deny: !allow, preferenceSet: true)
    guard n > 0 else { fail("no rule for \(id)") }
    try commitNE(objects)
    print("OK modified \(n) rule(s)")

case "ne-reset":
    guard args.count == 2 else { fail("args") }
    let objects = try mutableObjects()
    let n = NEPlist.setRule(in: objects, signingID: args[1], deny: true, preferenceSet: false)
    guard n > 0 else { fail("no rule for \(args[1])") }
    try commitNE(objects)
    print("OK reset \(n) rule(s)")

case "ne-remove":
    guard args.count == 2 else { fail("args") }
    let objects = try mutableObjects()
    let n = NEPlist.removeRule(in: objects, signingID: args[1])
    guard n > 0 else { fail("no rule for \(args[1])") }
    try commitNE(objects)
    print("OK removed \(n) rule ref(s)")

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
    print("OK")

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
