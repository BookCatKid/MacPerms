import Foundation

/// Plist-level access to /Library/Preferences/com.apple.networkextension.plist —
/// an NSKeyedArchiver file whose $top keys are config UUIDs. Works directly on the
/// archive's $objects array: no private NE classes needed.
/// Shared between the app (reads) and the `needt` root helper (writes).
enum NEPlist {

    static let filePath = "/Library/Preferences/com.apple.networkextension.plist"
    static let privacyPrefix = "com.apple.preferences.networkprivacy"

    struct Rule: Hashable, Identifiable {
        var id: String { signingID }
        let signingID: String
        let path: String?
        let denyMulticast: Bool
        let multicastPreferenceSet: Bool
        let denyAll: Bool
        let isDefault: Bool
        var allowed: Bool { !denyMulticast }
        var status: String {
            isDefault ? "Default" : (denyMulticast ? "Denied" : "Allowed")
        }
    }

    struct Config: Hashable {
        let uuid: String        // $top key
        let name: String        // e.g. com.apple.preferences.networkprivacy-<userUUID>
        let rules: [Rule]
        var userUUID: String? {
            name.hasPrefix(privacyPrefix)
                ? String(name.dropFirst(privacyPrefix.count + 1)) : nil
        }
    }

    // MARK: - Raw archive helpers

    /// UID index of a ref value. Handles both representations:
    /// {"CF$UID": n} dicts (XML) and CFKeyedArchiverUID objects (binary plist).
    static func uidIndex(_ v: Any?) -> Int? {
        if let d = v as? [String: Any], let uid = d["CF$UID"] as? Int { return uid }
        // Binary-plist UID refs parse as opaque CFKeyedArchiverUID objects
        // (class __NSCFType); its C accessors aren't exported on macOS 27,
        // so read the index out of its description "<CFKeyedArchiverUID…>{value = N}".
        if let o = v as AnyObject?, NSStringFromClass(type(of: o)) == "__NSCFType",
           let desc = o.description, desc.hasPrefix("<CFKeyedArchiverUID"),
           let r = desc.range(of: #"\{value = (\d+)\}"#, options: .regularExpression) {
            return Int(desc[r].dropFirst("{value = ".count).dropLast())
        }
        return nil
    }

    /// Resolve a UID ref or literal against the $objects array.
    static func resolve(_ v: Any?, _ objects: [Any]) -> Any? {
        if let uid = uidIndex(v) {
            guard uid > 0, uid < objects.count else { return nil }
            return objects[uid]
        }
        return v
    }

    /// NSKeyedArchiver stores NSArrays as {$class: NSArray, NS.objects: [refs]}.
    static func resolveArray(_ v: Any?, _ objects: [Any]) -> [Any]? {
        let r = resolve(v, objects)
        if let d = r as? [String: Any], let arr = d["NS.objects"] as? [Any] { return arr }
        return r as? [Any]
    }

    static func className(of dict: [String: Any], _ objects: [Any]) -> String? {
        guard let cls = resolve(dict["$class"], objects) as? [String: Any] else { return nil }
        return cls["$classname"] as? String
    }

    static func boolField(_ dict: [String: Any], _ key: String, _ objects: [Any]) -> Bool {
        (resolve(dict[key], objects) as? NSNumber)?.boolValue ?? false
    }

    /// Parse all NEConfiguration entries; returns configs with rules.
    static func parse(data: Data) throws -> [Config] {
        guard let plist = try PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any],
              let objects = plist["$objects"] as? [Any],
              let top = plist["$top"] as? [String: Any] else {
            throw NSError(domain: "NEPlist", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "not a keyed archive"])
        }
        var configs: [Config] = []
        for (uuid, ref) in top {
            guard uuid.contains("-"),
                  let cfg = resolve(ref, objects) as? [String: Any],
                  className(of: cfg, objects) == "NEConfiguration" else { continue }
            let name = resolve(cfg["Name"], objects) as? String ?? ""
            var rules: [Rule] = []
            if let pc = resolve(cfg["PathController"], objects) as? [String: Any],
               let arr = resolveArray(pc["Rules"], objects) {
                for rref in arr {
                    guard let r = resolve(rref, objects) as? [String: Any],
                          className(of: r, objects)?.hasPrefix("NE") == true else { continue }
                    let signingID = resolve(r["SigningIdentifier"], objects) as? String ?? ""
                    let path = resolve(r["Path"], objects) as? String
                    rules.append(Rule(
                        signingID: signingID,
                        path: path,
                        denyMulticast: boolField(r, "DenyMulticast", objects),
                        multicastPreferenceSet: boolField(r, "MulticastPreferenceSet", objects),
                        denyAll: boolField(r, "DenyAll", objects),
                        isDefault: signingID.hasPrefix("PathRuleDefault")))
                }
            }
            configs.append(Config(uuid: uuid, name: name, rules: rules))
        }
        return configs
    }

    // MARK: - Write surgery (mutable containers)

    /// Set DenyMulticast (+ MulticastPreferenceSet) for a signing id inside the
    /// mutable $objects array. Returns number of rules modified.
    @discardableResult
    static func setRule(in objects: NSMutableArray, signingID: String,
                        deny: Bool, preferenceSet: Bool) -> Int {
        var changed = 0
        for i in 0..<objects.count {
            guard let r = objects[i] as? NSMutableDictionary else { continue }
            guard let uid = uidIndex(r["SigningIdentifier"]), uid < objects.count,
                  (objects[uid] as? String) == signingID else { continue }
            var mutated = false
            func setBool(_ key: String, _ val: Bool) {
                if let u = uidIndex(r[key]), u > 0, u < objects.count {
                    objects[u] = NSNumber(value: val)   // bool stored as UID ref
                    mutated = true
                } else {
                    r[key] = NSNumber(value: val)        // bool stored as literal
                    mutated = true
                }
            }
            setBool("DenyMulticast", deny)
            setBool("MulticastPreferenceSet", preferenceSet)
            if mutated { changed += 1 }
        }
        return changed
    }

    /// Remove every array ref pointing at a rule with `signingID` — deletes
    /// the record from each config's Rules list. The orphaned rule dict
    /// stays in $objects (unreferenced, harmless — nehelper prunes it on
    /// its next write).
    @discardableResult
    static func removeRule(in objects: NSMutableArray, signingID: String) -> Int {
        var removed = 0
        for i in 0..<objects.count {
            guard let arr = objects[i] as? NSMutableDictionary,
                  let list = arr["NS.objects"] as? NSMutableArray else { continue }
            var j = 0
            while j < list.count {
                if let uid = uidIndex(list[j]), uid > 0, uid < objects.count,
                   let r = objects[uid] as? [String: Any],
                   let suid = uidIndex(r["SigningIdentifier"]), suid < objects.count,
                   (objects[suid] as? String) == signingID {
                    list.removeObject(at: j)
                    removed += 1
                } else { j += 1 }
            }
        }
        return removed
    }
}
