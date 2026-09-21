import SwiftUI
import AppKit

/// Dispatcher for the non-TCC permission stores. Data lives in
/// OtherStoresModel — pane views only choose which rows/footer to show.
struct OtherView: View {
    let pane: OtherPane

    var body: some View {
        switch pane {
        case .localNetwork: LocalNetworkView()
        case .loginItems: LoginItemsView()
        case .backgroundItems: BTMView()
        case .appExtensions: AppExtensionsView()
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

/// Base wrapper every Other pane shares: unified list + status + one
/// confirmation alert for all ops.
private struct OtherPaneShell<Content: View>: View {
    @EnvironmentObject var stores: OtherStoresModel
    let pane: OtherPane
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
            OtherStatus(text: stores.status[pane] ?? "")
        }
        .otherOpAlert($stores.op, perform: stores.perform)
    }
}

// MARK: - Local Network (nehelper / com.apple.networkextension.plist)

struct LocalNetworkView: View {
    @EnvironmentObject var stores: OtherStoresModel

    var body: some View {
        OtherPaneShell(pane: .localNetwork) {
            UnifiedListView(
                rows: stores.rows[.localNetwork] ?? [],
                footerText: stores.neDefaultRule.map {
                    "Default: \($0.denyMulticast ? "deny" : "allow")\($0.multicastPreferenceSet ? " (explicit)" : "")"
                },
                footerExtra: stores.neConfigs.count > 1 ? AnyView(
                    Picker("User", selection: Binding(
                        get: { stores.neConfigID ?? stores.neConfigs.first?.uuid ?? "" },
                        set: { stores.selectNEConfig($0) })) {
                        ForEach(stores.neConfigs, id: \.uuid) { c in
                            Text(c.userUUID ?? c.uuid).tag(c.uuid)
                        }
                    }
                    .labelsHidden().fixedSize()
                ) : nil,
                supportedOps: [.allow, .deny, .reset, .remove],
                onOp: stores.ask)
        }
    }
}

// MARK: - Login Items (Open at Login: BTM login items + shared file list)

struct LoginItemsView: View {
    @EnvironmentObject var stores: OtherStoresModel

    var body: some View {
        OtherPaneShell(pane: .loginItems) {
            UnifiedListView(
                rows: stores.rows[.loginItems] ?? [],
                footerText: "service items toggle via launchd · app items can be removed",
                supportedOps: [.enable, .disable, .remove],
                onOp: stores.ask)
        }
    }
}

// MARK: - Background Items (backgroundtaskmanagementd / .btm)

struct BTMView: View {
    @EnvironmentObject var stores: OtherStoresModel

    var body: some View {
        OtherPaneShell(pane: .backgroundItems) {
            UnifiedListView(
                rows: stores.rows[.backgroundItems] ?? [],
                footerText: "Allowed = user consent · Enabled = launchd state",
                pageActions: [
                    .init(label: "Reset ALL background items…", destructive: true) {
                        stores.showResetBTM = true
                    }
                ],
                supportedOps: [.enable, .disable],
                onOp: stores.ask)
        }
        .alert("Reset all background items?", isPresented: $stores.showResetBTM) {
            Button("Reset everything", role: .destructive) { stores.resetAllBTM() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Runs `sfltool resetbtm` as root. This wipes the entire .btm database — every login item and launch agent re-registers on next login/launch, and per-item user approvals are lost.")
        }
    }
}

// MARK: - App Extensions (pkd / pluginkit)

struct AppExtensionsView: View {
    @EnvironmentObject var stores: OtherStoresModel

    var body: some View {
        OtherPaneShell(pane: .appExtensions) {
            UnifiedListView(
                rows: stores.rows[.appExtensions] ?? [],
                supportedOps: [.enable, .disable],
                onOp: stores.ask)
        }
    }
}

// MARK: - Gatekeeper (syspolicyd / spctl)

struct GatekeeperView: View {
    @EnvironmentObject var stores: OtherStoresModel

    var body: some View {
        OtherPaneShell(pane: .gatekeeper) {
            UnifiedListView(
                rows: stores.rows[.gatekeeper] ?? [],
                footerText: stores.gkStatus.isEmpty ? nil : stores.gkStatus,
                supportedOps: [.enable, .disable, .remove],
                onOp: stores.ask)
        }
    }
}

// MARK: - Location Services (locationd / /var/db/locationd)

struct LocationView: View {
    @EnvironmentObject var stores: OtherStoresModel

    var body: some View {
        OtherPaneShell(pane: .location) {
            UnifiedListView(
                rows: stores.rows[.location] ?? [],
                supportedOps: [.allow, .deny],
                onOp: stores.ask)
        }
    }
}

// MARK: - Notifications (usernoted / group.com.apple.usernoted)

struct NotificationsView: View {
    @EnvironmentObject var stores: OtherStoresModel

    var body: some View {
        OtherPaneShell(pane: .notifications) {
            UnifiedListView(
                rows: stores.rows[.notifications] ?? [],
                footerText: "Reset removes the entry — the app re-prompts on next launch",
                supportedOps: [.allow, .deny, .reset],
                onOp: stores.ask)
        }
    }
}
