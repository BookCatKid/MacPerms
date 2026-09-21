import SwiftUI
import AppKit

/// Uniform row model — every permission store maps its records into PermRows,
/// so the list view is identical no matter which sidebar item is selected.
struct PermRow: Identifiable {
    let id: String
    let icon: NSImage
    let title: String          // display name
    let subtitle: String       // identifier
    let service: String        // TCC service / item type / rule type
    let status: String         // pill text
    let statusColor: Color
    let info: String           // provenance / explicit / enabled / label
    let detail: String         // path / db+date / requirement / executable
    let ops: Set<RowOp>        // actions valid for THIS row (empty = read-only)
    let payload: Any           // underlying record for op handlers
    /// Normalized application identity (bundle id or path) — used to merge
    /// every store's rows into the By App view. Empty = not attributable
    /// to a single app (e.g. Gatekeeper rules) → excluded from By App.
    var appKey: String = ""
    /// Optional extra context-menu copy action, evaluated lazily on click.
    var extraCopy: (() -> (label: String, text: String)?)? = nil
}

enum RowOp: String, CaseIterable {
    case allow, deny, reset, enable, disable, remove

    var label: String {
        switch self {
        case .allow: "Allow"; case .deny: "Deny"; case .reset: "Reset"
        case .enable: "Enable"; case .disable: "Disable"; case .remove: "Remove"
        }
    }
    var destructive: Bool { self != .allow && self != .enable }
}

/// One table + one bottom bar for the whole app. Panes supply rows, a footer
/// string, optional page-level actions, the op set this store supports, and
/// an op handler. Filter comes from the toolbar (model.searchText).
struct UnifiedListView: View {
    let rows: [PermRow]
    var footerText: String? = nil
    var footerExtra: AnyView? = nil
    var pageActions: [PageAction] = []
    var supportedOps: Set<RowOp> = []
    let onOp: (RowOp, [PermRow]) -> Void

    struct PageAction: Identifiable {
        let id = UUID()
        let label: String
        let destructive: Bool
        let run: () -> Void
    }

    @EnvironmentObject var model: TCCViewModel
    @State private var selection = Set<String>()
    @State private var sortOrder = [KeyPathComparator(\PermRow.title)]

    private var filtered: [PermRow] {
        guard !model.searchText.isEmpty else { return rows }
        let q = model.searchText.lowercased()
        return rows.filter {
            $0.title.lowercased().contains(q)
            || $0.subtitle.lowercased().contains(q)
            || $0.service.lowercased().contains(q)
            || $0.detail.lowercased().contains(q)
        }
    }

    private var selected: [PermRow] {
        filtered.filter { selection.contains($0.id) && !$0.ops.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            Table(filtered.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Application", value: \.title) { r in
                    HStack(spacing: 6) {
                        Image(nsImage: r.icon)
                        VStack(alignment: .leading) {
                            Text(r.title).lineLimit(1)
                            Text(r.subtitle).font(.caption)
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .width(min: 160, ideal: 220)

                TableColumn("Service", value: \.service) { r in
                    Text(r.service).lineLimit(1)
                }
                .width(min: 100, ideal: 140)

                TableColumn("Status", value: \.status) { r in
                    Text(r.status)
                        .font(.callout.bold())
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(r.statusColor.opacity(0.2), in: Capsule())
                        .foregroundStyle(r.statusColor)
                }
                .width(85)

                TableColumn("Info", value: \.info) { r in
                    Text(r.info).font(.callout).lineLimit(1)
                }
                .width(min: 90, ideal: 120)

                TableColumn("Detail", value: \.detail) { r in
                    Text(r.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .contextMenu(forSelectionType: String.self) { ids in
                let sel = filtered.filter { ids.contains($0.id) }
                let ops = sel.reduce(into: Set<RowOp>()) { $0.formUnion($1.ops) }
                ForEach(RowOp.allCases.filter { ops.contains($0) }, id: \.self) { op in
                    Button(op.label) { onOp(op, sel.filter { $0.ops.contains(op) }) }
                }
                if !ops.isEmpty || !sel.isEmpty { Divider() }
                if let first = sel.first {
                    Button("Copy Identifier") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(first.subtitle, forType: .string)
                    }
                    if let extra = first.extraCopy?() {
                        Button(extra.label) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(extra.text, forType: .string)
                        }
                    }
                }
            }

            Divider()
            HStack(spacing: 10) {
                Text("\(filtered.count) items"
                     + (selection.isEmpty ? "" : " · \(selection.count) selected"))
                    .foregroundStyle(.secondary).font(.callout)
                if let footerText {
                    Text("· \(footerText)").foregroundStyle(.secondary).font(.callout)
                }
                if let footerExtra { footerExtra }
                Spacer()
                ForEach(pageActions) { a in
                    Button(a.label, role: a.destructive ? .destructive : nil) { a.run() }
                }
                ForEach(RowOp.allCases.filter { supportedOps.contains($0) }, id: \.self) { op in
                    let targets = selected.filter { $0.ops.contains(op) }
                    Button(op.label, role: op.destructive ? .destructive : nil) {
                        onOp(op, targets)
                    }
                    .disabled(targets.isEmpty)
                }
            }
            .padding(8)
        }
    }
}
