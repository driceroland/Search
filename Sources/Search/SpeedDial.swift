import Combine
import SwiftUI
import WebKit

/// Ordered references to bookmarks, not a second bookmark database. This is
/// loaded only when used; older builds can keep writing bookmarks normally.
@MainActor
final class SpeedDial: @preconcurrency ObservableObject {
    struct Entry: Codable, Identifiable, Equatable {
        var id: UUID
        var previewURL: String?
    }
    /// Where Speed Dial is in a tab: a local marker, so reaching it is an
    /// entry in WebKit's own back/forward history, with no server, script or
    /// remote page behind it.
    static let address = URL(string: "about:blank#search-dial")!
    /// WebKit gives the fragment of an opaque about: address back escaped, in
    /// WKWebView.url, though location.href keeps the '#'.
    static func at(_ url: URL) -> Bool {
        url == address || url.absoluteString == "about:blank%23search-dial"
    }
    /// Only the web goes on the dial: http or https, with a host.
    static func isWebsite(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return (scheme == "http" || scheme == "https") && url.host != nil
    }
    static func website(_ text: String) -> URL? {
        Address.url(from: text.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { isWebsite($0) ? $0 : nil }
    }
    static let limit = 24
    static let imageLimit = 128 * 1024
    let objectWillChange = ObservableObjectPublisher()
    private(set) var entries: [Entry] = [] { willSet { objectWillChange.send() } }
    var error: String? { willSet { objectWillChange.send() } }
    private let bookmarks: Bookmarks
    private let folder: URL
    private var listener: AnyCancellable?
    private var captures: [UUID: UUID] = [:]

    nonisolated static var folder: URL { Store.folder.appendingPathComponent("SpeedDial") }

    init(bookmarks: Bookmarks, folder: URL = SpeedDial.folder) {
        self.bookmarks = bookmarks
        self.folder = folder
        let file = folder.appendingPathComponent("sites.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                entries = Array(try JSONDecoder().decode([Entry].self, from: Data(contentsOf: file)).prefix(Self.limit))
            } catch { self.error = "Could not read Speed Dial: \(error.localizedDescription)" }
        }
        reconcile(bookmarks.roots)
        // A renamed or moved bookmark changes its tile even when no entry does.
        listener = bookmarks.$roots.dropFirst().sink { [weak self] in self?.objectWillChange.send(); self?.reconcile($0) }
    }

