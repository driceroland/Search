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
    /// Reject snapshots from a document that has already been replaced.
    private var generation = 0
    /// Runs while the last page's color is held for a new page; ends the hold if it never reports.
    private var kept: DispatchWorkItem?
    /// Whether a new page has yet to say what it shows. Until it does, or the hold runs out, the strip
    /// should stay as it was rather than flash the page's background in between.
    var isWaiting: Bool { kept != nil }

    /// `snapshot` supplies the dominant color along the top edge, or nil if it could not be read.
    /// `isShown` is whether the page is on screen; a hidden page can't be snapshotted.
    init(
        delay: TimeInterval = 0.2, isLoading: @escaping () -> Bool, isShown: @escaping () -> Bool,
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
        generation += 1
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

    private func schedule(after wait: TimeInterval? = nil) {
        cancelPending()
        let work = DispatchWorkItem { [weak self] in self?.takeSnapshot() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (wait ?? delay), execute: work)
    }

    private func takeSnapshot() {
        pending = nil
        guard let element = undecided, isShown() else { return }
        // A slow page should not poll five times a second just because its
        // snapshot's quiet period is short once it has finished loading.
        if isLoading() { return schedule(after: 0.5) }
        snapshotted.insert(element)
        let current = generation
        snapshot { [weak self] color in
            guard let self, self.generation == current, let color else { return }
            found[element] = color
            // Only shown if that element still decides the edge; otherwise it waits for its return.
            if element == undecided { show(color) }
        }
    }

    /// Reduces a snapshot of the page's top edge to its prevailing color,
    /// ignoring minority pixels such as a logo or navigation text.
    static func sample(_ image: CGImage) -> NSColor? {
        let samples = 32
        var pixels = [UInt8](repeating: 0, count: samples * 4)
        guard
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: &pixels, width: samples, height: 1, bitsPerComponent: 8, bytesPerRow: samples * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: samples, height: 1))

        var groups: [Int: (count: Int, red: Int, green: Int, blue: Int)] = [:]
        for index in 0..<samples {
            let (red, green, blue) = (Int(pixels[index * 4]), Int(pixels[index * 4 + 1]), Int(pixels[index * 4 + 2]))
            let key = (red >> 4) << 8 | (green >> 4) << 4 | blue >> 4
            let group = groups[key] ?? (0, 0, 0, 0)
            groups[key] = (group.count + 1, group.red + red, group.green + green, group.blue + blue)
        }
        guard let winner = groups.values.max(by: { $0.count < $1.count }) else { return nil }
        let scale = 255 * CGFloat(winner.count)
        return NSColor(
            srgbRed: CGFloat(winner.red) / scale, green: CGFloat(winner.green) / scale,
            blue: CGFloat(winner.blue) / scale, alpha: 1)
    }
}

/// Receives reports from one tab's page. The tab holds the handler so WebKit
/// does not retain the tab through its own content controller.
final class TintRouter: NSObject, WKScriptMessageHandler {
    static let name = "tint"
    weak var tab: Tab?

