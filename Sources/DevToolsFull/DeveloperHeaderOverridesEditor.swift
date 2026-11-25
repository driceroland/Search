import AppKit
import SwiftUI

// The windows for header overrides: Chrome's "Override headers" editor
// (Network ▸ Headers ▸ Response Headers, and the request's context menu),
// and a plain editor for a `.headers` file opened from Sources ▸ Overrides.

/// A sheet on DevTools' window, closed by the view it shows.
@MainActor
enum DeveloperOverrideSheet {
    static func present<Content: View>(_ content: (_ close: @escaping () -> Void) -> Content) {
        guard let parent = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                             styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        sheet.isReleasedWhenClosed = false
        let close = { [weak parent, weak sheet] in
            guard let sheet else { return }
            if let parent { parent.endSheet(sheet) } else { sheet.close() }
        }
        sheet.contentViewController = NSHostingController(rootView: content(close))
        sheet.setContentSize(NSSize(width: 560, height: 420))
        sheet.contentMinSize = NSSize(width: 420, height: 260)
        parent.beginSheet(sheet)
    }
}

@MainActor
extension DeveloperHeaderOverridesEditor {
    /// The request's context menu: its headers as received, then the editor.
    static func open(for request: DeveloperToolsSession.Request, session: DeveloperToolsSession) {
        Task { @MainActor [weak session] in
            guard let session else { return }
            let details = await session.requestDetails(request.id)
            let response = (details?.responseHeaders ?? []).map { DeveloperHeaderOverrides.Header(name: $0.name, value: $0.value) }
            DeveloperLocalOverrides.shared.overrideHeaders(url: details?.url ?? request.url, response: response, session: session)
        }
    }

    /// Chrome's "Override content" from Network: the response saved to the
    /// overrides folder (chosen first when there is none), then shown in Sources.
    static func overrideContent(of request: DeveloperToolsSession.Request, session: DeveloperToolsSession) {
        Task { @MainActor [weak session] in
            guard let session else { return }
            guard let details = await session.requestDetails(request.id), let body = details.body else {
                session.message = "The response isn’t available to override."
                return
            }
            guard !details.base64Encoded else {
                session.message = "Only text responses can be overridden here."
                return
            }
            let url = details.url.isEmpty ? request.url : details.url
            let overrides = DeveloperLocalOverrides.shared
            let reveal = { [weak session] in
                guard let session, overrides.isOverridden(url) else { return }
                if session.resources.contains(where: { $0.url == url }) { session.revealSource(url: url, line: 1) }
            }
            if overrides.folder == nil {
                overrides.chooseFolder {
                    do { try overrides.save(url: url, content: body); reveal() } catch { session.message = error.localizedDescription }
                }
            } else {
                do { try overrides.save(url: url, content: body); reveal() } catch { session.message = error.localizedDescription }
            }
        }
    }

    static func present(url: String, response: [DeveloperHeaderOverrides.Header],
                        overrides: DeveloperLocalOverrides, session: DeveloperToolsSession?) {
        let rows = rows(response: response, own: overrides.ruleHeaders(for: url),
                        effective: overrides.headerOverrides(for: url))
        DeveloperOverrideSheet.present { close in
            DeveloperHeaderOverridesEditor(url: url, overrides: overrides, session: session, close: close, initial: rows)
        }
    }

    /// The editor's rows: the response's headers, each overridden one with
    /// its override's value, then the overrides it lacks.
    static func rows(response: [DeveloperHeaderOverrides.Header], own: [DeveloperHeaderOverrides.Header],
                     effective: [DeveloperHeaderOverrides.Header]) -> [Row] {
        func same(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }
        func cookie(_ name: String) -> Bool { same(name, "set-cookie") }
        var rows: [Row] = []
        var placed = Set<String>()
        for header in response {
            let key = header.name.lowercased()
            if cookie(header.name) {
                let isOwn = own.contains { cookie($0.name) && $0.value == header.value }
                let inherited = !isOwn && effective.contains { cookie($0.name) && $0.value == header.value }
                rows.append(Row(name: header.name, value: header.value, kind: isOwn ? .own : inherited ? .inherited : .response))
                continue
            }
            if placed.contains(key) { continue }
            let mine = own.filter { same($0.name, header.name) }
            let theirs = effective.filter { same($0.name, header.name) }
            if !mine.isEmpty {
                placed.insert(key)
                rows += mine.map { Row(name: header.name, value: $0.value, kind: .own) }
            } else if !theirs.isEmpty {
                placed.insert(key)
                rows += theirs.map { Row(name: header.name, value: $0.value, kind: .inherited) }
            } else {
                rows.append(Row(name: header.name, value: header.value, kind: .response))
            }
        }
        for header in own {
            if cookie(header.name) {
                if !rows.contains(where: { cookie($0.name) && $0.value == header.value }) {
                    rows.append(Row(name: header.name, value: header.value, kind: .own))
                }
            } else if !placed.contains(header.name.lowercased()) {
                rows.append(Row(name: header.name, value: header.value, kind: .own))
            }
        }
        let ownNames = Set(own.map { $0.name.lowercased() })
        for header in effective where !ownNames.contains(header.name.lowercased()) {
            if cookie(header.name) {
                if !rows.contains(where: { cookie($0.name) && $0.value == header.value }) {
                    rows.append(Row(name: header.name, value: header.value, kind: .inherited))
                }
            } else if !placed.contains(header.name.lowercased()) {
                placed.insert(header.name.lowercased())
                rows.append(Row(name: header.name, value: header.value, kind: .inherited))
            }
        }
        return rows
    }
}

