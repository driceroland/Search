import AppKit
import SwiftUI

// Site tiles on a new tab, as Chrome and Google have them: under the field,
// each site's icon and its name, with a + to add one, and editing, removing
// and reordering right there. Off unless Settings › Tabs › New tabs turns it
// on (idea 1285).
//
// The tiles are the sites of the bookmark folder called Home, the same one
// the plain Home grid shows (HomeGrid.swift). So they belong to the window's
// profile as its bookmarks do, travel with iCloud sync as bookmarks
// (Personal only, SYNC.md, nothing new in the contract), and are read from a
// file that is quarantined, not trusted, when it doesn't decode.
//
// What a tile may be (TileAddress): a web address, http or https, and
// nothing else, read as the address field reads what is typed. A name is
// plain text everywhere: SwiftUI draws it verbatim, and it is cleaned of
// control and direction-changing characters and cut to `TileName.most`.
//
// Icons: from the cache browsing fills, never fetched because a new tab
// opened, so no site can count new tabs. A tile added from an address
// typed in asks the site for its favicon.ico once, then; one added from
// the page you're on has its icon already. Visiting the site keeps it
// fresh. A private tab fetches nothing and changes nothing: it shows the
// tiles, from the cache or as letters, and opens them, and that's all.

/// What may be a tile's address, and how one typed in is read.
enum TileAddress {
    /// Longer than this and it isn't a site to go back to but a payload.
    static let most = 2048

    enum Problem: Error, Equatable {
        case empty, tooLong, scheme, notAddress, credentials, full, already

        var said: String {
            switch self {
            case .empty: "Type the site\u{2019}s address."
            case .tooLong: "That address is too long for a tile."
            case .scheme: "Only a website\u{2019}s address, http or https, can be a tile."
            case .notAddress: "That isn\u{2019}t a website\u{2019}s address."
            case .credentials: "An address with a name or password in it can\u{2019}t be a tile."
            case .full: "There\u{2019}s room for \(HomeTiles.most) tiles."
            case .already: "That site is a tile already."
            }
        }
    }

    /// Typed text as an address, the address field's way (Address.url):
    /// a bare host gets https, a local one http. Refused: every other
    /// scheme (javascript:, data:, file:, blob:, about:, an extension's,
    /// Search's own pages), a name and password before the host, which can
    /// pass for another site (https://bank.com@else.example), and anything
    /// over `most`. A host in another alphabet comes back as its punycode,
    /// which is what's kept; `shown` decides how it reads.
    static func read(_ typed: String) -> Result<URL, Problem> {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.empty) }
        guard text.utf8.count <= most else { return .failure(.tooLong) }
        guard let url = Address.url(from: text) else {
            return .failure(namesOtherScheme(text) ? .scheme : .notAddress)
        }
        return check(url)
    }

    /// One already made (the page you're on, a bookmark synced in) checked
    /// the same way.
    static func check(_ url: URL) -> Result<URL, Problem> {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return .failure(.scheme) }
        guard url.user == nil, url.password == nil else { return .failure(.credentials) }
        guard let host = url.host(percentEncoded: false), !host.isEmpty else { return .failure(.notAddress) }
        guard url.absoluteString.utf8.count <= most else { return .failure(.tooLong) }
        return .success(url)
    }

    static func allowed(_ url: URL) -> Bool {
        if case .success = check(url) { return true }
        return false
    }

    /// Written with a scheme of its own, "javascript:…", "data:…": refused
    /// for the scheme, which says more than "not an address". A host and
    /// port, "localhost:3000", is not a scheme.
    private static func namesOtherScheme(_ text: String) -> Bool {
        guard let colon = text.firstIndex(of: ":") else { return false }
        let scheme = text[..<colon].lowercased()
        guard let first = scheme.first, first.isASCII, first.isLetter,
              scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }),
              !["http", "https"].contains(scheme)
        else { return false }
        let rest = text[text.index(after: colon)...]
        let port = rest.prefix { $0.isNumber }
        return !(port.count > 0 && (rest.count == port.count || "/?#".contains(rest[rest.index(rest.startIndex, offsetBy: port.count)])))
    }

    /// The site as a tile says it under its name, or as its name when it
    /// has none: the host without www., in its own alphabet only when that
    /// can't pass for another site (Hosts.display), its punycode otherwise,
    /// as the tab's address at rest says it.
    static func shown(_ url: URL) -> String {
        guard let host = url.host(percentEncoded: false), !host.isEmpty else { return "" }
        let ascii = Hosts.ascii(host)
        let bare = ascii.hasPrefix("www.") && ascii.split(separator: ".").count > 2 ? String(ascii.dropFirst(4)) : ascii
        let standard = url.scheme?.lowercased() == "https" ? 443 : 80
        let port = url.port.map { $0 == standard ? "" : ":\($0)" } ?? ""
        return Hosts.display(bare) + port
    }

    /// As the editor's field shows it to be changed: the address field's way.
    static func editable(_ url: URL) -> String { Address.editable(url) }
}

