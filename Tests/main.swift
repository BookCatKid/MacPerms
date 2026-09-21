// Self-test for TCCStore write path — exercises the exact functions the app uses.
// Compile: swiftc -O -o selftest Tests/selftest.swift Sources/Model.swift Sources/Database.swift \
//          -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
import Foundation

let client = "dev.macperms.selftest"
let service = "kTCCServiceMicrophone"   // user-DB service
var failures = 0

func check(_ cond: Bool, _ name: String) {
    print("\(cond ? "PASS" : "FAIL")  \(name)")
    if !cond { failures += 1 }
}

let dbs = TCCStore.discoverDatabases()
print("Discovered DBs:")
for d in dbs { print("  [\(d.kind.rawValue)] \(d.url.path)") }
check(dbs.contains { $0.kind == .system }, "system DB discovered")
check(dbs.contains { $0.kind == .user }, "user DB discovered")

guard let userDB = dbs.first(where: { $0.kind == .user }) else {
    print("no user DB — aborting"); exit(2)
}

let all = (try? TCCStore.readRecords(from: userDB)) ?? []
check(!all.isEmpty, "user DB readable, \(all.count) access records")

// 1. grant
let grantSQL = TCCStore.upsertSQL(service: service, client: client, clientType: 0,
                                allow: true, indirectObject: "UNUSED", csreq: nil)
try? TCCStore.apply(sql: grantSQL, to: userDB)
var v = try? TCCStore.verify(service: service, client: client, clientType: 0,
                             indirectObject: "UNUSED", in: userDB)
check(v?.authValue == 2, "grant → auth_value=2 verified by read-back")

// 2. revoke
let denySQL = TCCStore.upsertSQL(service: service, client: client, clientType: 0,
                                 allow: false, indirectObject: "UNUSED", csreq: nil)
try? TCCStore.apply(sql: denySQL, to: userDB)
v = try? TCCStore.verify(service: service, client: client, clientType: 0,
                         indirectObject: "UNUSED", in: userDB)
check(v?.authValue == 0, "revoke → auth_value=0 verified by read-back")

// 3. delete/reset
let delSQL = TCCStore.deleteSQL(service: service, client: client, clientType: 0,
                                indirectObject: "UNUSED")
try? TCCStore.apply(sql: delSQL, to: userDB)
v = try? TCCStore.verify(service: service, client: client, clientType: 0,
                         indirectObject: "UNUSED", in: userDB)
check(v == nil, "delete → record gone")

// 4. system DB readable
if let sysDB = dbs.first(where: { $0.kind == .system }) {
    let sysRecs = (try? TCCStore.readRecords(from: sysDB)) ?? []
    check(!sysRecs.isEmpty, "system DB readable, \(sysRecs.count) records")
}

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
