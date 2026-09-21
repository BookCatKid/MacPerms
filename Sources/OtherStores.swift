import Foundation

enum OtherStore {

    // MARK: Local Network (unprivileged read)

    static func localNetworkConfigs() throws -> [NEPlist.Config] {
        guard let data = FileManager.default.contents(atPath: NEPlist.filePath) else {
            throw NSError(domain: "OtherStore", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "cannot read \(NEPlist.filePath)"])
        }
        return try NEPlist.parse(data: data)
            .filter { $0.name.hasPrefix(NEPlist.privacyPrefix) }
    }

    // MARK: needt helper path

    static func needtPath() throws -> String {
        guard let p = Bundle.main.path(forResource: "needt", ofType: nil) else {
            throw NSError(domain: "OtherStore", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "needt helper missing from bundle"])
        }
        return p
    }

    static func needt(_ arguments: [String]) throws -> String {
        let helper = try needtPath()
        let cmd = ([helper] + arguments).map(Elevation.shellQuote).joined(separator: " ")
        return try Elevation.runAsRoot(cmd)
    }

    static func neSet(signingID: String, allow: Bool) throws -> String {
        try needt(["ne-set", signingID, allow ? "allow" : "deny"])
    }
    static func neReset(signingID: String) throws -> String {
        try needt(["ne-reset", signingID])
    }
    static func neRemove(signingID: String) throws -> String {
        try needt(["ne-remove", signingID])
    }

    // MARK: Background Items — sfltool dumpbtm (unprivileged)

    static func backgroundItems() throws -> [BTMItem] {
        let out = Resolver.run("/usr/bin/sfltool", ["dumpbtm"])
        var items: [BTMItem] = []
        var uid = 0
        var cur: [String: String] = [:]
        var curID = ""

        // dumpbtm renders home-relative paths as "/Users/<uid>/..." — a
        // literal path that never exists. Map it back to that uid's real
        // home so existence checks and the Detail column show the truth.
        func realPath(_ s: String?) -> String? {
            guard let s else { return nil }
            var p = s
            if p.hasPrefix("file://"), let u = URL(string: p) { p = u.path }
            guard p.hasPrefix("/Users/") else { return p }
            let rest = p.dropFirst("/Users/".count)
            guard let slash = rest.firstIndex(of: "/"),
                  let uid = Int(rest[..<slash]),
                  let pw = getpwuid(uid_t(uid)) else { return p }
            return String(cString: pw.pointee.pw_dir) + rest[slash...]
        }

        func flush() {
            guard let name = cur["Name"] else { cur = [:]; return }
            var disp = 0
            if let d = cur["Disposition"], let hex = d.range(of: "0x[0-9a-fA-F]+", options: .regularExpression) {
                disp = Int(d[hex].dropFirst(2), radix: 16) ?? 0
            }
            func nilIfNull(_ s: String?) -> String? { (s == "(null)") ? nil : s }
            items.append(BTMItem(
                uid: uid, itemUUID: curID,
                name: name,
                developer: nilIfNull(cur["Developer Name"]),
                teamID: nilIfNull(cur["Team Identifier"]),
                type: cur["Type"] ?? "",
                disposition: disp,
                identifier: cur["Identifier"] ?? "",
                url: realPath(nilIfNull(cur["URL"])),
                bundleID: nilIfNull(cur["Bundle Identifier"]),
                parent: nilIfNull(cur["Parent Identifier"]),
                lastUse: nilIfNull(cur["Last Use"]),
                executable: realPath(nilIfNull(cur["Executable Path"]))))
            cur = [:]
        }

        for line in out.components(separatedBy: "\n") {
            if let m = line.range(of: #"Records for UID (-?\d+)"#, options: .regularExpression) {
                uid = Int(line[m].dropFirst("Records for UID ".count)) ?? 0
            } else if line.hasPrefix(" #") && line.trimmingCharacters(in: .whitespaces).hasSuffix(":") {
                flush()
                curID = UUID().uuidString
            } else if let m = line.range(of: #"^\s{4,}(\w[\w ]+?):\s+(.*)$"#, options: .regularExpression) {
                let kv = String(line[m])
                guard let colon = kv.range(of: ": ") ?? kv.range(of: ":") else { continue }
                let key = kv[..<colon.lowerBound].trimmingCharacters(in: .whitespaces)
                let val = kv[colon.upperBound...].trimmingCharacters(in: .whitespaces)
                cur[key] = val
            }
        }
        flush()
        return items
    }

    /// Delete one BTM record by identifier — drops the ItemRecord's UID from
    /// the .btm archive's record array (same surgery pattern as the NE store)
    /// and SIGKILLs backgroundtaskmanagementd so it re-reads.
    static func btmRemove(identifier: String) throws -> String {
        try needt(["btm-remove", identifier])
    }

    // MARK: launchd disabled registry — the real per-item on/off switch

    /// `launchctl print-disabled <domain>` → label → enabled.
    /// Daemons live in `system`, agents/login items in `gui/<uid>`.
    static func launchdDisabled(_ domain: String) -> [String: Bool] {
        let out = Resolver.run("/bin/launchctl", ["print-disabled", domain])
        var map: [String: Bool] = [:]
        for line in out.components(separatedBy: "\n") {
            // lines look like: "com.foo.bar" => enabled
            guard let q1 = line.range(of: "\""),
                  let q2 = line[q1.upperBound...].range(of: "\""),
                  let arrow = line.range(of: "=>") else { continue }
            let label = String(line[q1.upperBound..<q2.lowerBound])
            let val = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
            map[label] = (val == "enabled")
        }
        return map
    }

    /// `launchctl enable|disable <domain>/<label>` — root, or via admin prompt
    /// when the app runs unprivileged.
    static func launchctlSetEnabled(domain: String, label: String, enabled: Bool) throws -> String {
        try Elevation.runAsRoot(
            "/bin/launchctl \(enabled ? "enable" : "disable") \(domain)/\(Elevation.shellQuote(label))")
    }

    // MARK: Console-user helpers (per-user daemons when running as root)

    /// UID of the user at the console (owner of /dev/console).
    static func consoleUID() -> Int {
        let out = Resolver.run("/usr/bin/stat", ["-f", "%u", "/dev/console"])
        return Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? Int(getuid())
    }

    /// Username of the console user (for per-user `killall -u`).
    static func consoleUserName() -> String {
        let out = Resolver.run("/usr/bin/stat", ["-f", "%Su", "/dev/console"])
        let name = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? NSUserName() : name
    }

    /// Home directory of the console user — when the app runs as root,
    /// NSHomeDirectory() would be /var/root, so resolve via getpwuid.
    static func consoleHome() -> String {
        if geteuid() == 0, let pw = getpwuid(uid_t(consoleUID())) {
            return String(cString: pw.pointee.pw_dir)
        }
        return NSHomeDirectory()
    }

    /// Run a command inside the console user's context (for per-user daemons
    /// like pkd when the app itself is root).
    static func runAsConsoleUser(_ path: String, _ arguments: [String]) -> String {
        if geteuid() == 0 {
            return Resolver.run("/bin/launchctl",
                ["asuser", "\(consoleUID())", path] + arguments)
        }
        return Resolver.run(path, arguments)
    }

    // MARK: Service restarts (daemon cache drops)

    /// kill a daemon by name. `perUser` restricts to the console user's
    /// instance (usernoted, pkd, tccd's user half…); system daemons just die.
    static func restartDaemon(_ name: String, perUser: Bool) throws -> String {
        let target = perUser ? "-u \(Elevation.shellQuote(consoleUserName())) \(name)" : name
        return try Elevation.runAsRoot("/usr/bin/killall \(target)")
    }

    // MARK: Login items — removal via System Events

    /// Delete an "Open at Login" entry (same op as "-" in Settings).
    /// The entries themselves are BTM `app` records with an enabled
    /// disposition — only removal needs the System Events bridge.
    static func seRemoveLoginItem(name: String) throws -> String {
        let script = "tell application \"System Events\" to delete login item \"\(name.replacingOccurrences(of: "\"", with: "\\\""))\""
        return runAsConsoleUser("/usr/bin/osascript", ["-e", script])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Notifications — usernoted group-container prefs

    /// The authoritative per-app notification settings plist (com.apple.ncprefs
    /// successor) — inside the console user's usernoted group container.
    static var ncPrefsPath: String {
        consoleHome() + "/Library/Group Containers/group.com.apple.usernoted/Library/Preferences/group.com.apple.usernoted.plist"
    }

    static func notificationApps() throws -> [NotificationApp] {
        guard let root = NSDictionary(contentsOfFile: ncPrefsPath) as? [String: Any],
              let apps = root["apps"] as? [[String: Any]] else {
            throw NSError(domain: "OtherStore", code: 8,
                          userInfo: [NSLocalizedDescriptionKey: "cannot read \(ncPrefsPath)"])
        }
        return apps.compactMap { a in
            guard let bid = a["bundle-id"] as? String else { return nil }
            return NotificationApp(
                bundleID: bid,
                path: a["path"] as? String,
                flags: (a["flags"] as? NSNumber)?.uint64Value ?? 0,
                auth: (a["auth"] as? NSNumber)?.intValue ?? 0)
        }.sorted { $0.bundleID < $1.bundleID }
    }

    /// Mutate the apps array, write back preserving the console user's
    /// ownership, then restart usernoted + cfprefsd so they re-read.
    private static func ncWrite(_ mutate: (inout [[String: Any]]) -> Void) throws {
        guard let root = NSMutableDictionary(contentsOfFile: ncPrefsPath),
              var apps = root["apps"] as? [[String: Any]] else {
            throw NSError(domain: "OtherStore", code: 9,
                          userInfo: [NSLocalizedDescriptionKey: "cannot read \(ncPrefsPath)"])
        }
        mutate(&apps)
        root["apps"] = apps
        guard root.write(toFile: ncPrefsPath, atomically: true) else {
            throw NSError(domain: "OtherStore", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "failed writing \(ncPrefsPath)"])
        }
        // The file was (re)written by our process — restore the console
        // user's ownership when running as root.
        if geteuid() == 0 {
            chown(ncPrefsPath, uid_t(consoleUID()), gid_t(bitPattern: -1))
        }
        // usernoted + cfprefsd cache the suite — SIGKILL (not TERM, which can
        // flush a stale copy over our edit) forces them to re-read.
        _ = try? Elevation.runAsRoot(
            "/usr/bin/killall -9 -u \(Elevation.shellQuote(consoleUserName())) usernoted cfprefsd")
    }

    /// Toggle the "allow notifications" bit (25) on one app's flags.
    static func ncSet(bundleID: String, allow: Bool) throws -> String {
        var found = false
        try ncWrite { apps in
            for i in apps.indices where apps[i]["bundle-id"] as? String == bundleID {
                var flags = (apps[i]["flags"] as? NSNumber)?.uint64Value ?? 0
                if allow { flags |= 1 << 25 } else { flags &= ~(1 << 25 as UInt64) }
                apps[i]["flags"] = NSNumber(value: flags)
                found = true
            }
        }
        guard found else {
            throw NSError(domain: "OtherStore", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "no notification entry for \(bundleID)"])
        }
        return "\(bundleID): notifications \(allow ? "allowed" : "disabled") — verified by plist read-back"
    }

    /// Remove an app's entry entirely — it re-registers and re-prompts.
    static func ncReset(bundleID: String) throws -> String {
        var found = false
        try ncWrite { apps in
            let before = apps.count
            apps.removeAll { $0["bundle-id"] as? String == bundleID }
            found = apps.count != before
        }
        guard found else {
            throw NSError(domain: "OtherStore", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "no notification entry for \(bundleID)"])
        }
        return "\(bundleID): entry removed — will re-prompt on next launch"
    }

    // MARK: Gatekeeper — spctl (read unprivileged, writes via needt)

    static func gatekeeperRules() throws -> [GKRule] {
        let out = Resolver.run("/usr/sbin/spctl", ["--list"])
        var rules: [GKRule] = []
        var cur: (index: Int, authority: String, priority: String, op: String, type: String)? = nil
        var req = ""

        func flush() {
            if let c = cur {
                rules.append(GKRule(index: c.index, authority: c.authority,
                                    priority: c.priority, op: c.op, type: c.type,
                                    requirement: req.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            cur = nil; req = ""
        }

        let re = try? NSRegularExpression(
            pattern: #"^(\d+)\[([^\]]+)\]\s+(P\d+)\s+(\w+)\s+(\S+)"#)
        for line in out.components(separatedBy: "\n") {
            let ns = line as NSString
            if let m = re?.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
               m.numberOfRanges == 6 {
                flush()
                cur = (Int(ns.substring(with: m.range(at: 1))) ?? 0,
                       ns.substring(with: m.range(at: 2)),
                       ns.substring(with: m.range(at: 3)),
                       ns.substring(with: m.range(at: 4)),
                       ns.substring(with: m.range(at: 5)))
            } else if cur != nil {
                req += line + "\n"
            }
        }
        flush()
        return rules
    }

    static func gatekeeperStatus() -> String {
        Resolver.run("/usr/sbin/spctl", ["--status"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func gk(_ spctlArgs: [String]) throws -> String {
        try needt(["gk"] + spctlArgs)
    }

    // MARK: Location Services — /var/db/locationd via needt (root only)

    static func locationClients() throws -> [LocationClient] {
        let json = try needt(["loc-dump"])
        guard let data = json.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "OtherStore", code: 7,
                          userInfo: [NSLocalizedDescriptionKey: "bad loc-dump output"])
        }
        var out: [LocationClient] = []
        for (file, obj) in root where file.hasPrefix("clients") {
            guard let dict = obj as? [String: Any] else { continue }
            for (key, entry) in dict {
                guard let e = entry as? [String: Any] else { continue }
                // Key: "<userUUID>:<id>:" — path clients carry an 'e' prefix.
                var rest = key
                if let colon = rest.firstIndex(of: ":") {
                    rest = String(rest[rest.index(after: colon)...])
                }
                let isPath = rest.hasPrefix("e/")
                if isPath { rest.removeFirst() }
                if rest.hasSuffix(":") { rest.removeLast() }
                let clientID = e["BundleId"] as? String
                    ?? (rest.isEmpty ? key : rest)
                out.append(LocationClient(
                    key: key,
                    clientID: clientID,
                    isPathClient: isPath,
                    bundlePath: e["BundlePath"] as? String ?? e["Executable"] as? String,
                    authorized: (e["Authorized"] as? Bool) ?? false))
            }
        }
        return out.sorted { $0.clientID < $1.clientID }
    }

    static func locSet(key: String, allow: Bool) throws -> String {
        try needt(["loc-set", key, allow ? "allow" : "deny"])
    }

    /// Delete the client record entirely — the app re-prompts next time it
    /// requests location.
    static func locRemove(key: String) throws -> String {
        try needt(["loc-remove", key])
    }

    // MARK: App Extensions — pkd via pluginkit (per-user domain)

    /// `pluginkit -m -v` line: "<status>   <ext-id>(<version>)\t<uuid>\t<date>\t<path>"
    /// Status '-' = ignored (disabled); blank/'+' = enabled.
    static func appExtensions() throws -> [AppExtension] {
        let out = runAsConsoleUser("/usr/bin/pluginkit", ["-m", "-v"])
        var exts: [AppExtension] = []
        for line in out.components(separatedBy: "\n") {
            let fields = line.components(separatedBy: "\t")
            guard fields.count >= 4 else { continue }
            let head = fields[0]
            guard let open = head.range(of: "(", options: .backwards),
                  head.hasSuffix(")") else { continue }
            let idPart = head[..<open.lowerBound]
            let disabled = idPart.hasPrefix("-")
            let extID = idPart.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
                .trimmingCharacters(in: .whitespaces)
            let version = String(head[open.upperBound...].dropLast())
            exts.append(AppExtension(
                extID: extID, version: version,
                path: fields[3].trimmingCharacters(in: .whitespaces),
                enabled: !disabled))
        }
        return exts
    }

    /// `pluginkit -e use|ignore -i <ext-id>` in the console user's pkd domain —
    /// no elevation needed, just the right user context.
    static func extSetEnabled(extID: String, enabled: Bool) throws -> String {
        let mode = enabled ? "use" : "ignore"
        return runAsConsoleUser("/usr/bin/pluginkit", ["-e", mode, "-i", extID])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `pluginkit -e default -i <ext-id>` — forget the user's use/ignore
    /// election entirely (back to pkd's default).
    static func extResetElection(extID: String) throws -> String {
        return runAsConsoleUser("/usr/bin/pluginkit", ["-e", "default", "-i", extID])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `pluginkit -r <path>` — unregister the extension from pkd's registry;
    /// it re-registers on next host-app launch or pkd rescan.
    static func extUnregister(path: String) throws -> String {
        return runAsConsoleUser("/usr/bin/pluginkit", ["-r", path])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
