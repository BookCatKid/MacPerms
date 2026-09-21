import SwiftUI

@main
struct TCCManagerApp: App {
    @StateObject private var model = TCCViewModel()
    @StateObject private var stores = OtherStoresModel()

    init() {
        Self.relaunchAsRootIfNeeded()
    }

    /// Re-exec this binary as root via the standard administrator-auth dialog,
    /// then quit. The elevated process still renders in the user's GUI session.
    /// All privileged store ops detect geteuid()==0 and skip per-op prompts.
    /// Cancelling the dialog simply means the app doesn't start.
    private static func relaunchAsRootIfNeeded() {
        guard geteuid() != 0,
              !CommandLine.arguments.contains("--no-elevate"),
              let bin = Bundle.main.executablePath else { return }
        let escaped = bin
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        // Do NOT wait for osascript — it blocks until the GUI app exits.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e",
            "do shell script \"\(escaped)\" with prompt \"TCC Manager runs as root — all permission edits apply without further prompts.\" with administrator privileges"]
        try? proc.run()
        exit(0)
    }

    var body: some Scene {
        WindowGroup("TCC Manager") {
            ContentView()
                .environmentObject(model)
                .environmentObject(stores)
                .frame(minWidth: 980, minHeight: 600)
        }
    }
}