/// A tile's name: plain text, one line, short.
enum TileName {
    static let most = 60

    /// Trimmed, every run of spaces, line breaks and control characters one
    /// space, the characters that turn text around (U+202A–U+202E,
    /// U+2066–U+2069, U+200E/F) taken out so a name can't read backwards,
    /// and cut to `most` characters.
    static func clean(_ text: String) -> String {
        let turning: Set<UInt32> = [0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069]
        var out = String.UnicodeScalarView()
        var space = false
        for scalar in text.unicodeScalars {
            if turning.contains(scalar.value) { continue }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) || CharacterSet.controlCharacters.contains(scalar) {
                space = true
                continue
            }
            if space, !out.isEmpty { out.append(" ") }
            space = false
            out.append(scalar)
        }
        return String(String(out).prefix(most))
    }
}

// MARK: - kept in the Home folder

extension Bookmarks {
    /// The top-level folder called Home, any case, as the grid finds it.
    var homeFolder: Bookmark? {
        roots.first { $0.isFolder && $0.title.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("Home") == .orderedSame }
    }

    /// The tiles: the Home folder's sites with a web address, in its order,
    /// `HomeTiles.most` at most. A bookmarklet or a file kept there is left
    /// out, not opened from a new tab.
    var tiles: [Bookmark] {
        Array((homeFolder?.children ?? []).filter { !$0.isFolder && ($0.address.map(TileAddress.allowed) ?? false) }.prefix(HomeTiles.most))
    }

    /// A site at the end of the tiles, its folder made if there is none.
    @discardableResult
    func addTile(name: String, url: URL) -> Result<Bookmark, TileAddress.Problem> {
        if case let .failure(problem) = TileAddress.check(url) { return .failure(problem) }
        let now = tiles
        guard now.count < HomeTiles.most else { return .failure(.full) }
        guard !now.contains(where: { $0.url == url.absoluteString }) else { return .failure(.already) }
        let folder = homeFolder?.id ?? insert(.folder("Home", []), into: nil).id
        let named = TileName.clean(name)
        let made = Bookmark(title: named.isEmpty ? TileAddress.shown(url) : named, url: url.absoluteString, children: nil)
        // After the last tile, so it lands where the + was even with
        // other things kept in the folder after the tiles.
        let after = (homeFolder?.children ?? []).lastIndex { $0.id == now.last?.id }.map { $0 + 1 }
        insert(made, into: folder, at: after)
        return .success(made)
    }

