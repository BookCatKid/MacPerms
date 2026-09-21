import Foundation
import AppKit

enum ViewMode: String, CaseIterable { case byService = "By Service", byApp = "By App" }

/// Unified sidebar selection — TCC rows keep their String keys; Other panes
/// switch the detail column to the non-TCC stores.
enum NavItem: Hashable {
    case service(String)
    case client(String)
    case other(OtherPane)
}

@MainActor
final class TCCViewModel: ObservableObject {
    @Published var databases: [TCCDatabaseFile] = []
    @Published var records: [TCCRecord] = []
    @Published var loadErrors: [String] = []
    @Published var mode: ViewMode = .byService
    @Published var selection: NavItem?
    @Published var searchText = ""
    @Published var status = ""
    @Published var pending: [PendingChange]?
    @Published var showGrantSheet = false
    /// Bumped by the toolbar Refresh button — Other panes reload on change.
    @Published var otherReload = UUID()

    /// TCC accessors — kept so all existing call sites are unchanged.
    var selectedService: String? {
        get { if case .service(let s) = selection { return s }; return nil }
        set { selection = newValue.map { .service($0) } }
    }
    var selectedClient: String? {
        get { if case .client(let c) = selection { return c }; return nil }
        set { selection = newValue.map { .client($0) } }
    }
    var selectedOther: OtherPane? {
        if case .other(let p) = selection { return p }
        return nil
    }

    func refresh() {
        // DB reads + LaunchServices identity resolution are slow on first run —
        // do them off the main thread and publish the results.
        Task.detached { [self] in
            let dbs = TCCStore.discoverDatabases()
            var all: [TCCRecord] = []
            var errs: [String] = []
            for db in dbs {
                do { all.append(contentsOf: try TCCStore.readRecords(from: db)) }
                catch { errs.append("\(db.kind.rawValue) DB: \(error.localizedDescription)") }
            }
            // Warm the identity cache so row construction never blocks the UI.
            for r in all {
                _ = Resolver.identity(for: r.client, clientType: r.clientType)
                if r.indirectObject != "UNUSED" {
                    _ = Resolver.identity(for: r.indirectObject, clientType: 0)
                }
            }
            let records = all
            let errors = errs
            await MainActor.run {
                self.databases = dbs
                self.records = records
                self.loadErrors = errors
                // Only auto-pick a service when nothing is selected — otherwise
                // refresh would yank the user off an Other-Stores pane.
                if self.selection == nil { self.selection = records.first.map { .service($0.service) } }
            }
        }
    }

    /// Toolbar Refresh — reload TCC records AND signal Other panes to reload.
    func refreshAll() {
        refresh()
        otherReload = UUID()
    }

    /// Contextual help for the toolbar `?` popover.
    var currentHelp: String {
        switch selection {
        case .other(let pane): return pane.helpText
        case .service(let svc):
            return "\(ServiceCatalog.info(for: svc).displayName) — a TCC consent store.\n\nRecords come from the user and system TCC databases. Grant/Deny/Reset write auth_value directly (user DB) or via the privileged helper (system DB); every write is verified by read-back. Managed (MDM) rows are read-only. Relaunch affected apps — running processes may hold cached verdicts."
        case .client:
            return "All TCC permission records for one application, across both databases.\n\nGrant/Deny/Reset write auth_value directly (user DB) or via the privileged helper (system DB); every write is verified by read-back. Managed (MDM) rows are read-only. Relaunch the app to pick up changes."
        case nil:
            return "TCC Manager — inspect and edit macOS permission stores.\n\nTCC section: the Transparency, Consent & Control databases (user + system). Other Stores: Local Network (nehelper), Background Items (backgroundtaskmanagementd), Gatekeeper (syspolicyd), Location Services (locationd)."
        }
    }

    // MARK: - Groupings

    var servicesPresent: [String] {
        Array(Set(records.map(\.service))).sorted {
            ServiceCatalog.info(for: $0).displayName < ServiceCatalog.info(for: $1).displayName
        }
    }

    var clientsPresent: [String] {
        Array(Set(records.map { "\($0.clientType)|\($0.client)" })).sorted {
            Resolver.identity(for: $0.split(separator: "|", maxSplits: 1).last.map(String.init) ?? $0,
                              clientType: Int($0.prefix(1)) ?? 0).name.lowercased()
            < Resolver.identity(for: $1.split(separator: "|", maxSplits: 1).last.map(String.init) ?? $1,
                                clientType: Int($1.prefix(1)) ?? 0).name.lowercased()
        }
    }

    func recordsForService(_ service: String) -> [TCCRecord] {
        filtered(records.filter { $0.service == service })
    }