    static func sites(_ roots: [Bookmark]) -> [Bookmark] {
        roots.flatMap { $0.isFolder ? sites($0.children ?? []) : [$0] }
    }
    /// The dial's bookmarks, in its order. One edited since into something
    /// other than a website (an extension may rewrite a bookmark) is left
    /// off rather than opened.
    var sites: [Bookmark] {
        let all = Self.sites(bookmarks.roots)
        return entries.compactMap { entry in
            all.first { $0.id == entry.id && $0.url.flatMap(URL.init(string:)).map(Self.isWebsite) == true }
        }
    }
    private func imageURL(_ id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString).jpg") }
    func image(_ site: Bookmark) -> NSImage? {
        // Its size is asked before it is read: a file put there by hand can't
        // be larger than any this ever writes.
        let file = imageURL(site.id)
        guard entries.first(where: { $0.id == site.id })?.previewURL == site.url,
              let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= Self.imageLimit,
              let data = try? Data(contentsOf: file)
        else { return nil }
        return NSImage(data: data)
    }
    @discardableResult
    private func save(_ next: [Entry]) -> Bool {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: folder.appendingPathComponent("sites.json"), options: .atomic)
            entries = next
            return true
        } catch {
            self.error = "Could not save Speed Dial: \(error.localizedDescription)"
            return false
        }
    }
    private func reconcile(_ roots: [Bookmark]) {
        let sites = Self.sites(roots)
        var seen = Set<UUID>()
        let next = entries.compactMap { entry -> Entry? in
            guard let site = sites.first(where: { $0.id == entry.id }),
                  seen.insert(entry.id).inserted else { return nil }
            return Entry(id: entry.id, previewURL: entry.previewURL == site.url ? entry.previewURL : nil)
        }
        if next != entries, !save(next) { return }
        let kept = Set(next.filter { $0.previewURL != nil }.map { "\($0.id.uuidString).jpg" })
        for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            where file.pathExtension == "jpg" && !kept.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }
    static let full = "Speed Dial holds up to 24 sites."
    func add(_ site: Bookmark) {
        guard !entries.contains(where: { $0.id == site.id }) else { return }
        guard entries.count < Self.limit else { error = Self.full; return }
        guard let text = site.url, SpeedDial.website(text) != nil else { return }
        save(entries + [Entry(id: site.id)])
    }
    func remove(_ id: UUID) {
        guard save(entries.filter { $0.id != id }) else { return }
        captures[id] = nil
        try? FileManager.default.removeItem(at: imageURL(id))
    }
    /// One place earlier or later, or with a step past either end, to the
    /// start or the end.
    func move(_ id: UUID, by step: Int) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let to = min(entries.count - 1, max(0, index + step))
        guard to != index else { return }
        var next = entries
        next.insert(next.remove(at: index), at: to)
        save(next)
    }
    static func canCapture(_ tab: Tab) -> Bool {
        !tab.shy && !tab.bench && !tab.asleep && !tab.loading && tab.built != nil
            && tab.address.map(SpeedDial.isWebsite) == true
    }
    /// A typed address becomes a bookmark in a "Speed Dial" folder, so the
    /// dial still only points at bookmarks and the main list stays tidy. Its
    /// preview comes the first time the page is visited, not now.
    func add(address text: String, title: String) {
        error = nil
        guard let url = SpeedDial.website(text) else { error = "Enter a website such as https://example.com"; return }
        if let site = Self.sites(bookmarks.roots).first(where: { Self.matches($0, url) }) { add(site); return }
        guard entries.count < Self.limit else { error = Self.full; return }
        add(file(url, title: title))
    }
    /// Into a "Speed Dial" folder, made the first time, so the dial's own
    /// additions don't crowd the top of the bookmarks.
    private func file(_ url: URL, title: String) -> Bookmark {
        let folder = bookmarks.roots.first { $0.isFolder && $0.title == "Speed Dial" }
            ?? bookmarks.insert(.folder("Speed Dial", []), into: nil)
        return bookmarks.insert(.site(title, url), into: folder.id)
    }
    func addCurrent(_ tab: Tab?) {
        error = nil
        guard let tab, Self.canCapture(tab), let url = tab.address else { return }
        guard entries.count < Self.limit || sites.contains(where: { $0.url == url.absoluteString }) else {
            error = Self.full; return
        }
        // A bookmark that is already there, however its address is spelled,
        // is the one used; a new one is filed with the typed ones.
        let site = Self.sites(bookmarks.roots).first { Self.matches($0, url) } ?? file(url, title: tab.title)
        add(site)
        capture(site, from: tab)
    }
    static func matches(_ site: Bookmark, _ url: URL?) -> Bool {
        guard let url, let target = site.url.flatMap(URL.init(string:)) else { return false }
        // WebKit adds '/' to bare origins; bookmarks need not spell it out.
        return (target.path.isEmpty ? target.appendingPathComponent("") : target)
            == (url.path.isEmpty ? url.appendingPathComponent("") : url)
    }
    func capture(_ site: Bookmark, from tab: Tab) {
        guard Self.canCapture(tab), Self.matches(site, tab.address),
              entries.contains(where: { $0.id == site.id }), let web = tab.built else { return }
        // A bounded viewport crop; never capture a whole scrolling document.
        // A view with no size yet has nothing to give; the next visit tries.
        let width = web.bounds.width
        guard width > 0, web.bounds.height > 0 else { return }
        let token = UUID()
        captures[site.id] = token
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(x: 0, y: 0, width: width, height: min(web.bounds.height, width * 0.625))
        // Measured in points: ask for 480 pixels whatever the screen's scale,
        // so WebKit does the scaling and the image arrives at its final size.
        config.snapshotWidth = NSNumber(value: 480 / Double(web.window?.backingScaleFactor ?? 2))
        web.takeSnapshot(with: config) { [weak self, weak tab] image, _ in
            guard let self, let tab, Self.canCapture(tab), Self.matches(site, tab.address),
                  self.captures[site.id] == token,
                  self.sites.contains(where: { $0.id == site.id && $0.url == site.url }) else { return }
            self.captures[site.id] = nil
            guard let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let data = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.45]),
                  data.count <= Self.imageLimit else {
                self.error = "No preview was available. Open the page and try Refresh Preview."; return
            }
            do {
                try data.write(to: self.imageURL(site.id), options: .atomic)
                var next = self.entries
                guard let index = next.firstIndex(where: { $0.id == site.id }) else { return }
                next[index].previewURL = site.url
                self.save(next)
            } catch { self.error = "Could not save the preview: \(error.localizedDescription)" }
        }
    }
    /// Reuse a page the person loaded; never open a website for its thumbnail.
    func captureMissing(from tab: Tab) {
        guard let site = sites.first(where: { Self.matches($0, tab.address) }),
              captures[site.id] == nil, image(site) == nil else { return }
        capture(site, from: tab)
    }
    func reset() {
        guard save([]) else { return }
        captures.removeAll()
        error = nil
        reconcile(bookmarks.roots)
    }
    /// The tiles stay; their pictures go, to be taken again on the next visit.
    func forgetPreviews() {
        guard entries.contains(where: { $0.previewURL != nil }),
              save(entries.map { Entry(id: $0.id) }) else { return }
        captures.removeAll()
        reconcile(bookmarks.roots)
    }
}

