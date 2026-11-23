import SwiftUI

/// The Memory panel, as Chrome DevTools' Heap snapshot profile: Take heap
/// snapshot, Clear all profiles and Collect garbage in the toolbar, the
/// snapshots taken in a sidebar with their size, and for the one selected
/// a Summary (objects grouped by class, with count, shallow and retained
/// size, each class opening onto its objects, optionally only those
/// allocated before or between snapshots), a Comparison with another
/// snapshot (objects new and deleted per class), Containment (the heap
/// from the GC roots down) or Statistics (size by category). Retained sizes
/// come from the dominator tree DeveloperHeapSnapshot builds. Snapshots
/// save as .heapsnapshot files and load back (Save profile…, Load
/// profile), though a loaded one's objects aren't on the page. A
/// Detached elements profile lists the DOM nodes out of the document that
/// are still kept alive, grouped by description, each with its retainers.
struct DeveloperMemoryView: View {
    @ObservedObject var session: DeveloperToolsSession
    @ObservedObject var memory: DeveloperMemory

    @State private var perspective = Perspective.summary
    @State private var profile = Profile.snapshot
    @State private var filter = ""
    @State private var base: Int?
    @State private var allocationFilter = DeveloperHeapAllocationFilter.all

    enum Perspective: String, CaseIterable, Identifiable {
        case summary = "Summary", comparison = "Comparison"
        case containment = "Containment", statistics = "Statistics"
        var id: String { rawValue }
    }

    private enum Profile: String, CaseIterable, Identifiable {
        case snapshot = "Heap snapshot", allocations = "Allocations on timeline"
        case detached = "Detached elements"
        var id: String { rawValue }
    }

    private var recordingTitle: String {
        if memory.recordingAllocations { return "Stop recording" }
        return switch profile {
        case .snapshot: "Take heap snapshot"
        case .allocations: "Start recording"
        case .detached: "Obtain detached elements"
        }
    }

    private func record() {
        if memory.recordingAllocations {
            memory.stopAllocations()
            return
        }
        switch profile {
        case .snapshot: memory.takeSnapshot()
        case .allocations: memory.startAllocations()
        case .detached: memory.findDetachedElements()
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if memory.snapshots.isEmpty && memory.progress == nil && !memory.recordingAllocations {
                landing
            } else {
                HSplitView {
                    sidebar.frame(minWidth: 110, idealWidth: 180, maxWidth: 320)
                    detail.frame(minWidth: 200, maxWidth: .infinity)
                }
            }
        }
        .font(.system(size: 11))
        .onChange(of: memory.selected) { _, _ in
            chooseBase()
            allocationFilter = .all
        }
        .onChange(of: memory.recordingAllocations) { _, active in
            if active { profile = .allocations }
        }
        .onAppear {
            chooseBase()
            if memory.recordingAllocations { profile = .allocations }
        }
        .accessibilityIdentifier("developer-memory")
    }

    /// Comparison's base: the snapshot before the selected one, as in Chrome.
    private func chooseBase() {
        let others = memory.snapshots.filter { $0.id != memory.selected && $0.allocations == nil }
        if let base, others.contains(where: { $0.id == base }) { return }
        base = others.last { $0.id < (memory.selected ?? 0) }?.id ?? others.last?.id
    }

    // MARK: Toolbar

