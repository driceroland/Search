import Accessibility
import AppKit
import SwiftUI
import WebKit

struct DeveloperApplicationView: View {
    @ObservedObject var session: DeveloperToolsSession
    @State private var query = DeveloperApplicationQuery()
    @State private var filter = ""
    @State private var page: URL?
    @State private var loading = true
    @State private var refresh = 0
    @State private var snapshot: DeveloperApplicationSnapshot?
    @State private var displayed: LoadKey?
    @State private var selectedRow: Int?
    @State private var problem: String?
    @State private var editingValue: EditRequest?
    @State private var editingItem: ItemEdit?
    @State private var working = false
    @State private var actionProblem: String?
    /// The sidebar's databases, caches and frames.
    @State private var tree = DeveloperApplicationTree()
    /// Each table's sort and column widths while the panel is open.
    @State private var tables: [String: DeveloperTableState] = [:]
    /// The IndexedDB view's "Start from key" field, before it is submitted.
    @State private var startKeyDraft = ""
    /// Cookies' "Only show cookies with an issue".
    @State private var onlyIssues = false

    private struct ItemEdit: Identifiable {
        let id = UUID()
        let cookie: Bool
        let previous: DeveloperApplicationItem?
        let key: String
    }

    private struct LoadKey: Hashable {
        let page: URL?
        let loading: Bool
        let refresh: Int
        let query: DeveloperApplicationQuery
    }

    private struct EditRequest: Identifiable {
        let id = UUID()
        let reference: DeveloperApplicationValue
    }

    var body: some View {
        let request = key
        if let web = session.web {
            GeometryReader { geometry in
                if geometry.size.width >= 480 {
                    HSplitView {
                        navigation.frame(minWidth: 124, idealWidth: 153, maxWidth: 197)
                        details.frame(minWidth: 260)
                    }
                } else {
                    details
                }
            }
            .onReceive(web.publisher(for: \.url)) { updated in
                if page.flatMap(DeveloperApplication.origin) != updated.flatMap(DeveloperApplication.origin) {
                    resetDrilldown()
                    filter = ""
                }
                page = updated
            }
            .onReceive(web.publisher(for: \.isLoading)) { loading = $0 }
            .onAppear {
                DeveloperServiceWorkerReloads.shared.watch(web)
                // The early script the Back/forward cache and Reporting API views read.
                DeveloperApplicationProbe.shared.watch(web)
            }
            .onChange(of: request) { _, _ in editingValue = nil }
            .onChange(of: query.store) { _, _ in startKeyDraft = query.startKey ?? "" }
            // The page changed its Local or Session storage: the table is
            // read again, as Chrome's updates.
            .onChange(of: session.domStorageRevision) { _, _ in
                guard query.section == .local || query.section == .session, !working,
                      editingItem == nil, editingValue == nil else { return }
                refresh += 1
            }
            .task(id: request) { await load(request) }
            .task(id: TreeKey(page: page, loading: loading, refresh: refresh)) {
                guard !loading, let page, DeveloperApplication.origin(of: page) != nil else {
                    tree = DeveloperApplicationTree()
                    return
                }
                let fresh = await DeveloperApplication.tree(in: session, address: page)
                if !Task.isCancelled, fresh != tree { tree = fresh }
            }
            .developerSheet(item: $editingValue) { edit in
                DeveloperApplicationValueEditor(reference: edit.reference, session: session) {
                    guard editingValue?.id == edit.id else { return }
                    editingValue = nil
                    refresh += 1
                }
            }
            .developerSheet(item: $editingItem) { edit in
                if edit.cookie {
                    DeveloperCookieEditor(previous: edit.previous, session: session, page: page,
                                          origin: query.origin) {
                        editingItem = nil
                        refresh += 1
                    }
                } else {
                    DeveloperStorageItemEditor(previous: edit.previous, key: edit.key,
                                               persistent: query.section == .local, session: session, page: page,
                                               origin: query.origin) {
                        editingItem = nil
                        refresh += 1
                    }
                }
            }
            .onDisappear {
                editingValue = nil
                editingItem = nil
            }
        }
    }

