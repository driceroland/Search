import Combine
import Foundation
import SwiftUI

// Your own style for a site, as Arc's Boosts are: CSS you write, put on
// every page of that site. CSS only — Search never runs script you type
// into a page.
//
// Off until Settings › Browsing › Pages › Your own style for a site. Then
// View › Edit Site Style… writes the site you're on, and what you type is on
// the page as you type it. Kept by site the way hidden elements are (no
// www.), in styles.json beside hidden.json, and put in the same way: a
// stylesheet before the page has drawn, so nothing is seen changing. Turning
// the setting off takes every style off the pages and keeps them all.

@MainActor
final class SiteStyles: ObservableObject {
    static let shared = SiteStyles(file: Store.file("styles.json"))

    /// The element the sheet lives in, apart from the one that hides things.
    static let element = "office-style"

    /// Settings › Browsing › Pages. Off, pages get nothing at all.
    var on = false {
        didSet { if on != oldValue { changed.send(nil) } }
    }

    @Published private(set) var byHost: [String: String] = [:]

    /// A site whose style changed, for every window to pass on to its open
    /// pages of that site; nil for all of them, when the switch moved.
    let changed = PassthroughSubject<String?, Never>()

    private let file: URL
    private var saving = false

    init(file: URL) {
        self.file = file
        load()
    }

    /// The same host hidden elements and dark pages are kept by: no www., and
    /// only for a website.
    static func host(of url: URL?) -> String? { Dusk.host(of: url) }

    /// What a page of this site is to wear: nothing while the setting is off.
    func css(on host: String?) -> String? {
        guard on, let host, let css = byHost[host], !css.isEmpty else { return nil }
        return css
    }

    /// What was written for a site, on or off.
    func written(on host: String) -> String { byHost[host] ?? "" }

    var hosts: [String] { byHost.keys.sorted() }

    /// Nothing but whitespace is no style at all, and the site is forgotten.
    func set(_ css: String, on host: String) {
        let kept = css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : css
        guard byHost[host] != kept else { return }
        byHost[host] = kept
        save()
        changed.send(host)
    }

    func remove(on host: String) { set("", on: host) }

    // MARK: - into the page

    /// Puts the sheet in, or empties it. Last in the document once there is
    /// one, so a rule of yours wins over the site's own of the same weight
    /// without needing !important. Text in a style element, never markup:
    /// nothing in it can close the element and become something else.
    private static let apply = """
    function (css) {
      var sheet = document.getElementById('\(element)');
      if (!sheet) {
        if (!css) return;
        sheet = document.createElement('style');
        sheet.id = '\(element)';
      }
      sheet.textContent = css;
      var last = function () { document.documentElement.appendChild(sheet); };
      last();
      if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', last, { once: true });
    }
    """

    /// For a page about to load: the sheet as a string the script can't be
    /// broken out of, whatever quotes, backticks or `${` it holds.
    static func script(_ css: String) -> String {
        "(\(apply))(\(literal(css)));"
    }

    /// For the page up now, where the CSS travels as an argument and is
    /// never part of the source (see Tab.callInSearch).
    static let live = "(\(apply))(css);"

    /// A JavaScript string literal: JSON's, with the two line separators and
    /// `<` spelled out as well.
    static func literal(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed]),
              let json = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        return json
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
            .replacingOccurrences(of: "<", with: "\\u003c")
    }

    // MARK: - the file

    private func load() {
        guard let data = try? Data(contentsOf: file),
              let stored = try? JSONDecoder().decode([String: String].self, from: data)
        else { return }
        byHost = stored
    }

    /// Typing writes a few times a second; the file is written once it stops.
    private func save() {
        guard !saving else { return }
        saving = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            saving = false
            let snapshot = byHost
            let file = file
            DispatchQueue.global(qos: .utility).async { Self.write(snapshot, to: file) }
        }
    }

    /// Now rather than in a moment, for a test.
    func writeNow() { Self.write(byHost, to: file) }

    nonisolated private static func write(_ styles: [String: String], to file: URL) {
        guard let data = try? JSONEncoder().encode(styles) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}

/// View › Edit Site Style…: the CSS for the site in front, on the page as
/// you type. Done closes it; there is nothing to save, it already is.
/// Its bottom corner, away from the corner it hangs from, makes it larger
/// or smaller, the editor taking the room; the size is kept for next time.
struct StylePanel: View {
    @ObservedObject var browser: Browser
    let host: String

