import SwiftUI
import AppKit

/// Dispatcher for the non-TCC permission stores. Each store keeps its own
/// reader/writer — nothing is forced through the TCC model.
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
    @State private var selection = Set<String>()
    @State private var status = ""
    @State private var op: OtherOp?
    @State private var filter = ""

    private var config: NEPlist.Config? {
        configs.first { $0.uuid == configID } ?? configs.first
    }
    private var rules: [NEPlist.Rule] {
        guard let c = config else { return [] }
        let r = c.rules.filter { !$0.isDefault }
        if filter.isEmpty { return r }
        return r.filter { $0.signingID.localizedCaseInsensitiveContains(filter)
            || ($0.path ?? "").localizedCaseInsensitiveContains(filter) }
    }
    private var defaultRule: NEPlist.Rule? { config?.rules.first { $0.isDefault } }

    var body: some View {
        VStack(spacing: 0) {
            Table(rules, selection: $selection) {
                TableColumn("Application") { r in
                    let id = Resolver.identity(for: r.signingID, clientType: 0)
                    HStack(spacing: 6) {
                        Image(nsImage: id.icon)
                        VStack(alignment: .leading) {
                            Text(id.name).lineLimit(1)
                            Text(r.signingID).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .width(min: 180, ideal: 240)

                TableColumn("Status") { r in
                    Text(r.status)
                        .font(.callout.bold())
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Color(r.denyMulticast ? .red : .green).opacity(0.2), in: Capsule())
                        .foregroundStyle(r.denyMulticast ? .red : .green)
                }
                .width(70)

                TableColumn("Choice") { r in
                    Text(r.multicastPreferenceSet ? "Explicit" : "Implicit")
                        .font(.callout)
                        .foregroundStyle(r.multicastPreferenceSet ? .primary : .secondary)
                }
                .width(70)

                TableColumn("Path") { r in
                    Text(r.path ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .contextMenu(forSelectionType: String.self) { ids in
                let rs = rules.filter { ids.contains($0.signingID) }
                if !rs.isEmpty {
                    Button("Allow") { ask(.allow, rs) }
                    Button("Deny") { ask(.deny, rs) }
                    Button("Reset (reprompt)") { ask(.reset, rs) }
                }
            }

            Divider()
            HStack {
                if let d = defaultRule {
                    Label("Default: \(d.denyMulticast ? "deny" : "allow")"
                          + (d.multicastPreferenceSet ? " (explicit)" : ""),
                          systemImage: "asterisk.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if configs.count > 1 {
                    Picker("User", selection: Binding(
                        get: { configID ?? configs.first?.uuid ?? "" },
                        set: { configID = $0 })) {
                        ForEach(configs, id: \.uuid) { c in
                            Text(c.userUUID ?? c.uuid).tag(c.uuid)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Spacer()
                let sel = rules.filter { selection.contains($0.signingID) }
                Button("Allow") { ask(.allow, sel) }.disabled(sel.isEmpty)
                Button("Deny") { ask(.deny, sel) }.disabled(sel.isEmpty)
                Button("Reset", role: .destructive) { ask(.reset, sel) }.disabled(sel.isEmpty)
                TextField("Filter", text: $filter)
                    .textFieldStyle(.roundedBorder).frame(width: 140)
            }
            .padding(8)
            OtherStatus(text: status)
        }
        .alert(op?.title ?? "", isPresented: Binding(
            get: { op != nil }, set: { if !$0 { op = nil } })) {
            Button(op?.destructive == true ? "Reset" : "Apply",
                   role: op?.destructive == true ? .destructive : nil) { perform() }
            Button("Cancel", role: .cancel) { op = nil }
        } message: {
            Text(op?.message ?? "")
        }
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
                await MainActor.run {
                    status = "✓ \(out)\nVerified by archive read-back below. Relaunch the app to test enforcement."
                    configs = cfgs
                }
            } catch {
                await MainActor.run { status = "✗ \(error.localizedDescription)" }
            }
        }
    }

    private func load() {
        Task.detached {
            let cfgs = (try? OtherStore.localNetworkConfigs()) ?? []
            await MainActor.run {
                configs = cfgs
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
    @State private var items: [BTMItem] = []
    @State private var status = ""
    @State private var filter = ""
    @State private var showResetConfirm = false

    /// Best bundle-id for icon/name resolution: prefer the item's bundleID,
    /// else strip the leading "<type>." token off the identifier
    /// ("16.org.whatpulse.ChmodBPF" → "org.whatpulse.ChmodBPF").
    static func itemBundleID(_ i: BTMItem) -> String {
        if let b = i.bundleID, b.contains(".") { return b }
        let parts = i.identifier.split(separator: ".", maxSplits: 1)
        if parts.count == 2, parts[0].allSatisfy(\.isNumber) { return String(parts[1]) }
        return i.identifier
    }

    private var shown: [BTMItem] {
        if filter.isEmpty { return items }
        return items.filter {
            $0.name.localizedCaseInsensitiveContains(filter)
            || ($0.developer ?? "").localizedCaseInsensitiveContains(filter)
            || $0.identifier.localizedCaseInsensitiveContains(filter)
            || ($0.bundleID ?? "").localizedCaseInsensitiveContains(filter)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Table(shown) {
                TableColumn("Name") { i in
                    let id = Resolver.identity(for: Self.itemBundleID(i), clientType: 0)
                    HStack(spacing: 6) {
                        Image(nsImage: id.icon)
                        VStack(alignment: .leading) {
                            Text(i.name).lineLimit(1)
                            Text(i.identifier).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .width(min: 180, ideal: 260)
                TableColumn("Developer") { i in Text(i.developer ?? "—").lineLimit(1) }
                    .width(min: 100, ideal: 150)
                TableColumn("Type") { i in Text(i.type).font(.callout).lineLimit(1) }
                    .width(min: 110, ideal: 150)
                TableColumn("Enabled") { i in
                    Image(systemName: i.enabled ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(i.enabled ? .green : .secondary)
                }
                .width(60)
                TableColumn("Allowed") { i in
                    Text(i.status)
                        .font(.callout.bold())
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Color(i.allowed ? .green : .red).opacity(0.2), in: Capsule())
                        .foregroundStyle(i.allowed ? .green : .red)
                }
                .width(80)
                TableColumn("UID") { i in Text("\(i.uid)").font(.callout).foregroundStyle(.secondary) }
                    .width(50)
                TableColumn("Last use") { i in
                    Text(i.lastUse ?? "—").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            Divider()
            HStack {
                Text("\(items.count) items").foregroundStyle(.secondary).font(.callout)
                Spacer()
                Button("Reset ALL background items…", role: .destructive) { showResetConfirm = true }
                TextField("Filter", text: $filter)
                    .textFieldStyle(.roundedBorder).frame(width: 140)
            }
            .padding(8)
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
            await MainActor.run {
                items = it
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
    @State private var selection = Set<Int>()
    @State private var op: OtherOp?

    var body: some View {
        VStack(spacing: 0) {
            Table(rules, selection: $selection) {
                TableColumn("#") { r in Text("\(r.index)").foregroundStyle(.secondary) }
                    .width(35)
                TableColumn("Label") { r in Text(r.authority).lineLimit(1) }
                    .width(min: 90, ideal: 130)
                TableColumn("Pri") { r in Text(r.priority).foregroundStyle(.secondary) }
                    .width(45)
                TableColumn("Op") { r in
                    Text(r.op)
                        .font(.callout.bold())
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Color(r.op == "allow" ? .green : .red).opacity(0.2), in: Capsule())
                        .foregroundStyle(r.op == "allow" ? .green : .red)
                }
                .width(65)
                TableColumn("Type") { r in Text(r.type).font(.callout) }
                    .width(75)
                TableColumn("Requirement") { r in
                    Text(r.requirement).font(.caption.monospaced())
                        .foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .contextMenu(forSelectionType: Int.self) { ids in
                let rs = rules.filter { ids.contains($0.index) }
                if let labels = Set(rs.map(\.authority)) as Set<String>? {
                    Button("Enable label(s)") { ask("Enable", ["--enable"], Array(labels), rs) }
                    Button("Disable label(s)") { ask("Disable", ["--disable"], Array(labels), rs) }
                    Button("Remove rule(s)…") { ask("Remove", ["--remove"], Array(labels), rs) }
                }
            }

            Divider()
            HStack {
                Text("\(rules.count) rules")
                    .foregroundStyle(.secondary).font(.callout)
                if !gkStatus.isEmpty {
                    Text("· \(gkStatus)").foregroundStyle(.secondary).font(.callout)
                }
                Spacer()
                let rs = rules.filter { selection.contains($0.index) }
                let labels = Array(Set(rs.map(\.authority))).sorted()
                Button("Enable") { ask("Enable", ["--enable"], labels, rs) }.disabled(rs.isEmpty)
                Button("Disable") { ask("Disable", ["--disable"], labels, rs) }.disabled(rs.isEmpty)
                Button("Remove", role: .destructive) { ask("Remove", ["--remove"], labels, rs) }.disabled(rs.isEmpty)
            }
            .padding(8)
            OtherStatus(text: status)
        }
        .alert(op?.title ?? "", isPresented: Binding(
            get: { op != nil }, set: { if !$0 { op = nil } })) {
            Button("Apply", role: op?.destructive == true ? .destructive : nil) { perform() }
            Button("Cancel", role: .cancel) { op = nil }
        } message: { Text(op?.message ?? "") }
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
    @State private var clients: [LocationClient] = []
    @State private var status = ""
    @State private var loaded = false
    @State private var op: OtherOp?

    var body: some View {
        VStack(spacing: 0) {
            if !loaded {
                Spacer()
                Button("Load clients (requires admin)…") { load() }
                Spacer()
            } else {
                Table(clients) {
                    TableColumn("Client") { c in
                        let id = Resolver.identity(for: c.bundleID, clientType: 0)
                        HStack(spacing: 6) {
                            Image(nsImage: id.icon)
                            VStack(alignment: .leading) {
                                Text(id.name).lineLimit(1)
                                Text(c.bundleID).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .width(min: 180, ideal: 260)
                    TableColumn("Status") { c in
                        Text(c.authorized ? "Allowed" : "Denied")
                            .font(.callout.bold())
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Color(c.authorized ? .green : .red).opacity(0.2), in: Capsule())
                            .foregroundStyle(c.authorized ? .green : .red)
                    }
                    .width(70)
                    TableColumn("Executable") { c in
                        Text(c.executable ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    TableColumn("") { c in
                        Button(c.authorized ? "Deny" : "Allow") {
                            ask(c, allow: !c.authorized)
                        }
                        .buttonStyle(.borderless)
                    }
                    .width(50)
                }

                Divider()
                HStack {
                    Text("\(clients.count) clients")
                        .foregroundStyle(.secondary).font(.callout)
                    Spacer()
                    Button("Reload (admin)") { load() }
                }
                .padding(8)
            }
            OtherStatus(text: status)
        }
        .alert(op?.title ?? "", isPresented: Binding(
            get: { op != nil }, set: { if !$0 { op = nil } })) {
            Button("Apply") { perform() }
            Button("Cancel", role: .cancel) { op = nil }
        } message: { Text(op?.message ?? "") }
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
                await MainActor.run {
                    status = "✓ \(out) — store re-read below."
                    clients = fresh
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
                await MainActor.run {
                    clients = cl
                    loaded = true
                    if cl.isEmpty { status = "locationd client stores are empty." }
                }
            } catch {
                await MainActor.run { status = "✗ \(error.localizedDescription)" }
            }
        }
    }
}

// MARK: - Notifications (store not yet mapped on macOS 27)

struct NotificationsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Notifications", systemImage: "bell").font(.title3.bold())
            Text("Per-app notification authorization is managed by usernoted/Notification Center — but the authoritative store has not been located on macOS 27 yet.")
                .foregroundStyle(.secondary)
            GroupBox("What was checked") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("• `com.apple.ncprefs` / `usernotificationskit` plists — preference data only")
                    Text("• `db2` sqlite under `com.apple.notificationcenter` containers — not present on 27")
                    Text("• Biome notification streams — event history, not authorization")
                    Text("• `usernoted`/`notificationcenterui` — enforcement daemons identified")
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Label("Read-only placeholder — no mutation is offered until the store is mapped and a safe write path is verified.",
                  systemImage: "lock")
                .font(.callout).foregroundStyle(.orange)
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
