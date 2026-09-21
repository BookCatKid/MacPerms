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

    /// TCC records feed the Not Installed sweep — wired in ContentView's .task.
    weak var tcc: TCCViewModel?

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
        // Snapshotted on the main actor — the orphan sweep reads other panes'
        // rows plus TCC records, which must be captured before detaching.
        let snapshot = rows
        let tccRecs = tcc?.records ?? []
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
                case .uninstalled:      try await self.finishOrphans(rows: snapshot, tcc: tccRecs)
                }
                await MainActor.run { self.state[pane] = .done }
            } catch {
                await MainActor.run {
                    self.state[pane] = .failed
                    self.status[pane] = "✗ \(error.localizedDescription)"
                    self.rows[pane] = self.rows[pane] ?? []
                }
            }
            // Any pane refresh can create or clear orphans — rebuild the
            // sweep list once this pane's new rows are published.
            await MainActor.run {
                if pane != .uninstalled { self.load(.uninstalled) }
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
        row.pane = .localNetwork
        return row
    }

    /// Best bundle-id for icon/name resolution on a BTM record.
    nonisolated static func itemBundleID(_ i: BTMItem) -> String {
        if let b = i.bundleID, b.contains(".") { return b }
        return i.launchdLabel
    }

    nonisolated private static func btmRow(for i: BTMItem,
                                           launchd: [String: [String: Bool]],
                                           pane: OtherPane) -> PermRow {
        var id = Resolver.identity(for: itemBundleID(i), clientType: 0)
        if id.appURL == nil, let exe = i.executable {
            id = Resolver.identity(for: exe, clientType: 1)
        }
        let type = i.type.replacingOccurrences(
            of: #"\s*\(0x[0-9a-fA-F]+\)"#, with: "", options: .regularExpression)
        // Effective state: BOTH gates must allow the item — the launchd
        // override (when one exists) and the BTM disposition bit. An
        // override reading 'enabled' must not mask a disabled disposition.
        let launchdState = launchd[i.launchdDomain]?[i.launchdLabel]
        let enabled = (launchdState ?? true) && i.enabled
        // Enable/Disable flips the record's disposition enabled bit — the
        // same write the Settings toggle makes — so it applies to every
        // record type (app groupings, dock tiles, tasks), not just launchd
        // services. Enable also clears a stale launchd override on service
        // records, but Disable never writes one: launchd overrides are a
        // second kill-switch Settings can't see or undo.
        // Every record is removable: needt btm-remove drops the ItemRecord
        // from the .btm archive (enabled `app` records also lose their
        // System Events 'Open at Login' entry).
        let ops: Set<RowOp> = [.remove, .enable, .disable]
        // Status = the Settings-style toggle state (enabled/disposition);
        // Info = the consent bit, which toggles never touch.
        var row = PermRow(
            id: i.id, icon: id.icon, title: i.name, subtitle: i.identifier,
            service: type,
            status: !i.allowed ? "Disallowed" : (enabled ? "Enabled" : "Disabled"),
            statusColor: !i.allowed ? .red : (enabled ? .green : .secondary),
            info: i.allowed ? "Allowed" : "Blocked",
            detail: i.lastUse ?? i.url ?? "",
            ops: ops,
            payload: i)
        row.appKey = i.bundleID ?? ""
        row.pane = pane
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
            ops: [.enable, .disable, .reset, .remove],
            payload: x)
        row.appKey = x.hostAppPath
            .flatMap { Bundle(url: URL(fileURLWithPath: $0))?.bundleIdentifier } ?? ""
        row.pane = .appExtensions
        return row
    }

    nonisolated private static func gkRow(for r: GKRule) -> PermRow {
        var row = PermRow(
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
        row.pane = .gatekeeper
        return row
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
            ops: [.allow, .deny, .remove],
            payload: c)
        row.appKey = c.clientID
        row.pane = .location
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
        row.pane = .notifications
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
        }.map { Self.btmRow(for: $0, launchd: doms, pane: .loginItems) }
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
        let rs = items.map { Self.btmRow(for: $0, launchd: doms, pane: .backgroundItems) }
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

    // MARK: - Not Installed sweep

    nonisolated private static func orphanPathExists(_ p: String?) -> Bool {
        guard let p, !p.isEmpty else { return false }
        if p.hasPrefix("file://"), let u = URL(string: p) {
            return FileManager.default.fileExists(atPath: u.path)
        }
        return FileManager.default.fileExists(atPath: p)
    }
    nonisolated private static func orphanResolves(_ bid: String?) -> Bool {
        guard let bid, !bid.isEmpty, !bid.hasPrefix("/") else { return false }
        return Resolver.identity(for: bid, clientType: 0).appURL != nil
    }
    nonisolated private static func orphanSystemID(_ bid: String) -> Bool {
        bid.hasPrefix("com.apple.") || bid.hasPrefix("com.microsoft.")
    }

    /// A row is orphaned when nothing it points at still exists: every known
    /// filesystem path is gone AND the bundle id no longer resolves through
    /// LaunchServices. Bundle-id-only records are conservative — an
    /// unresolvable com.apple.* id is a system record, not an orphan.
    /// `liveParents`: bundle ids of BTM records that are demonstrably alive —
    /// helper/plugin records carry relative paths that can't be verified, so
    /// a live host prefix (com.host.App covering com.host.App.Helper) means
    /// the record still has its app.
    nonisolated static func isOrphan(_ r: PermRow, liveParents: Set<String> = []) -> Bool {
        let exists = orphanPathExists, resolves = orphanResolves, systemID = orphanSystemID
        switch r.payload {
        case let t as TCCRecord:
            if t.clientType == 1 || t.client.hasPrefix("/") { return !exists(t.client) }
            return !systemID(t.client) && !resolves(t.client)
        case let x as NEPlist.Rule:
            return !exists(x.path) && !systemID(x.signingID) && !resolves(x.signingID)
        case let i as BTMItem:
            guard i.executable != nil || i.url != nil || i.bundleID != nil else { return false }
            if exists(i.executable) || exists(i.url) { return false }
            if liveParents.contains(where: { i.launchdLabel.hasPrefix($0) }) { return false }
            guard let bid = i.bundleID else { return true }
            return !systemID(bid) && !resolves(bid)
        case let x as AppExtension:
            return !exists(x.path) && !exists(x.hostAppPath)
        case let c as LocationClient:
            if exists(c.bundlePath) { return false }
            return c.isPathClient ? !exists(c.clientID)
                                  : !systemID(c.clientID) && !resolves(c.clientID)
        case let n as NotificationApp:
            if exists(n.path) { return false }
            let bid = n.bundleID.hasPrefix("_SYSTEM_CENTER_:")
                ? String(n.bundleID.dropFirst("_SYSTEM_CENTER_:".count)) : n.bundleID
            return !systemID(bid) && !resolves(bid)
        default:
            return false   // Gatekeeper rules and anything not app-bound
        }
    }

    /// TCC record → PermRow (shared with ContentView's by-service/by-app lists).
    nonisolated static func tccRow(_ rec: TCCRecord) -> PermRow {
        let id = Resolver.identity(for: rec.client, clientType: rec.clientType)
        var service = ServiceCatalog.info(for: rec.service).displayName
        if rec.indirectObject != "UNUSED" {
            service += " → " + Resolver.identity(for: rec.indirectObject, clientType: 0).name
        }
        var row = PermRow(
            id: rec.id,
            icon: id.icon,
            title: id.name,
            subtitle: rec.client,
            service: service,
            status: rec.statusName,
            statusColor: rec.statusColor,
            info: rec.managed ? "Managed (MDM)" : rec.reasonName,
            detail: "\(rec.db.kind.rawValue) DB · \(rec.lastModified.formatted(date: .abbreviated, time: .omitted))",
            ops: rec.managed ? [] : [.allow, .deny, .reset],
            payload: rec)
        row.appKey = rec.client
        row.extraCopy = {
            guard let blob = rec.csreq, let text = Resolver.csreqText(blob)
            else { return nil }
            return ("Copy Code Requirement", text)
        }
        return row
    }

    /// Collect orphan rows from every loaded store + TCC. Service column is
    /// prefixed with the source store since the sweep list mixes everything.
    nonisolated private func finishOrphans(rows snapshot: [OtherPane: [PermRow]],
                                           tcc tccRecs: [TCCRecord]) async throws {
        // Live BTM host bundle ids — their helper/plugin records can't be
        // verified by path (relative URLs) so a live host protects them.
        var liveParents = Set<String>()
        for (_, rs) in snapshot {
            for r in rs {
                guard let i = r.payload as? BTMItem,
                      let bid = i.bundleID, !bid.isEmpty else { continue }
                if Self.orphanPathExists(i.url) || Self.orphanPathExists(i.executable)
                    || Self.orphanResolves(bid) {
                    liveParents.insert(bid)
                }
            }
        }
        var out: [PermRow] = []
        for (pane, rs) in snapshot where pane != .uninstalled && pane != .gatekeeper {
            for var r in rs where Self.isOrphan(r, liveParents: liveParents) {
                r.service = "\(pane.rawValue) · \(r.service)"
                r.ops.formIntersection([.reset, .remove])
                r.pane = .uninstalled
                out.append(r)
            }
        }
        for rec in tccRecs where !rec.managed {
            var r = Self.tccRow(rec)
            guard Self.isOrphan(r) else { continue }
            r.service = "TCC · \(r.service)"
            r.ops = [.reset]
            r.pane = .uninstalled
            out.append(r)
        }
        let result = out
        await MainActor.run { self.rows[.uninstalled] = result }
    }

    /// Verified TCC record deletion for the orphan sweep — same SQL path the
    /// confirmation sheet uses, minus the pending-list UI.
    nonisolated static func tccDelete(_ rec: TCCRecord) throws -> String {
        let sql = TCCStore.deleteSQL(service: rec.service, client: rec.client,
                                     clientType: rec.clientType,
                                     indirectObject: rec.indirectObject)
        if rec.db.kind == .system {
            try Elevation.systemWrite(sql: sql, restartTCCD: false)
        } else {
            try TCCStore.apply(sql: sql, to: rec.db)
        }
        let v = try TCCStore.verify(service: rec.service, client: rec.client,
                                    clientType: rec.clientType,
                                    indirectObject: rec.indirectObject, in: rec.db)
        return v == nil ? "deleted" : "still present"
    }

    // MARK: - Ops (always via OtherOp confirmation)

    /// Run a mutation per item: dedupes on the key (multiple rows can share
    /// one underlying record, e.g. NE rules with the same signingID) and
    /// captures per-item failures in the output instead of aborting the batch.
    nonisolated private static func each<T>(_ items: [T], _ key: (T) -> String,
                                            _ work: (T) throws -> String) -> String {
        var seen = Set<String>()
        return items.filter { seen.insert(key($0)).inserted }.map { item in
            do { return "\(key(item)): \(try work(item))" }
            catch { return "\(key(item)): ✗ \(error.localizedDescription)" }
        }.joined(separator: "\n")
    }

    /// Build the confirmation prompt for an op on selected rows — dispatches
    /// on payload type so it works from pane views AND the By App merge.
    func ask(_ o: RowOp, _ sel: [PermRow]) {
        defer { op?.pane = sel.first?.pane ?? .localNetwork }
        let parts = subOps(o, sel, names: Self.names(for: sel))
        op = mergedOp(o, sel, parts: parts)
    }

    /// Not Installed sweep bulk clear: delete every record its store can
    /// remove, reset records that can only be reset, leave read-only rows
    /// alone — all under one confirmation.
    func clearOrphans() {
        let rs = rows[.uninstalled] ?? []
        let removable = rs.filter { $0.ops.contains(.remove) }
        let resettable = rs.filter { !$0.ops.contains(.remove) && $0.ops.contains(.reset) }
        let skipped = rs.count - removable.count - resettable.count
        let parts = subOps(.remove, removable, names: "")
            + subOps(.reset, resettable, names: "")
        guard !parts.isEmpty else {
            status[.uninstalled] = "Nothing in the list can be removed or reset."
            return
        }
        var msg = "Deletes every record its store can remove and resets records that can only be reset.\n\n"
            + parts.map(\.title).joined(separator: "\n")
        if skipped > 0 { msg += "\n\n\(skipped) read-only row(s) left untouched." }
        op = OtherOp(title: "Clear all possible orphaned records?",
                     message: msg, destructive: true, run: Self.runAll(parts))
        op?.pane = .uninstalled
    }

    private static func names(for sel: [PermRow]) -> String {
        sel.prefix(4).map(\.title).joined(separator: ", ")
            + (sel.count > 4 ? " +\(sel.count - 4) more" : "")
    }

    /// Runs each store's sub-op in sequence, concatenating per-item results.
    private static func runAll(_ parts: [OtherOp]) -> () throws -> String {
        {
            var outs: [String] = []
            for p in parts { outs.append(try p.run()) }
            return outs.joined(separator: "\n")
        }
    }

    /// Single-type selections keep their dedicated alert; mixed selections get
    /// one merged confirmation running every sub-op.
    private func mergedOp(_ o: RowOp, _ sel: [PermRow], parts: [OtherOp]) -> OtherOp? {
        guard let first = parts.first else { return nil }
        guard parts.count > 1 else { return first }
        return OtherOp(
            title: "\(o.label) \(sel.count) record(s) across \(parts.count) stores?",
            message: Self.names(for: sel) + "\n\n" + parts.map(\.title).joined(separator: "\n"),
            destructive: parts.contains(where: { $0.destructive }),
            run: Self.runAll(parts))
    }

    /// Each payload type in the selection contributes a sub-op — selections in
    /// the Not Installed sweep mix stores, so one RowOp can fan out to several.
    private func subOps(_ o: RowOp, _ sel: [PermRow], names: String) -> [OtherOp] {
        var parts: [OtherOp] = []

        if let rs = nonEmpty(sel.compactMap { $0.payload as? TCCRecord }), o == .reset {
            parts.append(OtherOp(
                title: "Delete \(rs.count) TCC record(s)?",
                message: "\(names)\n\nDeletes the TCC records from their databases — each delete is verified by read-back.",
                destructive: true) {
                    let out = Self.each(rs, \.id) { try Self.tccDelete($0) }
                    Elevation.restartUserTCCD()
                    return out
                })
        }

        if let rs = nonEmpty(sel.compactMap { $0.payload as? NEPlist.Rule }) {
            switch o {
            case .allow, .deny:
                let allow = o == .allow
                parts.append(OtherOp(
                    title: "\(allow ? "Allow" : "Deny") Local Network for \(rs.count) app(s)?",
                    message: "\(names)\n\nSets DenyMulticast=\(!allow) on the per-user networkprivacy configuration.",
                    destructive: !allow) {
                        Self.each(rs, \.signingID) {
                            try OtherStore.neSet(signingID: $0.signingID, allow: allow)
                        }
                    })
            case .reset:
                parts.append(OtherOp(
                    title: "Reset Local Network for \(rs.count) app(s)?",
                    message: "\(names)\n\nClears the explicit decision (DenyMulticast restored to default, preference flag cleared) so the app is prompted again.",
                    destructive: true) {
                        Self.each(rs, \.signingID) {
                            try OtherStore.neReset(signingID: $0.signingID)
                        }
                    })
            case .remove:
                parts.append(OtherOp(
                    title: "Remove Local Network record for \(rs.count) app(s)?",
                    message: "\(names)\n\nDeletes the rule from the networkprivacy configuration entirely — the entry disappears and the app is prompted as if it had never asked.",
                    destructive: true) {
                        Self.each(rs, \.signingID) {
                            try OtherStore.neRemove(signingID: $0.signingID)
                        }
                    })
            default: break
            }
        }

        if let items = nonEmpty(sel.compactMap { $0.payload as? BTMItem }) {
            switch o {
            case .enable, .disable:
                let enable = o == .enable
                parts.append(OtherOp(
                    title: "\(enable ? "Enable" : "Disable") \(items.count) background item(s)?",
                    message: "\(names)\n\nFlips the enabled bit of each record's BTM disposition — the same write the System Settings toggle performs — then kills backgroundtaskmanagementd so it re-reads. Enable also clears any stale launchd override on launchd-backed items so the service can actually run.",
                    destructive: !enable) {
                        Self.each(items, \.identifier) {
                            var msgs = [try OtherStore.btmSetEnabled(
                                identifier: $0.identifier, enabled: enable)]
                            if enable, $0.isServiceType {
                                msgs.append(try OtherStore.launchctlSetEnabled(
                                    domain: $0.launchdDomain, label: $0.launchdLabel,
                                    enabled: true))
                            }
                            return msgs.joined(separator: "; ")
                        }
                    })
            case .remove:
                parts.append(OtherOp(
                    title: "Remove \(items.count) background item record(s)?",
                    message: "\(names)\n\nDeletes each ItemRecord from the .btm store and kills backgroundtaskmanagementd so it re-reads. Enabled 'Open at Login' entries are also removed via System Events. Live apps may re-register their record on next launch.",
                    destructive: true) {
                        Self.each(items, { "\($0.uid)|\($0.identifier)" }) {
                            var msgs: [String] = []
                            if $0.type.contains("app"), $0.enabled,
                               let out = try? OtherStore.seRemoveLoginItem(name: $0.name) {
                                msgs.append(out.isEmpty ? "login item removed" : out)
                            }
                            msgs.append(try OtherStore.btmRemove(identifier: $0.identifier))
                            return msgs.joined(separator: "; ")
                        }
                    })
            default: break
            }
        }

        if let xs = nonEmpty(sel.compactMap { $0.payload as? AppExtension }) {
            switch o {
            case .enable, .disable:
                let enable = o == .enable
                parts.append(OtherOp(
                    title: "\(enable ? "Enable" : "Disable") \(xs.count) extension(s)?",
                    message: "\(names)\n\nRuns `pluginkit -e \(enable ? "use" : "ignore") -i <id>` in the console user's pkd domain. The list is re-read after writing.",
                    destructive: !enable) {
                        Self.each(xs, \.extID) {
                            let out = try OtherStore.extSetEnabled(extID: $0.extID, enabled: enable)
                            return out.isEmpty ? "OK" : out
                        }
                    })
            case .reset:
                parts.append(OtherOp(
                    title: "Reset election for \(xs.count) extension(s)?",
                    message: "\(names)\n\nRuns `pluginkit -e default -i <id>` — forgets your use/ignore choice so the extension returns to pkd's default election.",
                    destructive: true) {
                        Self.each(xs, \.extID) {
                            let out = try OtherStore.extResetElection(extID: $0.extID)
                            return out.isEmpty ? "OK" : out
                        }
                    })
            case .remove:
                parts.append(OtherOp(
                    title: "Unregister \(xs.count) extension(s)?",
                    message: "\(names)\n\nRuns `pluginkit -r <path>` — removes the extension from pkd's registry. It re-registers on next host-app launch or pkd rescan.",
                    destructive: true) {
                        Self.each(xs, \.extID) {
                            let out = try OtherStore.extUnregister(path: $0.path)
                            return out.isEmpty ? "removed" : out
                        }
                    })
            default: break
            }
        }

        if let rs = nonEmpty(sel.compactMap { $0.payload as? GKRule }) {
            let labels = Array(Set(rs.map(\.authority))).sorted()
            if !labels.isEmpty {
                let flag: [String]
                let verb: String
                switch o {
                case .enable:  flag = ["--enable"];  verb = "Enable"
                case .disable: flag = ["--disable"]; verb = "Disable"
                case .remove:  flag = ["--remove"];  verb = "Remove"
                default: flag = []; verb = ""
                }
                if !flag.isEmpty {
                    parts.append(OtherOp(
                        title: "\(verb) Gatekeeper label(s): \(labels.joined(separator: ", "))?",
                        message: "Runs `spctl \(flag.joined(separator: " ")) --label` for each label as root (affects \(rs.count) listed rule(s)).",
                        destructive: o != .enable) {
                            Self.each(labels, { $0 }) { try OtherStore.gk(flag + ["--label", $0]) }
                        })
                }
            }
        }

        if let cl = nonEmpty(sel.compactMap { $0.payload as? LocationClient }) {
            switch o {
            case .allow, .deny:
                let allow = o == .allow
                parts.append(OtherOp(
                    title: "\(allow ? "Allow" : "Deny") Location Services for \(cl.count) client(s)?",
                    message: "\(names)\n\nWrites Authorized=\(allow) to the locationd clients store as root. UNVERIFIED write path — locationd may ignore it until restarted. Relaunch the app to test.",
                    destructive: !allow) {
                        Self.each(cl, \.key) { try OtherStore.locSet(key: $0.key, allow: allow) }
                    })
            case .remove:
                parts.append(OtherOp(
                    title: "Remove \(cl.count) Location Services record(s)?",
                    message: "\(names)\n\nDeletes the client entry from the locationd stores entirely — the app re-prompts next time it requests location.",
                    destructive: true) {
                        Self.each(cl, \.key) { try OtherStore.locRemove(key: $0.key) }
                    })
            default: break
            }
        }

        if let apps = nonEmpty(sel.compactMap { $0.payload as? NotificationApp }) {
            switch o {
            case .allow, .deny:
                let allow = o == .allow
                parts.append(OtherOp(
                    title: "\(allow ? "Allow" : "Disable") notifications for \(apps.count) app(s)?",
                    message: "\(names)\n\n\(allow ? "Sets" : "Clears") the allow-notifications flag (bit 25) in the usernoted store and restarts usernoted + cfprefsd to re-read it.",
                    destructive: !allow) {
                        Self.each(apps, \.bundleID) {
                            try OtherStore.ncSet(bundleID: $0.bundleID, allow: allow)
                        }
                    })
            case .reset, .remove:
                parts.append(OtherOp(
                    title: "Reset notification settings for \(apps.count) app(s)?",
                    message: "\(names)\n\nRemoves the app's entry from the usernoted store entirely — it re-registers and re-prompts on next launch.",
                    destructive: true) {
                        Self.each(apps, \.bundleID) {
                            try OtherStore.ncReset(bundleID: $0.bundleID)
                        }
                    })
            default: break
            }
        }

        return parts
    }

    /// Execute the confirmed op, then reload every pane it could have touched.
    func perform() {
        guard let o = op else { return }
        op = nil
        Task.detached {
            do {
                let out = try o.run()
                await MainActor.run {
                    self.status[o.pane] = "✓ \(out)"
                    self.tcc?.refresh()   // TCC deletes must re-read the DBs too
                    for pane in OtherPane.allCases { self.load(pane) }
                }
            } catch {
                await MainActor.run {
                    self.status[o.pane] = "✗ \(error.localizedDescription)"
                }
            }
        }
    }

    private func nonEmpty<T>(_ a: [T]) -> [T]? { a.isEmpty ? nil : a }
}
