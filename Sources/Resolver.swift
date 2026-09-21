import Foundation
import AppKit

enum Resolver {
    private static var cache: [String: ClientIdentity] = [:]

    /// Resolve a TCC client (bundle id / signing identifier, or absolute path) to a
    /// display name + icon.
    static func identity(for client: String, clientType: Int) -> ClientIdentity {
        let key = "\(clientType)|\(client)"
        if let c = cache[key] { return c }

        var result: ClientIdentity
        if clientType == 0 {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: client) {
                result = appIdentity(url: url, fallback: client)
            } else {
                result = ClientIdentity(
                    name: client,
                    icon: NSImage(systemSymbolName: "questionmark.square.dashed",
                                  accessibilityDescription: nil) ?? NSImage(),
                    appURL: nil, isPathClient: false)
            }
        } else {
            let url = URL(fileURLWithPath: client)
            // Walk up to an enclosing .app bundle if present.
            var u = url
            var bundleURL: URL?
            while u.path != "/" {
                if u.pathExtension == "app" { bundleURL = u; break }
                u.deleteLastPathComponent()
            }
            if let b = bundleURL {
                result = appIdentity(url: b, fallback: url.lastPathComponent)
                result = ClientIdentity(name: result.name + " (\(url.lastPathComponent))",
                                        icon: result.icon, appURL: result.appURL,
                                        isPathClient: true)
            } else {
                let icon = FileManager.default.fileExists(atPath: client)
                    ? NSWorkspace.shared.icon(forFile: client)
                    : NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)!
                result = ClientIdentity(name: url.lastPathComponent, icon: icon,
                                        appURL: FileManager.default.fileExists(atPath: client) ? url : nil,
                                        isPathClient: true)
            }
        }
        cache[key] = result
        return result
    }

    private static func appIdentity(url: URL, fallback: String) -> ClientIdentity {
        let bundle = Bundle(url: url)
        let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        return ClientIdentity(name: name, icon: NSWorkspace.shared.icon(forFile: url.path),
                              appURL: url, isPathClient: false)
    }

    /// Decode a csreq blob to its requirement text (via /usr/bin/csreq).
    static func csreqText(_ blob: Data) -> String? {
        let tmp = NSTemporaryDirectory() + "tccmgr-csreq-\(UUID().uuidString).bin"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        guard (try? blob.write(to: URL(fileURLWithPath: tmp))) != nil else { return nil }
        return run("/usr/bin/csreq", ["-r", tmp, "-t"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Compute the designated-requirement blob for an app bundle.
    static func designatedRequirement(for appURL: URL) -> Data? {
        let out = run("/usr/bin/codesign", ["-d", "-r-", appURL.path])
        guard let line = out.split(separator: "\n").first(where: { $0.contains("designated =>") }),
              let req = line.split(separator: " ").dropFirst(2).joined(separator: " ") as String?,
              !req.isEmpty else { return nil }
        let tmp = NSTemporaryDirectory() + "tccmgr-dr-\(UUID().uuidString).bin"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/csreq")
        proc.arguments = ["-r", "-", "-b", tmp]
        let pipe = Pipe()
        proc.standardInput = pipe
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return nil }
        pipe.fileHandleForWriting.write(req.data(using: .utf8)!)
        pipe.fileHandleForWriting.closeFile()
        proc.waitUntilExit()
        return try? Data(contentsOf: URL(fileURLWithPath: tmp))
    }

    static func run(_ path: String, _ args: [String]) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return "" }
        // Read before waitUntilExit — drains the pipe so large outputs don't deadlock.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
