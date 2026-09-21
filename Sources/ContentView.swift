import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var model: TCCViewModel
    @State private var selection = Set<TCCRecord.ID>()
    @State private var showRestartConfirm = false
    @State private var showHelp = false
    @State private var sortOrder = [KeyPathComparator(\TCCRecord.client)]

    private var visibleRecords: [TCCRecord] {
        let recs: [TCCRecord]
        switch model.mode {
        case .byService:
            recs = model.selectedService.map { model.recordsForService($0) } ?? []
        case .byApp:
            if let sel = model.selectedClient {
                let parts = sel.split(separator: "|", maxSplits: 1)
                recs = model.recordsForClient(String(parts.last ?? ""), clientType: Int(parts.first ?? "0") ?? 0)
            } else { recs = [] }
        }
        return recs.sorted(using: sortOrder)
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                Picker("Mode", selection: $model.mode) {
                    ForEach(ViewMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(8)

                List(selection: $model.selection) {
                    Section("TCC") {
                        if model.mode == .byService { serviceRows } else { appRows }
                    }
                    Section("Other Stores") {
                        ForEach(OtherPane.allCases) { pane in
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
                recordTable
                Divider()
                actionBar
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
                Menu("Daemon") {
                    Button("Restart user tccd") { showRestartConfirm = true }
                    Button("Restart system tccd (admin)…") { model.restartSystemTCCD() }
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
        .alert("Restart user tccd?", isPresented: $showRestartConfirm) {
            Button("Restart") { model.restartUserTCCD() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The per-user tccd will be killed and relaunched on demand. This drops its identity cache. Running apps keep any kernel-cached verdicts.")
        }
        .onAppear { model.refresh() }
    }

    // MARK: Sidebars

    @ViewBuilder
    private var serviceRows: some View {
        let grouped = Dictionary(grouping: model.servicesPresent) {
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
                            Text("\(model.recordsForService(svc).count)")
                                .foregroundStyle(.secondary)
                                .font(.callout)
                        }
                    } icon: { Image(systemName: info.symbol) }
                    .tag(NavItem.service(svc))
                }
            }
        }
    }

    @ViewBuilder
    private var appRows: some View {
        ForEach(model.clientsPresent, id: \.self) { key in
            let parts = key.split(separator: "|", maxSplits: 1)
            let client = String(parts.last ?? "")
            let type = Int(parts.first ?? "0") ?? 0
            let id = Resolver.identity(for: client, clientType: type)
            let count = model.recordsForClient(client, clientType: type).count
            Label {
                HStack {
                    Text(id.name).lineLimit(1)
                    Spacer()
                    Text("\(count)").foregroundStyle(.secondary).font(.callout)
                }
            } icon: { Image(nsImage: id.icon) }
            .tag(NavItem.client(key))
        }
    }

    // MARK: Record table

    private var recordTable: some View {
        Table(visibleRecords, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Application", value: \.client) { rec in
                let id = Resolver.identity(for: rec.client, clientType: rec.clientType)
                HStack(spacing: 6) {
                    Image(nsImage: id.icon)
                    VStack(alignment: .leading) {
                        Text(id.name).lineLimit(1)
                        Text(rec.client).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .width(min: 160, ideal: 220)

            TableColumn("Service") { rec in
                Text(ServiceCatalog.info(for: rec.service).displayName)
            }
            .width(min: 110, ideal: 150)

            TableColumn("Status", value: \.authValue) { rec in
                Text(rec.statusName)
                    .font(.callout.bold())
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Color(rec.statusColor).opacity(0.2), in: Capsule())
                    .foregroundStyle(Color(rec.statusColor))
            }
            .width(80)

            TableColumn("Set By", value: \.authReason) { rec in
                Text(rec.managed ? "Managed (MDM)" : rec.reasonName).font(.callout)
            }
            .width(110)

            TableColumn("Target") { rec in
                if rec.indirectObject != "UNUSED" {
                    let tid = Resolver.identity(for: rec.indirectObject, clientType: 0)
                    HStack(spacing: 4) {
                        Image(nsImage: tid.icon)
                        Text(tid.name).lineLimit(1)
                    }
                }
            }
            .width(min: 90, ideal: 130)

            TableColumn("DB") { rec in
                Text(rec.db.kind.rawValue).font(.callout).foregroundStyle(.secondary)
            }
            .width(60)

            TableColumn("Modified", value: \.lastModified) { rec in
                Text(rec.lastModified, style: .date).font(.callout).foregroundStyle(.secondary)
            }
            .width(90)
        }
        .contextMenu(forSelectionType: TCCRecord.ID.self) { ids in
            contextButtons(for: ids)
        }
    }

    @ViewBuilder
    private func contextButtons(for ids: Set<TCCRecord.ID>) -> some View {
        let recs = visibleRecords.filter { ids.contains($0.id) && !$0.managed }
        if !recs.isEmpty {
            Button("Allow") { recs.forEach { model.request(.grant, for: $0) } }
            Button("Deny") { recs.forEach { model.request(.revoke, for: $0) } }
            Divider()
            Button("Reset (delete record)") { recs.forEach { model.request(.reset, for: $0) } }
        }
        if let first = visibleRecords.first(where: { ids.contains($0.id) }) {
            Divider()
            Button("Copy Client ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(first.client, forType: .string)
            }
            if let csreq = first.csreq, let text = Resolver.csreqText(csreq) {
                Button("Copy Code Requirement") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
        }
    }

    private var actionBar: some View {
        let recs = visibleRecords.filter { selection.contains($0.id) && !$0.managed }
        return HStack {
            Text("\(visibleRecords.count) records")
                .foregroundStyle(.secondary).font(.callout)
            if selection.isEmpty == false {
                Text("· \(selection.count) selected").foregroundStyle(.secondary).font(.callout)
            }
            Spacer()
            Button("Allow") { recs.forEach { model.request(.grant, for: $0) } }.disabled(recs.isEmpty)
            Button("Deny") { recs.forEach { model.request(.revoke, for: $0) } }.disabled(recs.isEmpty)
            Button("Reset", role: .destructive) { recs.forEach { model.request(.reset, for: $0) } }.disabled(recs.isEmpty)
        }
        .padding(8)
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
