import SwiftUI
import AppKit

/// Dispatcher for the non-TCC permission stores. Every pane loads its own data
/// and maps it to PermRows — the list view itself is identical everywhere.
struct OtherView: View {
    let pane: OtherPane

    var body: some View {
        switch pane {
        case .localNetwork: LocalNetworkView()
        case .backgroundItems: BTMView()
        case .gatekeeper: GatekeeperView()
        case .location: LocationView()
        case .notifications: NotificationsView()
        }
    }
}

/// Shared "are you sure" plumbing for Other-pane mutations.
struct OtherOp: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let destructive: Bool
    let run: () throws -> String
}

/// Generic confirmation alert wiring for OtherOp.
private struct OtherOpAlert: ViewModifier {
    @Binding var op: OtherOp?
    let perform: () -> Void
    func body(content: Content) -> some View {
        content.alert(op?.title ?? "", isPresented: Binding(
            get: { op != nil }, set: { if !$0 { op = nil } })) {
            Button("Apply", role: op?.destructive == true ? .destructive : nil) { perform() }
            Button("Cancel", role: .cancel) { op = nil }
        } message: { Text(op?.message ?? "") }
    }
}
extension View {
    func otherOpAlert(_ op: Binding<OtherOp?>, perform: @escaping () -> Void) -> some View {
        modifier(OtherOpAlert(op: op, perform: perform))
    }
}

struct OtherStatus: View {
    let text: String
    var body: some View {
        if !text.isEmpty {
            Divider()
            ScrollView {
                Text(text)
                    .font(.callout.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 90)
            .background(Color(nsColor: .textBackgroundColor))
        }
    }
}

// MARK: - Local Network (nehelper / com.apple.networkextension.plist)

struct LocalNetworkView: View {
    @EnvironmentObject var model: TCCViewModel
    @State private var configs: [NEPlist.Config] = []
    @State private var configID: String?
    @State private var rowsByConfig: [String: [PermRow]] = [:]
    @State private var status = ""
    @State private var op: OtherOp?

    private var config: NEPlist.Config? {
        configs.first { $0.uuid == configID } ?? configs.first
    }
    private var defaultRule: NEPlist.Rule? { config?.rules.first { $0.isDefault } }
    private var rows: [PermRow] { rowsByConfig[config?.uuid ?? ""] ?? [] }

    /// Identity resolution hits LaunchServices — run off the main thread.
    nonisolated private static func row(for r: NEPlist.Rule) -> PermRow {
        let id = Resolver.identity(for: r.signingID, clientType: 0)
        return PermRow(
            id: r.signingID, icon: id.icon, title: id.name, subtitle: r.signingID,
            service: "Local Network",
            status: r.status,
            statusColor: r.denyMulticast ? .red : .green,
            info: r.multicastPreferenceSet ? "Explicit" : "Implicit",
            detail: r.path ?? "",
            ops: [.allow, .deny, .reset],
            payload: r)
    }