    func recordsForClient(_ client: String, clientType: Int) -> [TCCRecord] {
        filtered(records.filter { $0.client == client && $0.clientType == clientType })
    }

    private func filtered(_ recs: [TCCRecord]) -> [TCCRecord] {
        guard !searchText.isEmpty else { return recs.sorted { $0.client < $1.client } }
        let q = searchText.lowercased()
        return recs.filter {
            $0.client.lowercased().contains(q)
                || $0.service.lowercased().contains(q)
                || Resolver.identity(for: $0.client, clientType: $0.clientType).name.lowercased().contains(q)
        }.sorted { $0.client < $1.client }
    }

    // MARK: - Mutations (always via confirmation sheet)

    func request(_ op: PendingChange.Op, for record: TCCRecord) {
        request(op, for: [record])
    }

    func request(_ op: PendingChange.Op, for recs: [TCCRecord]) {
        let eligible = recs.filter { !$0.managed }
        guard !eligible.isEmpty else { return }
        pending = eligible.map {
            PendingChange(op: op, service: $0.service, client: $0.client,
                          clientType: $0.clientType, indirectObject: $0.indirectObject,
                          db: $0.db, csreq: $0.csreq)
        }
    }

    func requestAllServices(_ op: PendingChange.Op, client: String, clientType: Int) {
        pending = recordsForClient(client, clientType: clientType).filter { !$0.managed }.map {
            PendingChange(op: op, service: $0.service, client: $0.client,
                          clientType: $0.clientType, indirectObject: $0.indirectObject,
                          db: $0.db, csreq: $0.csreq)
        }
    }

    func confirmPending(restartTCCD: Bool) {
        guard let changes = pending else { return }
        var results: [String] = []
        var touchedUser = false
        for ch in changes {
            do {
                let sql: String
                switch ch.op {
                case .grant:  sql = TCCStore.upsertSQL(service: ch.service, client: ch.client, clientType: ch.clientType, allow: true,  indirectObject: ch.indirectObject, csreq: ch.csreq)
                case .revoke: sql = TCCStore.upsertSQL(service: ch.service, client: ch.client, clientType: ch.clientType, allow: false, indirectObject: ch.indirectObject, csreq: ch.csreq)
                case .reset, .delete:
                    sql = TCCStore.deleteSQL(service: ch.service, client: ch.client, clientType: ch.clientType, indirectObject: ch.indirectObject)
                }

                if ch.db.kind == .system {
                    try Elevation.systemWrite(sql: sql, restartTCCD: restartTCCD)
                } else {
                    try TCCStore.apply(sql: sql, to: ch.db)
                    touchedUser = true
                }

                // Verify by read-back.
                let verify = try TCCStore.verify(service: ch.service, client: ch.client,
                                                 clientType: ch.clientType,
                                                 indirectObject: ch.indirectObject,
                                                 in: ch.db)
                switch ch.op {
                case .grant:
                    results.append(verify?.authValue == 2
                        ? "✓ \(ch.summary) — verified allowed"
                        : "✗ \(ch.summary) — row present but auth_value=\(verify?.authValue ?? -1)")
                case .revoke:
                    results.append(verify?.authValue == 0
                        ? "✓ \(ch.summary) — verified denied"
                        : "✗ \(ch.summary) — row present but auth_value=\(verify?.authValue ?? -1)")
                case .reset, .delete:
                    results.append(verify == nil
                        ? "✓ \(ch.summary) — record removed"
                        : "✗ \(ch.summary) — record still present")
                }
            } catch {
                results.append("✗ \(ch.summary) — \(error.localizedDescription)")
            }
        }
        if touchedUser && restartTCCD { Elevation.restartUserTCCD() }
        status = results.joined(separator: "\n")
            + (results.allSatisfy { $0.hasPrefix("✓") } && !results.isEmpty
               ? "\nNote: relaunch affected apps — running processes may hold cached verdicts." : "")
        pending = nil
        refresh()
    }

    func restartUserTCCD() {
        Elevation.restartUserTCCD()
        status = "User tccd restarted (it will relaunch on demand)."
    }

    func restartSystemTCCD() {
        do {
            try Elevation.restartSystemTCCD()
            status = "System tccd restarted."
        } catch {
            status = "Failed to restart system tccd: \(error.localizedDescription)"
        }
    }

    /// Open a System Settings page. `page` is the URL-scheme identifier, e.g.
    /// "com.apple.settings.PrivacySecurity.extension?Privacy_LocalNetwork".
    func openSystemSettings(_ page: String) {
        if let url = URL(string: "x-apple.systempreferences:\(page)") {
            NSWorkspace.shared.open(url)
        }
    }

    func openPrivacySettings() {
        openSystemSettings("com.apple.settings.PrivacySecurity.extension")
    }
}
