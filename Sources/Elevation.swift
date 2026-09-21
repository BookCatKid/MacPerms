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
    /// True when the app itself is already running as root (launched via the
    /// administrator-auth wrapper) — privileged commands then run directly.
    static var isRoot: Bool { geteuid() == 0 }

    /// Run a shell command directly (used when the process is already root).
    /// Throws on non-zero exit, matching the osascript path.
    private static func runDirect(_ command: String) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", command]
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        guard (try? proc.run()) != nil else {
            throw ElevationError.helperFailed("failed to spawn /bin/sh")
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let msg = String(data: errData, encoding: .utf8) ?? "exit \(proc.terminationStatus)"
            throw ElevationError.helperFailed(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }

    /// Run a command as root using `do shell script ... with administrator privileges`.
    /// Presents the standard macOS administrator-auth dialog (password or Touch ID).
    /// When the app itself runs as root, executes directly — no prompt.
    @discardableResult
    static func runAsRoot(_ command: String) throws -> String {
        if isRoot { return try runDirect(command) }
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