    /// A tile's new name and address.
    @discardableResult
    func editTile(_ id: Bookmark.ID, name: String, url: URL) -> TileAddress.Problem? {
        if case let .failure(problem) = TileAddress.check(url) { return problem }
        guard tiles.contains(where: { $0.id == id }) else { return .notAddress }
        if tiles.contains(where: { $0.id != id && $0.url == url.absoluteString }) { return .already }
        let named = TileName.clean(name)
        update(id, title: named.isEmpty ? TileAddress.shown(url) : named, url: url.absoluteString)
        return nil
    }

    func removeTile(_ id: Bookmark.ID) {
        guard tiles.contains(where: { $0.id == id }) else { return }
        remove(id)
    }

    /// A tile to another tile's place, counted among the tiles; whatever
    /// else the folder holds stays where it is.
    func moveTile(_ id: Bookmark.ID, to place: Int) {
        let now = tiles
        guard let folder = homeFolder, let from = now.firstIndex(where: { $0.id == id }) else { return }
        let to = min(max(place, 0), now.count - 1)
        guard to != from, let kids = folder.children,
              let target = kids.firstIndex(where: { $0.id == now[to].id }) else { return }
        // `move` counts the place as the folder reads before the move.
        move(id, into: folder.id, at: to > from ? target + 1 : target)
    }
}

// MARK: - from the window

extension Browser {
    /// Whether tiles can be changed from where you are: the setting on and
    /// the tab in front not private.
    var tilesEditable: Bool {
        prefs.homeTiles && !(active?.shy ?? false)
    }

    /// The page in `tab` as a tile, by its title. Nil when it went in, the
    /// reason when it didn't.
    @discardableResult
    func addTile(from tab: Tab) -> TileAddress.Problem? {
        guard prefs.homeTiles, !tab.shy, let url = tab.address else { return .notAddress }
        switch bookmarks.addTile(name: Browser.ownTitle(of: tab), url: url) {
        case .success:
            announce("Added to new tabs")
            return nil
        case let .failure(problem):
            announce(problem.said)
            return problem
        }
    }

    /// One typed in the tiles' editor. Its icon is asked for this once,
    /// unless browsing has it already.
    func addTile(name: String, typed: String) -> TileAddress.Problem? {
        guard tilesEditable else { return .notAddress }
        switch TileAddress.read(typed) {
        case let .failure(problem): return problem
        case let .success(url):
            switch bookmarks.addTile(name: name, url: url) {
            case let .failure(problem): return problem
            case .success:
                Favicons.shared.fetchOnce(for: url)
                return nil
            }
        }
    }

    func editTile(_ id: Bookmark.ID, name: String, typed: String) -> TileAddress.Problem? {
        guard tilesEditable else { return .notAddress }
        switch TileAddress.read(typed) {
        case let .failure(problem): return problem
        case let .success(url):
            let before = bookmarks.bookmark(id)?.url
            if let problem = bookmarks.editTile(id, name: name, url: url) { return problem }
            if before != url.absoluteString { Favicons.shared.fetchOnce(for: url) }
            return nil
        }
    }

    /// Whether the page in `tab` can be added from its menu, and isn't a
    /// tile already.
    func offersTile(_ tab: Tab) -> Bool {
        guard prefs.homeTiles, !tab.shy, let url = tab.address, TileAddress.allowed(url) else { return false }
        let now = bookmarks.tiles
        return now.count < HomeTiles.most && !now.contains { $0.url == url.absoluteString }
    }
}

// MARK: - drawn

struct HomeTiles: View {
    /// Two short lines of chips at most, usually.
    static let most = 12
    /// A chip: a small icon and the site's name, in a quiet capsule.
    static let chipHeight: CGFloat = 28
    static let gap: CGFloat = 6
    static let padding: CGFloat = 10
    static let iconSize: CGFloat = 14
    static let iconGap: CGFloat = 6
    /// A name longer than this ends in an ellipsis.
    static let labelWidth: CGFloat = 140
    static let fontSize: CGFloat = 12

    /// Asked through the field: Tab from an empty field on a new tab goes
    /// to the first tile (Omnibox).
    static let focusFirst = Notification.Name("SearchHomeTilesFocusFirst")

