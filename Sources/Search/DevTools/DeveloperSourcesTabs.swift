import AppKit
import SwiftUI
import WebKit

// The Sources panel's open files, as Chrome's editor keeps them: a tab per
// file over the code, ✕ or a middle-click or ⌥W to close one, and each
// file's place (scroll, caret, pretty-printing) kept while another is in
// front. The editor column (tabs, code, Search) is one view the panel
// hosts: DeveloperSourceEditor.

/// The open files of one DevTools session, kept for as long as it lasts,
/// so switching panels and back finds the same tabs.
@MainActor
final class DeveloperSourceTabs: ObservableObject {
    static func of(_ session: DeveloperToolsSession) -> DeveloperSourceTabs {
        DeveloperSessionModels.model(for: session, make: DeveloperSourceTabs.init)
    }

    private(set) weak var session: DeveloperToolsSession?
    @Published private(set) var tabs: [SourceResource] = []
    /// Files edited for Local Overrides and not saved yet, by address.
    @Published var unsaved = Set<String>()
    /// The Search pane (⌥⌘F, ⇧⌘F), and a count that asks its field for focus.
    @Published var searchShown = false
    @Published private(set) var searchFocus = 0
    /// Each file's document, by address: its scroll, caret and pretty-printing.
    private var documents: [String: SourceDocument] = [:]

    init(session: DeveloperToolsSession) {
        self.session = session
    }

    /// A file opened anywhere (the navigator, ⌘P, a link) gets a tab; the
    /// same address loaded again takes its old tab.
    func note(_ resource: SourceResource?) {
        guard let resource, !tabs.contains(resource) else { return }
        if let index = tabs.firstIndex(where: { $0.url == resource.url }) {
            tabs[index] = resource
        } else {
            tabs.append(resource)
        }
    }

    func select(_ resource: SourceResource) {
        guard let session, session.sourceResource != resource else { return }
        if resource.type == "Snippet" {
            let name = String(resource.url.dropFirst("snippet:///".count))
            guard let snippet = DeveloperSnippets.shared.snippet(named: name) else { close(resource); return }
            session.openSnippet(snippet.name, text: snippet.text)
            return
        }
        // After a reload the page lists the file under its new frame.
        let current = (session.resources + session.contentScripts).first { $0.url == resource.url } ?? resource
        session.openSource(current)
    }

    /// Closes a tab; closing the one in front shows its neighbour, as in Chrome.
    func close(_ resource: SourceResource) {
        guard let index = tabs.firstIndex(of: resource) else { return }
        tabs.remove(at: index)
        documents[resource.url] = nil
        unsaved.remove(resource.url)
        guard let session, session.sourceResource == resource else { return }
        if tabs.isEmpty { session.closeSource() } else { select(tabs[min(index, tabs.count - 1)]) }
    }

    /// ⌥W.
    func closeCurrent() {
        guard let current = session?.sourceResource, tabs.contains(current) else { return }
        close(current)
    }

    func closeOthers(_ resource: SourceResource) {
        for tab in tabs where tab != resource { close(tab) }
        select(resource)
    }

    func closeToRight(of resource: SourceResource) {
        guard let index = tabs.firstIndex(of: resource) else { return }
        for tab in tabs[(index + 1)...] { close(tab) }
    }

    func closeAll() {
        for tab in tabs { close(tab) }
    }

    /// The file's document: the one kept for it when its text is the same
    /// (or still loading), else a new one.
    func document(for resource: SourceResource, text: String?) -> SourceDocument? {
        if let cached = documents[resource.url],
           text == nil || cached.originalText == text || cached.editedText != nil {
            return cached
        }
        guard let text else { return nil }
        let document = SourceDocument(text: text, url: resource.url, type: resource.type)
        documents[resource.url] = document
        return document
    }

    /// The file's text changed on disk (Changes' Revert): its kept document
    /// goes, so the editor opens it again from the overrides folder.
    func reload(_ url: String) {
        documents[url] = nil
        unsaved.remove(url)
        objectWillChange.send()
    }

    func showSearch() {
        searchShown = true
        searchFocus += 1
    }

    /// ⌘Page Down and ⌘Page Up: the tab after or before the one in front,
    /// round the ends.
    func selectTab(by offset: Int) {
        guard let session, let next = Self.adjacent(tabs, from: session.sourceResource, by: offset) else { return }
        select(next)
    }

    /// The tab `offset` places from `current`, wrapping; the first (or last)
    /// when none is in front.
    static func adjacent<Item: Equatable>(_ items: [Item], from current: Item?, by offset: Int) -> Item? {
        guard !items.isEmpty else { return nil }
        guard let current, let index = items.firstIndex(of: current) else {
            return offset >= 0 ? items.first : items.last
        }
        let count = items.count
        return items[((index + offset) % count + count) % count]
    }

