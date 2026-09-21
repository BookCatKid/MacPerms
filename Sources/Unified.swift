import SwiftUI
import AppKit

/// Uniform row model — every permission store maps its records into PermRows,
/// so the list view is identical no matter which sidebar item is selected.
struct PermRow: Identifiable {
    let id: String
    let icon: NSImage
    let title: String          // display name
    let subtitle: String       // identifier
    var service: String        // TCC service / item type / rule type
    let status: String         // pill text
    let statusColor: Color
    let info: String           // provenance / explicit / enabled / label
    let detail: String         // path / db+date / requirement / executable
    var ops: Set<RowOp>        // actions valid for THIS row (empty = read-only)
    let payload: Any           // underlying record for op handlers
    /// Normalized application identity (bundle id or path) — used to merge
    /// every store's rows into the By App view. Empty = not attributable
    /// to a single app (e.g. Gatekeeper rules) → excluded from By App.
    var appKey: String = ""
    /// Which Other-pane produced this row — lets op results land in the
    /// right pane's status area even when run from the By App merge.
    var pane: OtherPane? = nil
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

// MARK: - NSTableView bridge

/// Right-click handler: select the clicked row if it isn't already in the
/// selection (standard table behavior), then ask the coordinator for a menu.
private final class MenuTable: NSTableView {
    var menuBuilder: ((IndexSet) -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        guard !selectedRowIndexes.isEmpty else { return nil }
        return menuBuilder?(selectedRowIndexes)
    }
}

/// NSTableView in an NSScrollView — SwiftUI Table has no horizontal scrolling
/// and wrapping it in a ScrollView drags the header through overscroll. This
/// is the real thing: pinned column headers, native sort chevrons, cmd/shift
/// selection, resizable columns, no rubber-band jank.
private struct PermTableView: NSViewRepresentable {
    let rows: [PermRow]
    @Binding var selection: Set<String>
    let onOp: (RowOp, [PermRow]) -> Void

    func makeCoordinator() -> Coord { Coord(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = MenuTable()
        context.coordinator.table = table
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.headerView = NSTableHeaderView()
        table.style = .inset          // padded rows + rounded selection
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 50
        table.intercellSpacing = NSSize(width: 12, height: 4)
        table.allowsMultipleSelection = true
        table.selectionHighlightStyle = .regular
        // Detail absorbs extra width; anything smaller than the minimums
        // produces a native horizontal scrollbar.
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.menuBuilder = { [weak c = context.coordinator] idx in c?.menu(for: idx) }

        for (key, title, width, minW) in [
            ("app", "Application", 240.0, 180.0),
            ("service", "Service", 160.0, 110.0),
            ("status", "Status", 90.0, 80.0),
            ("info", "Info", 140.0, 100.0),
            ("detail", "Detail", 420.0, 260.0),
        ] {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
            c.title = title
            c.width = width
            c.minWidth = minW
            c.resizingMask = .userResizingMask
            c.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: true)
            table.addTableColumn(c)
        }
        table.sortDescriptors = [NSSortDescriptor(key: "app", ascending: true)]

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        // No rubber-banding in either axis — overscroll dragged the header
        // off and made scrolling feel stuck.
        scroll.horizontalScrollElasticity = .none
        scroll.verticalScrollElasticity = .none
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply(rows: rows)
    }

    final class Coord: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: PermTableView
        weak var table: NSTableView?
        var displayed: [PermRow] = []
        /// Rows that were selected when the context menu was built.
        var menuRows: [PermRow] = []

        init(_ p: PermTableView) { parent = p }

        private func key(_ r: PermRow, _ col: String) -> String {
            switch col {
            case "service": r.service
            case "status":  r.status
            case "info":    r.info
            case "detail":  r.detail
            default:        r.title
            }
        }

        private func resort(_ rows: [PermRow]) -> [PermRow] {
            guard let sd = table?.sortDescriptors.first, let k = sd.key else { return rows }
            return rows.sorted {
                let c = key($0, k).localizedStandardCompare(key($1, k))
                return sd.ascending ? c == .orderedAscending : c == .orderedDescending
            }
        }

        /// Called from updateNSView — keep the table in sync with new rows
        /// and restore the selection across reloads.
        func apply(rows new: [PermRow]) {
            displayed = resort(new)
            table?.reloadData()
            guard let table else { return }
            let sel = IndexSet(displayed.indices.filter { parent.selection.contains(displayed[$0].id) })
            if sel != table.selectedRowIndexes {
                table.selectRowIndexes(sel, byExtendingSelection: false)
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { displayed.count }

        private func field(_ s: String, font: NSFont, color: NSColor) -> NSTextField {
            let f = NSTextField(labelWithString: s)
            f.font = font
            f.textColor = color
            f.lineBreakMode = .byTruncatingTail
            return f
        }

        /// Centers a view vertically in its cell — bare text fields pin
        /// their text to the top of the cell frame.
        private func centered(_ v: NSView) -> NSView {
            let outer = NSView()
            v.translatesAutoresizingMaskIntoConstraints = false
            outer.addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: outer.leadingAnchor),
                v.centerYAnchor.constraint(equalTo: outer.centerYAnchor),
                v.trailingAnchor.constraint(lessThanOrEqualTo: outer.trailingAnchor),
            ])
            return outer
        }