    private var toolbar: some View {
        VStack(spacing: 0) {
            HStack(spacing: DeveloperToolsStyle.controlSpacing) {
                DeveloperPanelIcon(symbol: memory.recordingAllocations ? "stop.circle" : "record.circle",
                                   title: recordingTitle,
                                   active: memory.progress != nil || memory.recordingAllocations, action: record)
                    .disabled(memory.progress != nil || !session.ready)
                    .accessibilityIdentifier("developer-memory-snapshot")
                DeveloperPanelIcon(symbol: "nosign", title: "Clear all profiles") { memory.clear() }
                    .disabled(memory.snapshots.isEmpty || memory.progress != nil || memory.recordingAllocations)
                DeveloperPanelIcon(symbol: "trash", title: "Collect garbage") { memory.collectGarbage() }
                    .disabled(!session.ready)
                    .accessibilityIdentifier("developer-memory-gc")
                DeveloperPanelIcon(symbol: "arrow.up.to.line", title: "Load profile…") {
                    DeveloperMemoryFiles.load(into: memory)
                }
                .disabled(memory.progress != nil)
                .accessibilityIdentifier("developer-memory-load")
                DeveloperPanelIcon(symbol: "arrow.down.to.line", title: "Save profile…") {
                    if let entry = memory.selectedEntry { DeveloperMemoryFiles.save(entry, from: memory) }
                }
                .disabled(memory.selectedEntry?.canSave != true)
                .accessibilityIdentifier("developer-memory-save")
                Picker("Profile type", selection: $profile) {
                    ForEach(Profile.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().controlSize(.small).fixedSize()
                .disabled(memory.progress != nil || memory.recordingAllocations)
                .accessibilityIdentifier("developer-memory-profile-type")
                if let entry = memory.selectedEntry {
                    Divider().frame(height: 16).padding(.horizontal, 2)
                    if entry.allocations == nil, entry.detached == nil {
                        Picker("Perspective", selection: $perspective) {
                            ForEach(Perspective.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden().controlSize(.small).fixedSize()
                    }
                    if entry.detached != nil {
                        TextField("Filter", text: $filter).developerToolsField().frame(maxWidth: 180)
                    } else if entry.allocations != nil || perspective == .summary || perspective == .comparison {
                        TextField("Class filter", text: $filter).developerToolsField().frame(maxWidth: 180)
                    }
                    if perspective == .summary, entry.allocations == nil, entry.detached == nil {
                        let options = DeveloperMemory.allocationFilters(for: entry, in: memory.snapshots)
                        let retention = DeveloperMemory.retentionFilters(for: entry)
                        Picker("Objects", selection: $allocationFilter) {
                            ForEach(options) { option in Text(option.title).tag(option.filter) }
                            if !retention.isEmpty { Divider() }
                            ForEach(retention) { option in Text(option.title).tag(option.filter) }
                        }
                        .labelsHidden().controlSize(.small).fixedSize()
                        .disabled(options.count + retention.count < 2)
                        .accessibilityIdentifier("developer-memory-allocation-filter")
                    }
                    if perspective == .comparison, entry.allocations == nil, entry.detached == nil {
                        let others = memory.snapshots.filter { $0.id != entry.id && $0.allocations == nil }
                        Picker("Base snapshot", selection: $base) {
                            ForEach(others) { entry in
                                Text(entry.title).tag(Optional(entry.id))
                            }
                        }
                        .labelsHidden().controlSize(.small).fixedSize()
                        .disabled(others.isEmpty)
                        .help("The snapshot to compare against")
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DeveloperToolsStyle.gutter)
            .frame(height: DeveloperToolsStyle.toolbarHeight)
            // A narrow pane cuts the toolbar off rather than widening the
            // panel past the pane's edge.
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .clipped()
            .background(DeveloperToolsStyle.chrome)
            Divider()
            if let message = memory.message {
                Text(message).foregroundStyle(.secondary).textSelection(.enabled)
                    .padding(DeveloperToolsStyle.gutter)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DeveloperToolsStyle.raised)
                Divider()
            }
        }
    }

    private var landing: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(profile.rawValue).font(.system(size: 13, weight: .semibold))
            if profile == .snapshot {
                Text("See how memory is spread among the page’s JavaScript objects and the DOM nodes they hold.")
                    .foregroundStyle(.secondary)
                Label("Take another snapshot and use Comparison to see what was allocated and freed in between.",
                      systemImage: "arrow.left.arrow.right")
                    .foregroundStyle(.secondary)
            } else if profile == .detached {
                Text("Find DOM nodes that are no longer in the document but that JavaScript still keeps alive, and what retains them.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Record to see objects allocated during that time that are still alive when you stop.")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button(profile == .snapshot ? "Take snapshot" : profile == .detached ? "Start" : recordingTitle,
                       action: record)
                    .disabled(!session.ready)
                if profile == .snapshot {
                    Button("Load profile") { DeveloperMemoryFiles.load(into: memory) }
                }
            }
            .padding(.top, 4)
        }
        .font(.system(size: 12))
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("HEAP SNAPSHOTS")
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, DeveloperToolsStyle.gutter)
                .frame(height: DeveloperToolsStyle.rowHeight)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(memory.snapshots) { entry in
                        Button { memory.selected = entry.id } label: {
                            HStack(spacing: 6) {
                                Image(systemName: entry.detached != nil ? "square.dashed"
                                      : entry.allocations == nil ? "square.stack.3d.up" : "chart.bar.xaxis")
                                    .foregroundStyle(.secondary)
                                Text(entry.title).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(Self.megabytes(entry.snapshot.totalSize)).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, DeveloperToolsStyle.gutter)
                            .frame(height: DeveloperToolsStyle.rowHeight)
                            .background(memory.selected == entry.id ? DeveloperToolsStyle.selected : .clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Save profile…") { DeveloperMemoryFiles.save(entry, from: memory) }
                                .disabled(!entry.canSave)
                            Button("Delete") { memory.remove(entry.id) }
                        }
                    }
                    if let progress = memory.progress ?? (memory.recordingAllocations ? "Recording allocations…" : nil) {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text(progress).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .padding(.horizontal, DeveloperToolsStyle.gutter)
                        .frame(height: DeveloperToolsStyle.rowHeight)
                    }
                }
            }
        }
        .background(DeveloperToolsStyle.surface)
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if let entry = memory.selectedEntry {
            if let report = entry.detached {
                DeveloperHeapDetachedView(entry: entry, report: report, filter: filter, memory: memory).id(entry.id)
            } else if let allocations = entry.allocations {
                VStack(spacing: 0) {
                    DeveloperHeapCollectionStrip(profile: allocations, end: entry.snapshot.timestamp)
                    Divider()
                    DeveloperHeapSummary(entry: entry, filter: filter, memory: memory)
                }
                .id(entry.id)
            } else if perspective == .summary {
                let scope = (DeveloperMemory.allocationFilters(for: entry, in: memory.snapshots)
                    + DeveloperMemory.retentionFilters(for: entry))
                    .first { $0.filter == allocationFilter }?.scope
                DeveloperHeapSummary(entry: entry, filter: filter, memory: memory, scope: scope).id(entry.id)
            } else if perspective == .containment {
                DeveloperHeapContainment(entry: entry, memory: memory).id(entry.id)
            } else if perspective == .statistics {
                DeveloperHeapStatisticsView(entry: entry).id(entry.id)
            } else if let base, let other = memory.snapshots.first(where: { $0.id == base }) {
                DeveloperHeapComparison(entry: entry, base: other, filter: filter)
            } else {
                placeholder("Take another snapshot to compare this one against.")
            }
        } else {
            placeholder(memory.progress ?? (memory.recordingAllocations ? "Recording allocations…" : "Select a profile."))
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func megabytes(_ bytes: Int) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_000_000)
    }
}

