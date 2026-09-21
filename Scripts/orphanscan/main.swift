// orphanscan — diagnostic: list permission records whose app is gone.
// Compiles against the app's shared sources; run as root so every store
// (system TCC.db, /var/db/locationd, NE archive) is readable.
//
//   swiftc -O -o /tmp/orphanscan Scripts/orphanscan/main.swift \
//     Sources/{Model,Database,NEPlist,OtherStores,OtherModel,Resolver,Elevation}.swift \
//     -target arm64-apple-macosx15.0 -sdk $(xcrun --show-sdk-path)
import Foundation
import AppKit

let fm = FileManager.default

func pathExists(_ p: String?) -> Bool {
    guard let p, !p.isEmpty else { return false }
    if p.hasPrefix("file://"), let u = URL(string: p) { return fm.fileExists(atPath: u.path) }
    return fm.fileExists(atPath: p)
}
func bidResolves(_ bid: String) -> Bool {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) != nil
}
func sysID(_ bid: String) -> Bool {
    bid.hasPrefix("com.apple.") || bid.hasPrefix("com.microsoft.")
}

print("== TCC ==")
for db in TCCStore.discoverDatabases() {
    let recs = (try? TCCStore.readRecords(from: db)) ?? []
    for r in recs {
        let orphan: Bool
        if r.clientType == 1 || r.client.hasPrefix("/") {
            orphan = !pathExists(r.client)
        } else {
            orphan = !sysID(r.client) && !bidResolves(r.client)
        }
        if orphan {
            print("  [\(db.kind.rawValue)] \(r.service)  \(r.client)  type=\(r.clientType) managed=\(r.managed)")
        }
    }
}

print("== Local Network ==")
if let cfgs = try? OtherStore.localNetworkConfigs() {
    for c in cfgs {
        for r in c.rules where !r.isDefault {
            if !pathExists(r.path) && !sysID(r.signingID) && !bidResolves(r.signingID) {
                print("  \(c.name)  \(r.signingID)  path=\(r.path ?? "-")")
            }
        }
    }
}

print("== Location Services ==")
for name in ["clients.plist", "clients-b.plist"] {
    let p = "/var/db/locationd/\(name)"
    guard let dict = NSDictionary(contentsOfFile: p) as? [String: Any] else { continue }
    for (key, e) in dict {
        guard let e = e as? [String: Any] else { continue }
        var rest = key
        if let c = rest.firstIndex(of: ":") { rest = String(rest[rest.index(after: c)...]) }
        let isPath = rest.hasPrefix("e/")
        if isPath { rest.removeFirst() }
        if rest.hasSuffix(":") { rest.removeLast() }
        let bid = e["BundleId"] as? String ?? rest
        let bp = e["BundlePath"] as? String ?? e["Executable"] as? String
        let orphan = isPath ? !pathExists(bid)
                            : (!pathExists(bp) && !sysID(bid) && !bidResolves(bid))
        if orphan { print("  \(name)  \(key)  bid=\(bid) path=\(bp ?? "-")") }
    }
}

print("== Notifications ==")
if let root = NSDictionary(contentsOfFile: OtherStore.ncPrefsPath) as? [String: Any],
   let apps = root["apps"] as? [[String: Any]] {
    for a in apps {
        guard let bid = a["bundle-id"] as? String else { continue }
        let path = a["path"] as? String
        let real = bid.hasPrefix("_SYSTEM_CENTER_:")
            ? String(bid.dropFirst("_SYSTEM_CENTER_:".count)) : bid
        if !pathExists(path) && !sysID(real) && !bidResolves(real) {
            print("  \(bid)  path=\(path ?? "-")")
        }
    }
}

print("== App Extensions ==")
for line in OtherStore.runAsConsoleUser("/usr/bin/pluginkit", ["-m", "-v"])
        .components(separatedBy: "\n") {
    let f = line.components(separatedBy: "\t")
    guard f.count >= 4 else { continue }
    let path = f[3].trimmingCharacters(in: .whitespaces)
    if !path.isEmpty && !pathExists(path) { print("  \(line)") }
}

print("== Background/Login Items (BTM) ==")
if let items = try? OtherStore.backgroundItems() {
    // Mirror the app's liveParents logic: a BTM record whose bundle id is
    // verifiably alive protects sibling helper/plugin records that prefix it.
    var liveParents = Set<String>()
    for i in items {
        guard let bid = i.bundleID, !bid.isEmpty else { continue }
        if pathExists(i.url) || pathExists(i.executable) || bidResolves(bid) {
            liveParents.insert(bid)
        }
    }
    for i in items {
        func label() -> String {
            let parts = i.identifier.split(separator: ".", maxSplits: 1)
            return parts.count == 2 && parts[0].allSatisfy(\.isNumber)
                ? String(parts[1]) : i.identifier
        }
        var orphan = false
        if pathExists(i.executable) || pathExists(i.url) {
            orphan = false
        } else if liveParents.contains(where: { label().hasPrefix($0) }) {
            orphan = false
        } else if let bid = i.bundleID {
            orphan = !sysID(bid) && !bidResolves(bid)
        } else {
            orphan = i.executable != nil || i.url != nil
        }
        if orphan {
            print("  [\(i.type)] \(i.name)  id=\(i.identifier) exec=\(i.executable ?? "-") url=\(i.url ?? "-") bid=\(i.bundleID ?? "-")")
        }
    }
}
print("== done ==")
