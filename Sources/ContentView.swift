import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var model: TCCViewModel
    @EnvironmentObject var stores: OtherStoresModel
    @State private var showHelp = false
    @State private var sidebarSearch = ""
    @State private var restartTarget: RestartableService?

    /// A daemon that can be killed to drop its cached state.
    struct RestartableService: Identifiable {
        let label: String
        let process: String
        let perUser: Bool
        let note: String
        var id: String { label }
        static let all: [RestartableService] = [
            .init(label: "tccd (user)", process: "tccd", perUser: true,
                  note: "Drops the per-user TCC identity cache; relaunches on demand."),
            .init(label: "tccd (all)", process: "tccd", perUser: false,
                  note: "Kills every tccd instance including the system one."),
            .init(label: "usernoted", process: "usernoted", perUser: true,
                  note: "Notification settings + delivered-notification caches."),
            .init(label: "pkd", process: "pkd", perUser: true,
                  note: "Plug-in/extension registry cache."),
            .init(label: "cfprefsd", process: "cfprefsd", perUser: true,
                  note: "Cached preferences — needed after direct plist edits."),
            .init(label: "locationd", process: "locationd", perUser: false,
                  note: "Location Services authorization cache."),
            .init(label: "backgroundtaskmanagementd", process: "backgroundtaskmanagementd", perUser: false,
                  note: "Login/background item registry cache."),
            .init(label: "syspolicyd", process: "syspolicyd", perUser: false,
                  note: "Gatekeeper assessment cache."),
            .init(label: "nehelper", process: "nehelper", perUser: false,
                  note: "Local Network decision cache."),
        ]
    }

    private var visibleRecords: [TCCRecord] {
        switch model.mode {
        case .byService:
            return model.selectedService.map { model.recordsForService($0) } ?? []
        case .byApp:
            if let sel = model.selectedClient {
                let parts = sel.split(separator: "|", maxSplits: 1)
                return model.recordsForClient(String(parts.last ?? ""), clientType: Int(parts.first ?? "0") ?? 0)
            }
            return []
        }
    }

    /// TCC records mapped into the unified row model.
    private var tccRows: [PermRow] {
        visibleRecords.map { rec in
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
    }

    /// Rows for the detail pane — by-service/by-app TCC records, plus every
    /// Other-store row attributable to the selected app in By App mode.
    private var detailRows: [PermRow] {
        guard case .client = model.selection else { return tccRows }
        let parts = model.selectedClient?.split(separator: "|", maxSplits: 1)
        let client = parts?.last.map(String.init) ?? ""
        return tccRows + stores.rows.values.flatMap { $0 }.filter { $0.appKey == client }
    }

    /// One op dispatcher for the detail list — TCC payloads go through the
    /// TCC confirmation sheet, everything else through the store handlers.
    private func dispatchOp(_ op: RowOp, _ sel: [PermRow]) {
        let tcc = sel.compactMap { $0.payload as? TCCRecord }
        if !tcc.isEmpty {
            switch op {
            case .allow: model.request(.grant, for: tcc)
            case .deny:  model.request(.revoke, for: tcc)
            case .reset: model.request(.reset, for: tcc)
            default: break
            }
        }
        stores.ask(op, sel.filter { !($0.payload is TCCRecord) })
    }

    /// Shared supported-op set for the mixed By App list.
    private static let allOps: Set<RowOp> = Set(RowOp.allCases)

    var body: some View {
        Group {
            if model.didInitialLoad && stores.booted {
                mainView
            } else {
                loadingView
            }
        }
        .task {
            model.refresh()
            stores.loadAll()
        }
    }

    /// Startup gate — everything loads once up front so no pane shows a
    /// loading screen afterwards.
    private var loadingView: some View {
        VStack(spacing: 14) {
            Text("MacPerms").font(.title.bold())
            ProgressView()
            VStack(alignment: .leading, spacing: 4) {
                loadRow("TCC databases", done: model.didInitialLoad)
                ForEach(OtherPane.allCases) { pane in
                    loadRow(pane.rawValue, done: stores.state[pane] != nil
                            && stores.state[pane] != .loading)
                }
            }
            .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadRow(_ label: String, done: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dotted")
                .foregroundStyle(done ? .green : .secondary)
            Text(label)
        }
    }

    private var mainView: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                Picker("Mode", selection: $model.mode) {
                    ForEach(ViewMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(8)

                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search", text: $sidebarSearch)
                        .textFieldStyle(.plain)
                }
                .padding(6)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 8).padding(.bottom, 6)

                List(selection: $model.selection) {
                    Section("TCC") {
                        if model.mode == .byService { serviceRows } else { appRows }
                    }
                    Section("Other Stores") {
                        ForEach(otherPanesShown) { pane in
                            Label {
                                HStack {
                                    Text(pane.rawValue)
                                    Spacer()
                                }
                            } icon: { Image(systemName: pane.symbol) }
                            .tag(NavItem.other(pane))
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } detail: {
            if let pane = model.selectedOther {
                OtherView(pane: pane)
            } else {
            VStack(spacing: 0) {
                UnifiedListView(
                    rows: detailRows,
                    supportedOps: model.selectedClient != nil
                        ? Self.allOps : [.allow, .deny, .reset],
                    onOp: dispatchOp)
                if !model.status.isEmpty {
                    Divider()
                    ScrollView {
                        Text(model.status)
                            .font(.callout.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 110)
                    .background(Color(nsColor: .textBackgroundColor))
                }
            }
            .otherOpAlert($stores.op, perform: stores.perform)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { showHelp = true } label: {
                    Image(systemName: "questionmark.circle")
                }
                .help("About this page")
                .popover(isPresented: $showHelp) {
                    Text(model.currentHelp)
                        .font(.callout)
                        .padding(12)
                        .frame(width: 360)
                        .textSelection(.enabled)
                }
                Button { model.showGrantSheet = true } label: {
                    Label("Grant to App…", systemImage: "plus")
                }
                Button { model.refreshAll() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Menu("Restart") {
                    ForEach(RestartableService.all) { s in
                        Button("\(s.label)…") { restartTarget = s }
                    }
                }
                Menu {
                    if case .service(let svc) = model.selection,
                       let anchor = ServiceCatalog.settingsAnchor(for: svc) {
                        Button("Open \(ServiceCatalog.info(for: svc).displayName) Settings…") {
                            model.openSystemSettings("com.apple.settings.PrivacySecurity.extension?Privacy_\(anchor)")
                        }
                        Divider()
                    }
                    Button("Privacy & Security…") {
                        model.openSystemSettings("com.apple.settings.PrivacySecurity.extension")
                    }
                    Button("Gatekeeper / App Security…") {
                        model.openSystemSettings("com.apple.settings.PrivacySecurity.extension")
                    }
                    Divider()
                    Button("Local Network…") {
                        model.openSystemSettings("com.apple.settings.PrivacySecurity.extension?Privacy_LocalNetwork")
                    }
                    Button("Location Services…") {
                        model.openSystemSettings("com.apple.settings.PrivacySecurity.extension?Privacy_LocationServices")
                    }
                    Button("Notifications…") {
                        model.openSystemSettings("com.apple.preference.notifications")
                    }
                    Button("Login Items & Extensions…") {
                        model.openSystemSettings("com.apple.LoginItems-Settings.extension")
                    }
                } label: {
                    Label("System Settings", systemImage: "gear")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                TextField("Filter", text: $model.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
            }
        }
        .sheet(isPresented: Binding(
            get: { model.pending != nil },
            set: { if !$0 { model.pending = nil } })
        ) {
            ConfirmSheet()
        }
        .sheet(isPresented: $model.showGrantSheet) { GrantSheet() }
        .alert(restartTarget.map { "Restart \($0.label)?" } ?? "", isPresented: Binding(
            get: { restartTarget != nil }, set: { if !$0 { restartTarget = nil } })) {
            Button("Restart", role: .destructive) {
                if let s = restartTarget {
                    Task.detached {
                        do {
                            _ = try OtherStore.restartDaemon(s.process, perUser: s.perUser)
                            await MainActor.run { model.status = "\(s.label) restarted — it relaunches on demand." }
                        } catch {
                            await MainActor.run { model.status = "✗ \(s.label): \(error.localizedDescription)" }
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(restartTarget?.note ?? "")
        }
        .onChange(of: model.otherReload) { _, _ in stores.loadAll() }
    }

    // MARK: Sidebars

    /// Sidebar search — filters services/apps and the Other Stores list.
    private var otherPanesShown: [OtherPane] {
        let q = sidebarSearch.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return Array(OtherPane.allCases) }
        return OtherPane.allCases.filter {
            $0.rawValue.localizedCaseInsensitiveContains(q)
        }
    }

    @ViewBuilder
    private var serviceRows: some View {
        let q = sidebarSearch.trimmingCharacters(in: .whitespaces).lowercased()
        let grouped = Dictionary(grouping: model.servicesPresent.filter {
            q.isEmpty
                || ServiceCatalog.info(for: $0).displayName.lowercased().contains(q)
                || $0.lowercased().contains(q)
        }) {
            ServiceCatalog.info(for: $0).category
        }
        ForEach(grouped.keys.sorted(), id: \.self) { cat in
            Section(cat) {
                ForEach(grouped[cat]!, id: \.self) { svc in
                    let info = ServiceCatalog.info(for: svc)
                    Label {
                        HStack {
                            Text(info.displayName)
                            Spacer()
                            Text("\(model.serviceCounts[svc] ?? 0)")
                                .foregroundStyle(.secondary)
                                .font(.callout)
                        }
                    } icon: { Image(systemName: info.symbol) }
                    .tag(NavItem.service(svc))
                }
            }
        }
    }

    /// By App sidebar — TCC clients merged with every Other-store row's
    /// appKey, keyed "<type>|<client>" like TCC clients (type 1 = path).
    private var allAppKeys: [String] {
        var keys = Set(model.clientsPresent)
        for row in stores.rows.values.flatMap({ $0 }) where !row.appKey.isEmpty {
            keys.insert("\(row.appKey.hasPrefix("/") ? 1 : 0)|\(row.appKey)")
        }
        // Resolve each key's display name once, then sort — a Resolver call
        // per comparison is O(n log n) lookups per render.
        return keys.map { ($0, Self.keyName($0).lowercased()) }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    private static func keyParts(_ key: String) -> (client: String, type: Int) {
        let parts = key.split(separator: "|", maxSplits: 1)
        return (String(parts.last ?? ""), Int(parts.first ?? "0") ?? 0)
    }

    private static func keyName(_ key: String) -> String {
        let p = keyParts(key)
        return Resolver.identity(for: p.client, clientType: p.type).name
    }

    /// Per-app Other-store row counts — one pass over all store rows.
    private var otherCountByKey: [String: Int] {
        Dictionary(grouping: stores.rows.values.flatMap { $0 }.filter { !$0.appKey.isEmpty },
                   by: \.appKey).mapValues(\.count)
    }

    @ViewBuilder
    private var appRows: some View {
        let q = sidebarSearch.trimmingCharacters(in: .whitespaces).lowercased()
        let counts = otherCountByKey
        ForEach(allAppKeys.filter { key in
            guard !q.isEmpty else { return true }
            return Self.keyParts(key).client.lowercased().contains(q)
                || Self.keyName(key).lowercased().contains(q)
        }, id: \.self) { key in
            let p = Self.keyParts(key)
            let id = Resolver.identity(for: p.client, clientType: p.type)
            let count = (model.clientCounts[key] ?? 0)
                + (counts[p.client] ?? 0)
            // Explicit HStack — a 36pt icon would overflow Label's fixed
            // icon slot and overlap the text.
            HStack(spacing: 10) {
                Image(nsImage: id.icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 36, height: 36)
                Text(id.name).lineLimit(1)
                Spacer()
                Text("\(count)").foregroundStyle(.secondary).font(.callout)
            }
            .tag(NavItem.client(key))
        }
    }

}

// MARK: - Confirmation sheet

struct ConfirmSheet: View {
    @EnvironmentObject var model: TCCViewModel
    @State private var restartTCCD = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Confirm changes").font(.title2.bold())
            Text("The following records will be modified. Every change is verified by reading the database back after writing.")
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.pending ?? []) { ch in
                        HStack(alignment: .top) {
                            Image(systemName: ch.op == .grant ? "checkmark.circle"
                                  : ch.op == .revoke ? "xmark.circle" : "trash")
                                .foregroundStyle(ch.op == .grant ? .green
                                               : ch.op == .revoke ? .red : .orange)
                            VStack(alignment: .leading) {
                                Text(ch.summary).bold()
                                Text("\(ServiceCatalog.info(for: ch.service).displayName) · \(ch.db.kind.rawValue) DB"
                                     + (ch.indirectObject != "UNUSED" ? " · target \(ch.indirectObject)" : ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 220)

            if (model.pending ?? []).contains(where: { $0.db.kind == .system }) {
                Label("System-database changes require administrator authorization (one prompt).",
                      systemImage: "lock.shield")
                    .font(.callout).foregroundStyle(.orange)
            }

            Toggle("Restart tccd after applying (drops daemon caches)", isOn: $restartTCCD)

            HStack {
                Button("Cancel", role: .cancel) { model.pending = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Apply & Verify") { model.confirmPending(restartTCCD: restartTCCD) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

// MARK: - Grant-new sheet

struct GrantSheet: View {
    @EnvironmentObject var model: TCCViewModel
    @Environment(\.dismiss) var dismiss
    @State private var service = "kTCCServiceAccessibility"
    @State private var client = ""
    @State private var clientType = 0
    @State private var allow = true
    @State private var indirect = "UNUSED"
    @State private var error: String?

    private var allServices: [String] {
        let known = Set(model.records.map(\.service))
        var list = model.servicesPresent
        // offer the common grantable ones even if no rows exist yet
        for s in ["kTCCServiceAccessibility","kTCCServiceScreenCapture","kTCCServiceListenEvent",
                  "kTCCServiceSystemPolicyAllFiles","kTCCServiceMicrophone","kTCCServiceCamera",
                  "kTCCServiceAppleEvents","kTCCServiceSystemPolicyDesktopFolder",
                  "kTCCServiceSystemPolicyDocumentsFolder","kTCCServiceSystemPolicyDownloadsFolder"]
        where !known.contains(s) && !list.contains(s) {
            list.append(s)
        }
        return list.sorted { ServiceCatalog.info(for: $0).displayName < ServiceCatalog.info(for: $1).displayName }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add permission record").font(.title2.bold())
            Picker("Service", selection: $service) {
                ForEach(allServices, id: \.self) {
                    Text(ServiceCatalog.info(for: $0).displayName).tag($0)
                }
            }
            Picker("Client type", selection: $clientType) {
                Text("Bundle identifier").tag(0)
                Text("Executable path").tag(1)
            }
            .pickerStyle(.segmented)
            HStack {
                TextField(clientType == 0 ? "com.example.app" : "/path/to/binary", text: $client)
                if clientType == 0 {
                    Button("Choose App…") { pickApp() }
                } else {
                    Button("Choose…") { pickBinary() }
                }
            }
            if service == "kTCCServiceAppleEvents" {
                HStack {
                    Text("Target app:")
                    TextField("com.apple.finder (or UNUSED)", text: $indirect)
                }
            }
            Picker("Value", selection: $allow) {
                Text("Allow").tag(true)
                Text("Deny").tag(false)
            }
            .pickerStyle(.segmented)
            Label("Destination: \(ServiceCatalog.info(for: service).inSystemDB ? "System" : "User") database"
                  + (ServiceCatalog.info(for: service).inSystemDB ? " (admin auth required)" : ""),
                  systemImage: ServiceCatalog.info(for: service).inSystemDB ? "lock.shield" : "person")
                .font(.callout).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Stage change") { stage() }.keyboardShortcut(.defaultAction)
                    .disabled(client.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func pickApp() {
        let p = NSOpenPanel()
        p.canChooseDirectories = false
        p.allowedContentTypes = [.application]
        if p.runModal() == .OK, let url = p.url {
            if let b = Bundle(url: url), let id = b.bundleIdentifier {
                client = id
            } else {
                error = "That bundle has no CFBundleIdentifier — use executable path instead."
            }
        }
    }

    private func pickBinary() {
        let p = NSOpenPanel()
        p.canChooseDirectories = false
        if p.runModal() == .OK, let url = p.url { client = url.path }
    }

    private func stage() {
        let sys = ServiceCatalog.info(for: service).inSystemDB
        guard let db = model.databases.first(where: { sys ? $0.kind == .system : $0.kind == .user }) else {
            error = "No \(sys ? "system" : "user") TCC database found."; return
        }
        var csreq: Data? = nil
        if clientType == 0, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: client) {
            csreq = Resolver.designatedRequirement(for: url)
        }
        model.pending = [PendingChange(op: allow ? .grant : .revoke, service: service,
                                       client: client, clientType: clientType,
                                       indirectObject: indirect, db: db, csreq: csreq)]
        dismiss()
    }
}