private struct DeveloperHeapCollectionStrip: View {
    let profile: DeveloperHeapAllocationProfile
    let end: Double

    var body: some View {
        let duration = max(0, end - profile.start.timestamp)
        let count = profile.collections.count
        let marks = profile.marks(end: end)
        let events: String = "\(count.formatted()) \(count == 1 ? "event" : "events")"
        // WebKit's timestamps may not advance; then the length isn't known.
        let length: String = duration > 0 ? " · \(duration.formatted(.number.precision(.fractionLength(2)))) s" : ""
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Garbage collection")
                Spacer()
                Text(events + length)
            }
            .foregroundStyle(.secondary)
            Canvas { context, size in
                for mark in marks {
                    let width = min(size.width, max(2, mark.width * size.width))
                    let rect = CGRect(x: max(0, min(size.width - width, mark.offset * size.width - (mark.width > 0 ? 0 : width / 2))),
                                      y: 0, width: width, height: size.height)
                    context.fill(Path(rect), with: .color(DeveloperToolsStyle.tint.opacity(mark.full ? 1 : 0.5)))
                }
            }
            .frame(height: 9)
            .background(DeveloperToolsStyle.raised)
        }
        .padding(DeveloperToolsStyle.gutter)
        .background(DeveloperToolsStyle.chrome)
        .accessibilityIdentifier("developer-memory-collections")
    }
}

/// Formatting and header pieces shared by Summary and Comparison.
private enum DeveloperHeapTable {
    /// How much the number columns shrink to leave the name column at
    /// least `name` points: 1 when the table is wide enough, never below
    /// a third.
    static func scale(_ columns: CGFloat, in width: CGFloat, name: CGFloat = 140) -> CGFloat {
        guard width > 0, columns > 0 else { return 1 }
        return max(1 / 3, min(1, (width - name - 2 * DeveloperToolsStyle.gutter) / columns))
    }

    /// Whether a size column is wide enough for its percentage too.
    static func showsPercent(_ width: CGFloat) -> Bool { width >= 110 }

    static func bytes(_ value: Int) -> String { value.formatted() }

    /// A size cell: the bytes, and their share of `total` when the column
    /// has room for it.
    static func size(_ value: Int, of total: Int, width: CGFloat) -> some View {
        HStack(spacing: 6) {
            Text(bytes(value))
            if showsPercent(width) {
                Text(percent(value, of: total)).foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
            }
        }
        .frame(width: width, alignment: .trailing)
    }

    static func signed(_ value: Int) -> String { (value > 0 ? "+" : "") + value.formatted() }

    static func percent(_ value: Int, of total: Int) -> String {
        guard total > 0 else { return "" }
        return String(format: "%.0f %%", Double(value) / Double(total) * 100)
    }

    /// A sortable header cell: the column's name and, when it's the one
    /// sorted by, which way.
    static func header(_ title: String, width: CGFloat?, sorted: Bool, ascending: Bool,
                       action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if width != nil { Spacer(minLength: 0) }
                Text(title).lineLimit(1)
                if sorted {
                    Image(systemName: ascending ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .semibold))
                }
                if width == nil { Spacer(minLength: 0) }
            }
            .frame(width: width)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .frame(height: DeveloperToolsStyle.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(sorted ? Palette.ink : .secondary)
    }
}

/// Summary: one row per class, opening onto its objects, then
/// `Heap.getPreview` for the object selected.
private struct DeveloperHeapSummary: View {
    let entry: DeveloperMemory.Entry
    let filter: String
    @ObservedObject var memory: DeveloperMemory
    /// Only the objects of a range of ids or a filter, or all of them.
    var scope: DeveloperHeapSummaryScope? = nil

    @State private var sort = DeveloperHeapSort()
    @State private var grouping: DeveloperHeapGrouping?
    /// While a filter reads the page: what it's doing.
    @State private var working: String?
    /// Why a filter couldn't be applied, or what it left out.
    @State private var note: String?
    @State private var expanded = Set<Int>()
    /// How many of a class's objects are listed, by class index.
    @State private var limits: [Int: Int] = [:]
    @State private var rows: [Row] = []
    @State private var selected: Int?
    @State private var preview: String?

    private static let baseCountWidth: CGFloat = 70
    private static let baseSizeWidth: CGFloat = 130
    @State private var tableWidth: CGFloat = 0
    private var scale: CGFloat { DeveloperHeapTable.scale(Self.baseCountWidth + 2 * Self.baseSizeWidth, in: tableWidth) }
    private var countWidth: CGFloat { (Self.baseCountWidth * scale).rounded() }
    private var sizeWidth: CGFloat { (Self.baseSizeWidth * scale).rounded() }
    private static let pageSize = 100

    enum Row: Identifiable {
        case group(DeveloperHeapClass)
        case object(node: Int)
        case more(classIndex: Int, remaining: Int)

        var id: String {
            switch self {
            case .group(let row): "c\(row.index)"
            case .object(let node): "n\(node)"
            case .more(let index, _): "m\(index)"
            }
        }
    }