    @State private var text = ""
    @State private var pending: DispatchWorkItem?
    @FocusState private var typing: Bool
    /// The card's width and the editor's height, as last left.
    @State private var size = StylePanel.kept
    @State private var start: CGSize?
    @State private var over = false

    /// What it opens at the first time, and the least it is made.
    static let first = CGSize(width: 420, height: 220)
    static let least = CGSize(width: 340, height: 120)

    static var kept: CGSize {
        let width = Store.settings.double(forKey: "sitestyle.width")
        let height = Store.settings.double(forKey: "sitestyle.height")
        guard width > 0, height > 0 else { return first }
        return CGSize(width: max(width, least.width), height: max(height, least.height))
    }

    static func keep(_ size: CGSize) {
        Store.settings.set(Double(size.width), forKey: "sitestyle.width")
        Store.settings.set(Double(size.height), forKey: "sitestyle.height")
    }

    /// The most it may take: the window, less the margins round the card,
    /// its title and its foot.
    static func most(in room: CGSize?) -> CGSize {
        guard let room, room.width > 0, room.height > 0 else { return CGSize(width: 1200, height: 900) }
        return CGSize(width: max(least.width, room.width - 28),
                      height: max(least.height, room.height - Metrics.strip - 8 - 14 - 150))
    }

    /// `from` pulled by `moved` at the corner under the card's left edge:
    /// left and down make it larger.
    static func pulled(_ from: CGSize, by moved: CGSize, room: CGSize?) -> CGSize {
        let most = most(in: room)
        return CGSize(width: min(max(from.width - moved.width, least.width), most.width),
                      height: min(max(from.height + moved.height, least.height), most.height))
    }

    private var room: CGSize? { browser.window?.contentView?.bounds.size }

    var body: some View {
        let most = Self.most(in: room)
        let shown = CGSize(width: min(size.width, most.width), height: min(size.height, most.height))
        return Plate(host, width: shown.width, close: close) {
            VStack(alignment: .leading, spacing: 6) {
                Caption("CSS for every page of this site")
                TextEditor(text: $text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Palette.ink)
                    .scrollContentBackgroundHidden()
                    .autocorrectionDisabled()
                    .focused($typing)
                    .padding(8)
                    .frame(height: shown.height)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        } foot: {
            HStack(spacing: 8) {
                Pill("Done", filled: true, action: close)
                if !text.isEmpty {
                    Pill("Clear") { text = "" }
                }
                Spacer()
            }
        }
        .overlay(alignment: .bottomLeading) { corner }
        .onAppear {
            text = SiteStyles.shared.written(on: host)
            typing = true
        }
        .onChangeCompat(of: text) { _, now in
            // A moment after the last key, so a half-typed rule isn't sent
            // to every open page of the site on each letter.
            pending?.cancel()
            let work = DispatchWorkItem { SiteStyles.shared.set(now, on: host) }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }

    /// The corner that resizes it: a small mark, the pointer's resize arrow
    /// over it; a double-click puts it back to its first size.
    private var corner: some View {
        Image(systemName: "arrow.down.left.and.arrow.up.right")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(over || start != nil ? Palette.muted : Palette.faint)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .onHover { inside in
                guard inside != over else { return }
                over = inside
                if inside { Self.cursor.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let from = start ?? size
                        if start == nil { start = from }
                        size = Self.pulled(from, by: drag.translation, room: room)
                    }
                    .onEnded { _ in
                        start = nil
                        Self.keep(size)
                    }
            )
            .onTapGesture(count: 2) {
                size = Self.first
                Self.keep(size)
            }
            .help("Drag to resize")
            .accessibilityHidden(true)
    }

    /// The diagonal resize arrow where macOS has one to give.
    private static var cursor: NSCursor {
        if #available(macOS 15, *) { return .frameResize(position: .bottomLeft, directions: .all) }
        return .crosshair
    }

    private func close() {
        pending?.cancel()
        SiteStyles.shared.set(text, on: host)
        browser.styling = nil
    }
}

/// The setting's switch, and beside it the sites that have a style, each to
/// take off for good. Their styles are kept while the switch is off.
struct SiteStylesControl: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject private var styles = SiteStyles.shared

    var body: some View {
        HStack(spacing: 10) {
            if !styles.hosts.isEmpty {
                Menu(styles.hosts.count == 1 ? "1 site" : "\(styles.hosts.count) sites") {
                    ForEach(styles.hosts, id: \.self) { host in
                        Menu(host) {
                            Button("Remove Style") { styles.remove(on: host) }
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            Switch(on: $prefs.sitesStyles)
        }
    }
}
