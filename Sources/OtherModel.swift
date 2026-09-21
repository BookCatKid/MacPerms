import Foundation

enum OtherPane: String, CaseIterable, Identifiable, Hashable {
    case localNetwork = "Local Network"
    case loginItems = "Login Items"
    case backgroundItems = "Background Items"
    case appExtensions = "App Extensions"
    case gatekeeper = "Gatekeeper"
    case location = "Location Services"
    case notifications = "Notifications"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .localNetwork: return "network"
        case .loginItems: return "person.crop.rectangle.stack"
        case .backgroundItems: return "gear.badge"
        case .appExtensions: return "puzzlepiece.extension"
        case .gatekeeper: return "checkmark.shield"
        case .location: return "location"
        case .notifications: return "bell"
        }
    }
    var helpText: String {
        switch self {
        case .localNetwork:
            return "Local Network decisions are enforced by nehelper (com.apple.network.localnetworkdecision) and stored per-user inside the NetworkExtension keyed archive /Library/Preferences/com.apple.networkextension.plist.\n\nDenyMulticast is the allow/deny flag; MulticastPreferenceSet marks an explicit user choice. Apps need NSLocalNetworkUsageDescription to be prompted.\n\nWrites go through SCPreferences as root — the archive round-trip is verified, but whether nehelper honors a write without restart is unverified; relaunch the app to test."
        case .loginItems:
            return "Open-at-login items registered through SMAppService / SMLoginItem — System Settings → General → Login Items & Extensions → Open at Login.\n\nEach item is a launchd service in the gui domain, so Enable/Disable maps to `launchctl enable|disable gui/<uid>/<label>` — the same state Settings toggles (print-disabled state mirrors the BTM disposition)."
        case .backgroundItems:
            return "Launch agents/daemons and app background activity — managed by backgroundtaskmanagementd via binary .btm files. This is System Settings → General → Login Items & Extensions → Allow in the Background.\n\nsfltool exposes no per-item toggle, but every launchd-backed item's enabled state lives in `launchctl print-disabled` — Enable/Disable writes that registry directly (state shown per row; launchd value wins when present). Grouping records (developer/app/dock tile) are not services and stay read-only.\n\n'Reset ALL' runs sfltool resetbtm — the nuclear option: every item re-registers on next launch."
        case .appExtensions:
            return "App extensions (.appex plug-ins — share sheets, Quick Look, widgets, Finder sync…) managed by pkd and listed via `pluginkit`.\n\nEnable/disable writes the per-user use/ignore election via `pluginkit -e use|ignore`, run inside the console user's domain."
        case .gatekeeper:
            return "Gatekeeper assessment rules, managed by syspolicyd and backed by /var/db/SystemPolicyConfiguration/ExecPolicy.\n\nReads use `spctl --list` (unprivileged). Enable/disable/remove operate on a rule's label via `spctl` as root — one admin prompt per batch."
        case .location:
            return "Per-app Location Services authorization is locationd's own store (clients plists under /var/db/locationd), not TCC — reading it requires root.\n\nClient keys are composite (<userUUID>:<bundleID>: or <userUUID>:e<path>:); the real identity comes from each entry's BundleId/BundlePath/Executable.\n\nToggling writes the `Authorized` flag directly — an UNVERIFIED write path on macOS 27: locationd may ignore it until restarted. Relaunch the app to test."
        case .notifications:
            return "Per-app notification authorization is managed by usernoted/Notification Center — but the authoritative store has not been located on macOS 27 yet.\n\nChecked: com.apple.ncprefs (prefs only), the db2 sqlite under com.apple.notificationcenter containers (absent on 27), Biome notification streams (event history, not authorization).\n\nNo mutation is offered until the store is mapped and a safe write path is verified."
        }
    }
}

struct BTMItem: Identifiable, Hashable {
    let uid: Int
    let itemUUID: String
    let name: String
    let developer: String?
    let teamID: String?
    let type: String
    let disposition: Int
    let identifier: String
    let url: String?
    let bundleID: String?
    let parent: String?
    let lastUse: String?
    let executable: String?
    var id: String { "\(uid)|\(itemUUID)" }
    var enabled: Bool { disposition & 0x1 != 0 }
    var allowed: Bool { disposition & 0x2 != 0 }
    var notified: Bool { disposition & 0x8 != 0 }
    var status: String { allowed ? "Allowed" : "Disallowed" }
    /// launchd label — BTM identifiers carry a location-type prefix ("16.org.foo").
    var launchdLabel: String {
        let parts = identifier.split(separator: ".", maxSplits: 1)
        if parts.count == 2, parts[0].allSatisfy(\.isNumber) { return String(parts[1]) }
        return identifier
    }
    /// launchd domain this item lives in: system daemons vs per-user gui domain.
    var launchdDomain: String { uid > 0 ? "gui/\(uid)" : "system" }
    /// True for actual services (agents, daemons, login items) — launchctl can
    /// disable them even with no existing print-disabled entry. Grouping
    /// records (developer/app/dock tile/background tasks) are not services.
    var isServiceType: Bool {
        type.contains("agent") || type.contains("daemon") || type.contains("login")
    }
}

struct GKRule: Identifiable, Hashable {
    let index: Int
    let authority: String
    let priority: String
    let op: String
    let type: String
    let requirement: String
    var id: Int { index }
}

/// locationd clients.plist entry. Keys are composite:
///   "<userUUID>:<bundleID>:"      — bundled app client
///   "<userUUID>:e<path>:"         — executable-path client
/// The real identity is inside the entry (BundleId / BundlePath / Executable).
struct LocationClient: Identifiable, Hashable {
    let key: String            // raw plist key — required by loc-set
    let clientID: String       // bundle id or executable path (for display)
    let isPathClient: Bool
    let bundlePath: String?    // containing .app, for icon resolution
    let authorized: Bool
    var id: String { key }
}

/// A pkd-managed .appex plug-in (share sheets, Quick Look, widgets, …).
struct AppExtension: Identifiable, Hashable {
    let extID: String
    let version: String
    let path: String
    let enabled: Bool          // pluginkit '-' marker means ignored
    var id: String { extID }
}