    private struct Key: Equatable {
        let filter: String
        let sort: DeveloperHeapSort
        let expanded: Set<Int>
        let limits: [Int: Int]
    }

    private var snapshot: DeveloperHeapSnapshot { entry.snapshot }

    /// An allocation profile's retained sizes are the end snapshot's.
    private var retainedNote: String {
        entry.allocations == nil ? "" : "Includes older objects that only these new objects keep alive."
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 0).onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { tableWidth = $0 }
            if let note {
                Text(note).foregroundStyle(.secondary).lineLimit(2)
                    .padding(DeveloperToolsStyle.gutter)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DeveloperToolsStyle.chrome)
                Divider()
            }
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in line(row) }
                }
            }
            if let selected {
                Divider()
                HStack(alignment: .top, spacing: 8) {
                    Text("@\(snapshot.ids[selected])").foregroundStyle(.secondary).monospacedDigit()
                    Text(preview ?? "Loading preview…").font(DeveloperToolsStyle.code)
                        .lineLimit(4).textSelection(.enabled)
                        .foregroundStyle(preview == nil ? Color.secondary : Palette.ink)
                    Spacer(minLength: 0)
                }
                .padding(DeveloperToolsStyle.gutter)
                .background(DeveloperToolsStyle.chrome)
                Divider()
                DeveloperHeapRetainers(entry: entry, node: selected, memory: memory)
                    .id(selected)
                    .frame(height: 142)
            }
        }
        .overlay {
            if let working {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(working).foregroundStyle(.secondary)
                }
            } else if let scope, grouping != nil, rows.isEmpty, filter.isEmpty {
                Text(Self.emptyText(scope)).foregroundStyle(.secondary)
            }
        }
        .task(id: Key(filter: filter, sort: sort, expanded: expanded, limits: limits)) { rebuild() }
        .task(id: scope) { await regroup() }
        .task(id: selected) {
            preview = nil
            guard let selected else { return }
            if entry.loaded {
                preview = "No preview: this snapshot was loaded from a file."
                return
            }
            preview = await memory.preview(snapshot.ids[selected])
        }
    }

    private static func emptyText(_ scope: DeveloperHeapSummaryScope) -> String {
        switch scope {
        case .range: return "No objects were allocated in this range."
        case .duplicatedStrings: return "No duplicated strings were found."
        case .retainedByDetachedNodes: return "No objects are retained by detached DOM nodes."
        case .retainedByConsole: return "No objects are retained only by the DevTools console."
        }
    }

    /// The classes and objects for `scope`, worked out off the main thread
    /// once what a filter needs from the page is in.
    private func regroup() async {
        working = nil
        note = nil
        guard let scope else {
            grouping = nil
            rebuild()
            return
        }
        let snapshot = snapshot
        var result = DeveloperHeapGrouping(classes: [], instances: [])
        do {
            switch scope {
            case .range(let range):
                result = await Task.detached(priority: .userInitiated) { snapshot.allocated(in: range) }.value
            case .retainedByConsole:
                result = await Task.detached(priority: .userInitiated) { snapshot.retainedByConsole() }.value
            case .retainedByDetachedNodes:
                working = "Checking DOM nodes…"
                let detached = try await memory.detachedNodes(in: entry) { working = $0 }
                result = await Task.detached(priority: .userInitiated) { snapshot.retained(byDetached: detached) }.value
            case .duplicatedStrings:
                working = "Reading strings…"
                let scan = try await memory.stringValues(in: entry) { working = $0 }
                result = await Task.detached(priority: .userInitiated) { snapshot.duplicatedStrings(scan.values) }.value
                if scan.truncated {
                    note = "Only the \(scan.checked.formatted()) largest of \(scan.total.formatted()) strings were read."
                }
            }
        } catch {
            note = error.localizedDescription
        }
        guard !Task.isCancelled else { return }
        working = nil
        expanded = []
        limits = [:]
        grouping = result
        rebuild()
    }

    private func rebuild() {
        var list: [Row] = []
        let classes = grouping?.classes ?? entry.allocations?.classes
        let instances = grouping?.instances ?? entry.allocations?.instances
        for group in snapshot.summary(filter: filter, sort: sort, groups: classes) {
            list.append(.group(group))
            guard expanded.contains(group.index) else { continue }
            let objects = snapshot.instances(of: group.index, sort: sort, in: instances)
            let limit = limits[group.index] ?? Self.pageSize
            list += objects.prefix(limit).map { .object(node: $0) }
            if objects.count > limit { list.append(.more(classIndex: group.index, remaining: objects.count - limit)) }
        }
        rows = list
    }

    private var header: some View {
        HStack(spacing: 0) {
            column("Constructor", nil, .name)
            column("Count", countWidth, .count)
            column("Shallow size", sizeWidth, .shallow)
            column("Retained size", sizeWidth, .retained)
                .help(retainedNote)
        }
        .padding(.horizontal, DeveloperToolsStyle.gutter)
    }

    private func column(_ title: String, _ width: CGFloat?, _ column: DeveloperHeapSort.Column) -> some View {
        DeveloperHeapTable.header(title, width: width, sorted: sort.column == column, ascending: sort.ascending) {
            sort.toggle(column)
        }
    }

    @ViewBuilder private func line(_ row: Row) -> some View {
        let total = snapshot.totalSize
        switch row {
        case .group(let group):
            let open = expanded.contains(group.index)
            Button {
                if open { expanded.remove(group.index) } else { expanded.insert(group.index) }
            } label: {
                HStack(spacing: 0) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary).frame(width: 12)
                    Text(group.name).lineLimit(1).truncationMode(.middle)
                    Text(" ×\(group.count)").foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(group.count.formatted()).frame(width: countWidth, alignment: .trailing)
                    size(group.shallowSize, of: total)
                    size(group.retainedSize, of: total)
                }
                .rowStyle(selected: false)
            }
            .buttonStyle(.plain)
        case .object(let node):
            Button { selected = selected == node ? nil : node } label: {
                HStack(spacing: 0) {
                    Text(snapshot.classNames[snapshot.classIndexes[node]]).lineLimit(1).truncationMode(.middle)
                        .padding(.leading, 24)
                    Text(" @\(snapshot.ids[node])").foregroundStyle(.secondary)
                    if snapshot.isInternal(node) { Text(" (internal)").foregroundStyle(.tertiary) }
                    Spacer(minLength: 4)
                    Color.clear.frame(width: countWidth, height: 1)
                    size(snapshot.sizes[node], of: total)
                    size(snapshot.retained[node], of: total)
                }
                .rowStyle(selected: selected == node)
            }
            .buttonStyle(.plain)
            .modifier(DeveloperHeapObjectMenu(entry: entry, node: node, memory: memory))
        case .more(let index, let remaining):
            DeveloperHeapMoreRow(remaining: remaining, page: Self.pageSize, indent: 24) {
                limits[index] = (limits[index] ?? Self.pageSize) + Self.pageSize * 5
            }
        }
    }

    private func size(_ value: Int, of total: Int) -> some View {
        DeveloperHeapTable.size(value, of: total, width: sizeWidth)
    }
}