/// Chrome's header override editor: the response headers, editable; an
/// edited or added header is an override, drawn purple, and Save writes
/// the address's rule to its folder's `.headers` file.
struct DeveloperHeaderOverridesEditor: View {
    struct Row: Identifiable, Equatable {
        enum Kind { case response, own, inherited }
        let id = UUID()
        var name: String
        var value: String
        /// `own`: this address's rule sets it; `inherited`: a wildcard rule does.
        var kind: Kind
        var added = false
    }

    let url: String
    let overrides: DeveloperLocalOverrides
    weak var session: DeveloperToolsSession?
    let close: () -> Void
    @State private var rows: [Row]
    @State private var error: String?

    init(url: String, overrides: DeveloperLocalOverrides, session: DeveloperToolsSession?,
         close: @escaping () -> Void, initial: [Row]) {
        self.url = url
        self.overrides = overrides
        self.session = session
        self.close = close
        _rows = State(initialValue: initial)
    }

    private static let purple = Color.purple

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Override headers").font(.system(size: 13, weight: .semibold))
                Text(url).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .padding(12)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach($rows) { $row in line($row) }
                }
                .padding(.vertical, 4)
            }
            Divider()
            HStack(spacing: 8) {
                Button {
                    rows.append(Row(name: "", value: "", kind: .own, added: true))
                } label: {
                    Label("Add header", systemImage: "plus")
                }
                .accessibilityIdentifier("developer-header-overrides-add")
                if let path = DeveloperLocalOverrides.headersPath(for: url)?.path {
                    Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        .help("Saved in the overrides folder. Reload the page to see the change.")
                }
                Spacer(minLength: 0)
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("developer-header-overrides-save")
            }
            .padding(12)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 12).padding(.bottom, 8)
            }
        }
        .frame(minWidth: 420, idealWidth: 560, minHeight: 260, idealHeight: 420)
        .background(DeveloperToolsStyle.surface)
    }

    private func line(_ row: Binding<Row>) -> some View {
        let item = row.wrappedValue
        let overridden = item.kind != .response
        return HStack(spacing: 6) {
            Group {
                if item.added {
                    TextField("header-name", text: row.name)
                        .developerToolsField()
                } else {
                    Text(item.name + ":").fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(overridden ? Self.purple : Color.secondary)
                }
            }
            .frame(width: 180, alignment: .leading)
            TextField("header-value", text: Binding(get: { row.wrappedValue.value }, set: { value in
                guard value != row.wrappedValue.value else { return }
                row.wrappedValue.value = value
                // Editing a header makes it this address's override.
                row.wrappedValue.kind = .own
            }))
            .developerToolsField()
            .foregroundStyle(overridden ? Self.purple : Palette.ink)
            Button {
                rows.removeAll { $0.id == item.id }
            } label: {
                Image(systemName: "minus.circle").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(item.kind == .own ? 1 : 0)
            .disabled(item.kind != .own)
            .help("Remove this override")
            .accessibilityLabel("Remove override \(item.name)")
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .background(overridden ? Self.purple.opacity(0.08) : Color.clear)
        .help(item.kind == .inherited ? "Set by another rule in a .headers file" : "")
    }

    private func save() {
        let headers = rows.filter { $0.kind == .own }
            .map { DeveloperHeaderOverrides.Header(name: $0.name.trimmingCharacters(in: .whitespaces), value: $0.value) }
            .filter { !$0.name.isEmpty }
        if let bad = headers.first(where: { $0.name.contains(where: { $0 == ":" || $0.isWhitespace }) }) {
            error = "“\(bad.name)” isn’t a header name."
            return
        }
        do {
            try overrides.saveHeaders(url: url, headers: headers)
            session?.message = nil
            close()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// A `.headers` file opened from Sources ▸ Overrides, edited as JSON.
struct DeveloperHeadersFileEditor: View {
    let file: DeveloperLocalOverrides.File
    let overrides: DeveloperLocalOverrides
    let close: () -> Void
    @State private var text: String
    @State private var error: String?

    static func present(_ file: DeveloperLocalOverrides.File, overrides: DeveloperLocalOverrides) {
        DeveloperOverrideSheet.present { close in
            DeveloperHeadersFileEditor(file: file, overrides: overrides, close: close)
        }
    }

    init(file: DeveloperLocalOverrides.File, overrides: DeveloperLocalOverrides, close: @escaping () -> Void) {
        self.file = file
        self.overrides = overrides
        self.close = close
        let saved = overrides.text(of: file) ?? ""
        _text = State(initialValue: saved.isEmpty ? DeveloperHeaderOverrides.encode([
            .init(applyTo: "*", headers: [.init(name: "header-name", value: "header-value")]),
        ]) : saved)
        _error = State(initialValue: overrides.headerErrors[file.path])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(file.path).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.head)
                .padding(12)
            Divider()
            TextEditor(text: $text)
                .font(DeveloperToolsStyle.code)
                .autocorrectionDisabled()
                .padding(6)
                .accessibilityIdentifier("developer-headers-file-text")
            Divider()
            HStack(spacing: 8) {
                Text(error ?? "[{\"applyTo\": \"file or *\", \"headers\": [{\"name\": …, \"value\": …}]}]")
                    .font(.caption).foregroundStyle(error == nil ? Color.secondary : Color.red)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Save") {
                    do {
                        try overrides.saveHeadersFile(file, text: text)
                        close()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .keyboardShortcut("s", modifiers: .command)
            }
            .padding(12)
        }
        .frame(minWidth: 420, idealWidth: 560, minHeight: 260, idealHeight: 420)
        .background(DeveloperToolsStyle.surface)
    }
}