    nonisolated private static func mapRows(_ cfgs: [NEPlist.Config]) -> [String: [PermRow]] {
        Dictionary(uniqueKeysWithValues: cfgs.map {
            ($0.uuid, $0.rules.filter { !$0.isDefault }.map { Self.row(for: $0) })
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            UnifiedListView(
                rows: rows,
                footerText: defaultRule.map {
                    "Default: \($0.denyMulticast ? "deny" : "allow")\($0.multicastPreferenceSet ? " (explicit)" : "")"
                },
                footerExtra: configs.count > 1 ? AnyView(
                    Picker("User", selection: Binding(
                        get: { configID ?? configs.first?.uuid ?? "" },
                        set: { configID = $0 })) {
                        ForEach(configs, id: \.uuid) { c in
                            Text(c.userUUID ?? c.uuid).tag(c.uuid)
                        }
                    }
                    .labelsHidden().fixedSize()
                ) : nil,
                supportedOps: [.allow, .deny, .reset],
                onOp: { o, sel in
                    let rs = sel.compactMap { $0.payload as? NEPlist.Rule }
                    switch o {
                    case .allow: ask(.allow, rs)
                    case .deny:  ask(.deny, rs)
                    case .reset: ask(.reset, rs)
                    default: break
                    }
                })
            OtherStatus(text: status)
        }
        .otherOpAlert($op, perform: perform)
        .onAppear(perform: load)
        .onChange(of: model.otherReload) { _, _ in load() }
    }

    private enum Op { case allow, deny, reset }

    private func ask(_ o: Op, _ rs: [NEPlist.Rule]) {
        guard !rs.isEmpty else { return }
        let names = rs.prefix(4).map(\.signingID).joined(separator: ", ")
            + (rs.count > 4 ? " +\(rs.count - 4) more" : "")
        let admin = "Administrator authorization is required (one prompt)."
        switch o {
        case .allow:
            op = OtherOp(title: "Allow Local Network for \(rs.count) app(s)?",
                         message: "\(names)\n\nSets DenyMulticast=false on the per-user networkprivacy configuration. \(admin)",
                         destructive: false) {
                            try rs.map { try OtherStore.neSet(signingID: $0.signingID, allow: true) }.joined(separator: "\n")
                         }
        case .deny:
            op = OtherOp(title: "Deny Local Network for \(rs.count) app(s)?",
                         message: "\(names)\n\nSets DenyMulticast=true. \(admin)",
                         destructive: true) {
                            try rs.map { try OtherStore.neSet(signingID: $0.signingID, allow: false) }.joined(separator: "\n")
                         }
        case .reset:
            op = OtherOp(title: "Reset Local Network for \(rs.count) app(s)?",
                         message: "\(names)\n\nClears the explicit decision (DenyMulticast restored to default, preference flag cleared) so the app is prompted again. \(admin)",
                         destructive: true) {
                            try rs.map { try OtherStore.neReset(signingID: $0.signingID) }.joined(separator: "\n")
                         }
        }
    }

    private func perform() {
        guard let o = op else { return }
        op = nil
        Task.detached {
            do {
                let out = try o.run()
                let cfgs = (try? OtherStore.localNetworkConfigs()) ?? []
                let map = Self.mapRows(cfgs)
                await MainActor.run {
                    status = "✓ \(out)\nVerified by archive read-back below. Relaunch the app to test enforcement."
                    configs = cfgs
                    rowsByConfig = map
                }
            } catch {
                await MainActor.run { status = "✗ \(error.localizedDescription)" }
            }
        }
    }

    private func load() {
        Task.detached {
            let cfgs = (try? OtherStore.localNetworkConfigs()) ?? []
            let map = Self.mapRows(cfgs)
            await MainActor.run {
                configs = cfgs
                rowsByConfig = map
                if configID == nil { configID = cfgs.first?.uuid }
                if cfgs.isEmpty {
                    status = "No networkprivacy configuration found — no app has made a Local Network decision yet."
                }
            }
        }
    }
}

// MARK: - Background Items (backgroundtaskmanagementd / .btm files)

struct BTMView: View {
    @EnvironmentObject var model: TCCViewModel
    @State private var rows: [PermRow] = []
    @State private var status = ""
    @State private var showResetConfirm = false

    /// Best bundle-id for icon/name resolution: prefer the item's bundleID,
    /// else strip the leading "<type>." token off the identifier
    /// ("16.org.whatpulse.ChmodBPF" → "org.whatpulse.ChmodBPF").
    nonisolated static func itemBundleID(_ i: BTMItem) -> String {
        if let b = i.bundleID, b.contains(".") { return b }
        let parts = i.identifier.split(separator: ".", maxSplits: 1)
        if parts.count == 2, parts[0].allSatisfy(\.isNumber) { return String(parts[1]) }
        return i.identifier
    }