/// Detached elements: one row per node description (tag#id.class) with
/// how many detached nodes share it and what they retain, each opening
/// onto its nodes; the node selected (a group's largest, when a group is
/// clicked) shows its retainers beneath, as Chrome's profile does.
private struct DeveloperHeapDetachedView: View {
    let entry: DeveloperMemory.Entry
    let report: DeveloperHeapDetachedReport
    let filter: String
    @ObservedObject var memory: DeveloperMemory

    @State private var expanded = Set<String>()
    @State private var limits: [String: Int] = [:]
    @State private var selected: Int?

    private static let countWidth: CGFloat = 70
    private static let sizeWidth: CGFloat = 130
    private static let pageSize = 100

    private enum Row: Identifiable {
        case group(DeveloperHeapDetachedGroup)
        case node(Int, group: String)
        case more(group: String, remaining: Int)

        var id: String {
            switch self {
            case .group(let group): "g" + group.id
            case .node(let node, let group): "n\(node)/" + group
            case .more(let group, _): "m" + group
            }
        }
    }

    private var snapshot: DeveloperHeapSnapshot { entry.snapshot }

    private var rows: [Row] {
        var list: [Row] = []
        for group in report.filtered(filter) {
            list.append(.group(group))
            guard expanded.contains(group.id) else { continue }
            let limit = limits[group.id] ?? Self.pageSize
            list += group.nodes.prefix(limit).map { .node($0, group: group.id) }
            if group.count > limit { list.append(.more(group: group.id, remaining: group.count - limit)) }
        }
        return list
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(summary).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(DeveloperToolsStyle.gutter)
            .background(DeveloperToolsStyle.chrome)
            Divider()
            HStack(spacing: 0) {
                heading("Node", nil)
                heading("Count", Self.countWidth)
                heading("Retained size", Self.sizeWidth)
            }
            .padding(.horizontal, DeveloperToolsStyle.gutter)
            Divider()
            if report.groups.isEmpty {
                Text("No detached DOM nodes were found.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in line(row) }
                    }
                }
            }
            if let selected {
                Divider()
                DeveloperHeapRetainers(entry: entry, node: selected, memory: memory)
                    .id(selected)
                    .frame(height: 180)
            }
        }
        .accessibilityIdentifier("developer-memory-detached")
    }

    private var summary: String {
        let count = report.detachedCount
        var text = "\(count.formatted()) detached \(count == 1 ? "node" : "nodes") of \(report.checked.formatted()) DOM \(report.checked == 1 ? "node" : "nodes") checked."
        if report.truncated {
            text += " Only the \(report.checked.formatted()) largest of \(report.candidates.formatted()) were checked."
        }
        return text
    }

    private func heading(_ title: String, _ width: CGFloat?) -> some View {
        DeveloperHeapTable.header(title, width: width, sorted: false, ascending: false) {}
    }

    @ViewBuilder private func line(_ row: Row) -> some View {
        let total = snapshot.totalSize
        switch row {
        case .group(let group):
            let open = expanded.contains(group.id)
            Button {
                if open { expanded.remove(group.id) } else { expanded.insert(group.id) }
                selected = group.nodes.first
            } label: {
                HStack(spacing: 0) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary).frame(width: 12)
                    Text(group.description).font(DeveloperToolsStyle.code).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(group.count.formatted()).frame(width: Self.countWidth, alignment: .trailing)
                    size(group.retainedSize, of: total)
                }
                .rowStyle(selected: false)
            }
            .buttonStyle(.plain)
        case .node(let node, let group):
            Button { selected = selected == node ? nil : node } label: {
                HStack(spacing: 0) {
                    Text(group).font(DeveloperToolsStyle.code).lineLimit(1).truncationMode(.middle)
                        .padding(.leading, 24)
                    Text(" @\(snapshot.ids[node])").foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Color.clear.frame(width: Self.countWidth, height: 1)
                    size(snapshot.retained[node], of: total)
                }
                .rowStyle(selected: selected == node)
            }
            .buttonStyle(.plain)
            .modifier(DeveloperHeapObjectMenu(entry: entry, node: node, memory: memory))
        case .more(let group, let remaining):
            DeveloperHeapMoreRow(remaining: remaining, page: Self.pageSize, indent: 24) {
                limits[group] = (limits[group] ?? Self.pageSize) + Self.pageSize * 5
            }
        }
    }

    private func size(_ value: Int, of total: Int) -> some View {
        DeveloperHeapTable.size(value, of: total, width: Self.sizeWidth)
    }
}

