import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum TCCStoreError: LocalizedError {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case verifyFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let m): return "Cannot open database: \(m)"
        case .prepareFailed(let m): return "SQL prepare failed: \(m)"
        case .stepFailed(let m): return "SQL execution failed: \(m)"
        case .verifyFailed(let m): return "Verification failed: \(m)"
        }
    }
}

final class SQLiteDB {
    let path: String
    private(set) var db: OpaquePointer?

    init(path: String, readOnly: Bool = true) throws {
        self.path = path
        var d: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        if sqlite3_open_v2(path, &d, flags, nil) != SQLITE_OK {
            let msg = d.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(d)
            throw TCCStoreError.openFailed("\(path): \(msg)")
        }
        self.db = d
        sqlite3_busy_timeout(d, 3000)
    }

    deinit { sqlite3_close(db) }

    func columnNames(_ table: String) -> [String] {
        var names: [String] = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK else { return [] }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 1) { names.append(String(cString: c)) }
        }
        sqlite3_finalize(stmt)
        return names
    }

    /// Generic row fetch — returns array of column-indexed rows for `SELECT <cols> FROM <table> <where>`.
    func select(_ table: String, where clause: String = "") throws -> [[String: Any?]] {
        var stmt: OpaquePointer?
        let sql = "SELECT * FROM \(table) \(clause.isEmpty ? "" : "WHERE \(clause)")"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw TCCStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        let n = sqlite3_column_count(stmt)
        var out: [[String: Any?]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: Any?] = [:]
            for i in 0..<n {
                let name = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: row[name] = Int(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT:   row[name] = sqlite3_column_double(stmt, i)
                case SQLITE_TEXT:
                    row[name] = sqlite3_column_text(stmt, i).map { String(cString: $0) }
                case SQLITE_BLOB:
                    let len = sqlite3_column_bytes(stmt, i)
                    row[name] = len > 0 ? Data(bytes: sqlite3_column_blob(stmt, i), count: Int(len)) : Data()
                default: row[name] = nil
                }
            }
            out.append(row)
        }
        return out
    }

    func execute(_ sql: String, bind: ((OpaquePointer?) -> Void)? = nil) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw TCCStoreError.prepareFailed("\(String(cString: sqlite3_errmsg(db))) [\(sql)]")
        }
        defer { sqlite3_finalize(stmt) }
        bind?(stmt)
        if sqlite3_step(stmt) != SQLITE_DONE {
            throw TCCStoreError.stepFailed("\(String(cString: sqlite3_errmsg(db))) [\(sql)]")
        }
    }
}

// Convenience binders
func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ s: String) {
    sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
}
func bindBlob(_ stmt: OpaquePointer?, _ idx: Int32, _ d: Data?) {
    if let d, !d.isEmpty {
        _ = d.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(d.count), SQLITE_TRANSIENT) }
    } else {
        sqlite3_bind_null(stmt, idx)
    }
}

// MARK: - TCC store

final class TCCStore {
    /// Discover all TCC databases on this machine.
    static func discoverDatabases() -> [TCCDatabaseFile] {
        var out: [TCCDatabaseFile] = []
        let sys = URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC/TCC.db")
        if FileManager.default.fileExists(atPath: sys.path) {
            out.append(TCCDatabaseFile(url: sys, kind: .system))
        }
        // macOS 27: per-user DBs live under ProtectedSystem containers.
        let fm = FileManager.default
        if let dirs = try? fm.contentsOfDirectory(atPath: "/private/var/containers/Data/ProtectedSystem") {
            for d in dirs {
                let p = "/private/var/containers/Data/ProtectedSystem/\(d)/Data/Library/Application Support/com.apple.TCC/TCC.db"
                if fm.fileExists(atPath: p), fm.isReadableFile(atPath: p) {
                    out.append(TCCDatabaseFile(url: URL(fileURLWithPath: p), kind: .user))
                }
            }
        }
        // Legacy path fallback + REG.db trusted paths.
        let home = NSHomeDirectory()
        let legacy = "\(home)/Library/Application Support/com.apple.TCC/TCC.db"
        if fm.fileExists(atPath: legacy) {
            out.append(TCCDatabaseFile(url: URL(fileURLWithPath: legacy), kind: .user))
        }
        if let reg = try? SQLiteDB(path: "/Library/Application Support/com.apple.TCC/REG.db"),
           let rows = try? reg.select("registry") {
            for r in rows {
                guard let p = r["abs_path"] as? String,
                      let trusted = r["trusted"] as? Int, trusted == 1,
                      p != sys.path, fm.isReadableFile(atPath: p) else { continue }
                let kind: TCCDatabaseFile.Kind = p.hasPrefix("/Library/") ? .system : .user
                out.append(TCCDatabaseFile(url: URL(fileURLWithPath: p), kind: kind))
            }
        }
        // dedupe
        var seen = Set<String>()
        return out.filter { seen.insert($0.url.path).inserted }
    }

