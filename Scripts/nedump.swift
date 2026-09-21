// Dump local-network (and other) NEConfiguration records from
// /Library/Preferences/com.apple.networkextension.plist
import Foundation

let path = "/Library/Preferences/com.apple.networkextension.plist"
guard let data = FileManager.default.contents(atPath: path) else { print("cannot read"); exit(1) }
dlopen("/System/Library/Frameworks/NetworkExtension.framework/NetworkExtension", RTLD_NOW)

let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
let top = plist["$top"] as! [String: Any]

let un = try NSKeyedUnarchiver(forReadingFrom: data)
un.requiresSecureCoding = false
un.decodingFailurePolicy = .setErrorAndReturn

func get(_ o: AnyObject, _ key: String) -> Any? {
    if let v = o.value(forKey: key), !(v is NSNull) { return v }
    return nil
}

for key in top.keys.sorted() where key.contains("-") {
    guard let c = un.decodeObject(forKey: key) as AnyObject? else { continue }
    let cls = NSStringFromClass(type(of: c))
    guard cls == "NEConfiguration" else { print("== \(key): <\(cls)>"); continue }
    let name = get(c, "name") ?? "?"
    let app = get(c, "application") ?? get(c, "applicationIdentifier")
    print("== config \(key)\n   name=\(name) app=\(app ?? "nil") appName=\(get(c,"applicationName") ?? "nil") grade=\(get(c,"grade") ?? "nil") enabled=\(get(c,"isEnabled") ?? "nil")")
    if let pc = get(c, "pathController") as AnyObject? {
        let rules = (get(pc, "pathRules") as? [AnyObject]) ?? []
        print("   pathController: enabled=\(get(pc,"enabled") ?? "nil") rules=\(rules.count)")
        for r in rules {
            let sig = get(r, "matchSigningIdentifier") ?? "?"
            print("     rule: id=\(sig) denyAll=\(get(r,"denyAll") ?? "nil") denyMulticast=\(get(r,"denyMulticast") ?? "nil") denyCellFallback=\(get(r,"denyCellularFallback") ?? "nil") wifiBehavior=\(get(r,"wifiBehavior") ?? "nil") cellBehavior=\(get(r,"cellularBehavior") ?? "nil") default=\(get(r,"defaultPathRule") ?? "nil") extId=\(get(r,"isIdentifierExternal") ?? "nil") mcastSet=\(get(r,"multicastPreferenceSet") ?? "nil") tmpAllow=\(get(r,"temporaryAllowMulticastNetworkName") ?? "nil")")
            if let p = get(r, "matchPath") { print("        path=\(p)") }
            if let d = get(r, "matchDomains") { print("        domains=\(d)") }
            if let t = get(r, "matchTools") { print("        tools=\(t)") }
        }
    }
}
un.finishDecoding()