/// An object's context menu: Store as global variable and, for a DOM
/// node, Reveal in Elements panel. Both need the object on the page, so
/// they're off for a loaded snapshot or one from before the page changed.
private struct DeveloperHeapObjectMenu: ViewModifier {
    let entry: DeveloperMemory.Entry
    let node: Int
    @ObservedObject var memory: DeveloperMemory

    func body(content: Content) -> some View {
        content.contextMenu {
            Button("Store as global variable") {
                Task { _ = await memory.storeAsGlobal(node, in: entry) }
            }
            .disabled(entry.objectGeneration != memory.objectGeneration)
            if entry.snapshot.suggestsDOMNode(node) {
                Button("Reveal in Elements panel") {
                    Task { await memory.revealInElements(node, in: entry) }
                }
                .disabled(entry.objectGeneration != memory.objectGeneration)
            }
        }
    }
}

/// Containment: the heap from the GC roots down, each object opening onto
/// the objects it holds (a page at a time, as Retainers), and the selected
/// object's retainers beneath.
private struct DeveloperHeapContainment: View {
    let entry: DeveloperMemory.Entry
    @ObservedObject var memory: DeveloperMemory

    @State private var expanded = Set<String>()
    @State private var limits: [String: Int] = [:]
    @State private var rows: [DeveloperHeapRetainerRow] = []
    @State private var selected: String?

    private static let baseDistanceWidth: CGFloat = 70
    private static let baseSizeWidth: CGFloat = 130
    @State private var tableWidth: CGFloat = 0
    private var scale: CGFloat { DeveloperHeapTable.scale(Self.baseDistanceWidth + 2 * Self.baseSizeWidth, in: tableWidth, name: 180) }
    private var distanceWidth: CGFloat { (Self.baseDistanceWidth * scale).rounded() }
    private var sizeWidth: CGFloat { (Self.baseSizeWidth * scale).rounded() }

    private struct Key: Equatable {
        let expanded: Set<String>
        let limits: [String: Int]
    }

    private var snapshot: DeveloperHeapSnapshot { entry.snapshot }