    let browser: Browser
    @ObservedObject private var typing: FieldState
    @ObservedObject private var prefs: Preferences
    /// Rendered for a picture in a test, with the editor open.
    var editorForTest: Editing?

    enum Editing: Equatable {
        case new
        case tile(Bookmark.ID)
    }

    enum Focus: Hashable {
        case tile(Bookmark.ID), add, name, address
    }

    @State private var editing: Editing?
    @State private var name = ""
    @State private var address = ""
    @State private var problem: String?
    @State private var hovered: Bookmark.ID?
    @State private var addHovered = false
    /// The order shown while a tile is dragged, put down on the drop.
    @State private var order: [Bookmark.ID]?
    @State private var dragged: Bookmark.ID?
    @FocusState private var focus: Focus?

    init(browser: Browser, editorForTest: Editing? = nil) {
        self.browser = browser
        typing = browser.typing
        prefs = browser.prefs
        self.editorForTest = editorForTest
    }

    /// What a tile reads as: its name, or its site when it has none.
    static func label(_ tile: Bookmark) -> String {
        tile.unnamed ? tile.address.map(TileAddress.shown) ?? "" : tile.title
    }

    /// A chip's width, as the row lays it out: the name measured in the
    /// chip's type and cut at `labelWidth`. The + chip for nil.
    @MainActor static func chipWidth(_ label: String?) -> CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize)
        guard let label else {
            let add = ("Add" as NSString).size(withAttributes: [.font: font]).width
            return ceil(padding * 2 + 10 + 4 + add)
        }
        return ceil(padding * 2 + iconSize + iconGap + labelFit(label))
    }

    /// The name's own width in the chip's type, `labelWidth` at most.
    @MainActor static func labelFit(_ label: String) -> CGFloat {
        let text = (label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize)]).width
        return min(ceil(text) + 1, labelWidth)
    }

    /// How many lines chips of `widths` take in `width`, each line filled
    /// before the next, as ChipFlow lays them.
    static func lines(_ widths: [CGFloat], in width: CGFloat) -> Int {
        guard !widths.isEmpty else { return 0 }
        var lines = 1, used: CGFloat = 0
        for chip in widths {
            let need = used == 0 ? chip : used + gap + chip
            if need > width, used > 0 {
                lines += 1
                used = chip
            } else {
                used = need
            }
        }
        return lines
    }

    /// Whether a new tab shows them now.
    @MainActor static func showing(_ browser: Browser) -> Bool {
        browser.prefs.homeTiles && browser.active?.isBlank == true && browser.typing.typed.isEmpty
    }

    /// What's drawn, the + included: none in a private tab, nor once there
    /// are twelve.
    @MainActor static func count(_ browser: Browser) -> Int {
        guard browser.prefs.homeTiles else { return 0 }
        let tiles = browser.bookmarks.tiles.count
        return tiles + (browser.tilesEditable && tiles < most ? 1 : 0)
    }

    /// The chips' widths in order, the + last when it's drawn.
    @MainActor static func widths(_ browser: Browser) -> [CGFloat] {
        let tiles = browser.bookmarks.tiles
        let add = browser.tilesEditable && tiles.count < most
        return tiles.map { chipWidth(label($0)) } + (add ? [chipWidth(nil)] : [])
    }

    /// How tall they stand in `width`, nought when not drawn.
    @MainActor static func height(_ browser: Browser, width: CGFloat = Metrics.fieldWidth) -> CGFloat {
        guard showing(browser), count(browser) > 0 else { return 0 }
        let lines = CGFloat(lines(widths(browser), in: width))
        return lines * chipHeight + (lines - 1) * gap
    }

    var body: some View {
        if prefs.homeTiles, browser.active?.isBlank == true, typing.typed.isEmpty {
            GeometryReader { page in
                let width = min(Metrics.fieldWidth, max(0, page.size.width - 28))
                let top = page.size.height / 2 - 30 + 25 + 14
                // Lines that don't fit under the field are cut off: a short
                // window keeps what fits, rather than chips under its edge.
                let room = max(0, page.size.height - top - 16)
                content(width: width)
                    .frame(width: width)
                    .frame(maxHeight: room, alignment: .top)
                    .clipped()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, top)
            }
            .onReceive(NotificationCenter.default.publisher(for: HomeTiles.focusFirst)) { note in
                guard (note.object as? Browser) === browser, editing == nil else { return }
                focus = browser.bookmarks.tiles.first.map { .tile($0.id) } ?? (browser.tilesEditable ? .add : nil)
            }
            .onAppear { if let editorForTest { begin(editorForTest) } }
        }
    }

    @ViewBuilder
    private func content(width: CGFloat) -> some View {
        if let editing, browser.tilesEditable {
            editor(editing)
                .frame(width: min(380, width))
                .frame(maxWidth: .infinity)
        } else {
            let editable = browser.tilesEditable
            let tiles = shownTiles
            ChipFlow(gap: HomeTiles.gap) {
                ForEach(Array(tiles.enumerated()), id: \.element.id) { at, tile in
                    chip(tile, at: at, editable: editable)
                }
                if editable, tiles.count < HomeTiles.most { addChip }
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Sites")
        }
    }

    /// The tiles in the order shown, the dragged one where it is held.
    private var shownTiles: [Bookmark] {
        let tiles = browser.bookmarks.tiles
        guard let order else { return tiles }
        let byID = Dictionary(uniqueKeysWithValues: tiles.map { ($0.id, $0) })
        let held = order.compactMap { byID[$0] }
        return held.count == tiles.count ? held : tiles
    }

    // MARK: a chip

    private func chip(_ tile: Bookmark, at index: Int, editable: Bool) -> some View {
        let url = tile.address
        let label = HomeTiles.label(tile)
        let site = url.map(TileAddress.shown) ?? ""
        let focused = focus == .tile(tile.id)
        let lit = hovered == tile.id || focused
        return HStack(spacing: HomeTiles.iconGap) {
            Group {
                if let icon = Favicons.shared.cached(for: url) {
                    Mark(icon: icon, letter: "", size: HomeTiles.iconSize)
                } else {
                    Text(verbatim: HomeTiles.letter(label))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(lit ? Palette.ink : Palette.muted)
                        .frame(width: HomeTiles.iconSize, height: HomeTiles.iconSize)
                        .background(RoundedRectangle(cornerRadius: 3.5, style: .continuous).fill(Palette.ink.opacity(0.05)))
                }
            }
            Text(verbatim: label)
                .font(.system(size: HomeTiles.fontSize))
                .foregroundStyle(lit ? Palette.ink : Palette.ink.opacity(0.78))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: HomeTiles.labelFit(label), alignment: .leading)
        }
        .padding(.horizontal, HomeTiles.padding)
        .frame(height: HomeTiles.chipHeight)
        // Focused by keys, as hovered: the fill a shade deeper.
        .background(Capsule(style: .continuous).fill(lit ? Palette.ink.opacity(0.07) : Palette.ink.opacity(0.035)))
        .background(WallBacking(shape: Capsule(style: .continuous)))
        .overlay(alignment: .topTrailing) {
            // Hovered, a small × to take it off; right-click for the rest.
            if editable, hovered == tile.id, dragged == nil {
                Button { remove(tile.id) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 15, height: 15)
                        .background(Circle().fill(Palette.ground))
                        .overlay(Circle().strokeBorder(Palette.hairline))
                }
                .buttonStyle(.plain)
                .help("Remove")
                .offset(x: 4, y: -5)
                .accessibilityHidden(true)
            }
        }
        .contentShape(Capsule())
        .opacity(dragged == tile.id ? 0.4 : 1)
        .help(site)
        .onHover { inside in
            if inside { hovered = tile.id } else if hovered == tile.id { hovered = nil }
            // A drag let go of somewhere else never reaches a drop here:
            // the next hover with no button down puts the order back.
            if dragged != nil, NSEvent.pressedMouseButtons == 0 {
                dragged = nil
                order = nil
            }
        }
        .onTapGesture { open(tile) }
        .focusable()
        .focusEffectDisabled()
        .focused($focus, equals: .tile(tile.id))
        .onKeyPress(phases: .down) { press in key(press, tile: tile, at: index, editable: editable) }
        .contextMenu {
            Button("Open in New Tab") { if let url { browser.open(url, foreground: true, from: browser.active) } }
            if editable {
                Button("Edit\u{2026}") { begin(.tile(tile.id)) }
                Button("Remove") { remove(tile.id) }
            }
        }
        .modifier(TileDragging(on: editable, id: tile.id, dragged: $dragged, order: $order, tiles: { browser.bookmarks.tiles },
                               put: { id, place in browser.bookmarks.moveTile(id, to: place) }))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityValue(Text(verbatim: site))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(editable ? "Opens the site. Actions to edit, move or remove it." : "Opens the site.")
        .accessibilityAction { open(tile) }
        .modifier(TileActions(on: editable,
                              edit: { begin(.tile(tile.id)) },
                              earlier: { move(tile.id, to: index - 1) },
                              later: { move(tile.id, to: index + 1) },
                              remove: { remove(tile.id) }))
    }

    /// The keys on a chip: Return or Space opens it (⌘ behind), the arrows
    /// go from chip to chip, ⌘ with an arrow moves it, ⌫ removes it,
    /// ⌥Return edits it, Escape goes back to the field.
    private func key(_ press: KeyPress, tile: Bookmark, at index: Int, editable: Bool) -> KeyPress.Result {
        let command = press.modifiers.contains(.command)
        let step: Int? = switch press.key {
        case .leftArrow, .upArrow: -1
        case .rightArrow, .downArrow: 1
        default: nil
        }
        if let step {
            if command {
                guard editable else { return .ignored }
                move(tile.id, to: index + step)
                return .handled
            }
            let tiles = shownTiles
            let to = index + step
            if tiles.indices.contains(to) { focus = .tile(tiles[to].id) }
            else if to == tiles.count, editable, tiles.count < HomeTiles.most { focus = .add }
            return .handled
        }
        switch press.key {
        case .return where press.modifiers.contains(.option):
            guard editable else { return .ignored }
            begin(.tile(tile.id))
            return .handled
        case .return, .space:
            open(tile)
            return .handled
        case .delete, .deleteForward:
            guard editable else { return .ignored }
            let tiles = shownTiles
            let next = tiles.indices.contains(index + 1) ? tiles[index + 1].id : index > 0 ? tiles[index - 1].id : nil
            remove(tile.id)
            focus = next.map { .tile($0) } ?? .add
            return .handled
        case .escape:
            focus = nil
            browser.giveFieldTheKeys()
            return .handled
        default:
            return .ignored
        }
    }

    private var addChip: some View {
        let focused = focus == .add
        let lit = addHovered || focused
        return HStack(spacing: 4) {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .medium))
                .frame(width: 10)
            Text("Add")
                .font(.system(size: HomeTiles.fontSize))
        }
        .foregroundStyle(lit ? Palette.ink : Palette.muted)
        .padding(.horizontal, HomeTiles.padding)
        .frame(height: HomeTiles.chipHeight)
        // Fainter than a site's chip until hovered or focused.
        .background(Capsule(style: .continuous).fill(lit ? Palette.ink.opacity(0.07) : Palette.ink.opacity(0.02)))
        .background(WallBacking(shape: Capsule(style: .continuous)))
        .contentShape(Capsule())
        .onHover { addHovered = $0 }
        .onTapGesture { begin(.new) }
        .focusable()
        .focusEffectDisabled()
        .focused($focus, equals: .add)
        .onKeyPress(phases: .down) { press in
            switch press.key {
            case .return, .space: begin(.new); return .handled
            case .leftArrow, .upArrow:
                if let last = shownTiles.last { focus = .tile(last.id) }
                return .handled
            case .escape:
                focus = nil
                browser.giveFieldTheKeys()
                return .handled
            default: return .ignored
            }
        }
        .help("Add a site")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Add a site")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { begin(.new) }
    }

    static func letter(_ label: String) -> String {
        label.first(where: { $0.isLetter || $0.isNumber }).map { String($0).uppercased() } ?? "·"
    }

    // MARK: the editor

    private func editor(_ editing: Editing) -> some View {
        let isNew = editing == .new
        return VStack(alignment: .leading, spacing: 8) {
            Text(isNew ? "Add a site" : "Edit site")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.ink)
            field("Name", text: $name, focus: .name)
                .onSubmit { focus = .address }
            field("Address", text: $address, focus: .address)
                .onSubmit(save)
            if let problem {
                Text(verbatim: problem)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.unsafe)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            HStack(spacing: 8) {
                if case let .tile(id) = editing {
                    Button("Remove") { remove(id) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                }
                Spacer()
                Button("Cancel", action: close)
                    .controlSize(.small)
                Button(isNew ? "Add" : "Save", action: save)
                    .controlSize(.small)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.ground))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline))
        .onExitCommand(perform: close)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isNew ? "Add a site" : "Edit site")
    }

    private func field(_ title: String, text: Binding<String>, focus which: Focus) -> some View {
        TextField(title, text: text, prompt: Text(which == .address ? "example.com" : "Name"))
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.ink.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(focus == which ? Palette.faint : Palette.hairline))
            .focused($focus, equals: which)
            .accessibilityLabel(title)
    }

    // MARK: doing

    private func open(_ tile: Bookmark) {
        guard let url = tile.address, TileAddress.allowed(url) else { return }
        browser.openBookmark(url)
    }

    private func begin(_ what: Editing) {
        guard browser.tilesEditable else { return }
        problem = nil
        switch what {
        case .new:
            name = ""
            address = ""
        case let .tile(id):
            guard let tile = browser.bookmarks.bookmark(id) else { return }
            name = tile.title
            address = tile.address.map(TileAddress.editable) ?? tile.url ?? ""
        }
        editing = what
        DispatchQueue.main.async { focus = .name }
    }

    private func save() {
        guard let editing else { return }
        let failed: TileAddress.Problem? = switch editing {
        case .new: browser.addTile(name: name, typed: address)
        case let .tile(id): browser.editTile(id, name: name, typed: address)
        }
        if let failed {
            problem = failed.said
            focus = .address
            return
        }
        let back: Focus? = switch editing {
        case .new: browser.bookmarks.tiles.last.map { .tile($0.id) }
        case let .tile(id): .tile(id)
        }
        self.editing = nil
        DispatchQueue.main.async { focus = back }
    }

    private func close() {
        let back: Focus? = switch editing {
        case .new?: .add
        case let .tile(id)?: .tile(id)
        case nil: nil
        }
        editing = nil
        problem = nil
        DispatchQueue.main.async { focus = back }
    }

    private func remove(_ id: Bookmark.ID) {
        guard browser.tilesEditable else { return }
        browser.bookmarks.removeTile(id)
        if editing == .tile(id) { editing = nil }
    }

    private func move(_ id: Bookmark.ID, to place: Int) {
        guard browser.tilesEditable else { return }
        browser.bookmarks.moveTile(id, to: place)
        DispatchQueue.main.async { focus = .tile(id) }
    }
}