struct SpeedDialPage: View {
    @ObservedObject var browser: Browser
    /// Not observed here: each grid follows the dial itself, so every open
    /// Speed Dial tab changes the moment one of them does.
    let dial: SpeedDial

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Grid(browser: browser, dial: dial, shy: browser.active?.shy == true)
                    .padding(.top, geometry.size.height / 4 + 64)
                // The field's own 60 of lift, over half the page: it stands
                // at the upper quarter with no position of its own to keep.
                Omnibox(browser: browser, over: false)
                    .frame(height: geometry.size.height / 2 + 60)
            }
        }
        .background(Palette.ground)
    }

    private struct Grid: NSViewRepresentable {
        let browser: Browser
        let dial: SpeedDial
        /// The same grid is kept across a switch of tabs; a private one
        /// hides Recently Closed, so going to or from one redraws it.
        let shy: Bool
        func makeNSView(context: Context) -> Content { Content(browser: browser, dial: dial) }
        func updateNSView(_ view: Content, context: Context) { if view.shy != shy { view.refresh() } }
    }

    final class Content: NSScrollView {
        private let browser: Browser
        private let dial: SpeedDial
        private let canvas = Canvas()
        private var rows: [NSView] = []
        private var tiles: [SpeedDialTile] = []
        private var available: [Bookmark] = []
        private var recent: [URL] = []
        private var addTiles: [AddTile] = []
        private var watch: [AnyCancellable] = []
        private var pending = false

        init(browser: Browser, dial: SpeedDial) {
            self.browser = browser
            self.dial = dial
            super.init(frame: .zero)
            drawsBackground = true
            backgroundColor = Palette.NS.ground
            hasVerticalScroller = true
            documentView = canvas
            refresh()
            // Changes arrive before they're made (objectWillChange), and a
            // reset makes several at once: redraw once, on the next turn.
            watch = [dial.objectWillChange.sink { [weak self] in self?.later() },
                     browser.$ghosts.dropFirst().sink { [weak self] _ in self?.later() }]
        }
        required init?(coder: NSCoder) { nil }
        private func later() {
            guard !pending else { return }
            pending = true
            DispatchQueue.main.async { [weak self] in self?.pending = false; self?.refresh() }
        }
        final class Canvas: NSView { override var isFlipped: Bool { true } }

        /// Whether the grid was last drawn for a private tab.
        private(set) var shy = false
        func refresh() {
            rows.forEach { $0.removeFromSuperview() }
            rows.removeAll()
            let sites = dial.sites
            // Reuse buttons by bookmark ID to preserve keyboard focus.
            var old = tiles
            tiles = sites.map { site in
                let key = site.id.uuidString
                let tile: SpeedDialTile
                if let index = old.firstIndex(where: { $0.identifier?.rawValue == key }) {
                    tile = old.remove(at: index)
                } else { tile = SpeedDialTile(browser: browser, dial: dial, site: site) }
                tile.identifier = NSUserInterfaceItemIdentifier(key)
                tile.update(site)
                canvas.addSubview(tile)
                return tile
            }
            old.forEach { $0.removeFromSuperview() }
            available = SpeedDial.sites(browser.bookmarks.roots).filter { site in
                !dial.entries.contains(where: { $0.id == site.id }) && site.url.flatMap(URL.init(string:)).map(SpeedDial.isWebsite) == true
            }
            let count = tiles.isEmpty ? 4 : (tiles.count < SpeedDial.limit ? 1 : 0)
            while addTiles.count > count { addTiles.removeLast().removeFromSuperview() }
            while addTiles.count < count {
                let tile = AddTile(frame: .zero, pullsDown: true)
                tile.target = self
                tile.action = #selector(addSite(_:))
                tile.toolTip = "Add a site"
                tile.setAccessibilityLabel("Add a site")
                addTiles.append(tile)
                canvas.addSubview(tile)
            }
            for tile in addTiles {
                // The first item is a pull-down's title and never chosen. A
                // bookmark row carries its bookmark; the two others, a tag.
                tile.removeAllItems()
                tile.addItems(withTitles: ["Add a site", "Add Address…"])
                tile.lastItem?.tag = -1
                tile.menu?.addItem(.separator())
                for site in available {
                    tile.addItem(withTitle: site.title)
                    tile.lastItem?.representedObject = site.id
                }
                if available.isEmpty {
                    tile.addItem(withTitle: "Open Bookmarks…")
                    tile.lastItem?.tag = -2
                }
            }
            shy = browser.active?.shy == true
            let ghosts = shy ? [] : Array(browser.ghosts.reversed().prefix(6))
            recent = ghosts.map(\.url)
            if !ghosts.isEmpty { label("Recently Closed", bold: true) }
            for (index, ghost) in ghosts.enumerated() {
                button(ghost.label + " — " + (ghost.url.host ?? ""), tag: index)
            }
            if let error = dial.error {
                label(error)
                button("Dismiss", tag: -1)
            }
            needsLayout = true
        }
        private func label(_ text: String, bold: Bool = false) {
            let view = NSTextField(wrappingLabelWithString: text)
            view.font = .systemFont(ofSize: 13, weight: bold ? .semibold : .regular)
            view.textColor = bold ? .labelColor : .secondaryLabelColor
            rows.append(view)
            canvas.addSubview(view)
        }
        private func button(_ text: String, tag: Int) {
            let view = NSButton(title: text, target: self, action: #selector(row(_:)))
            view.tag = tag
            view.isBordered = false
            view.alignment = .left
            view.lineBreakMode = .byTruncatingTail
            rows.append(view)
            canvas.addSubview(view)
        }
        override func layout() {
            super.layout()
            let width = contentSize.width
            let inner = max(180, min(896, width - 64))
            let x = max(16, (width - inner) / 2)
            let columns = max(1, Int((inner + 18) / 198))
            let tileWidth = min(260, (inner - CGFloat(columns - 1) * 18) / CGFloat(columns))
            let rowHeight: CGFloat = tiles.isEmpty ? tileWidth + 22 : 182
            let cells: [NSView] = tiles + addTiles
            for (index, tile) in cells.enumerated() {
                let height: CGFloat = tile is AddTile ? (tiles.isEmpty ? tileWidth : 116) : 160
                tile.frame = NSRect(x: x + CGFloat(index % columns) * (tileWidth + 18), y: CGFloat(index / columns) * rowHeight, width: tileWidth, height: height)
            }
            var y = CGFloat((cells.count + columns - 1) / columns) * rowHeight
            for row in rows {
                let height: CGFloat
                if let label = row as? NSTextField {
                    height = max(20, label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: inner, height: 10000)).height ?? 20)
                } else { height = 28 }
                row.frame = NSRect(x: x, y: y, width: inner, height: height)
                y += height + 12
            }
            canvas.frame = NSRect(x: 0, y: 0, width: width, height: max(contentSize.height, y + 32))
        }
        @objc private func addSite(_ sender: NSPopUpButton) {
            guard let item = sender.selectedItem else { return }
            if let id = item.representedObject as? UUID, let site = available.first(where: { $0.id == id }) { dial.add(site) }
            else if item.tag == -1 { askAddress() }
            else if item.tag == -2 { browser.bookmarking = true }
        }
        /// The address and, if wanted, a name: two fields in one sheet.
        private func askAddress() {
            guard let window else { return }
            let alert = NSAlert()
            alert.messageText = "Add to Speed Dial"
            alert.addButton(withTitle: "Add")
            alert.addButton(withTitle: "Cancel")
            let address = NSTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 24))
            address.placeholderString = "example.com"
            let name = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            name.placeholderString = "Name (optional)"
            let fields = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54))
            fields.addSubview(address)
            fields.addSubview(name)
            alert.accessoryView = fields
            alert.window.initialFirstResponder = address
            alert.beginSheetModal(for: window) { [dial] answer in
                guard answer == .alertFirstButtonReturn else { return }
                let url = SpeedDial.website(address.stringValue)
                let title = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                dial.add(address: address.stringValue, title: title.isEmpty ? url.map(Address.pretty) ?? "" : title)
            }
        }
        /// A normal popup button keeps native menus and keyboard access;
        /// only its idle appearance is the quiet empty tile.
        final class AddTile: NSPopUpButton {
            override func draw(_ dirtyRect: NSRect) {
                let rect = bounds.insetBy(dx: 1, dy: 1)
                let shape = NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14)
                (isHighlighted ? Palette.NS.hover : Palette.NS.ground).setFill()
                shape.fill()
                Palette.NS.hairline.setStroke()
                shape.lineWidth = 1
                shape.stroke()
                let plus = NSBezierPath()
                plus.move(to: NSPoint(x: rect.midX - 6, y: rect.midY))
                plus.line(to: NSPoint(x: rect.midX + 6, y: rect.midY))
                plus.move(to: NSPoint(x: rect.midX, y: rect.midY - 6))
                plus.line(to: NSPoint(x: rect.midX, y: rect.midY + 6))
                Palette.NS.muted.setStroke()
                plus.lineWidth = 1.5
                plus.lineCapStyle = .round
                plus.stroke()
            }
            override var focusRingMaskBounds: NSRect { bounds }
            override func drawFocusRingMask() {
                NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()
            }
        }
        /// A recently closed page by its place in the list; -1 dismisses the error.
        @objc private func row(_ sender: NSButton) {
            if recent.indices.contains(sender.tag) { browser.visit(recent[sender.tag]) } else { dial.error = nil }
        }
    }
}
