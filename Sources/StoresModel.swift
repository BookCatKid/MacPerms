import Foundation
import AppKit

/// Central state for every non-TCC store. Loaders run detached and publish
/// finished PermRows here — pane views stay thin, and the By App view can
/// merge rows across stores via PermRow.appKey.
@MainActor
final class OtherStoresModel: ObservableObject, @unchecked Sendable {
    enum LoadState { case idle, loading, done, failed }

    @Published var rows: [OtherPane: [PermRow]] = [:]
    @Published var status: [OtherPane: String] = [:]
    @Published var state: [OtherPane: LoadState] = [:]
    @Published var op: OtherOp?
    /// False until the initial loadAll() sweep finishes (the loading screen).
    @Published var booted = false

    // Pane-specific extras rendered in the bottom bar.
    @Published var neConfigs: [NEPlist.Config] = []
    @Published var neConfigID: String?
    @Published var neRowsByConfig: [String: [PermRow]] = [:]
    @Published var gkStatus = ""
    @Published var showResetBTM = false

    var neDefaultRule: NEPlist.Rule? {
        let cfg = neConfigs.first { $0.uuid == neConfigID } ?? neConfigs.first
        return cfg?.rules.first { $0.isDefault }
    }

    // MARK: - Loading

    /// Kick every loader concurrently (app startup / toolbar Refresh).
    func loadAll() {
        for pane in OtherPane.allCases { load(pane) }
        // Flip `booted` once every pane has left the loading state.
        Task {
            while state.count < OtherPane.allCases.count
                  || state.values.contains(where: { $0 == .loading }) {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            booted = true
        }
    }

    func load(_ pane: OtherPane) {
        state[pane] = .loading
        Task.detached {
            do {
                switch pane {
                case .localNetwork:     try await self.finishNE()
                case .loginItems:       try await self.finishLoginItems()
                case .backgroundItems:  try await self.finishBTM()
                case .appExtensions:    try await self.finishExtensions()
                case .gatekeeper:       try await self.finishGatekeeper()
                case .location:         try await self.finishLocation()
                case .notifications:    try await self.finishNotifications()
                }
                await MainActor.run { self.state[pane] = .done }
            } catch {
                await MainActor.run {
                    self.state[pane] = .failed
                    self.status[pane] = "✗ \(error.localizedDescription)"
                    self.rows[pane] = self.rows[pane] ?? []
                }
            }
        }
    }

    // MARK: - Row builders (nonisolated — LaunchServices is slow)

    nonisolated private static func neRow(for r: NEPlist.Rule) -> PermRow {
        let id = Resolver.identity(for: r.signingID, clientType: 0)
        var row = PermRow(
            id: r.signingID, icon: id.icon, title: id.name, subtitle: r.signingID,
            service: "Local Network",
            status: r.status,
            statusColor: r.denyMulticast ? .red : .green,
            info: r.multicastPreferenceSet ? "Explicit" : "Implicit",
            detail: r.path ?? "",
            ops: [.allow, .deny, .reset, .remove],
            payload: r)
        row.appKey = r.signingID
        return row
    }

    /// Best bundle-id for icon/name resolution on a BTM record.
    nonisolated static func itemBundleID(_ i: BTMItem) -> String {
        if let b = i.bundleID, b.contains(".") { return b }
        return i.launchdLabel
    }

    nonisolated private static func btmRow(for i: BTMItem,
                                           launchd: [String: [String: Bool]]) -> PermRow {
        var id = Resolver.identity(for: itemBundleID(i), clientType: 0)
        if id.appURL == nil, let exe = i.executable {
            id = Resolver.identity(for: exe, clientType: 1)
        }
        let type = i.type.replacingOccurrences(
            of: #"\s*\(0x[0-9a-fA-F]+\)"#, with: "", options: .regularExpression)
        let launchdState = launchd[i.launchdDomain]?[i.launchdLabel]
        let enabled = launchdState ?? i.enabled
        // launchctl can disable any service label — the entry is created
        // on first write; grouping records (developer/app) are not services.
        // `app` records whose disposition is enabled ARE the "Open at Login"
        // entries Settings lists — removable via System Events.
        var ops: Set<RowOp> = []
        if i.isServiceType { ops = [.enable, .disable] }
        else if i.type.contains("app"), i.enabled { ops = [.remove] }
        var row = PermRow(
            id: i.id, icon: id.icon, title: i.name, subtitle: i.identifier,
            service: type,
            status: i.status,
            statusColor: i.allowed ? .green : .red,
            info: enabled ? "Enabled" : "Disabled",
            detail: i.lastUse ?? i.url ?? "",
            ops: ops,
            payload: i)
        row.appKey = i.bundleID ?? ""
        return row
    }

    nonisolated private static func extRow(for x: AppExtension) -> PermRow {
        let id = Resolver.identity(for: x.path, clientType: 1)
        let b = Bundle(url: URL(fileURLWithPath: x.path))
        let name = b?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? b?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? x.extID
        let point = ((b?.object(forInfoDictionaryKey: "NSExtension") as? [String: Any])?["NSExtensionPointIdentifier"] as? String)
            .map { $0.replacingOccurrences(of: "com.apple.", with: "") } ?? ""
        var row = PermRow(
            id: x.extID, icon: id.icon, title: name, subtitle: x.extID,
            service: point,
            status: x.enabled ? "Enabled" : "Disabled",
            statusColor: x.enabled ? .green : .red,
            info: x.version == "(null)" ? "" : x.version,
            detail: x.path,
            ops: [.enable, .disable],
            payload: x)
        row.appKey = x.hostAppPath
            .flatMap { Bundle(url: URL(fileURLWithPath: $0))?.bundleIdentifier } ?? ""
        return row
    }

    nonisolated private static func gkRow(for r: GKRule) -> PermRow {
        PermRow(
            id: "\(r.index)",
            icon: NSImage(systemSymbolName: "checkmark.shield",
                          accessibilityDescription: nil) ?? NSImage(),
            title: r.authority, subtitle: "rule \(r.index) · \(r.priority)",
            service: r.type,
            status: r.op.capitalized,
            statusColor: r.op == "allow" ? .green : .red,
            info: r.authority,
            detail: r.requirement,
            ops: [.enable, .disable, .remove],
            payload: r)
    }

    nonisolated private static func locRow(for c: LocationClient) -> PermRow {
        var id = Resolver.identity(for: c.clientID, clientType: c.isPathClient ? 1 : 0)
        if id.appURL == nil, let bp = c.bundlePath {
            id = Resolver.identity(for: bp, clientType: 1)
        }
        var row = PermRow(
            id: c.key, icon: id.icon, title: id.name, subtitle: c.clientID,
            service: "Location",
            status: c.authorized ? "Allowed" : "Denied",
            statusColor: c.authorized ? .green : .red,
            info: "",
            detail: c.bundlePath ?? "",
            ops: [.allow, .deny],
            payload: c)
        row.appKey = c.clientID
        return row
    }

    nonisolated private static func ncRow(for n: NotificationApp) -> PermRow {
        // "_SYSTEM_CENTER_:<bid>" entries are internal Notification Center
        // clients — resolve the real bundle id for display.
        let displayID = n.bundleID.hasPrefix("_SYSTEM_CENTER_:")
            ? String(n.bundleID.dropFirst("_SYSTEM_CENTER_:".count)) : n.bundleID
        var id = Resolver.identity(for: displayID, clientType: 0)
        if id.appURL == nil, let p = n.path {
            id = Resolver.identity(for: p, clientType: 1)
        }
        var row = PermRow(
            id: n.bundleID, icon: id.icon, title: id.name, subtitle: n.bundleID,
            service: "Notifications",
            status: n.allowed ? "Allowed" : "Denied",
            statusColor: n.allowed ? .green : .red,
            info: n.summary,
            detail: n.path ?? "",
            ops: [.allow, .deny, .reset],
            payload: n)
        row.appKey = displayID
        return row
    }

    // MARK: - Loaders

    nonisolated private func finishNE() async throws {
        let cfgs = (try? OtherStore.localNetworkConfigs()) ?? []
        let map = Dictionary(uniqueKeysWithValues: cfgs.map {
            ($0.uuid, $0.rules.filter { !$0.isDefault }.map { Self.neRow(for: $0) })
        })
        await MainActor.run {
            neConfigs = cfgs
            neRowsByConfig = map
            if neConfigID == nil { neConfigID = cfgs.first?.uuid }
            rows[.localNetwork] = map[neConfigID ?? cfgs.first?.uuid ?? ""] ?? []
            if cfgs.isEmpty {
                status[.localNetwork] = "No networkprivacy configuration found — no app has made a Local Network decision yet."
            }
        }
    }

    /// Rows for the selected NE user config.
    func selectNEConfig(_ uuid: String) {
        neConfigID = uuid
        rows[.localNetwork] = neRowsByConfig[uuid] ?? []
    }

    nonisolated private func finishLoginItems() async throws {
        // "Open at Login" = BTM `login item` records + `app` records whose
        // disposition is enabled — the same entries System Events reports
        // as login items (verified against the System Events list).
        let items = (try? OtherStore.backgroundItems()) ?? []
        var doms: [String: [String: Bool]] = [:]
        for uid in Set(items.map(\.uid)) {
            let d = uid > 0 ? "gui/\(uid)" : "system"
            if doms[d] == nil { doms[d] = OtherStore.launchdDisabled(d) }
        }
        let rs = items.filter {
            $0.type.contains("login") || ($0.type.contains("app") && $0.enabled)
        }.map { Self.btmRow(for: $0, launchd: doms) }
        await MainActor.run {
            rows[.loginItems] = rs
            if rs.isEmpty { status[.loginItems] = "No login items found." }
        }
    }

    nonisolated private func finishBTM() async throws {
        let items = try OtherStore.backgroundItems()
        var doms: [String: [String: Bool]] = [:]
        for uid in Set(items.map(\.uid)) {
            let d = uid > 0 ? "gui/\(uid)" : "system"
            if doms[d] == nil { doms[d] = OtherStore.launchdDisabled(d) }
        }
        let rs = items.map { Self.btmRow(for: $0, launchd: doms) }
        await MainActor.run {
            rows[.backgroundItems] = rs
            if items.isEmpty { status[.backgroundItems] = "No items returned by `sfltool dumpbtm`." }
        }
    }

    nonisolated private func finishExtensions() async throws {
        let xs = (try? OtherStore.appExtensions()) ?? []
        let rs = xs.map { Self.extRow(for: $0) }
        await MainActor.run {
            rows[.appExtensions] = rs
            if xs.isEmpty { status[.appExtensions] = "`pluginkit -m` returned no extensions." }
        }
    }

    nonisolated private func finishGatekeeper() async throws {
        let rs = try OtherStore.gatekeeperRules()
        let st = OtherStore.gatekeeperStatus()
        let mapped = rs.map { Self.gkRow(for: $0) }
        await MainActor.run {
            rows[.gatekeeper] = mapped
            gkStatus = st
            if rs.isEmpty { status[.gatekeeper] = "`spctl --list` returned no rules." }
        }
    }

    nonisolated private func finishLocation() async throws {
        let cl = try OtherStore.locationClients()
        let rs = cl.map { Self.locRow(for: $0) }
        await MainActor.run {
            rows[.location] = rs
            status[.location] = cl.isEmpty ? "locationd client stores are empty." : ""
        }
    }

    nonisolated private func finishNotifications() async throws {
        let apps = try OtherStore.notificationApps()
        let rs = apps.map { Self.ncRow(for: $0) }
        await MainActor.run {
            rows[.notifications] = rs
            if apps.isEmpty { status[.notifications] = "No per-app notification entries in the usernoted store." }
        }
    }

    // MARK: - Ops (always via OtherOp confirmation)

    /// Build the confirmation prompt for an op on selected rows — dispatches
    /// on payload type so it works from pane views AND the By App merge.
    func ask(_ o: RowOp, _ sel: [PermRow]) {
        let names = sel.prefix(4).map(\.title).joined(separator: ", ")
            + (sel.count > 4 ? " +\(sel.count - 4) more" : "")

        if let rs = nonEmpty(sel.compactMap { $0.payload as? NEPlist.Rule }) {
            switch o {
            case .allow, .deny:
                let allow = o == .allow
                op = OtherOp(
                    title: "\(allow ? "Allow" : "Deny") Local Network for \(rs.count) app(s)?",
                    message: "\(names)\n\nSets DenyMulticast=\(!allow) on the per-user networkprivacy configuration.",
                    destructive: !allow) {
                        try rs.map { try OtherStore.neSet(signingID: $0.signingID, allow: allow) }.joined(separator: "\n")
                    }
            case .reset:
                op = OtherOp(
                    title: "Reset Local Network for \(rs.count) app(s)?",
                    message: "\(names)\n\nClears the explicit decision (DenyMulticast restored to default, preference flag cleared) so the app is prompted again.",
                    destructive: true) {
                        try rs.map { try OtherStore.neReset(signingID: $0.signingID) }.joined(separator: "\n")
                    }
            case .remove:
                op = OtherOp(
                    title: "Remove Local Network record for \(rs.count) app(s)?",
                    message: "\(names)\n\nDeletes the rule from the networkprivacy configuration entirely — the entry disappears and the app is prompted as if it had never asked.",
                    destructive: true) {
                        try rs.map { try OtherStore.neRemove(signingID: $0.signingID) }.joined(separator: "\n")
                    }
            default: break
            }
            return
        }

        if let items = nonEmpty(sel.compactMap { $0.payload as? BTMItem }) {
            switch o {
            case .enable, .disable:
                let enable = o == .enable
                let svc = items.filter { $0.isServiceType }
                guard !svc.isEmpty else { return }
                op = OtherOp(
                    title: "\(enable ? "Enable" : "Disable") \(svc.count) item(s)?",
                    message: "\(names)\n\nRuns `launchctl \(enable ? "enable" : "disable") <domain>/<label>` for each item — the same per-service switch Settings toggles. State is re-read from print-disabled after writing.",
                    destructive: !enable) {
                        try svc.map {
                            try OtherStore.launchctlSetEnabled(
                                domain: $0.launchdDomain, label: $0.launchdLabel, enabled: enable)
                        }.joined(separator: "\n")
                    }
            case .remove:
                let apps = items.filter { $0.type.contains("app") && $0.enabled }
                guard !apps.isEmpty else { return }
                op = OtherOp(
                    title: "Remove \(apps.count) login item(s)?",
                    message: "\(names)\n\nDeletes the 'Open at Login' entry via System Events — the same as '-' in Settings → Login Items.",
                    destructive: true) {
                        try apps.map {
                            let out = try OtherStore.seRemoveLoginItem(name: $0.name)
                            return "\($0.name): \(out.isEmpty ? "removed" : out)"
                        }.joined(separator: "\n")
                    }
            default: break
            }
            return
        }

        if let xs = nonEmpty(sel.compactMap { $0.payload as? AppExtension }) {
            guard o == .enable || o == .disable else { return }
            let enable = o == .enable
            op = OtherOp(
                title: "\(enable ? "Enable" : "Disable") \(xs.count) extension(s)?",
                message: "\(names)\n\nRuns `pluginkit -e \(enable ? "use" : "ignore") -i <id>` in the console user's pkd domain. The list is re-read after writing.",
                destructive: !enable) {
                    try xs.map {
                        let out = try OtherStore.extSetEnabled(extID: $0.extID, enabled: enable)
                        return "\($0.extID): \(out.isEmpty ? "OK" : out)"
                    }.joined(separator: "\n")
                }
            return
        }

        if let rs = nonEmpty(sel.compactMap { $0.payload as? GKRule }) {
            let labels = Array(Set(rs.map(\.authority))).sorted()
            guard !labels.isEmpty else { return }
            let flag: [String]
            let verb: String
            switch o {
            case .enable:  flag = ["--enable"];  verb = "Enable"
            case .disable: flag = ["--disable"]; verb = "Disable"
            case .remove:  flag = ["--remove"];  verb = "Remove"
            default: return
            }
            op = OtherOp(
                title: "\(verb) Gatekeeper label(s): \(labels.joined(separator: ", "))?",
                message: "Runs `spctl \(flag.joined(separator: " ")) --label` for each label as root (affects \(rs.count) listed rule(s)).",
                destructive: o != .enable) {
                    try labels.map { try OtherStore.gk(flag + ["--label", $0]) }.joined(separator: "\n")
                }
            return
        }

        if let cl = nonEmpty(sel.compactMap { $0.payload as? LocationClient }) {
            guard o == .allow || o == .deny else { return }
            let allow = o == .allow
            op = OtherOp(
                title: "\(allow ? "Allow" : "Deny") Location Services for \(cl.count) client(s)?",
                message: "\(names)\n\nWrites Authorized=\(allow) to the locationd clients store as root. UNVERIFIED write path — locationd may ignore it until restarted. Relaunch the app to test.",
                destructive: !allow) {
                    try cl.map { try OtherStore.locSet(key: $0.key, allow: allow) }.joined(separator: "\n")
                }
            return
        }

        if let apps = nonEmpty(sel.compactMap { $0.payload as? NotificationApp }) {
            switch o {
            case .allow, .deny:
                let allow = o == .allow
                op = OtherOp(
                    title: "\(allow ? "Allow" : "Disable") notifications for \(apps.count) app(s)?",
                    message: "\(names)\n\n\(allow ? "Sets" : "Clears") the allow-notifications flag (bit 25) in the usernoted store and restarts usernoted + cfprefsd to re-read it.",
                    destructive: !allow) {
                        try apps.map { try OtherStore.ncSet(bundleID: $0.bundleID, allow: allow) }.joined(separator: "\n")
                    }
            case .reset:
                op = OtherOp(
                    title: "Reset notification settings for \(apps.count) app(s)?",
                    message: "\(names)\n\nRemoves the app's entry from the usernoted store entirely — it re-registers and re-prompts on next launch.",
                    destructive: true) {
                        try apps.map { try OtherStore.ncReset(bundleID: $0.bundleID) }.joined(separator: "\n")
                    }
            default: break
            }
            return
        }
    }

    /// Execute the confirmed op, then reload every pane it could have touched.
    func perform() {
        guard let o = op else { return }
        op = nil
        Task.detached {
            do {
                let out = try o.run()
                await MainActor.run {
                    self.status[.localNetwork] = "✓ \(out)"
                    for pane in OtherPane.allCases { self.load(pane) }
                }
            } catch {
                await MainActor.run {
                    self.status[.localNetwork] = "✗ \(error.localizedDescription)"
                }
            }
        }
    }

    /// Nuclear BTM reset — behind its own confirmation in the pane view.
    func resetAllBTM() {
        Task.detached {
            do {
                let out = try OtherStore.resetBTM()
                await MainActor.run {
                    self.status[.backgroundItems] = "✓ \(out.isEmpty ? "BTM database reset — apps will re-register on next launch." : out)"
                    self.load(.backgroundItems)
                    self.load(.loginItems)
                }
            } catch {
                await MainActor.run { self.status[.backgroundItems] = "✗ \(error.localizedDescription)" }
            }
        }
    }

    private func nonEmpty<T>(_ a: [T]) -> [T]? { a.isEmpty ? nil : a }
}
