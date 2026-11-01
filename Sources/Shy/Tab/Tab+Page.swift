import Combine
import ImageIO
import SwiftUI
import WebKit

extension Tab {
    /// Between two fifths and three times, which is as far as a page is worth
    /// pushing in either direction.
    func magnify(to value: CGFloat) {
        let wanted = min(3, max(0.4, value))
        guard abs(wanted - web.pageZoom) > 0.004 else { return }
        web.pageZoom = wanted
        zoom = wanted
        rememberZoom()
        onZoom?(self, wanted)
    }

    func magnify(by factor: CGFloat) { magnify(to: web.pageZoom * factor) }

    /// ⌘0 undoes both kinds of zoom at once — whichever one you reached for —
    /// back to the size every site starts at.
    func resetZoom() {
        magnify(to: Tab.defaultZoom)
        guard web.magnification != 1 else { return }
        web.magnification = 1
        onZoom?(self, 1)
    }
}

// The page's own settings: reading mode, its icon, its zoom and its sound.
extension Tab {
    /// Leaving reading mode reloads rather than putting the old markup back:
    /// restoring the HTML gives you a page that looks right and does nothing,
    /// because every listener the page had was thrown away with it.
    func toggleReader(_ done: @escaping (Bool) -> Void) {
        guard isWeb else {
            done(false)
            return
        }
        guard !reader else {
            reader = false
            web.reload()
            done(true)
            return
        }
        guess(done)
    }

    /// The page's own article, worked out from the page (see Reader.script).
    private func guess(_ done: @escaping (Bool) -> Void) {
        let arguments: [String: Any] = ["sheet": Reader.sheet, "readerLook": Reader.look.rawValue]
        web.quietly(Reader.script, asFunction: true, arguments: arguments, in: nil, in: .page) { [weak self] result in
            let worked = (try? result.get()) as? String == "read"
            if worked { self?.reader = true }
            done(worked)
        }
    }

    /// The letter a pinned tab is reduced to, and what a tab shows in place of
    /// an icon it doesn't have yet.
    var monogram: String {
        if let page { return String(page.title.prefix(1)) }
        // A file on this Mac has no host: its name's first letter.
        if let address, address.isFileURL {
            let name = address.lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "/."))
            return name.first.map { String($0).uppercased() } ?? "•"
        }
        let host = address?.host()?.replacingOccurrences(of: "www.", with: "") ?? ""
        return host.first.map { String($0).uppercased() } ?? "•"
    }

    func adoptIcon() {
        if let page {
            icon = page.glyph
            return
        }
        icon = Favicons.of(profile).cached(for: address, shy: shy)
    }

    /// What a site opens at until you zoom it yourself: Settings › General ›
    /// Page zoom. Read from the file, not from the one object the window holds.
    static var defaultZoom: CGFloat {
        CGFloat(Store.settings.object(forKey: "pageZoom") as? Double ?? 1)
    }

    /// Remembered for the site, not for the tab: setting a paper's type to
    /// 125% once should be the last time you think about it. A site at the
    /// size every site starts at keeps nothing, and follows that size.
    func rememberZoom() {
        guard let host = address?.host(), !shy else { return }
        let key = SiteMemory.key("zoom.", host, profile)
        if abs(zoom - Tab.defaultZoom) < 0.01 {
            Store.settings.removeObject(forKey: key)
        } else {
            Store.settings.set(Double(zoom), forKey: key)
        }
    }

    func applyRememberedZoom() {
        guard let host = address?.host() else { return }
        // A private tab keeps none, and reads none of another's.
        let kept = (shy ? nil : Store.settings.object(forKey: SiteMemory.key("zoom.", host, profile)) as? Double).map { CGFloat($0) }
            ?? Tab.defaultZoom
        guard abs(kept - web.pageZoom) > 0.004 else { return }
        web.pageZoom = kept
        zoom = kept
    }

    /// Not `web`: a tab asleep is muted without being woken, and hears of
    /// it when its page is built again.
    func toggleMute() {
        muted.toggle()
        if let built { Muter.set(muted, on: built) }
    }

    /// Where the last image right-clicked came from (see ImageMenu.swift).
    var imageFrame: WKFrameInfo? { images.frame }

    /// For the bench.
    var hushing: Bool { quiet != nil }
}