/// Chips side by side, each line centred, wrapping to the next when the
/// line is full: the same rule as HomeTiles.lines.
struct ChipFlow: Layout {
    var gap: CGFloat

    private func rows(_ sizes: [CGSize], width: CGFloat) -> [[Int]] {
        var rows: [[Int]] = [], row: [Int] = [], used: CGFloat = 0
        for (i, size) in sizes.enumerated() {
            let need = row.isEmpty ? size.width : used + gap + size.width
            if need > width, !row.isEmpty {
                rows.append(row)
                row = [i]
                used = size.width
            } else {
                row.append(i)
                used = need
            }
        }
        if !row.isEmpty { rows.append(row) }
        return rows
    }

    private func lineWidth(_ line: [Int], _ sizes: [CGSize]) -> CGFloat {
        var sum: CGFloat = 0
        for i in line { sum += sizes[i].width }
        return sum + gap * CGFloat(max(0, line.count - 1))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let width = proposal.width ?? .infinity
        let lines = rows(sizes, width: width)
        var height: CGFloat = 0, widest: CGFloat = 0
        for line in lines {
            height += line.map { sizes[$0].height }.max() ?? 0
            widest = max(widest, lineWidth(line, sizes))
        }
        height += gap * CGFloat(max(0, lines.count - 1))
        return CGSize(width: proposal.width ?? widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var y = bounds.minY
        for line in rows(sizes, width: bounds.width) {
            let lineWidth = lineWidth(line, sizes)
            let lineHeight = line.map { sizes[$0].height }.max() ?? 0
            var x = bounds.minX + (bounds.width - lineWidth) / 2
            for i in line {
                subviews[i].place(at: CGPoint(x: x, y: y + (lineHeight - sizes[i].height) / 2), proposal: ProposedViewSize(sizes[i]))
                x += sizes[i].width + gap
            }
            y += lineHeight + gap
        }
    }
}

/// VoiceOver's actions on a tile, when it can be changed.
private struct TileActions: ViewModifier {
    let on: Bool
    let edit: () -> Void
    let earlier: () -> Void
    let later: () -> Void
    let remove: () -> Void