    /// ⌥⌘S, Chrome's Save all: every Local Overrides or workspace file
    /// edited and not saved yet.
    func saveAll() {
        let overrides = DeveloperLocalOverrides.shared
        let workspace = DeveloperWorkspace.shared
        let page = session?.address?.absoluteString
        for url in unsaved.sorted() {
            guard let document = documents[url] else { continue }
            do {
                let text = document.editedText ?? document.originalText
                let css = document.language == .css
                if !overrides.isOverridden(url), workspace.isMapped(url, page: page) {
                    try workspace.save(url: url, page: page, content: text, needsReload: !css)
                } else {
                    try overrides.save(url: url, content: text)
                }
                unsaved.remove(url)
                if css, let session { DeveloperWorkspace.applyStyleSheet(url: url, text: text, session: session) }
            } catch {
                session?.message = error.localizedDescription
            }
        }
    }
}

// MARK: Editor column

/// The open-file tabs over the code view. `placeholder` draws the panel's
/// empty state with the text given.
struct DeveloperSourceEditor<Placeholder: View>: View {
    @ObservedObject var session: DeveloperToolsSession
    @ObservedObject private var tabs: DeveloperSourceTabs
    @ObservedObject private var overrides = DeveloperLocalOverrides.shared
    @ObservedObject private var workspace = DeveloperWorkspace.shared
    private let placeholder: (String) -> Placeholder

    init(session: DeveloperToolsSession, @ViewBuilder placeholder: @escaping (String) -> Placeholder) {
        self.session = session
        tabs = DeveloperSourceTabs.of(session)
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if tabs.searchShown {
                // Chrome opens Search in the drawer, under the panel.
                VSplitView {
                    editor.frame(minHeight: 80)
                    DeveloperSourcesSearchView(session: session) { tabs.searchShown = false }
                        .frame(minHeight: 90, idealHeight: 220)
                }
            } else {
                editor
            }
        }
        .background(DeveloperSourcesKeyAnchor(tabs: tabs))
        .onAppear { tabs.note(session.sourceResource) }
        .onChange(of: session.sourceResource) { _, resource in tabs.note(resource) }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            if !tabs.tabs.isEmpty { strip }
            code
        }
    }

    @ViewBuilder private var code: some View {
        // A file served from Local Overrides shows as saved there; one
        // mapped to a workspace folder, as the file on disk has it.
        if let resource = session.sourceResource,
           let document = tabs.document(for: resource, text: overrides.activeContent(for: resource.url)
                                        ?? workspaceContent(resource) ?? session.source) {
            // A view per document: switching tabs brings back that file's place.
            DeveloperSourcePane(session: session, document: document)
                .id(ObjectIdentifier(document))
        } else {
            Group {
                if session.sourceResource == nil { Self.shortcuts } else { placeholder("Loading source") }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            // A folder dropped here joins the page's workspace, as in Chrome.
            .dropDestination(for: URL.self) { urls, _ in
                let page = session.address?.absoluteString
                guard let origin = page.flatMap(DeveloperWorkspace.origin(of:)) else {
                    session.message = "Only http and https pages can have a workspace."
                    return false
                }
                let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                folders.forEach { workspace.add($0, origin: origin) }
                return !folders.isEmpty
            }
        }
    }

    /// As Chrome's empty editor: the ways to open something.
    static var shortcuts: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            ForEach([("Open file", "⌘ P"), ("Run command", "⇧ ⌘ P")], id: \.0) { name, keys in
                GridRow {
                    Text(name).gridColumnAlignment(.trailing)
                    Text(keys).font(DeveloperToolsStyle.code)
                }
            }
            Text("Drop in a folder to add to workspace").padding(.top, 6).gridCellColumns(2)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    private func workspaceContent(_ resource: SourceResource) -> String? {
        guard resource.type != "Snippet", resource.type != "ContentScript" else { return nil }
        return workspace.content(for: resource.url, page: session.address?.absoluteString)
    }

    private var strip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: DeveloperToolsStyle.controlSpacing) {
                    ForEach(tabs.tabs) { resource in
                        DeveloperSourceTab(
                            resource: resource, selected: session.sourceResource == resource,
                            unsaved: tabs.unsaved.contains(resource.url),
                            select: { tabs.select(resource) }, close: { tabs.close(resource) },
                            closeOthers: { tabs.closeOthers(resource) }, closeToRight: { tabs.closeToRight(of: resource) },
                            closeAll: { tabs.closeAll() })
                            .id(resource.id)
                    }
                }
                .padding(.horizontal, DeveloperToolsStyle.gutter)
                .frame(height: DeveloperToolsStyle.toolbarHeight)
            }
            .scrollIndicators(.never)
            .onChange(of: session.sourceResource) { _, resource in
                if let resource { withAnimation(nil) { proxy.scrollTo(resource.id) } }
            }
        }
        .frame(height: DeveloperToolsStyle.toolbarHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DeveloperToolsStyle.chrome)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// One tab: the file's icon and name (with `*` while unsaved), and ✕.