        /// Pill label for the Status column — capsule background + colored text.
        private func pill(_ text: String, color: NSColor) -> NSView {
            let label = field(text, font: .systemFont(ofSize: 12, weight: .bold), color: color)
            let box = NSView()
            box.wantsLayer = true
            box.layer?.backgroundColor = color.withAlphaComponent(0.2).cgColor
            box.layer?.cornerRadius = 8
            box.translatesAutoresizingMaskIntoConstraints = false
            label.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8),
                label.topAnchor.constraint(equalTo: box.topAnchor, constant: 2),
                label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -2),
            ])
            let outer = NSView()
            box.setContentHuggingPriority(.required, for: .horizontal)
            box.setContentCompressionResistancePriority(.required, for: .horizontal)
            box.translatesAutoresizingMaskIntoConstraints = false
            outer.addSubview(box)
            NSLayoutConstraint.activate([
                box.leadingAnchor.constraint(equalTo: outer.leadingAnchor),
                box.centerYAnchor.constraint(equalTo: outer.centerYAnchor),
            ])
            return outer
        }

        func tableView(_ tv: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
            guard let col, row < displayed.count else { return nil }
            let r = displayed[row]
            switch col.identifier.rawValue {
            case "app":
                let stack = NSStackView()
                stack.orientation = .horizontal
                stack.spacing = 10
                stack.alignment = .centerY
                let iv = NSImageView(image: r.icon)
                iv.imageScaling = .scaleProportionallyUpOrDown
                iv.translatesAutoresizingMaskIntoConstraints = false
                iv.widthAnchor.constraint(equalToConstant: 40).isActive = true
                iv.heightAnchor.constraint(equalToConstant: 40).isActive = true
                // Skip the subtitle when it's identical to the title —
                // unidentified apps resolve to their raw identifier.
                var textViews = [
                    field(r.title, font: .systemFont(ofSize: 13), color: .labelColor)
                ]
                if r.subtitle != r.title {
                    textViews.append(
                        field(r.subtitle, font: .systemFont(ofSize: 11), color: .secondaryLabelColor))
                }
                let texts = NSStackView(views: textViews)
                texts.orientation = .vertical
                texts.alignment = .leading
                texts.spacing = 1
                stack.addArrangedSubview(iv)
                stack.addArrangedSubview(texts)
                return stack
            case "status":
                return pill(r.status, color: NSColor(r.statusColor))
            case "service":
                return centered(field(r.service, font: .systemFont(ofSize: 13), color: .labelColor))
            case "info":
                return centered(field(r.info, font: .systemFont(ofSize: 12), color: .labelColor))
            default:
                return centered(field(r.detail, font: .systemFont(ofSize: 11), color: .secondaryLabelColor))
            }
        }

        // MARK: Selection / sorting / menu

        func tableViewSelectionDidChange(_ n: Notification) {
            guard let table else { return }
            let sel = Set(table.selectedRowIndexes.compactMap {
                $0 < displayed.count ? displayed[$0].id : nil
            })
            if sel != parent.selection { parent.selection = sel }
        }

        func tableView(_ tv: NSTableView, sortDescriptorsDidChange old: [NSSortDescriptor]) {
            displayed = resort(displayed)
            tv.reloadData()
            let sel = IndexSet(displayed.indices.filter { parent.selection.contains(displayed[$0].id) })
            tv.selectRowIndexes(sel, byExtendingSelection: false)
        }

        func menu(for indexes: IndexSet) -> NSMenu {
            let sel = indexes.compactMap { $0 < displayed.count ? displayed[$0] : nil }
            menuRows = sel
            let m = NSMenu()
            let ops = sel.reduce(into: Set<RowOp>()) { $0.formUnion($1.ops) }
            for op in RowOp.allCases where ops.contains(op) {
                let item = NSMenuItem(title: op.label, action: #selector(didChooseOp(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = op.rawValue
                m.addItem(item)
            }
            if !m.items.isEmpty, !sel.isEmpty { m.addItem(.separator()) }
            if let first = sel.first {
                let copy = NSMenuItem(title: "Copy Identifier", action: #selector(didCopyID), keyEquivalent: "")
                copy.target = self
                m.addItem(copy)
                if first.extraCopy?() != nil {
                    let extra = NSMenuItem(title: first.extraCopy?()?.label ?? "Copy",
                                           action: #selector(didCopyExtra), keyEquivalent: "")
                    extra.target = self
                    m.addItem(extra)
                }
            }
            return m
        }

        @objc private func didChooseOp(_ item: NSMenuItem) {
            guard let raw = item.representedObject as? String,
                  let op = RowOp(rawValue: raw) else { return }
            parent.onOp(op, menuRows.filter { $0.ops.contains(op) })
        }

        @objc private func didCopyID() {
            guard let s = menuRows.first?.subtitle else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s, forType: .string)
        }

        @objc private func didCopyExtra() {
            guard let extra = menuRows.first?.extraCopy?() else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(extra.text, forType: .string)
        }
    }
}

// MARK: - Unified view

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
            PermTableView(rows: filtered, selection: $selection, onOp: onOp)

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