    private var selectedNode: Int? {
        guard let selected else { return nil }
        return rows.first { $0.id == selected }?.reference?.node
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 0).onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { tableWidth = $0 }
            HStack(spacing: 0) {
                heading("Object", nil)
                heading("Distance", distanceWidth)
                heading("Shallow size", sizeWidth)
                heading("Retained size", sizeWidth)
            }
            .padding(.horizontal, DeveloperToolsStyle.gutter)
            Divider()
            if snapshot.hasChildren(snapshot.root) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in line(row) }
                    }
                }
            } else {
                Text("The GC roots hold no objects in this snapshot.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let node = selectedNode, node != snapshot.root {
                Divider()
                DeveloperHeapRetainers(entry: entry, node: node, memory: memory)
                    .id(selected)
                    .frame(height: 142)
            }
        }
        .task(id: Key(expanded: expanded, limits: limits)) { rebuild() }
        .accessibilityIdentifier("developer-memory-containment")
    }

    private func rebuild() {
        let entry = entry, memory = memory
        rows = snapshot.containmentRows(expanded: expanded, limits: limits) { node in
            memory.children(of: node, in: entry)
        }
    }

    private func heading(_ title: String, _ width: CGFloat?) -> some View {
        DeveloperHeapTable.header(title, width: width, sorted: false, ascending: false) {}
    }

    @ViewBuilder private func line(_ row: DeveloperHeapRetainerRow) -> some View {
        let indent = CGFloat(min(row.depth, 16)) * 12
        let total = snapshot.totalSize
        if let reference = row.reference {
            let node = reference.node
            HStack(spacing: 0) {
                Button {
                    if expanded.contains(row.id) { expanded.remove(row.id) } else { expanded.insert(row.id) }
                } label: {
                    Image(systemName: row.expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12, height: DeveloperToolsStyle.rowHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(row.expandable ? 1 : 0)
                .disabled(!row.expandable)
                HStack(spacing: 5) {
                    Text(reference.label).foregroundStyle(.secondary).lineLimit(1)
                    Text("::").foregroundStyle(.tertiary)
                    Text(snapshot.classNames[snapshot.classIndexes[node]]).lineLimit(1).truncationMode(.middle)
                    Text("@\(snapshot.ids[node])").foregroundStyle(.secondary).lineLimit(1)
                    if snapshot.isInternal(node) { Text("(internal)").foregroundStyle(.tertiary).lineLimit(1) }
                    Spacer(minLength: 4)
                    Text(reference.distance?.formatted() ?? "—")
                        .frame(width: distanceWidth, alignment: .trailing)
                    size(snapshot.sizes[node], of: total)
                    size(snapshot.retained[node], of: total)
                }
                .padding(.leading, 5)
                .contentShape(Rectangle())
                .onTapGesture { selected = selected == row.id ? nil : row.id }
            }
            .padding(.leading, indent)
            .rowStyle(selected: selected == row.id)
            .modifier(DeveloperHeapObjectMenu(entry: entry, node: node, memory: memory))
        } else {
            let page = DeveloperHeapSnapshot.retainerPageSize
            DeveloperHeapMoreRow(remaining: row.remaining, page: page, indent: indent + 17) {
                limits[row.parent] = (limits[row.parent] ?? page) + page * 5
            }
        }
    }

    private func size(_ value: Int, of total: Int) -> some View {
        DeveloperHeapTable.size(value, of: total, width: sizeWidth)
    }
}

/// Statistics: how the heap's size divides among code, strings, arrays,
/// typed arrays, system objects, DOM nodes and other objects, as a
/// stacked bar and a table.
private struct DeveloperHeapStatisticsView: View {
    let entry: DeveloperMemory.Entry

    @State private var statistics: DeveloperHeapStatistics?

    private let countWidth: CGFloat = 90
    private let sizeWidth: CGFloat = 130

    static func color(_ category: DeveloperHeapCategory) -> Color {
        switch category {
        case .code: .orange
        case .strings: .pink
        case .arrays: .blue
        case .typedArrays: .teal
        case .system: .gray
        case .dom: .purple
        case .other: .green
        }
    }

    var body: some View {
        Group {
            if let statistics {
                content(statistics)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: entry.id) {
            let snapshot = entry.snapshot
            let result = await Task.detached(priority: .userInitiated) { snapshot.statistics() }.value
            guard !Task.isCancelled else { return }
            statistics = result
        }
        .accessibilityIdentifier("developer-memory-statistics")
    }

    private func content(_ statistics: DeveloperHeapStatistics) -> some View {
        let shown = statistics.buckets.filter { $0.size > 0 }
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Total size").fontWeight(.semibold)
                    Spacer()
                    Text(DeveloperMemoryView.megabytes(statistics.total)).monospacedDigit()
                }
                Canvas { context, size in
                    guard statistics.total > 0 else { return }
                    var x: CGFloat = 0
                    for bucket in shown {
                        let width = size.width * CGFloat(bucket.size) / CGFloat(statistics.total)
                        context.fill(Path(CGRect(x: x, y: 0, width: width, height: size.height)),
                                     with: .color(Self.color(bucket.category)))
                        x += width
                    }
                }
                .frame(height: 16)
                .background(DeveloperToolsStyle.raised)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .accessibilityHidden(true)
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Text("Category").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Count").frame(width: countWidth, alignment: .trailing)
                        Text("Size").frame(width: sizeWidth, alignment: .trailing)
                    }
                    .foregroundStyle(.secondary)
                    .frame(height: DeveloperToolsStyle.rowHeight)
                    Divider()
                    ForEach(statistics.buckets) { bucket in
                        HStack(spacing: 0) {
                            HStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 2).fill(Self.color(bucket.category))
                                    .frame(width: 9, height: 9)
                                Text(bucket.category.rawValue)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text(bucket.count.formatted()).frame(width: countWidth, alignment: .trailing)
                            HStack(spacing: 6) {
                                Text(DeveloperHeapTable.bytes(bucket.size))
                                Text(DeveloperHeapTable.percent(bucket.size, of: statistics.total))
                                    .foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                            }
                            .frame(width: sizeWidth, alignment: .trailing)
                        }
                        .monospacedDigit()
                        .frame(height: DeveloperToolsStyle.rowHeight)
                        .foregroundStyle(bucket.size > 0 ? Palette.ink : Color.secondary)
                    }
                }
                .frame(maxWidth: 560)
            }
            .padding(DeveloperToolsStyle.gutter * 2)
        }
    }
}

/// Incoming references for a selected object, one flat list of rows in
/// which only open branches are followed and each lists a page of its
/// references, so the whole heap graph never becomes a view tree.
private struct DeveloperHeapRetainers: View {
    let entry: DeveloperMemory.Entry
    let node: Int
    let memory: DeveloperMemory

    /// Open rows and how many references each branch lists, by row path.
    @State private var expanded = Set<String>()
    @State private var limits: [String: Int] = [:]
    @State private var rows: [DeveloperHeapRetainerRow] = []

    private struct Key: Equatable {
        let expanded: Set<String>
        let limits: [String: Int]
    }