    static func readRecords(from dbFile: TCCDatabaseFile) throws -> [TCCRecord] {
        let db = try SQLiteDB(path: dbFile.url.path, readOnly: true)
        var records: [TCCRecord] = []

        let makeRecord: ([String: Any?], Bool) -> TCCRecord = { row, managed in
            TCCRecord(
                db: dbFile,
                service: row["service"] as? String ?? "",
                client: row["client"] as? String ?? "",
                clientType: row["client_type"] as? Int ?? 0,
                authValue: row["auth_value"] as? Int ?? 1,
                authReason: row["auth_reason"] as? Int ?? 0,
                authVersion: row["auth_version"] as? Int ?? 1,
                csreq: row["csreq"] as? Data,
                policyID: row["policy_id"] as? Int,
                indirectObject: row["indirect_object_identifier"] as? String ?? "UNUSED",
                flags: row["flags"] as? Int ?? 0,
                lastModified: Date(timeIntervalSince1970: (row["last_modified"] as? Int).map { TimeInterval($0) } ?? 0),
                managed: managed,
                adminAuthValue: row["admin_auth_value"] as? Int
            )
        }

        for row in try db.select("access") { records.append(makeRecord(row, false)) }
        if db.columnNames("managed_overrides").count > 0 {
            for row in try db.select("managed_overrides") { records.append(makeRecord(row, true)) }
        }
        return records
    }

    // MARK: Writes (caller must have write permission on the file)

    /// SQL text for a grant/deny upsert — shared between the direct-write path and
    /// the privileged-helper path (same statement either way).
    static func upsertSQL(service: String, client: String, clientType: Int,
                          allow: Bool, indirectObject: String, csreq: Data?) -> String {
        let authValue = allow ? 2 : 0
        let csreqLiteral: String
        if let csreq, !csreq.isEmpty {
            csreqLiteral = "X'\(csreq.map { String(format: "%02x", $0) }.joined())'"
        } else { csreqLiteral = "NULL" }
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }
        return """
        INSERT OR REPLACE INTO access \
        (service, client, client_type, auth_value, auth_reason, auth_version, csreq, \
        policy_id, indirect_object_identifier, flags, pid, pid_version, boot_uuid, \
        one_time_reprompt_eligible, last_reminded, reminder_count) VALUES (\
        \(q(service)), \(q(client)), \(clientType), \(authValue), 3, 1, \(csreqLiteral), \
        NULL, \(q(indirectObject)), 0, NULL, NULL, 'UNUSED', NULL, \
        CAST(strftime('%s','now') AS INTEGER), 0)
        """
    }

    static func deleteSQL(service: String, client: String, clientType: Int,
                          indirectObject: String) -> String {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }
        return """
        DELETE FROM access WHERE service=\(q(service)) AND client=\(q(client)) \
        AND client_type=\(clientType) AND indirect_object_identifier=\(q(indirectObject))
        """
    }

    /// Apply SQL directly to a user-writable DB file.
    static func apply(sql: String, to dbFile: TCCDatabaseFile) throws {
        let db = try SQLiteDB(path: dbFile.url.path, readOnly: false)
        try db.execute(sql)
    }

    /// Read back a specific row to verify a change took effect.
    static func verify(service: String, client: String, clientType: Int,
                       indirectObject: String, in dbFile: TCCDatabaseFile) throws -> TCCRecord? {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }
        let db = try SQLiteDB(path: dbFile.url.path, readOnly: true)
        let rows = try db.select("access", where: """
            service=\(q(service)) AND client=\(q(client)) AND client_type=\(clientType) \
            AND indirect_object_identifier=\(q(indirectObject))
            """)
        guard let row = rows.first else { return nil }
        return TCCRecord(
            db: dbFile,
            service: row["service"] as? String ?? "",
            client: row["client"] as? String ?? "",
            clientType: row["client_type"] as? Int ?? 0,
            authValue: row["auth_value"] as? Int ?? 1,
            authReason: row["auth_reason"] as? Int ?? 0,
            authVersion: row["auth_version"] as? Int ?? 1,
            csreq: row["csreq"] as? Data,
            policyID: row["policy_id"] as? Int,
            indirectObject: row["indirect_object_identifier"] as? String ?? "UNUSED",
            flags: row["flags"] as? Int ?? 0,
            lastModified: Date(timeIntervalSince1970: (row["last_modified"] as? Int).map { TimeInterval($0) } ?? 0),
            managed: false,
            adminAuthValue: nil
        )
    }
}