private struct DeveloperSourceTab: View {
    let resource: SourceResource
    let selected: Bool
    let unsaved: Bool
    let select: () -> Void
    let close: () -> Void
    let closeOthers: () -> Void
    let closeToRight: () -> Void
    let closeAll: () -> Void
    @State private var hovering = false

    private var title: String {
        resource.type == "Snippet" ? String(resource.url.dropFirst("snippet:///".count)) : SourceTree.fileName(resource.url)
    }

    private var icon: String {
        switch resource.type {
        case "Script", "ContentScript": return "curlybraces"
        case "Stylesheet": return "paintbrush"
        case "Document": return "doc.richtext"
        case "Snippet": return "doc.text"
        case DeveloperSourceMaps.authoredType: return DeveloperSourceMaps.icon(for: resource.url)
        default: return "doc"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(.secondary)
            Text((unsaved ? "*" : "") + title).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 180, alignment: .leading)
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    .frame(width: 14, height: 14).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .opacity(selected || hovering ? 1 : 0.001)
            .help("Close")
            .accessibilityLabel("Close \(title)")
        }
        .developerTab(selected: selected)
        .background(DeveloperMiddleClick(action: close))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .help(resource.url)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
        .contextMenu {
            Button("Close", action: close)
            Button("Close others", action: closeOthers)
            Button("Close tabs to the right", action: closeToRight)
            Button("Close all", action: closeAll)
        }
    }
}

/// A middle-click on the view it sits behind. SwiftUI has no gesture for
/// the middle button, so one event monitor checks each such view.
private struct DeveloperMiddleClick: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> Catcher {
        let view = Catcher()
        view.action = action
        return view
    }

    func updateNSView(_ view: Catcher, context: Context) { view.action = action }

    final class Catcher: NSView {
        var action: (() -> Void)?
        private static var catchers: [Weak] = []
        private static var monitor: Any?

        struct Weak { weak var view: Catcher? }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            Self.catchers.removeAll { $0.view == nil || $0.view === self }
            guard window != nil else { return }
            Self.catchers.append(Weak(view: self))
            guard Self.monitor == nil else { return }
            Self.monitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseUp) { event in
                guard event.buttonNumber == 2 else { return event }
                let hit = MainActor.assumeIsolated { () -> Bool in
                    for item in Self.catchers {
                        guard let view = item.view, view.window === event.window, !view.isHiddenOrHasHiddenAncestor,
                              view.bounds.contains(view.convert(event.locationInWindow, from: nil)) else { continue }
                        view.action?()
                        return true
                    }
                    return false
                }
                return hit ? nil : event
            }
        }
    }
}

// MARK: Panel keys

/// Marks where the Sources panel is in a window, so its keys work while the
/// keyboard is anywhere in DevTools there, not only in the code: ⌥W closes
/// the open file's tab, ⌥⌘F and ⇧⌘F open Search, as in Chrome.
struct DeveloperSourcesKeyAnchor: NSViewRepresentable {
    let tabs: DeveloperSourceTabs

    func makeNSView(context: Context) -> Anchor {
        let view = Anchor()
        view.tabs = tabs
        return view
    }

    func updateNSView(_ view: Anchor, context: Context) { view.tabs = tabs }

    final class Anchor: NSView {
        weak var tabs: DeveloperSourceTabs?
        private static var anchors: [Weak] = []

        struct Weak { weak var view: Anchor? }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            Self.anchors.removeAll { $0.view == nil || $0.view === self }
            if window != nil { Self.anchors.append(Weak(view: self)) }
        }

        /// The Sources panel's key, wherever the keyboard is in its window
        /// (but not in the page itself).
        @MainActor static func take(_ event: NSEvent) -> Bool {
            guard let window = event.window,
                  let anchor = anchors.lazy.compactMap(\.view).first(where: { $0.window === window && !$0.isHiddenOrHasHiddenAncestor }),
                  let tabs = anchor.tabs else { return false }
            let responder = window.firstResponder as? NSView
            var view = responder
            while let current = view {
                if current is WKWebView { return false }
                view = current.superview
            }
            // Only with the keyboard in DevTools: not the address field's.
            guard DeveloperToolsKeys.host(of: responder) != nil
                || DeveloperToolsWindow.shared.host(in: window) != nil else { return false }
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            switch (flags, key) {
            case ([.command, .option], "f"), ([.command, .shift], "f"):
                tabs.showSearch()
                return true
            case ([.option], "w"):
                // Not while typing elsewhere, where ⌥W is a character.
                if let text = responder as? NSTextView, text.isEditable { return false }
                tabs.closeCurrent()
                return true
            default:
                return false
            }
        }
    }
}