    func body(content: Content) -> some View {
        if on {
            content
                .accessibilityAction(named: "Edit", edit)
                .accessibilityAction(named: "Move earlier", earlier)
                .accessibilityAction(named: "Move later", later)
                .accessibilityAction(named: "Remove", remove)
        } else {
            content
        }
    }
}

/// A tile dragged among the others: they make room as it passes, and the
/// new order is kept once, on the drop.
private struct TileDragging: ViewModifier {
    let on: Bool
    let id: Bookmark.ID
    @Binding var dragged: Bookmark.ID?
    @Binding var order: [Bookmark.ID]?
    let tiles: () -> [Bookmark]
    let put: (Bookmark.ID, Int) -> Void

    func body(content: Content) -> some View {
        if on {
            content
                .onDrag {
                    dragged = id
                    order = tiles().map(\.id)
                    return NSItemProvider(object: id.uuidString as NSString)
                }
                .onDrop(of: [.plainText], delegate: Drop(id: id, dragged: $dragged, order: $order, put: put))
        } else {
            content
        }
    }

    struct Drop: DropDelegate {
        let id: Bookmark.ID
        @Binding var dragged: Bookmark.ID?
        @Binding var order: [Bookmark.ID]?
        let put: (Bookmark.ID, Int) -> Void

        func validateDrop(info: DropInfo) -> Bool { dragged != nil }

        func dropEntered(info: DropInfo) {
            guard let dragged, dragged != id, var now = order,
                  let from = now.firstIndex(of: dragged), let to = now.firstIndex(of: id) else { return }
            now.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
            withAnimation(Motion.quick) { order = now }
        }

        func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

        func performDrop(info: DropInfo) -> Bool {
            if let dragged, let place = order?.firstIndex(of: dragged) { put(dragged, place) }
            dragged = nil
            order = nil
            return true
        }
    }
}