    /// Identity resolution hits LaunchServices — run off the main thread.
    nonisolated private static func row(for i: BTMItem) -> PermRow {
        let id = Resolver.identity(for: itemBundleID(i), clientType: 0)
        let type = i.type.replacingOccurrences(
            of: #"\s*\(0x[0-9a-fA-F]+\)"#, with: "", options: .regularExpression)
        return PermRow(
            id: i.id, icon: id.icon, title: i.name, subtitle: i.identifier,
            service: type,
            status: i.status,
            statusColor: i.allowed ? .green : .red,
            info: i.enabled ? "Enabled" : "Disabled",
            detail: i.lastUse ?? i.url ?? "",
            ops: [],
            payload: i)
    }

    var body: some View {
        VStack(spacing: 0) {
            UnifiedListView(
                rows: rows,
                footerText: "read-only — per-item toggling is not exposed",
                pageActions: [
                    .init(label: "Reset ALL background items…", destructive: true) {
                        showResetConfirm = true
                    }
                ],
                supportedOps: [],
                onOp: { _, _ in })
            OtherStatus(text: status)
        }
        .alert("Reset all background items?", isPresented: $showResetConfirm) {
            Button("Reset everything", role: .destructive) {
                Task.detached {
                    do {
                        let out = try OtherStore.resetBTM()
                        await MainActor.run { status = "✓ \(out.isEmpty ? "BTM database reset — apps will re-register on next launch." : out)"; load() }
                    } catch {
                        await MainActor.run { status = "✗ \(error.localizedDescription)" }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Runs `sfltool resetbtm` as root. This wipes the entire .btm database — every login item and launch agent re-registers on next login/launch, and per-item user approvals are lost. This is Apple's supported nuclear option; there is no per-item reset.")
        }
        .onAppear(perform: load)
        .onChange(of: model.otherReload) { _, _ in load() }
    }

    private func load() {
        Task.detached {
            let it = (try? OtherStore.backgroundItems()) ?? []
            let rs = it.map { Self.row(for: $0) }
            await MainActor.run {
                rows = rs
                if it.isEmpty { status = "No items returned by `sfltool dumpbtm`." }
            }
        }
    }
}

// MARK: - Gatekeeper (syspolicyd / spctl)

struct GatekeeperView: View {
    @EnvironmentObject var model: TCCViewModel
    @State private var rules: [GKRule] = []
    @State private var status = ""
    @State private var gkStatus = ""
    @State private var op: OtherOp?

    private var rows: [PermRow] {
        rules.map { r in
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
    }

    var body: some View {
        VStack(spacing: 0) {
            UnifiedListView(
                rows: rows,
                footerText: gkStatus.isEmpty ? nil : gkStatus,
                supportedOps: [.enable, .disable, .remove],
                onOp: { o, sel in
                    let rs = sel.compactMap { $0.payload as? GKRule }
                    let labels = Array(Set(rs.map(\.authority))).sorted()
                    switch o {
                    case .enable:  ask("Enable", ["--enable"], labels, rs)
                    case .disable: ask("Disable", ["--disable"], labels, rs)
                    case .remove:  ask("Remove", ["--remove"], labels, rs)
                    default: break
                    }
                })
            OtherStatus(text: status)
        }
        .otherOpAlert($op, perform: perform)
        .onAppear(perform: load)
        .onChange(of: model.otherReload) { _, _ in load() }
    }

    private func ask(_ verb: String, _ flag: [String], _ labels: [String], _ rs: [GKRule]) {
        guard !labels.isEmpty else { return }
        let destructive = verb == "Remove" || verb == "Disable"
        op = OtherOp(
            title: "\(verb) Gatekeeper label(s): \(labels.joined(separator: ", "))?",
            message: "Runs `spctl \(flag.joined(separator: " ")) --label` for each label as root (affects \(rs.count) listed rule(s)). Administrator authorization required.",
            destructive: destructive) {
                try labels.map { try OtherStore.gk(flag + ["--label", $0]) }.joined(separator: "\n")
            }
    }

    private func perform() {
        guard let o = op else { return }
        op = nil
        Task.detached {
            do {
                let out = try o.run()
                let fresh = (try? OtherStore.gatekeeperRules()) ?? []
                await MainActor.run {
                    status = "✓ \(out.isEmpty ? "Done — rule list re-read below." : out)"
                    rules = fresh
                }
            } catch {
                await MainActor.run { status = "✗ \(error.localizedDescription)" }
            }
        }
    }

    private func load() {
        Task.detached {
            let rs = (try? OtherStore.gatekeeperRules()) ?? []
            let st = OtherStore.gatekeeperStatus()
            await MainActor.run {
                rules = rs
                gkStatus = st
                if rs.isEmpty { status = "`spctl --list` returned no rules." }
            }
        }
    }
}

// MARK: - Location Services (locationd / /var/db/locationd)

struct LocationView: View {
    @EnvironmentObject var model: TCCViewModel
    @State private var rows: [PermRow] = []
    @State private var status = ""
    @State private var requested = false
    @State private var op: OtherOp?

    /// Identity resolution hits LaunchServices — run off the main thread.
    nonisolated private static func row(for c: LocationClient) -> PermRow {
        let id = Resolver.identity(for: c.bundleID, clientType: 0)
        return PermRow(
            id: c.bundleID, icon: id.icon, title: id.name, subtitle: c.bundleID,
            service: "Location",
            status: c.authorized ? "Allowed" : "Denied",
            statusColor: c.authorized ? .green : .red,
            info: "",
            detail: c.executable ?? "",
            ops: [.allow, .deny],
            payload: c)
    }

    var body: some View {
        VStack(spacing: 0) {
            UnifiedListView(
                rows: rows,
                supportedOps: [.allow, .deny],
                onOp: { o, sel in
                    for c in sel.compactMap({ $0.payload as? LocationClient }) {
                        ask(c, allow: o == .allow)
                    }
                })
            OtherStatus(text: status)
        }
        .otherOpAlert($op, perform: perform)
        // Same as every other pane: load on appear and on toolbar Refresh.
        // Loading needs admin auth — if the user cancels, the list just
        // stays empty with the reason in the status line.
        .onAppear {
            if !requested { requested = true; load() }
        }
        .onChange(of: model.otherReload) { _, _ in load() }
    }

    private func ask(_ c: LocationClient, allow: Bool) {
        op = OtherOp(
            title: "\(allow ? "Allow" : "Deny") Location Services for \(c.bundleID)?",
            message: "Writes Authorized=\(allow) to the locationd clients store as root. UNVERIFIED write path — locationd may ignore it until restarted. Relaunch the app to test.",
            destructive: !allow) {
                try OtherStore.locSet(bundleID: c.bundleID, allow: allow)
            }
    }

    private func perform() {
        guard let o = op else { return }
        op = nil
        Task.detached {
            do {
                let out = try o.run()
                let fresh = (try? OtherStore.locationClients()) ?? []
                let rs = fresh.map { Self.row(for: $0) }
                await MainActor.run {
                    status = "✓ \(out) — store re-read below."
                    rows = rs
                }
            } catch {
                await MainActor.run { status = "✗ \(error.localizedDescription)" }
            }
        }
    }

    private func load() {
        Task.detached {
            do {
                let cl = try OtherStore.locationClients()
                let rs = cl.map { Self.row(for: $0) }
                await MainActor.run {
                    rows = rs
                    status = cl.isEmpty ? "locationd client stores are empty." : ""
                }
            } catch {
                await MainActor.run {
                    rows = []
                    status = "✗ \(error.localizedDescription)"
                }
            }
        }
    }
}

// MARK: - Notifications (store not yet mapped on macOS 27)

struct NotificationsView: View {
    var body: some View {
        UnifiedListView(
            rows: [],
            footerText: "authoritative store not mapped on macOS 27 — press ? for what was checked",
            supportedOps: [],
            onOp: { _, _ in })
    }
}