    private var snapshot: DeveloperHeapSnapshot { entry.snapshot }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Retainers").fontWeight(.semibold)
                Spacer(minLength: 4)
                Text("Distance").foregroundStyle(.secondary)
            }
            .rowStyle(selected: false)
            .background(DeveloperToolsStyle.chrome)
            Divider()
            if snapshot.hasRetainers(node) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in line(row) }
                    }
                }
            } else {
                Text("No retainers in this snapshot.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: Key(expanded: expanded, limits: limits)) { rebuild() }
        .accessibilityIdentifier("developer-memory-retainers")
    }

    private func rebuild() {
        let entry = entry, memory = memory
        rows = snapshot.retainerRows(of: node, expanded: expanded, limits: limits) { owner in
            memory.retainers(of: owner, in: entry)
        }
    }

    @ViewBuilder private func line(_ row: DeveloperHeapRetainerRow) -> some View {
        let indent = CGFloat(min(row.depth, 12)) * 12
        if let reference = row.reference {
            let owner = reference.node
            Button {
                if expanded.contains(row.id) { expanded.remove(row.id) } else { expanded.insert(row.id) }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: row.expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                        .opacity(row.expandable ? 1 : 0)
                    Text(reference.label).foregroundStyle(.secondary).lineLimit(1)
                    if owner == snapshot.root {
                        Text("(GC roots)").lineLimit(1)
                    } else {
                        Text(snapshot.classNames[snapshot.classIndexes[owner]]).lineLimit(1).truncationMode(.middle)
                        Text("@\(snapshot.ids[owner])").foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text(reference.distance?.formatted() ?? "—")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.leading, indent)
                .rowStyle(selected: false)
            }
            .buttonStyle(.plain)
            .disabled(!row.expandable)
        } else {
            let page = DeveloperHeapSnapshot.retainerPageSize
            DeveloperHeapMoreRow(remaining: row.remaining, page: page, indent: indent + 17) {
                limits[row.parent] = (limits[row.parent] ?? page) + page * 5
            }
        }
    }
}

/// Comparison: per class, the objects that are new since the base
/// snapshot and the ones gone from it.
private struct DeveloperHeapComparison: View {
    let entry: DeveloperMemory.Entry
    let base: DeveloperMemory.Entry
    let filter: String

    @State private var sort = DeveloperHeapDeltaSort()
    @State private var deltas: [DeveloperHeapDelta]?
    @State private var rows: [DeveloperHeapDelta] = []

    private static let baseCountWidth: CGFloat = 70
    private static let baseSizeWidth: CGFloat = 96
    @State private var tableWidth: CGFloat = 0
    private var scale: CGFloat { DeveloperHeapTable.scale(3 * Self.baseCountWidth + 3 * Self.baseSizeWidth, in: tableWidth, name: 120) }
    private var countWidth: CGFloat { (Self.baseCountWidth * scale).rounded() }
    private var sizeWidth: CGFloat { (Self.baseSizeWidth * scale).rounded() }

    private struct Pair: Equatable { let entry: Int, base: Int }
    private struct Key: Equatable { let ready: Bool; let filter: String; let sort: DeveloperHeapDeltaSort }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 0).onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { tableWidth = $0 }
            HStack(spacing: 0) {
                column("Constructor", nil, .name)
                column("# New", countWidth, .added)
                column("# Deleted", countWidth, .deleted)
                column("# Delta", countWidth, .delta)
                column("Alloc. size", sizeWidth, .allocated)
                column("Freed size", sizeWidth, .freed)
                column("Size delta", sizeWidth, .sizeDelta)
            }
            .padding(.horizontal, DeveloperToolsStyle.gutter)
            Divider()
            if deltas == nil {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                Text(filter.isEmpty ? "No objects were allocated or freed between \(base.title) and \(entry.title)."
                                    : "No classes match the filter.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            HStack(spacing: 0) {
                                Text(row.name).lineLimit(1).truncationMode(.middle).padding(.leading, 12)
                                Spacer(minLength: 4)
                                cell(row.added.formatted(), countWidth)
                                cell(row.deleted.formatted(), countWidth)
                                cell(DeveloperHeapTable.signed(row.delta), countWidth)
                                cell(DeveloperHeapTable.bytes(row.allocatedSize), sizeWidth)
                                cell(DeveloperHeapTable.bytes(row.freedSize), sizeWidth)
                                cell(DeveloperHeapTable.signed(row.sizeDelta), sizeWidth)
                            }
                            .rowStyle(selected: false)
                        }
                    }
                }
            }
        }
        .task(id: Pair(entry: entry.id, base: base.id)) {
            deltas = nil
            let current = entry.snapshot, previous = base.snapshot
            let result = await Task.detached(priority: .userInitiated) { current.comparison(from: previous) }.value
            guard !Task.isCancelled else { return }
            deltas = result
        }
        .task(id: Key(ready: deltas != nil, filter: filter, sort: sort)) {
            rows = sort.sorted(deltas ?? [], filter: filter)
        }
    }

    private func column(_ title: String, _ width: CGFloat?, _ column: DeveloperHeapDeltaSort.Column) -> some View {
        DeveloperHeapTable.header(title, width: width, sorted: sort.column == column, ascending: sort.ascending) {
            sort.toggle(column)
        }
    }

    private func cell(_ text: String, _ width: CGFloat) -> some View {
        Text(text).frame(width: width, alignment: .trailing)
    }
}

/// "Show 500 more of 1,234": the next pages of a long list.
private struct DeveloperHeapMoreRow: View {
    let remaining: Int
    let page: Int
    let indent: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Show \(min(remaining, page * 5).formatted()) more of \(remaining.formatted())")
                .foregroundStyle(DeveloperToolsStyle.tint)
                .padding(.leading, indent)
                .rowStyle(selected: false)
        }
        .buttonStyle(.plain)
    }
}

private extension View {
    func rowStyle(selected: Bool) -> some View {
        monospacedDigit()
            .padding(.horizontal, DeveloperToolsStyle.gutter)
            .frame(height: DeveloperToolsStyle.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? DeveloperToolsStyle.selected : .clear)
            .contentShape(Rectangle())
    }
}