    private var key: LoadKey { LoadKey(page: page, loading: loading, refresh: refresh, query: query) }

    /// The frame whose view (DeveloperFrameDetailsView) is shown, when one is.
    private var frameDetail: String? {
        guard query.section == .frames, query.resource == nil, let frame = query.frame, !loading,
              page.flatMap(DeveloperApplication.origin) != nil else { return nil }
        return frame
    }

    private struct TreeKey: Hashable {
        let page: URL?
        let loading: Bool
        let refresh: Int
    }

    /// Chrome's sidebar as a tree: DeveloperApplicationTree.swift.
    private var navigation: some View {
        DeveloperApplicationSidebar(query: $query, tree: tree, workers: session.workers,
                                    revealWorker: { [session] worker in session.revealWorker(worker) }) { choose($0) }
    }

    private var details: some View {
        VStack(spacing: 0) {
            toolbar
            if query.section == .indexedDB, let database = query.database {
                breadcrumbs(database)
            }
            if query.section == .caches, let cache = query.cache {
                cacheBreadcrumbs(cache)
            }
            if let actionProblem {
                DeveloperApplicationProblemBar(text: actionProblem) { self.actionProblem = nil }
            }
            if query.section == .backForwardCache {
                // Shown through the test's own navigation away and back.
                DeveloperBackForwardCacheView(session: session, page: page, loading: loading)
            } else if query.section == .extensionStorage {
                DeveloperExtensionStorageView(session: session, page: page, loading: loading, refresh: refresh)
            } else if query.section == .notifications {
                // Recording goes on through the page's navigations.
                DeveloperNotificationsView(session: session)
            } else if query.section == .reporting, let page, DeveloperApplication.origin(of: page) != nil, !loading {
                DeveloperReportingView(session: session, page: page, refresh: refresh)
            } else if let frame = frameDetail, let page {
                DeveloperFrameDetailsView(session: session, page: page, frameID: frame, refresh: refresh) { url in
                    query.resource = url
                }
            } else if query.section == .workers, page.flatMap(DeveloperApplication.origin) != nil, !loading {
                DeveloperServiceWorkersView(session: session, refresh: refresh)
            } else if query.section == .storage, let page, DeveloperApplication.origin(of: page) != nil, !loading {
                DeveloperStorageOverviewView(session: session, page: page, refresh: refresh) { refresh += 1 }
            } else if showsQuery, let snapshot {
                results(snapshot)
            } else if displayed == key, let problem {
                placeholder(problem)
            } else if page == nil || loading {
                placeholder("Waiting for the page")
            } else if page.flatMap(DeveloperApplication.origin) == nil {
                placeholder("Choose an HTTP or HTTPS page to inspect application data.")
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var toolbar: some View {
        VStack(spacing: 0) {
            HStack(spacing: DeveloperToolsStyle.controlSpacing) {
                sectionMenu
                actionIcon("arrow.clockwise", "Refresh this section") {
                    filter = ""
                    refresh += 1
                }
                .disabled(loading || page.flatMap(DeveloperApplication.origin) == nil)
                HStack(spacing: DeveloperToolsStyle.controlSpacing) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("Filter", text: $filter)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, DeveloperToolsStyle.gutter)
                .frame(minWidth: 52, maxWidth: 240)
                .frame(height: DeveloperToolsStyle.controlHeight)
                .background(Color.primary.opacity(0.045),
                            in: RoundedRectangle(cornerRadius: DeveloperToolsStyle.controlRadius))
                actions
                if query.section == .cookies {
                    Toggle("Only show cookies with an issue", isOn: $onlyIssues)
                        .toggleStyle(.developerCheckbox)
                        .lineLimit(1)
                        .help("Only show cookies with SameSite=None but not Secure, or Secure on an origin that isn't HTTPS")
                }
                Spacer(minLength: 0)
                if working { ProgressView().controlSize(.mini).accessibilityLabel("Working") }
            }
            .padding(.horizontal, DeveloperToolsStyle.gutter)
            .padding(.vertical, DeveloperToolsStyle.controlSpacing)
            Divider()
        }
        .background(DeveloperToolsStyle.chrome)
    }

    private var current: DeveloperApplicationSnapshot? { showsQuery ? snapshot : nil }

    /// The rows on screen are this query's, though they may be being read
    /// again (Refresh, a change on the page).
    private var showsQuery: Bool {
        guard let displayed else { return false }
        return displayed == key || (displayed.query == key.query && displayed.page == key.page
            && !displayed.loading && !key.loading)
    }

    private var selectedItem: DeveloperApplicationItem? {
        guard let id = selectedRow else { return nil }
        return current?.rows.first { $0.id == id }?.item
    }

    private var cookiesWritable: Bool {
        if #available(macOS 27, *) { return true }
        return false
    }

    private func matchingRows(_ data: DeveloperApplicationSnapshot) -> [DeveloperApplicationSnapshot.Row] {
        let issuesOnly = onlyIssues && query.section == .cookies
        return data.rows.filter { row in
            (filter.isEmpty || row.values.contains(where: { $0.localizedCaseInsensitiveContains(filter) }))
                && (!issuesOnly || cookieIssue(row) != nil)
        }
    }

    /// The origin whose cookies are shown: the subframe's chosen, or the page's.
    private var shownOrigin: String? {
        query.origin ?? page.flatMap(DeveloperApplication.origin).map(DeveloperApplication.originText)
    }

    private func cookieIssue(_ row: DeveloperApplicationSnapshot.Row) -> String? {
        guard query.section == .cookies else { return nil }
        return DeveloperCookieIssues.issue(row: row.values, origin: shownOrigin)
    }

    @ViewBuilder
    private var actions: some View {
        let section = query.section
        if section == .local || section == .session || section == .cookies {
            actionIcon("plus", section == .cookies ? "Add cookie" : "Add item") {
                editingItem = ItemEdit(cookie: section == .cookies, previous: nil, key: "")
            }
            .disabled(current == nil || working || (section == .cookies && !cookiesWritable))
        }
        if let data = current, data.deletable || data.container != nil {
            if data.deletable {
                actionIcon("xmark", "Delete selected") { deleteSelected() }
                    .disabled(selectedItem == nil || working)
            }
            if let clear = clearAction(data) {
                actionIcon(clear.icon, clear.title) { perform(clear.items, after: clear.after) }
                    .disabled(clear.items.isEmpty || working)
            }
        }
    }

    private func clearAction(_ data: DeveloperApplicationSnapshot)
        -> (title: String, icon: String, items: [DeveloperApplicationItem], after: () -> Void)? {
        let filtered = matchingRows(data).compactMap(\.item)
        switch query.section {
        case .local, .session:
            if !filter.isEmpty { return ("Clear filtered items", "nosign", filtered, {}) }
            return ("Clear all", "nosign", data.container.map { [$0] } ?? [], {})
        case .cookies:
            return (filter.isEmpty && !onlyIssues ? "Clear all cookies" : "Clear filtered cookies", "nosign", filtered, {})
        case .indexedDB:
            guard let container = data.container else { return nil }
            if query.store != nil { return ("Clear object store", "nosign", [container], {}) }
            return ("Delete database", "trash", [container], { resetDrilldown() })
        case .caches:
            guard let container = data.container else { return nil }
            return ("Delete cache", "trash", [container], { resetDrilldown() })
        default: return nil
        }
    }

    private func actionIcon(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: DeveloperToolsStyle.controlHeight, height: DeveloperToolsStyle.controlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }

    private func deleteSelected() {
        guard let item = selectedItem, !working else { return }
        perform([item]) {}
    }

    private func perform(_ items: [DeveloperApplicationItem], after: @escaping () -> Void) {
        guard !items.isEmpty, !working else { return }
        working = true
        actionProblem = nil
        Task {
            defer {
                working = false
                selectedRow = nil
                refresh += 1
            }
            do {
                try await DeveloperApplication.delete(items, in: session)
                after()
            } catch {
                actionProblem = error.localizedDescription
            }
        }
    }

    private func cacheBreadcrumbs(_ cache: String) -> some View {
        barRow {
            Button("Caches") { resetDrilldown() }
                .buttonStyle(.plain).foregroundStyle(DeveloperToolsStyle.tint)
            chevron
            Text(cache).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.secondary)
    }

    /// A one-line bar under the toolbar: breadcrumbs or the pager.
    private func barRow(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: DeveloperToolsStyle.controlSpacing, content: content)
            .lineLimit(1)
            .padding(.horizontal, DeveloperToolsStyle.gutter)
            .frame(height: DeveloperToolsStyle.rowHeight)
            .overlay(alignment: .bottom) { Divider() }
    }

    private func pager(_ data: DeveloperApplicationSnapshot) -> some View {
        let first = data.rows.isEmpty ? data.skip : data.skip + 1
        let last = data.skip + data.rows.count
        let total = data.total.map { " of \($0)" } ?? ""
        return barRow {
            actionIcon("chevron.left", "Show previous page") {
                query.skip = max(0, query.skip - DeveloperApplicationQuery.pageSize)
            }
            .disabled(data.skip == 0)
            actionIcon("chevron.right", "Show next page") { query.skip += DeveloperApplicationQuery.pageSize }
                .disabled(!data.hasMore)
            Text("Entries \(first)–\(last)\(total)").foregroundStyle(.secondary).monospacedDigit()
            Spacer(minLength: 0)
        }
    }

    private var sectionMenu: some View {
        Menu {
            Picker("Application section", selection: Binding(get: { query.section }, set: choose)) {
                ForEach(DeveloperApplicationSection.allCases) { section in
                    Label(section.rawValue, systemImage: section.icon).tag(section)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: DeveloperToolsStyle.controlSpacing) {
                Image(systemName: query.section.icon).foregroundStyle(.secondary)
                Text(query.section.rawValue)
                Image(systemName: "chevron.down").font(.system(size: 8)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, DeveloperToolsStyle.controlSpacing)
            .frame(height: DeveloperToolsStyle.controlHeight)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Application section")
        .accessibilityValue(query.section.rawValue)
    }

    private func breadcrumbs(_ database: String) -> some View {
        barRow {
            Button("Databases") { resetDrilldown() }
                .buttonStyle(.plain).foregroundStyle(DeveloperToolsStyle.tint)
            chevron
            Button(database) {
                query.store = nil
                query.index = nil
                query.startKey = nil
                filter = ""
            }
            .buttonStyle(.plain)
            .foregroundStyle(query.store == nil ? .primary : DeveloperToolsStyle.tint)
            .disabled(query.store == nil)
            if let store = query.store {
                chevron
                Button(store) {
                    query.index = nil
                    query.skip = 0
                }
                .buttonStyle(.plain)
                .foregroundStyle(query.index == nil ? .secondary : DeveloperToolsStyle.tint)
                .disabled(query.index == nil)
                if let index = query.index {
                    chevron
                    Text(index).foregroundStyle(.secondary)
                }
                Spacer(minLength: DeveloperToolsStyle.gutter)
                // Chrome's "Start from key", as JSON: 42, "name" or [1, "a"].
                TextField("Start from key", text: $startKeyDraft)
                    .textFieldStyle(.plain)
                    .font(DeveloperToolsStyle.code)
                    .developerToolsField()
                    .frame(minWidth: 90, idealWidth: 160, maxWidth: 200)
                    .onSubmit {
                        let key = startKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        query.startKey = key.isEmpty ? nil : key
                        query.skip = 0
                    }
                    .help("Show entries from this key on. Write the key as JSON: 42, \"name\" or [1, \"a\"].")
                    .accessibilityLabel("Start from key")
            }
            Spacer(minLength: 0)
        }
    }

    private func results(_ data: DeveloperApplicationSnapshot) -> some View {
        let matching = matchingRows(data)
        return VStack(spacing: 0) {
            if data.skip > 0 || data.hasMore {
                pager(data)
            }
            if let note = data.note, !data.rows.isEmpty {
                Text(note).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DeveloperToolsStyle.gutter)
                    .padding(.vertical, DeveloperToolsStyle.controlSpacing)
                Divider()
            }
            if query.section == .manifest, let report = data.manifest {
                DeveloperManifestView(rows: data.rows, report: report)
            } else if data.rows.isEmpty && !addsRows {
                placeholder(data.note ?? "No entries")
            } else if matching.isEmpty && !data.rows.isEmpty {
                placeholder("No matching entries")
            } else {
                table(data, rows: matching)
                if let id = selectedRow, let row = matching.first(where: { $0.id == id }) {
                    rowDetails(row, columns: data.columns)
                }
                if data.preview != nil || data.previewImage != nil {
                    resourcePreview(text: data.preview, image: data.previewImage)
                }
            }
        }
    }

    // MARK: The table: DeveloperApplicationTable.swift

    private func table(_ data: DeveloperApplicationSnapshot, rows: [DeveloperApplicationSnapshot.Row]) -> some View {
        let stateKey = query.section.rawValue + "\n" + data.columns.joined(separator: "\n")
        return GeometryReader { geometry in
            DeveloperApplicationTable(
                columns: data.columns, rows: rows,
                defaultWidths: columnWidths(data.columns, available: geometry.size.width),
                state: Binding(get: { tables[stateKey] ?? DeveloperTableState() }, set: { tables[stateKey] = $0 }),
                selection: $selectedRow,
                editable: editableColumns, toggles: toggleColumns,
                canEdit: { $0.item?.editable == true },
                addsRows: addsRows,
                activate: { show($0) },
                fullText: { row, column in await fullText(row, column: column) },
                commit: { row, changes in await commit(row, changes) },
                delete: { row in if let item = row.item, !working { perform([item]) {} } }
            ) { row in
                if let editable = row.editableValue {
                    Button("Edit Value…") { beginEditing(editable) }
                }
                if let item = row.item, item.editable {
                    Button(query.section == .cookies ? "Edit Cookie…" : "Edit Item…") {
                        beginEditing(item)
                    }
                }
                if let item = row.item {
                    if row.editableValue != nil || item.editable { Divider() }
                    Button(item.deleteTitle) { perform([item]) {} }
                }
            }
        }
    }

    /// The cookie table's columns: Name, Value, Domain, Path, Expires and SameSite as text.
    private static let cookieText = [0, 1, 2, 3, 4, 8]

    private var editableColumns: [Int] {
        switch query.section {
        case .local, .session: [0, 1]
        case .cookies: cookiesWritable ? Self.cookieText : []
        default: []
        }
    }

    /// HttpOnly and Secure, which a double-click turns on or off, as Chrome's checkboxes do.
    private var toggleColumns: Set<Int> { query.section == .cookies && cookiesWritable ? [6, 7] : [] }

    private var addsRows: Bool {
        current != nil && !working && (query.section == .local || query.section == .session
                                        || (query.section == .cookies && cookiesWritable))
    }

    /// The whole key or value, which the table shows cut at 4 KB.
    private func fullText(_ row: DeveloperApplicationSnapshot.Row, column: Int) async -> String? {
        guard query.section == .local || query.section == .session, let item = row.item else { return nil }
        if column == 0 { return item.storageKey }
        return try? await DeveloperApplication.storageValue(of: item, in: session)
    }

    /// Saves cells edited in place through the editors' own paths.
    private func commit(_ row: DeveloperApplicationSnapshot.Row?, _ changes: [Int: String]) async -> String? {
        guard let page else { return DeveloperApplication.Issue.pageChanged.errorDescription }
        do {
            switch query.section {
            case .local, .session:
                let persistent = query.section == .local
                if let row {
                    guard let item = row.item, let key = item.storageKey else { throw DeveloperApplication.Issue.unavailable }
                    let newKey = changes[0] ?? key
                    // As in Chrome DevTools, clearing an item's key removes it.
                    if newKey.isEmpty {
                        try await DeveloperApplication.delete([item], in: session)
                    } else {
                        try await DeveloperApplication.setStorageItem(key: newKey, value: changes[1], replacing: item,
                                                                      persistent: persistent, in: session, address: page)
                    }
                } else {
                    let key = changes[0] ?? ""
                    guard !key.isEmpty else { return "Enter a key for the new item." }
                    try await DeveloperApplication.setStorageItem(key: key, value: changes[1] ?? "", replacing: nil,
                                                                  persistent: persistent, in: session, address: page,
                                                                  origin: query.origin)
                }
            case .cookies:
                var draft = DeveloperCookieDraft()
                if let item = row?.item { draft = try await DeveloperApplication.cookieDraft(for: item, in: session) }
                // A subframe origin's cookies are host-only for its host.
                let host = query.origin.flatMap { URL(string: $0)?.host() } ?? page.host()
                try Self.apply(changes, to: &draft, host: host?.lowercased())
                guard !draft.name.isEmpty else { return row == nil ? "Enter a name for the new cookie." : nil }
                try await DeveloperApplication.saveCookie(draft, replacing: row?.item, in: session, address: page,
                                                          origin: query.origin)
            default:
                return nil
            }
            refresh += 1
            return nil
        } catch {
            refresh += 1
            return error.localizedDescription
        }
    }

    /// The cookie table's cells, by column, onto the cookie editor's fields.
    static func apply(_ changes: [Int: String], to draft: inout DeveloperCookieDraft, host: String?) throws {
        for (column, text) in changes {
            let value = text.trimmingCharacters(in: .whitespaces)
            switch column {
            case 0: draft.name = value
            case 1: draft.value = text
            case 2: draft.domain = value.lowercased() == host ? "" : value
            case 3: draft.path = value.isEmpty ? "/" : value
            case 4:
                if value.isEmpty || value.lowercased() == "session" { draft.expires = nil }
                else if let date = Self.date(value) { draft.expires = date }
                else { throw DeveloperApplication.Issue.invalidCookie("Enter the expiry as a date such as 2027-01-31T12:00:00Z, or Session.") }
            case 6: draft.httpOnly = !value.isEmpty && value.lowercased() != "false"
            case 7: draft.secure = !value.isEmpty && value.lowercased() != "false"
            case 8:
                switch value.lowercased() {
                case "": draft.sameSite = ""
                case "lax": draft.sameSite = "Lax"
                case "strict": draft.sameSite = "Strict"
                case "none": draft.sameSite = "None"
                default: throw DeveloperApplication.Issue.invalidCookie("SameSite is Lax, Strict, None or empty.")
                }
            default: break
            }
        }
    }

    /// An expiry as the table shows it (ISO 8601), with or without fractions of a second.
    static func date(_ text: String) -> Date? {
        let format = ISO8601DateFormatter()
        if let date = format.date(from: text) { return date }
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = format.date(from: text) { return date }
        format.formatOptions = [.withFullDate]
        return format.date(from: text)
    }

    /// A frame resource's content, as Chrome previews it beneath the resource's details.
    private func resourcePreview(text: String?, image: Data?) -> some View {
        Group {
            if let image, let picture = NSImage(data: image) {
                Image(nsImage: picture)
                    .resizable().interpolation(.high).scaledToFit()
                    .frame(maxWidth: min(picture.size.width, 480), maxHeight: min(picture.size.height, 240))
                    .padding(DeveloperToolsStyle.gutter)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Image preview")
            } else if let text {
                ScrollView([.vertical, .horizontal]) {
                    Text(text)
                        .font(DeveloperToolsStyle.code)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DeveloperToolsStyle.gutter)
                }
                .frame(minHeight: 80, maxHeight: .infinity)
            }
        }
        .background(DeveloperToolsStyle.surface)
        .overlay(alignment: .top) { Divider() }
    }

    private func columnWidths(_ columns: [String], available: CGFloat) -> [CGFloat] {
        if columns.count == 2 {
            let first: CGFloat = max(105, available * 0.37)
            return [first, max(130, available - first)]
        }
        return columns.enumerated().map { index, column in
            switch column {
            case "Value", "Scope", "Script URL": 218
            case "Expires", "State": 127
            case "Expires / Max-Age", "Date": 170
            case "HttpOnly", "Secure", "SameSite", "Size", "Priority": 71
            case "#": 44
            case "URL": 260
            case "Name" where query.section == .caches || query.section == .fileSystem: 260
            default: index == 0 && columns.count == 1 ? available : 145
            }
        }
    }

    private func rowDetails(_ row: DeveloperApplicationSnapshot.Row, columns: [String]) -> some View {
        VStack(spacing: 0) {
            if let editable = row.editableValue {
                Button {
                    beginEditing(editable)
                } label: {
                    Label("Edit Value…", systemImage: "pencil")
                        .frame(height: DeveloperToolsStyle.controlHeight)
                        .padding(.horizontal, DeveloperToolsStyle.controlSpacing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, DeveloperToolsStyle.gutter)
                .padding(.top, DeveloperToolsStyle.controlSpacing)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // The value previewed as Chrome does: a JSON tree, or URL-decoded.
            DeveloperStorageValueDetails(
                section: query.section,
                fields: detailFields(row, columns: columns),
                valueIndex: DeveloperStorageValuePreview.valueColumn(Array(columns.prefix(row.values.count))))
        }
        .background(DeveloperToolsStyle.chrome)
        .overlay(alignment: .top) { Divider() }
    }

    /// The selected row's label and value pairs, and a cookie's issue, when it has one.
    private func detailFields(_ row: DeveloperApplicationSnapshot.Row, columns: [String]) -> [(String, String)] {
        var pairs: [[String]] = zip(columns, row.values).map { [$0, $1] }
        pairs += row.details
        if let issue = cookieIssue(row) { pairs.append(["Issue", issue]) }
        return pairs.map { ($0.first ?? "", $0.dropFirst().first ?? "") }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(10)
    }

    private func choose(_ section: DeveloperApplicationSection) {
        guard query.section != section else { return }
        query = DeveloperApplicationQuery(section: section)
        filter = ""
    }

    /// An entry of the sidebar's tree.
    private func choose(_ target: DeveloperApplicationQuery) {
        guard query != target else { return }
        query = target
        startKeyDraft = ""
        filter = ""
    }

    private func resetDrilldown() {
        query = DeveloperApplicationQuery(section: query.section)
        filter = ""
    }

    private func show(_ row: DeveloperApplicationSnapshot.Row) {
        if query.section == .indexedDB, query.store == nil, let first = row.values.first {
            if query.database == nil { query.database = first }
            else { query.store = first }
            filter = ""
        } else if query.section == .caches, query.cache == nil, let first = row.values.first {
            query.cache = first
            filter = ""
        } else {
            selectedRow = row.id
        }
    }

    private func beginEditing(_ reference: DeveloperApplicationValue) {
        guard displayed == key, !loading, editingValue == nil else { return }
        editingValue = EditRequest(reference: reference)
    }

    private func beginEditing(_ item: DeveloperApplicationItem) {
        guard displayed == key, !loading, editingItem == nil, item.editable else { return }
        editingItem = ItemEdit(cookie: query.section == .cookies, previous: item, key: item.storageKey ?? item.name)
    }

    private func load(_ key: LoadKey) async {
        guard !Task.isCancelled else { return }
        // The same table read again (Refresh, a change on the page): the
        // rows and the selection stay until the new rows come.
        let again = displayed.map { $0.query == key.query && $0.page == key.page && !$0.loading } ?? false
        if !again {
            snapshot = nil
            selectedRow = nil
        }
        problem = nil
        if !again { displayed = nil }
        guard !key.loading, let page = key.page, DeveloperApplication.origin(of: page) != nil else { return }
        // Sections with views of their own read the page themselves.
        if key.query.section.ownView || (key.query.section == .frames && key.query.frame != nil && key.query.resource == nil) {
            displayed = key
            return
        }
        do {
            let data = try await DeveloperApplication.read(key.query, in: session, address: page)
            guard !Task.isCancelled, self.key == key else { return }
            // The selection follows its row by key, wherever it is now.
            let selectedKey = again ? snapshot?.rows.first { $0.id == selectedRow }?.values.first : nil
            snapshot = data
            if again { selectedRow = selectedKey.flatMap { key in data.rows.first { $0.values.first == key }?.id } }
        } catch {
            guard !Task.isCancelled, self.key == key else { return }
            snapshot = nil
            problem = (error as? DeveloperApplication.Issue)?.errorDescription
                ?? DeveloperApplication.Issue.unavailable.errorDescription
        }
        displayed = key
    }
}

private struct DeveloperApplicationValueEditor: View {
    @Environment(\.developerDismiss) private var dismiss
    @FocusState private var editorFocused: Bool
    @State private var original: String?
    @State private var draft = ""
    @State private var problem: String?
    @State private var saveTask: Task<Void, Never>?
    let reference: DeveloperApplicationValue
    let session: DeveloperToolsSession
    let didSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: DeveloperToolsStyle.controlSpacing) {
                Text("Edit Value").font(.headline).accessibilityAddTraits(.isHeader)
                Text(reference.name).font(DeveloperToolsStyle.code).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
            if original != nil {
                TextEditor(text: $draft)
                    .font(DeveloperToolsStyle.code)
                    .focused($editorFocused)
                    .disabled(saveTask != nil)
                    .frame(height: 120)
                    .scrollContentBackground(.hidden)
                    .background(Color.primary.opacity(0.045),
                                in: RoundedRectangle(cornerRadius: DeveloperToolsStyle.controlRadius))
                    .accessibilityLabel("Value for \(reference.name)")
            } else if problem == nil {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .accessibilityLabel("Loading value")
            }
            if let problem {
                Text(problem).font(.callout).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            HStack {
                if saveTask != nil {
                    ProgressView().controlSize(.small).accessibilityLabel("Saving value")
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(saveTask != nil)
                Button("Save") { save() }
                    .keyboardShortcut("s", modifiers: [.command])
                    .help("Save Value (⌘S)")
                    .buttonStyle(.borderedProminent)
                    .disabled(original == nil || original == draft || saveTask != nil)
            }
        }
        .padding(16)
        .frame(width: 400)
        .interactiveDismissDisabled(saveTask != nil)
        .task { await load() }
        .onChange(of: problem) { _, problem in
            if let problem { AccessibilityNotification.Announcement(problem).post() }
        }
        .onDisappear {
            saveTask?.cancel()
            saveTask = nil
            original = nil
            draft = ""
            problem = nil
        }
    }

    private func load() async {
        do {
            let value = try await DeveloperApplication.value(for: reference, in: session)
            guard !Task.isCancelled else { return }
            original = value
            draft = value
            editorFocused = true
        } catch {
            guard !Task.isCancelled else { return }
            problem = message(for: error)
        }
    }

    private func save() {
        guard let original, draft != original, saveTask == nil else { return }
        let updated = draft
        problem = nil
        saveTask = Task {
            defer { saveTask = nil }
            do {
                try await DeveloperApplication.setValue(updated, replacing: original, for: reference, in: session)
                guard !Task.isCancelled else { return }
                didSave()
            } catch {
                guard !Task.isCancelled else { return }
                problem = message(for: error)
            }
        }
    }

    private func message(for error: Error) -> String {
        (error as? DeveloperApplication.Issue)?.errorDescription ?? "The value is unavailable."
    }
}
