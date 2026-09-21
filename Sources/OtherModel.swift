import Foundation

enum OtherPane: String, CaseIterable, Identifiable, Hashable {
    case localNetwork = "Local Network"
    case backgroundItems = "Background Items"
    case gatekeeper = "Gatekeeper"
    case location = "Location Services"
    case notifications = "Notifications"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .localNetwork: return "network"
        case .backgroundItems: return "gear.badge"
        case .gatekeeper: return "checkmark.shield"
        case .location: return "location"
        case .notifications: return "bell"
        }
    }
    var helpText: String {
        switch self {
        case .localNetwork:
            return "Local Network decisions are enforced by nehelper (com.apple.network.localnetworkdecision) and stored per-user inside the NetworkExtension keyed archive /Library/Preferences/com.apple.networkextension.plist.\n\nDenyMulticast is the allow/deny flag; MulticastPreferenceSet marks an explicit user choice. Apps need NSLocalNetworkUsageDescription to be prompted.\n\nWrites go through SCPreferences as root — the archive round-trip is verified, but whether nehelper honors a write without restart is unverified; relaunch the app to test."
        case .backgroundItems:
            return "Login items, launch agents/daemons and app background items — managed by backgroundtaskmanagementd via binary .btm files. This is System Settings → General → Login Items & Extensions.\n\nsfltool exposes no per-item toggle; the only supported mutation is a full reset (sfltool resetbtm), after which every item re-registers on next launch."
        case .gatekeeper:
            return "Gatekeeper assessment rules, managed by syspolicyd and backed by /var/db/SystemPolicyConfiguration/ExecPolicy.\n\nReads use `spctl --list` (unprivileged). Enable/disable/remove operate on a rule's label via `spctl` as root — one admin prompt per batch."
        case .location:
            return "Per-app Location Services authorization is locationd's own store (clients plists under /var/db/locationd), not TCC — reading it requires root.\n\nToggling writes the `Authorized` flag directly — an UNVERIFIED write path on macOS 27: locationd may ignore it until restarted. Relaunch the app to test."
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
    var id: String { "\(uid)|\(itemUUID)" }
    var enabled: Bool { disposition & 0x1 != 0 }
    var allowed: Bool { disposition & 0x2 != 0 }
    var notified: Bool { disposition & 0x8 != 0 }
    var status: String { allowed ? "Allowed" : "Disallowed" }
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

struct LocationClient: Identifiable, Hashable {
    let bundleID: String
    let authorized: Bool
    let executable: String?
    var id: String { bundleID }
}
