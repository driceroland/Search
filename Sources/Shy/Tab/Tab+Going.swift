import Combine
import ImageIO
import SwiftUI
import WebKit

// Going somewhere, resting and sleeping, and pictures of the page.
extension Tab {
    /// Called from the page, a few dozen times a second at most — the script
    /// already waits for a frame before it says anything.
    func scrolled(to y: Double, of ceiling: Double, screens: Double? = nil) {
        if let screens { self.screens = (max(1, screens) * 10).rounded() / 10 }
    }

    func go(to url: URL) {
        if let own = InternalPage(url: url) {
            show(own)
            return
        }
        // Out of one of Shy's own pages, onto the web: Back comes back.
        if let page {
            behind = page
            self.page = nil
            trail = []
            ahead = []
            icon = nil
        }
        // Judged by the page it shows, not by how it was made: a tab an
        // extension's page opened with window.open is built from that
        // extension's configuration too. A tab with no page yet was just
        // built for where it is going, so it goes there.
        if let onCross, let here = built?.url ?? address,
           Browser.extensionHost(of: here) != Browser.extensionHost(of: url) {
            onCross(self, url)
            return
        }
        // Set straight away rather than waiting for the observer: the tab has to
        // stop being blank in the same frame the field disappears, or the empty
        // state flashes back for an instant on its way out.
        address = url
        held = nil
        title = ""
        failure = nil
        reader = false
        typing = false
        immersed = false
        draft = ""
        // Sent somewhere new, a sleeping tab is simply awake again — with
        // nothing of where it was before to bring back.
        pending = nil
        memory = nil
        picture = nil
        cover = nil
        adoptIcon()
        web.open(url)
        // Back, from a page that came out of one of Shy's own, goes there.
        steps()
    }

    /// Brought back from the last session: everything the row needs to draw it,
    /// and nothing fetched.
    func restore(url: URL, title: String, name: String? = nil) {
        if let own = InternalPage(url: url) {
            self.name = name
            show(own)
            return
        }
        address = url
        self.title = title
        self.name = name
        pending = url
        adoptIcon()
    }

    /// True for a tab that has a place and an address but is holding no page —
    /// brought back from the last session, or put down with ⌘W while pinned.
    var asleep: Bool { pending != nil }

    /// ⌘W on a pinned tab. The letter keeps its place in the row and the
    /// address is remembered; everything the page was holding is let go, so a
    /// pin you are not reading costs a line in a file and nothing else.
    /// Given `home`, it is put down there instead of where it was: Arc's pin
    /// that goes back to its pinned page once closed (see Browser.close).
    func rest(at home: URL? = nil) {
        guard let url = home ?? address else { return }
        // The title was the page it is leaving; the host stands in until the
        // pinned page is woken and names itself.
        if let home, address != home {
            address = home
            title = home.host ?? ""
        }
        pending = url
        memory = nil
        picture = nil
        noisy = false
        stale = false
        pull = nil
        // Loading about:blank here looked like letting the page go, and
        // wasn't: WebKit keeps the document it just left in the back-forward
        // cache — alive, suspended, and still counted by its own origin as an
        // open tab. Coming back then started a second x.com beside a first
        // that would never answer, and the second waited for it until you
        // gave up and reloaded by hand. Only tearing the view down ends the
        // page; the next wake() builds a fresh one, and a fresh one boots.
        discard()
    }

    /// Nobody has looked at this page for a while. Its view goes, as with a
    /// pin put down by hand, but its history and a picture of it stay: the
    /// view built to wake it opens the same page, at the same place, with
    /// Back still going back. What was typed and not sent is the one thing
    /// that can't come back, which is why the browser asks `unsaved` first.
    func sleep(picture: Data?) {
        guard let url = address, let built else { return }
        memory = built.interactionState
        self.picture = picture
        pending = url
        stale = false
        pull = nil
        discard()
    }

    /// A page moved to a space signed in another way — another profile, or
    /// a space with sign-ins of its own — must start there afresh. WebKit
    /// binds the store when the view is made, so the view goes and is built
    /// again with the destination's store; and nothing of the old session
    /// comes along: not its Back and Forward, its place or what was typed
    /// (the view's interaction state, kept for a sleeping tab too), not a
    /// picture of the page as it was signed in, not what the page was asking.
    /// Only the address goes, and is loaded anew.
    func rehome(in space: UUID) {
        guard !shy, !bench, store !== Spaces.store(for: space) else { return }
        let url = address ?? built?.url ?? pending
        if built != nil { discard() }
        memory = nil
        picture = nil
        cover = nil
        peeked = nil
        popupSites = []
        pending = url
        configuration = Web.configuration(space: space)
    }

    /// Settings › Videos wait for a click, changed: the page's next view
    /// is made the new way. One already made keeps what it was made with —
    /// WebKit fixes it then — and its next page follows through its own
    /// autoplay policy (see Autoplay.apply).
    func playbackChanged() {
        configuration.mediaTypesRequiringUserActionForPlayback = Web.playback
    }

    /// Whether the page holds something typed and not yet sent — a draft, a
    /// half-filled form. A page that can't answer is treated as holding
    /// nothing: a PDF, an image, a page whose process has already gone.
    func unsaved(_ done: @escaping (Bool) -> Void) {
        guard let built else { return done(false) }
        built.evaluateInShy(
            "!!(window.__officeForms && window.__officeForms.unsaved && window.__officeForms.unsaved())"
        ) { value in
            MainActor.assumeIsolated { done((value as? Bool) == true) }
        }
    }

    /// The page as it looks right now, compressed. Drawn by the page's own
    /// process, so a view that is off screen — every tab but the one you are
    /// on — can still be pictured. Nil when there is nothing to draw.
    func snapshot(_ done: @escaping (Data?) -> Void) {
        guard let built else { return done(nil) }
        built.takeSnapshot(with: nil) { image, _ in
            guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return done(nil)
            }
            DispatchQueue.global(qos: .utility).async {
                let data = Tab.jpeg(cg)
                DispatchQueue.main.async { done(data) }
            }
        }
    }

    /// A small picture of the page for the tab switcher. A sleeping tab's
    /// comes from the picture kept for waking it; a tab brought back from
    /// last time and not opened yet has none, rather than a page built for it.
    func preview(width: CGFloat, _ done: @escaping (NSImage?) -> Void) {
        if let picture {
            DispatchQueue.global(qos: .userInitiated).async {
                let source = CGImageSourceCreateWithData(picture as CFData, nil)
                let options = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: Int(width * 2)
                ] as CFDictionary
                let thumbnail = source.flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, options) }
                DispatchQueue.main.async {
                    let image = thumbnail.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
                    done(image)
                }
            }
            return
        }
        guard let built else { return done(nil) }
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = NSNumber(value: Double(width))
        built.takeSnapshot(with: configuration) { image, _ in done(image) }
    }

    nonisolated private static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let out = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(out, image, [kCGImageDestinationLossyCompressionQuality: 0.55] as CFDictionary)
        return CGImageDestinationFinalize(out) ? data as Data : nil
    }
}
