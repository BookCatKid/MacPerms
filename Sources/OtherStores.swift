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
                lastUse: nilIfNull(cur["Last Use"])))
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
            for (bundleID, entry) in dict {
                guard let e = entry as? [String: Any] else { continue }
                out.append(LocationClient(
                    bundleID: bundleID,
                    authorized: (e["Authorized"] as? Bool) ?? false,
                    executable: e["Executable"] as? String))
            }
        }
        return out.sorted { $0.bundleID < $1.bundleID }
    }

    static func locSet(bundleID: String, allow: Bool) throws -> String {
        try needt(["loc-set", bundleID, allow ? "allow" : "deny"])
    }
}