    /// Reads the page's top edge while tint is enabled and reports a color to the native tint controller.
    static let script = #"""
    // Works out which color the strip should take, from styles alone, painting nothing.
    //
    // Not everything that touches the top edge counts. A page like a feed has cards and columns
    // scrolling under the strip; following those would flip the strip's color with every card. So at
    // five points across the edge the script finds the element whose background shows there, and only
    // two kinds can set the color. A pinned element, fixed or sticky, stays put while the page scrolls:
    // a sticky header, or an app's sidebar. A plain colored column with a pinned layer in front of it
    // counts too, which is how GitHub builds its sidebar. An invisible layer does not count, and neither
    // does anything less than 12px tall at the edge: a site's loading bar is pinned and full width, and
    // would otherwise turn the strip its color whenever a page loads slowly. A band runs from one side
    // of the page to the other: a hero, a full-bleed section, often just the page's backdrop. A hero
    // set in from the sides, however wide, is a card: the page's background shows beside it and above
    // its rounded corners, and that background is what the strip continues. Pinned beats scrolling, a
    // band beats a column, then the wider wins. Anything else, a card or a column passing by, leaves
    // the page's own background.
    //
    // The report, sent when it changes, is "r,g,b", "page", or "unknown:<n>:<look>" when a band is an
    // image, gradient or other painted element: n numbers the element and look is a hash of its
    // styles and of what is in front of it, so the native side can remember each look it has seen.
    // Translucent colors are composited through the elements behind them, a blurred backdrop
    // included, since a blur keeps the average color.
    // A vertical gradient counts as the color of its top stop. A pinned element is also searched for
    // what hit-testing skips, layers that ignore the pointer and pseudo-elements, which is how a bar
    // with nothing but a fading scrim behind it is read. Web components are looked into, since their
    // paint is inside their shadow trees. A dialog's scrim over the whole viewport is left to pixels.
    // Colors outside sRGB notation, such as oklch, are converted by filling one pixel of a detached
    // canvas. A video is painted content like an image: its one snapshot gives a hero video a steady
    // color where the page's background could clash with it. A painted element narrower than a band
    // never counts, since a snapshot could not tell its part of the edge from the rest.
    //
    // Asking where elements are makes the page bring its layout up to date, which is real work on a
    // busy page, so a full read is kept rare. Load, resize and scroll read at most twenty times a second,
    // and once more shortly after the last of them to catch a header that was still fading. Around
    // the moments a page can change, each frame also takes a glance, one hit test and a few style
    // reads, and a full read follows at once if it differs, so a header restyled by the page's scroll
    // handler and the strip change in the same frame. A transition is read for where it is going: the
    // report ends in "~<ms>,<easing>", the fade the page is making, and the strip makes the same one.
    // The start of a transition on an element of the last read is read at once, and the end of any on
    // a property that can change the edge is read once.
    //
    // Pages also change with no such event: a client-rendered header arrives late, a route or theme
    // changes. Those follow a moment that is known: the load, a click, a key, a change of the system's
    // color scheme, a return from the back-forward cache, or `readPageTint()`, which the native side
    // calls when the address changes without a new page. Each such moment is followed by a second of
    // glances, one a frame (three seconds as a page first appears), and by five reads spread over
    // eight seconds, and then nothing until the next one, so an idle page is never read and a hidden
    // one waits until it is shown. A read of a page whose layout is up to date took 0.07ms on a page
    // of 20,000 elements, a glance 0.007ms. A mutation observer would notice more, but measured on the
    // same page it nearly doubled the cost of a burst of DOM changes, so there is none. It never
    // listens to animations either; a page full of them would be read on every frame.
    //
    // The script runs in the isolated client world, where the page's own scripts can neither see it
    // nor send reports in its name.
    //
    // Reports go to the message handler named "tint"; see TintRouter in PageTint.swift.
    (() => {
        // The preference is supplied before this script runs; an existing page can be toggled later.
        let enabled = globalThis.pageTintEnabled === true;
        delete globalThis.pageTintEnabled;
        const painted = /^(IMG|VIDEO|CANVAS|PICTURE|SVG|IFRAME|EMBED|OBJECT)$/i;
        const edgeProperty = /^(background|opacity|transform|visibility|height|top)/;
        const blurred = /blur\((?!0(px)?\))/;
        const numbers = new WeakMap(), parsed = new Map();
        let pinned = new WeakMap(), pixel;
        let last, count = 0, readTimer = 0, settleTimer = 0, readAt = 0;
        // What the last read walked through, and what those looked like, for `glance`.
        let touched = new Set(), touchedPseudo = [], watched = [], watchedPseudo = [], seen = '', frame = 0;
        // The longest transition met by the current read, and its easing.
        let glide = 0, easing = 'ease';
        // Until when every frame takes a glance; see `watchFrames`.
        let watchUntil = 0;
        let followUps = [], missed = false;

        function number(element) {
            if (!numbers.has(element)) numbers.set(element, ++count);
            return numbers.get(element);
        }

        // Where an element's running transitions will leave it. A header fades to its new color
        // over a few hundred milliseconds; reading the color it has now would make the strip trail
        // it, learning of the change step by step. Reading where it is going, and how long it will
        // take, lets the strip set off for the same color at the same moment and arrive together.
        // A pseudo-element's transitions are listed with its element's subtree, so they are asked for
        // only where a pseudo-element paints: sites often fade a header in as its `::after`.
        function fadeTarget(element, pseudo) {
            const to = {};
            if (!element.getAnimations) return to;
            for (const animation of pseudo ? element.getAnimations({ subtree: true }) : element.getAnimations()) {
                const property = animation.transitionProperty, effect = animation.effect;
                if (property !== 'background-color' && property !== 'opacity') continue;
                if (!effect || effect.target !== element || (effect.pseudoElement || null) !== (pseudo || null)) continue;
                const frames = effect.getKeyframes(), final = frames[frames.length - 1] || {};
                if (property === 'opacity') to.opacity = Number(final.opacity); else to.backgroundColor = final.backgroundColor;
                const left = (effect.getComputedTiming().endTime || 0) - (animation.currentTime || 0);
                if (left > glide) { glide = left; easing = effect.getTiming().easing || 'ease'; }
            }
            return to;
        }

        // Names a painted element and its look: its own styles and the color in front of it.
        function unknown(element, style, front) {
            number(element);
            const image = style.backgroundImage;
            const look = [image.length, image.slice(0, 200), style.backgroundColor, Number(style.opacity).toFixed(1),
                (element.currentSrc || '').slice(-200), front].join('|');
            let hash = 0;
            for (let i = 0; i < look.length; i++) hash = (hash * 31 + look.charCodeAt(i)) | 0;
            return 'unknown:' + numbers.get(element) + ':' + (hash >>> 0).toString(36);
        }

        // A computed color as [red, green, blue, alpha]; null when not even a canvas can read it.
        function rgba(color) {
            if (color.startsWith('rgb')) {
                const [red, green, blue, alpha = 1] = color.match(/[\d.]+/g).map(Number);
                return [red, green, blue, alpha];
            }
            if (!parsed.has(color)) {
                if (parsed.size > 200) parsed.clear();
                if (!pixel) {
                    const canvas = document.createElement('canvas');
                    canvas.width = canvas.height = 1;
                    pixel = canvas.getContext('2d', { willReadFrequently: true });
                }
                pixel.fillStyle = '#010203';
                pixel.fillStyle = color;
                let value = null;
                if (pixel.fillStyle !== '#010203') {
                    pixel.clearRect(0, 0, 1, 1);
                    pixel.fillRect(0, 0, 1, 1);
                    const [red, green, blue, alpha] = pixel.getImageData(0, 0, 1, 1).data;
                    value = [red, green, blue, alpha / 255];
                }
                parsed.set(color, value);
            }
            return parsed.get(color);
        }

        function isPinned(element) {
            if (!pinned.has(element)) {
                let found = false;
                for (let e = element; e && e !== document.documentElement && !found; e = e.parentElement) {
                    const position = getComputedStyle(e).position;
                    found = position === 'fixed' || position === 'sticky';
                }
                pinned.set(element, found);
            }
            return pinned.get(element);
        }

        // The color a vertical gradient shows along its top edge, its first stop or, running upward,
        // its last; null for any other image, which only pixels can tell.
        function gradientTop(image) {
            if (!image.startsWith('linear-gradient(')) return null;
            const parts = [];
            let depth = 0, start = 16;
            for (let i = 16; i < image.length; i++) {
                const c = image[i];
                if (c === '(') depth++;
                else if (c === ',' && depth === 0) { parts.push(image.slice(start, i)); start = i + 1; }
                else if (c === ')' && depth-- === 0) {
                    if (i !== image.length - 1) return null;
                    parts.push(image.slice(start, i));
                }
            }
            let direction = 'to bottom';
            if (/^\s*(to\s|-?[\d.]+(deg|turn|rad|grad))/.test(parts[0] || '')) direction = parts.shift().trim();
            const down = direction === 'to bottom' || direction === '180deg';
            if (!down && direction !== 'to top' && direction !== '0deg') return null;
            const stop = down ? parts[0] : parts[parts.length - 1];
            return stop ? rgba(stop.trim().replace(/(\s+-?[\d.]+(%|px))+$/, '')) : null;
        }

        // What a pinned element paints that hit-testing skips: layers set to ignore the pointer,
        // such as a scrim of blurs and a fading tint laid behind a bar, and its pseudo-elements.
        // Hit-testing leaves out what is not visible, so this does too. Only the first 60 descendants
        // are walked, one at a time: a pinned app shell can hold the whole page.
        function hiddenLayers(element, x) {
            const layers = [];
            const walker = document.createTreeWalker(element, NodeFilter.SHOW_ELEMENT);
            for (let child = walker.nextNode(), walked = 1; child && walked <= 60; child = walker.nextNode(), walked++) {
                const style = getComputedStyle(child);
                if (style.visibility === 'hidden') continue;
                if (style.pointerEvents !== 'none' || (style.position !== 'absolute' && style.position !== 'fixed')) continue;
                const box = child.getBoundingClientRect();
                if (box.left <= x && box.right >= x && box.top <= 1 && box.bottom - Math.max(box.top, 0) >= 12)
                    layers.push([child, style, null]);
            }
            const width = element.getBoundingClientRect().width;
            for (const pseudo of ['::before', '::after']) {
                const style = getComputedStyle(element, pseudo);
                if (style.content === 'none' || style.visibility === 'hidden') continue;
                if (style.position !== 'absolute' && style.position !== 'fixed') continue;
                if (parseFloat(style.top) <= 1 && parseFloat(style.height) >= 12 && parseFloat(style.width) >= width * 0.9)
                    layers.push([element, style, pseudo]);
            }
            return layers;
        }

        // The elements at one point of the top edge, front to back, looking inside web components:
        // hit-testing the document stops at a component's host, while what paints is within its shadow
        // tree. Closed shadow trees stay closed.
        function stack(x, root = document, depth = 0) {
            const out = [];
            for (const element of root.elementsFromPoint(x, 1)) {
                if (root !== document && element.getRootNode() !== root) continue;
                if (element.shadowRoot && depth < 3) out.push(...stack(x, element.shadowRoot, depth + 1));
                out.push(element);
            }
            return out;
        }

        // What shows at one point of the top edge: the answer, the element that owns it, and whether
        // it stays put. Sites often color a plain column and pin a transparent layer inside it, so the
        // owner also counts as pinned when something visible, pinned and no wider sits in front of it
        // and within it. Within matters: a clear header floating over the page is in front of every card
        // that scrolls beneath it, and would otherwise make each of them count as pinned in turn.
        // `glass` is how opaque a header that blurs its backdrop is by its own tint; see `paint`.
        function at(x) {
            let r = 0, g = 0, b = 0, a = 0, owner = null, glass = null;
            const front = [];
            const result = (answer, element, isPainted) => {
                const own = owner || element, box = own.getBoundingClientRect(), width = box.width;
                // A band runs from one side of the page to the other. Something nearly as wide but inset,
                // a rounded card holding a hero, leaves the page's own background showing beside it and
                // above its corners, and a strip in the card's color would sit on the page like a lid.
                const isBand = box.left <= 4 && box.right >= document.documentElement.clientWidth - 4;
                const stays = isPinned(own) || front.some(e => isPinned(e) && own.contains(e) && e.getBoundingClientRect().width <= width + 2);
                return { answer, width, stays, isPainted, isBand };
            };
            // Adds one layer, `pseudo` naming the pseudo-element when it is one. Returns the result when
            // the walk ends at it.
            const paint = (element, style, isPaintedTag, inFront, pseudo) => {
                const to = fadeTarget(element, pseudo);
                if (pseudo) touchedPseudo.push([element, pseudo]); else touched.add(element);
                const opacity = to.opacity ?? Number(style.opacity);
                if (opacity === 0) return null;
                let color = rgba(to.backgroundColor ?? style.backgroundColor), image = style.backgroundImage;
                const top = image === 'none' ? null : gradientTop(image);
                if (top && color) {
                    const alpha = top[3] + color[3] * (1 - top[3]);
                    color = alpha ? [0, 1, 2].map(i => (top[i] * top[3] + color[i] * color[3] * (1 - top[3])) / alpha).concat(alpha) : color;
                    image = 'none';
                }
                if (isPaintedTag || image !== 'none' || !color) {
                    // Under a header of glass what is behind only shows through faintly, so the header's
                    // own tint is the answer and no picture of the page is needed.
                    if (glass !== null && glass >= 0.5) return result([r, g, b].map(v => Math.round(v / a)).join(','), element, false);
                    const ahead = [r, g, b].map(v => Math.round(v / 8)).join(',') + ',' + a.toFixed(1);
                    return result(unknown(element, style, ahead), element, true);
                }
                const [red, green, blue, alpha] = color;
                // A translucent layer pinned over the whole viewport is a dialog's scrim. The page under it
                // is often made inert, which hides it from hit-testing, so only pixels can tell what shows.
                if (style.position === 'fixed' && alpha * opacity > 0.05 && alpha * opacity < 0.95) {
                    const box = element.getBoundingClientRect();
                    if (box.width >= innerWidth * 0.9 && box.height >= innerHeight * 0.9) {
                        const ahead = [r, g, b].map(v => Math.round(v / 8)).join(',') + ',' + a.toFixed(1);
                        return result(unknown(element, style, ahead), element, true);
                    }
                }
                const cover = (1 - a) * alpha * opacity;
                if (!owner && cover >= 0.5) owner = element;
                if (!owner && inFront && style.visibility !== 'hidden') front.push(element);
                r += cover * red; g += cover * green; b += cover * blue; a += cover;
                return a > 0.99 ? result([r, g, b].map(v => Math.round(v / a)).join(','), element, false) : null;
            };
            for (const element of stack(x)) {
                // A sliver along the edge, a loading bar or an accent stripe, is not the top of the page.
                const box = element.getBoundingClientRect();
                if (box.bottom - Math.max(box.top, 0) < 12) continue;
                const style = getComputedStyle(element);
                const layers = [[element, style, null]];
                if (style.position === 'fixed' || style.position === 'sticky') layers.push(...hiddenLayers(element, x));
                let blurs = false;
                for (const [layer, layerStyle, pseudo] of layers) {
                    blurs ||= blurred.test(layerStyle.backdropFilter || layerStyle.webkitBackdropFilter || '');
                    const isSelf = layerStyle === style;
                    const ended = paint(layer, layerStyle, isSelf && painted.test(element.tagName), isSelf, pseudo);
                    if (ended) return ended;
                }
                if (blurs && glass === null) glass = a;
            }
            // A transparent document canvas still paints in the system color scheme. Blend the
            // accumulated layers into that canvas instead of discarding their visible tint.
            if (a > 0 && owner) {
                const dark = getComputedStyle(document.documentElement).colorScheme.includes('dark')
                    || matchMedia('(prefers-color-scheme: dark)').matches;
                const canvas = dark ? 0 : 255;
                return result([r, g, b].map(v => Math.round(v + (1 - a) * canvas)).join(','), owner, false);
            }
            return null;
        }

        // What is pinned is looked up afresh each time: a header that only becomes fixed once the
        // page scrolls must not stay remembered as loose.
        function read() {
            if (!enabled) return;
            clearTimeout(readTimer);
            readTimer = 0;
            readAt = performance.now();
            pinned = new WeakMap();
            touched = new Set();
            touchedPseudo = [];
            glide = 0;
            // Pinned beats scrolling, since it stays; among equals a band beats a column, then the wider wins.
            let answer = 'page', best = 0;
            for (const f of [0.02, 0.25, 0.5, 0.75, 0.98]) {
                const found = at(Math.floor(innerWidth * f));
                if (!found) continue;
                const isBand = found.isBand;
                if (!isBand && (!found.stays || found.isPainted)) continue;
                const rank = (found.stays ? 2 : 0) + (isBand ? 1 : 0) + found.width / (innerWidth * 10);
                if (rank > best) { answer = found.answer; best = rank; }
            }
            // A page still being parsed has not said what it looks like yet; "page" would only make the
            // strip flash the background before the header arrives.
            if (answer === 'page' && document.readyState === 'loading') answer = last;
            // "~<ms>,<easing>" is the fade the page is making to get there; see `fadeTarget`.
            if (answer !== last) webkit.messageHandlers.tint.postMessage(glide > 20 ? answer + '~' + Math.round(glide) + ',' + easing : answer);
            last = answer;
            watched = [...touched].slice(0, 12);
            watchedPseudo = touchedPseudo.slice(0, 6);
            seen = glance();
        }

        // What a full read would most likely answer differently about, cheaply enough to ask every
        // frame of a scroll: which elements are at the middle of the edge, and the styles of the ones
        // the last read walked through. A running transition counts as one state, not sixty.
        function glance() {
            if (!enabled) return '';
            return document.elementsFromPoint(innerWidth >> 1, 1).slice(0, 6).map(number).join(',') + '|' + watched.map(element => {
                const style = getComputedStyle(element), moving = element.getAnimations ? element.getAnimations().length : 0;
                return (moving ? 'moving' + moving : style.backgroundColor + style.opacity + style.backgroundImage.slice(0, 160)) + style.position;
            }).join('|') + '|' + watchedPseudo.map(([element, pseudo]) => {
                const style = getComputedStyle(element, pseudo);
                return style.backgroundColor + style.opacity;
            }).join('|');
        }

        // Takes a glance every frame for a while, probing when it differs. A load, a click and a route
        // change are followed by changes that come with no event; watching frames catches them in the
        // frame they are drawn, where a timer would be late or early. Frames stop while a page is hidden.
        function watchFrames(ms) {
            if (!enabled) return;
            watchUntil = Math.max(watchUntil, performance.now() + ms);
            if (!frame) frame = requestAnimationFrame(tick);
        }

        function tick() {
            frame = 0;
            if (glance() !== seen) read();
            if (performance.now() < watchUntil) frame = requestAnimationFrame(tick);
        }

        function request(settle) {
            if (!enabled) return;
            if (!readTimer) readTimer = setTimeout(read, Math.max(0, 50 - (performance.now() - readAt)));
            if (!settle) return;
            clearTimeout(settleTimer);
            settleTimer = setTimeout(read, 400);
        }

        // Something happened that pages answer by changing, a little later and with no event.
        function expectChange() {
            if (!enabled) return;
            listenLast();
            watchFrames(1000);
            followUps.forEach(clearTimeout);
            followUps = [300, 1000, 2000, 4000, 8000].map(delay => setTimeout(() => {
                if (document.hidden) missed = true; else read();
            }, delay));
        }

        for (const type of ['scroll', 'resize'])
            addEventListener(type, () => request(true), { passive: true, capture: true });
        // A page restyles its header in its own scroll handler, which has run by the time the frame's
        // animation callbacks do. Probing then, only if a glance says something changed, lets the
        // strip change in the same frame as the header rather than up to a tenth of a second later.
        // Frame callbacks run in the order they were asked for, and many pages restyle their header from a
        // frame callback of their own, asked for in their scroll handler. A glance asked for before theirs
        // would look before they changed anything and see the change a frame late, so this listener is
        // moved to the end of the queue whenever the page may have added listeners, and glances go on for
        // a moment after each scroll, which also catches what intersection observers change.
        const afterScroll = () => watchFrames(150);
        function listenLast() {
            removeEventListener('scroll', afterScroll);
            addEventListener('scroll', afterScroll, { passive: true });
        }
        listenLast();
        document.addEventListener('scroll', afterScroll, { passive: true, capture: true });
        // The start of a transition on something the last read walked through: read where it is going.
        addEventListener('transitionrun', event => {
            if (edgeProperty.test(event.propertyName) && watched.includes(event.target)) read();
        }, true);
        for (const type of ['load', 'DOMContentLoaded'])
            addEventListener(type, () => { request(true); expectChange(); }, { passive: true, capture: true });
        for (const type of ['pointerdown', 'keydown'])
            addEventListener(type, expectChange, { passive: true, capture: true });
        matchMedia('(prefers-color-scheme: dark)').addEventListener('change', expectChange);
        addEventListener('transitionend', event => { if (edgeProperty.test(event.propertyName)) request(false); }, true);
        // A page brought back from the back-forward cache keeps `last`, but the strip starts over.
        addEventListener('pageshow', event => { if (event.persisted) { last = undefined; request(true); expectChange(); } });
        document.addEventListener('visibilitychange', () => {
            if (!document.hidden && missed) { missed = false; expectChange(); }
        });
        globalThis.readPageTint = () => { request(true); expectChange(); };
        globalThis.setPageTintEnabled = on => {
            if (enabled === on) return;
            enabled = on;
            if (on) {
                last = undefined;
                read();
                expectChange();
            } else {
                clearTimeout(readTimer);
                clearTimeout(settleTimer);
                followUps.forEach(clearTimeout);
                cancelAnimationFrame(frame);
                readTimer = settleTimer = frame = 0;
                followUps = [];
            }
        };
        // The first frames of an enabled page decide what the strip shows as it appears.
        if (enabled) watchFrames(3000);
    })();
    """#

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard Store.settings.bool(forKey: "tabs.tint"),
              let report = message.body as? String, message.webView === tab?.built else { return }
        tab?.pageTint.report(report)
    }
}
