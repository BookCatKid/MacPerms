import Foundation

enum ElevationError: LocalizedError {
    case helperMissing
    case appleScript(String)
    case helperFailed(String)

    var errorDescription: String? {
        switch self {
        case .helperMissing: return "Privileged helper script missing from app bundle"
        case .appleScript(let m): return "Admin authorization failed: \(m)"
        case .helperFailed(let m): return "Privileged operation failed: \(m)"
        }
    }
}

enum Elevation {
    /// Run a command as root using `do shell script ... with administrator privileges`.
    /// Presents the standard macOS administrator-auth dialog (password or Touch ID).
    @discardableResult
    static func runAsRoot(_ command: String) throws -> String {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let msg = error[NSAppleScript.errorMessage] as? String ?? "\(error)"
            throw ElevationError.appleScript(msg)
        }
        return result?.stringValue ?? ""
    }

    /// Apply a SQL statement to the system TCC.db as root.
    static func systemWrite(sql: String, restartTCCD: Bool) throws {
        guard let helper = Bundle.main.path(forResource: "tcc-system-write", ofType: "sh") else {
            throw ElevationError.helperMissing
        }
        let cmd = "\(shellQuote(helper)) \(shellQuote(sql)) \(restartTCCD ? "restart" : "")".trimmingCharacters(in: .whitespaces)
        let out = try runAsRoot(cmd)
        if !out.contains("OK") { throw ElevationError.helperFailed(out) }
    }

    static func restartSystemTCCD() throws {
        try runAsRoot("/usr/bin/killall tccd")
    }

    /// Restart the per-user tccd (no privileges needed — we own it).
    static func restartUserTCCD() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        proc.arguments = ["tccd"]
        try? proc.run()
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
