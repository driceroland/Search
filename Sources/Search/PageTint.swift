import AppKit
import WebKit

/// Decides the color the tab strip takes on so the chrome reads as part of the page. The page reports
/// what should set it (see `TintRouter.script` for which elements count): "r,g,b" when its styles
/// say, "page" when its own background should show, "unknown:<element>" when an image, gradient or
/// other painted content decides it. The element's name includes how it looks, so a header that turns
/// from a clear gradient into a dark one is a new name.
///
/// Only "unknown" needs pixels, and a snapshot makes the page paint on its main thread: tens of
/// milliseconds on a plain page, half a second on one full of canvases, during which the page freezes.
/// So snapshots are rationed hard: one per look of an element and `maxSnapshots` per page, taken only
/// once the page has loaded and both scrolling and reports have been quiet for `delay`. Until then,
/// and whenever that look is at the edge again, `color` is what is known, or stays what it was.
final class PageTint {
    /// The color along the top edge; nil until known, and when the page's own background shows there.
    private(set) var color: NSColor?
    /// The fade the page's header is making to `color`, read from the page's own transition so the
    /// strip can make the same one; nil when the page changed at once.
    private(set) var fade: Fade?

    struct Fade {
        let duration: TimeInterval
        let curve: CAMediaTimingFunction

        /// `text` is "<ms>,<easing>", the easing as CSS writes it.
        init?(_ text: Substring) {
            let parts = text.split(separator: ",", maxSplits: 1)
            guard let first = parts.first, let milliseconds = Double(first), milliseconds > 0 else { return nil }
            duration = milliseconds / 1000
            let easing = parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespaces) : "ease"
            let points =
                easing.hasPrefix("cubic-bezier(")
                ? easing.dropFirst(13).dropLast().split(separator: ",").compactMap { Swift.Float($0.trimmingCharacters(in: .whitespaces)) } : []
            switch easing {
            case _ where points.count == 4: curve = CAMediaTimingFunction(controlPoints: points[0], points[1], points[2], points[3])
            case "linear": curve = CAMediaTimingFunction(name: .linear)
            case "ease-in": curve = CAMediaTimingFunction(name: .easeIn)
            case "ease-out": curve = CAMediaTimingFunction(name: .easeOut)
            case "ease-in-out": curve = CAMediaTimingFunction(name: .easeInEaseOut)
            // Core Animation's default curve is CSS's `ease`.
            default: curve = CAMediaTimingFunction(name: .default)
            }
        }
    }
    /// Whether `color` was read from the page's styles, which is exact and current, rather than
    /// found in a snapshot or kept from before.
    var isFromStyles: Bool { color != nil && undecided == nil && kept == nil }

    /// A page that keeps changing its painted header can't make the strip freeze it over and over.
    static let maxSnapshots = 8

    private let delay: TimeInterval
    private let isLoading: () -> Bool
    private let isShown: () -> Bool
    private let snapshot: (@escaping (NSColor?) -> Void) -> Void
    private let onChange: () -> Void

    /// The latest "unknown" report, naming the element that decides the edge.
    private var undecided: String?
    /// What each element's one snapshot found, so coming back to it is instant.
    private var found: [String: NSColor] = [:]
    private var snapshotted: Set<String> = []
    private var pending: DispatchWorkItem?
    /// Runs while the last page's color is held for a new page; ends the hold if it never reports.
    private var kept: DispatchWorkItem?
    /// Whether a new page has yet to say what it shows. Until it does, or the hold runs out, the strip
    /// should stay as it was rather than flash the page's background in between.
    var isWaiting: Bool { kept != nil }

    /// `snapshot` supplies the dominant color along the top edge, or nil if it could not be read.
    /// `isShown` is whether the page is on screen; a hidden page can't be snapshotted.
    init(
        delay: TimeInterval = 0.5, isLoading: @escaping () -> Bool, isShown: @escaping () -> Bool,
        snapshot: @escaping (@escaping (NSColor?) -> Void) -> Void, onChange: @escaping () -> Void
    ) {
        (self.delay, self.isLoading, self.isShown, self.snapshot, self.onChange) = (delay, isLoading, isShown, snapshot, onChange)
    }

    /// Takes one report from the page. A first report that leaves `color` as it was still ends the
    /// wait, which changes what the tab shows, so it is announced like a change of color.
    func report(_ full: String) {
        let (wasWaiting, before) = (kept != nil, color)
        defer { if wasWaiting, color == before { onChange() } }
        kept?.cancel()
        kept = nil
        // "<answer>~<ms>,<easing>" when the header is fading to this answer.
        let timed = full.split(separator: "~", maxSplits: 1)
        fade = timed.count == 2 ? Fade(timed[1]) : nil
        let report = String(timed.first ?? "")
        guard report.hasPrefix("unknown") else {
            cancelPending()
            undecided = nil
            let parts = report.split(separator: ",").compactMap { Double($0) }
            return show(
                parts.count == 3
                    ? NSColor(srgbRed: parts[0] / 255, green: parts[1] / 255, blue: parts[2] / 255, alpha: 1)
                    : nil)
        }
        // A page that animates repeats itself constantly. A repeat must not restart the wait, or the
        // snapshot would never come while the animation runs.
        if report == undecided { return }
        undecided = report
        if let known = found[report] { show(known) }
        if snapshotted.contains(report) || snapshotted.count >= Self.maxSnapshots { cancelPending() } else { schedule() }
    }

    /// Called while the user scrolls, to keep a waiting snapshot from landing mid-scroll.
    func userIsScrolling() {
        if pending != nil { schedule() }
    }

    /// Called when the page is shown again: a snapshot that came due while it was hidden could not be
    /// taken, and the page will not repeat its report.
    func resume() {
        if let undecided, !snapshotted.contains(undecided), pending == nil { schedule() }
    }

    /// Forgets everything; the page was replaced. The strip keeps what it showed until the new page's
    /// first report, which comes with its first frames, or for `hold` if none comes: long within a
    /// site, where the header is usually the same, short when leaving it.
    func reset(holding hold: TimeInterval) {
        cancelPending()
        kept?.cancel()
        (undecided, found, snapshotted) = (nil, [:], [])
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            kept = nil
            if color == nil { onChange() } else { show(nil) }
        }
        kept = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hold, execute: work)
    }

    private func show(_ new: NSColor?) {
        guard new != color else { return }
        color = new
        onChange()
    }

    private func cancelPending() {
        pending?.cancel()
        pending = nil
    }

    private func schedule() {
        cancelPending()
        let work = DispatchWorkItem { [weak self] in self?.takeSnapshot() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func takeSnapshot() {
        pending = nil
        guard let element = undecided, isShown() else { return }
        if isLoading() { return schedule() }
        snapshotted.insert(element)
        snapshot { [weak self] color in
            guard let self, let color else { return }
            found[element] = color
            // Only shown if that element still decides the edge; otherwise it waits for its return.
            if element == undecided { show(color) }
        }
    }
}

/// Receives reports from one tab's page. The tab holds the handler so WebKit
/// does not retain the tab through its own content controller.
final class TintRouter: NSObject, WKScriptMessageHandler {
    static let name = "tint"
    weak var tab: Tab?

    /// The script that works out which color the strip should take, from styles alone. It lives in
    /// PageTint.js beside this file, with the rules it follows, and posts to the handler `name`.
    static let script: String = {
        let url = Bundle.module.url(forResource: "PageTint", withExtension: "js")!
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let report = message.body as? String, message.webView === tab?.built else { return }
        tab?.pageTint.report(report)
    }
}
