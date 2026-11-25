import SwiftUI

/// Adds a Local or Session Storage item, or edits an item's key and value.
struct DeveloperStorageItemEditor: View {
    @Environment(\.developerDismiss) private var dismiss
    let previous: DeveloperApplicationItem?
    let key: String
    let persistent: Bool
    let session: DeveloperToolsSession
    let page: URL?
    /// A subframe's origin a new item goes to; nil for the page's own.
    var origin: String? = nil
    let didSave: () -> Void
    @State private var draftKey = ""
    @State private var draftValue = ""
    @State private var original: String?
    @State private var loaded = false
    @State private var problem: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(previous == nil ? "Add Item" : "Edit Item").font(.headline).accessibilityAddTraits(.isHeader)
            Text(persistent ? "Local storage" : "Session storage").foregroundStyle(.secondary)
            TextField("Key", text: $draftKey)
                .font(DeveloperToolsStyle.code)
                .accessibilityLabel("Key")
            if loaded {
                TextEditor(text: $draftValue)
                    .font(DeveloperToolsStyle.code)
                    .frame(height: 120)
                    .scrollContentBackground(.hidden)
                    .background(Color.primary.opacity(0.045),
                                in: RoundedRectangle(cornerRadius: DeveloperToolsStyle.controlRadius))
                    .accessibilityLabel("Value")
            } else if problem == nil {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 50)
            }
            if let problem { Text(problem).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack {
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!loaded || saving || page == nil)
            }
        }
        .padding(16)
        .frame(width: 400)
        .task { await load() }
    }

    private func load() async {
        draftKey = key
        guard let previous else { loaded = true; return }
        do {
            let value = try await DeveloperApplication.storageValue(of: previous, in: session)
            original = value
            draftValue = value
            loaded = true
        } catch {
            problem = (error as? DeveloperApplication.Issue)?.errorDescription ?? error.localizedDescription
        }
    }

    private func save() {
        guard let page, !saving else { return }
        let changedValue = original != draftValue
        if previous != nil, draftKey == key, !changedValue { dismiss(); return }
        saving = true
        problem = nil
        let value = previous == nil || changedValue ? draftValue : nil
        let key = draftKey
        Task {
            defer { saving = false }
            do {
                try await DeveloperApplication.setStorageItem(key: key, value: value, replacing: previous,
                                                              persistent: persistent, in: session, address: page,
                                                              origin: origin)
                didSave()
            } catch {
                problem = (error as? DeveloperApplication.Issue)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

/// Chrome's editable cookie row, as a form: every attribute WebKit stores.
struct DeveloperCookieEditor: View {
    @Environment(\.developerDismiss) private var dismiss
    let previous: DeveloperApplicationItem?
    let session: DeveloperToolsSession
    let page: URL?
    /// A subframe's origin a new cookie goes to; nil for the page's own.
    var origin: String? = nil
    let didSave: () -> Void
    @State private var draft = DeveloperCookieDraft()
    @State private var sessionOnly = true
    @State private var expires = Date().addingTimeInterval(86_400 * 30)
    @State private var loaded = false
    @State private var problem: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(previous == nil ? "Add Cookie" : "Edit Cookie").font(.headline).accessibilityAddTraits(.isHeader)
            if loaded {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow { Text("Name"); TextField("Name", text: $draft.name).labelsHidden() }
                    GridRow { Text("Value"); TextField("Value", text: $draft.value).labelsHidden() }
                    GridRow {
                        Text("Domain")
                        TextField(page?.host() ?? "Host only", text: $draft.domain).labelsHidden()
                            .help("Leave empty for a host-only cookie")
                    }
                    GridRow { Text("Path"); TextField("Path", text: $draft.path).labelsHidden() }
                    GridRow {
                        Text("Expires")
                        HStack {
                            Toggle("Session", isOn: $sessionOnly).toggleStyle(.developerCheckbox)
                            if !sessionOnly {
                                DatePicker("Expires", selection: $expires).labelsHidden()
                            }
                        }
                    }
                    GridRow {
                        Text("SameSite")
                        Picker("SameSite", selection: $draft.sameSite) {
                            Text("Not set").tag("")
                            Text("Lax").tag("Lax")
                            Text("Strict").tag("Strict")
                            Text("None").tag("None")
                        }.labelsHidden().fixedSize()
                    }
                    GridRow {
                        Text("")
                        HStack {
                            Toggle("HttpOnly", isOn: $draft.httpOnly).toggleStyle(.developerCheckbox)
                            Toggle("Secure", isOn: $draft.secure).toggleStyle(.developerCheckbox)
                        }
                    }
                }
                .font(.system(size: 12))
                Text("WebKit does not store cookie priority, and partitioned cookies can’t be created here.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if problem == nil {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 50)
            }
            if let problem { Text(problem).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack {
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!loaded || saving || page == nil || draft.name.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 420)
        .task { await load() }
    }

    private func load() async {
        guard let previous else { loaded = true; return }
        do {
            draft = try await DeveloperApplication.cookieDraft(for: previous, in: session)
            if let date = draft.expires { expires = date; sessionOnly = false }
            loaded = true
        } catch {
            problem = (error as? DeveloperApplication.Issue)?.errorDescription ?? error.localizedDescription
        }
    }

    private func save() {
        guard let page, !saving else { return }
        var cookie = draft
        cookie.expires = sessionOnly ? nil : expires
        saving = true
        problem = nil
        Task {
            defer { saving = false }
            do {
                try await DeveloperApplication.saveCookie(cookie, replacing: previous, in: session, address: page,
                                                          origin: origin)
                didSave()
            } catch {
                problem = (error as? DeveloperApplication.Issue)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

/// Chrome's Application › Storage: usage, quota and "Clear site data".
struct DeveloperStorageOverviewView: View {
    let session: DeveloperToolsSession
    let page: URL
    let refresh: Int
    let didClear: () -> Void
    @State private var overview: DeveloperStorageOverview?
    @State private var problem: String?
    @State private var chosen = Set(DeveloperSiteData.allCases)
    @State private var clearing = false
    @State private var cleared: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(DeveloperApplication.origin(of: page)?.absoluteString ?? page.absoluteString)
                    .font(DeveloperToolsStyle.code).textSelection(.enabled)
                Text("Usage").fontWeight(.semibold)
                if let overview {
                    Text(usageText(overview)).textSelection(.enabled)
                    if overview.persisted == true { Text("Storage is persistent.").foregroundStyle(.secondary) }
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
                        ForEach(overview.counts, id: \.0) { name, count in
                            GridRow {
                                Text(name).foregroundStyle(.secondary)
                                Text(count.map(String.init) ?? "—").monospacedDigit()
                            }
                        }
                    }
                    if let breakdown = overview.breakdown {
                        Text("Usage by type").fontWeight(.semibold)
                        DeveloperStorageBreakdownBar(breakdown: breakdown, sizes: overview.sizes)
                        Text("WebKit reports a total only. Each type’s size is measured here from what the page stores (≈ marks an estimate); Other is what WebKit counts beyond them.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Toggle("Simulate custom storage quota", isOn: .constant(false))
                        .toggleStyle(.developerCheckbox)
                        .disabled(true)
                        .help("WebKit has no way to override an origin’s storage quota.")
                    Text("Not available: WebKit can’t override an origin’s storage quota.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let problem {
                    Text(problem).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
                Divider()
                Text("Clear site data").fontWeight(.semibold)
                Button("Clear site data") { clear() }
                    .disabled(chosen.isEmpty || clearing)
                if let cleared { Text(cleared).foregroundStyle(.secondary) }
                Text("Application").foregroundStyle(.secondary)
                toggle(.workers)
                Text("Storage").foregroundStyle(.secondary)
                ForEach([DeveloperSiteData.storage, .indexedDB, .cookies, .caches]) { toggle($0) }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(DeveloperToolsStyle.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: refresh) { await load() }
    }

    private func toggle(_ kind: DeveloperSiteData) -> some View {
        Toggle(kind.rawValue, isOn: Binding(get: { chosen.contains(kind) }, set: { on in
            if on { chosen.insert(kind) } else { chosen.remove(kind) }
        }))
        .toggleStyle(.developerCheckbox)
    }

    private func usageText(_ overview: DeveloperStorageOverview) -> String {
        let format = ByteCountFormatStyle(style: .file)
        guard let usage = overview.usage else { return "WebKit did not report storage usage for this origin." }
        let used = Int64(usage).formatted(format)
        guard let quota = overview.quota else { return used + " used" }
        return used + " used out of " + Int64(quota).formatted(format) + " storage quota"
    }

    private func load() async {
        do {
            overview = try await DeveloperApplication.overview(in: session, address: page)
            problem = nil
        } catch {
            problem = (error as? DeveloperApplication.Issue)?.errorDescription ?? error.localizedDescription
        }
    }

    private func clear() {
        guard !clearing else { return }
        clearing = true
        cleared = nil
        let kinds = chosen
        Task {
            defer { clearing = false }
            do {
                let failed = try await DeveloperApplication.clearSiteData(kinds, in: session, address: page)
                cleared = failed.isEmpty ? "Site data cleared." : "Could not clear: " + failed.joined(separator: ", ") + "."
                didClear()
            } catch {
                cleared = (error as? DeveloperApplication.Issue)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
