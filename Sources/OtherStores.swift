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

    // MARK: Background Items — sfltool dumpbtm (unprivileged)

    static func backgroundItems() throws -> [BTMItem] {
        let out = Resolver.run("/usr/bin/sfltool", ["dumpbtm"])
        var items: [BTMItem] = []
        var uid = 0
        var cur: [String: String] = [:]
        var curID = ""

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
                url: nilIfNull(cur["URL"]),
                bundleID: nilIfNull(cur["Bundle Identifier"]),
                parent: nilIfNull(cur["Parent Identifier"]),
                lastUse: nilIfNull(cur["Last Use"]),
                executable: nilIfNull(cur["Executable Path"])))
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

    static func resetBTM() throws -> String {
        try Elevation.runAsRoot("/usr/bin/sfltool resetbtm")
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

    /// Run a command inside the console user's context (for per-user daemons
    /// like pkd when the app itself is root).
    static func runAsConsoleUser(_ path: String, _ arguments: [String]) -> String {
        if geteuid() == 0 {
            return Resolver.run("/bin/launchctl",
                ["asuser", "\(consoleUID())", path] + arguments)
        }
        return Resolver.run(path, arguments)
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
}
