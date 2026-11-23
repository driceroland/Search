// Rendering's emulations that WebKit's Page domain doesn't have, run in the
// inspected page's own world (DeveloperRenderingPage.swift): Frame
// rendering stats, Layout shift regions, Emulate a focused page and the
// media features WebKit can't override. Called with the media rewriter
// (DeveloperRendering-media.js), the layout-shift estimator
// (DeveloperLayoutShift-estimate.js) and the state:
//
//     {frameStats, layoutShifts, focused, media: {"forced-colors": "active", ...}}
//
// The first call with anything on installs it once, under a symbol; each
// call after that applies the state it is given, and an empty one puts the
// page back (the focus and matchMedia hooks stay, passing straight through).
// All of it is approximate:
// - the meter counts requestAnimationFrame callbacks, not compositor frames;
// - shifts are the page's layout-shift entries where WebKit has them, else
//   the estimator's, flashed where the moved elements are now;
// - a focused page answers hasFocus() and visibilityState as focused and
//   swallows the window's blur, focusout and visibilitychange, but `:focus`
//   styles still drop when the window loses focus;
// - media features are emulated by rewriting the media text of the
//   document's style sheets (not cross-origin ones, whose rules can't be
//   read) and wrapping matchMedia.
(rewrite, estimate, state) => {
    const key = Symbol.for("perch.devtools.rendering");
    const isEmpty = (s) => !s || (!s.frameStats && !s.layoutShifts && !s.focused &&
        Object.keys(s.media || {}).length === 0);
    if (window[key]) return window[key].apply(state);
    if (isEmpty(state)) return true;

    const native = {
        hasFocus: Document.prototype.hasFocus,
        matchMedia: window.matchMedia,
        stop: Event.prototype.stopImmediatePropagation,
        listen: EventTarget.prototype.addEventListener,
        unlisten: EventTarget.prototype.removeEventListener,
        frame: window.requestAnimationFrame.bind(window),
        later: setTimeout.bind(window),
        now: performance.now.bind(performance),
        create: Document.prototype.createElement,
        attachShadow: Element.prototype.attachShadow,
        append: Node.prototype.appendChild,
        remove: Element.prototype.remove,
        rect: Element.prototype.getBoundingClientRect,
        Observer: MutationObserver,
    };
    let current = {frameStats: false, layoutShifts: false, focused: false, media: {}};
    const hasMedia = () => Object.keys(current.media).length > 0;

    // An element of our own, outside the page's styles: a fixed, unclickable
    // host with a closed shadow root.
    const overlay = (name, css) => {
        const host = native.create.call(document, name);
        host.style.cssText = "all: initial; position: fixed; pointer-events: none; z-index: 2147483647; " + css;
        const root = native.attachShadow.call(host, {mode: "closed"});
        return {host, root};
    };
    const element = (tag, css, text) => {
        const made = native.create.call(document, tag);
        made.style.cssText = css;
        if (text !== undefined) made.textContent = text;
        return made;
    };
    const mount = (host) => {
        const root = document.documentElement;
        if (!root) return false;
        if (!host.isConnected) native.append.call(root, host);
        return true;
    };

    // MARK: Emulate a focused page

    Document.prototype.hasFocus = function hasFocus() {
        return current.focused || native.hasFocus.call(this);
    };
    for (const [name, focused] of [["visibilityState", "visible"], ["hidden", false]]) {
        const descriptor = Object.getOwnPropertyDescriptor(Document.prototype, name);
        if (!descriptor || typeof descriptor.get !== "function") continue;
        Object.defineProperty(Document.prototype, name, {
            configurable: true, enumerable: descriptor.enumerable,
            get() { return current.focused ? focused : descriptor.get.call(this); },
        });
    }
    // A blur or focusout inside a page whose window still has focus is the
    // page's own, and goes through.
    const swallow = (event) => {
        if (!current.focused) return;
        if (event.target !== window && event.target !== document && native.hasFocus.call(document)) return;
        native.stop.call(event);
    };
    for (const type of ["blur", "focusout", "visibilitychange"]) native.listen.call(window, type, swallow, true);

    // MARK: Frame rendering stats

    let meter = null;
    const buildMeter = () => {
        const {host, root} = overlay("perch-frame-meter", "top: 8px; left: 8px;");
        const box = element("div", "font: 11px/1.35 -apple-system, system-ui, sans-serif; color: #fff; " +
            "background: rgba(32, 33, 36, 0.86); border-radius: 6px; padding: 6px 8px; width: 180px; " +
            "box-shadow: 0 1px 4px rgba(0, 0, 0, 0.3);");
        const title = element("div", "color: rgba(255, 255, 255, 0.7);", "Frame rate (approximate)");
        const rate = element("div", "font-size: 15px; font-weight: 600; font-variant-numeric: tabular-nums;", "– fps");
        const detail = element("div", "color: rgba(255, 255, 255, 0.7); font-variant-numeric: tabular-nums;", "");
        const canvas = element("canvas", "display: block; width: 180px; height: 32px; margin-top: 4px;");
        canvas.width = 360;
        canvas.height = 64;
        for (const part of [title, rate, detail, canvas]) native.append.call(box, part);
        native.append.call(root, box);
        return {host, rate, detail, canvas};
    };
    const drawMeter = (now) => {
        const view = meter.view;
        const recent = meter.times.filter((time) => now - time <= 1000);
        meter.times = recent;
        const intervals = meter.intervals;
        // The display's own interval: the shortest seen lately, kept to sane rates.
        const expected = Math.min(50, Math.max(4, Math.min(...intervals.slice(-120), 1000 / 60)));
        let dropped = 0;
        for (const interval of intervals.slice(-recent.length)) dropped += Math.max(0, Math.round(interval / expected) - 1);
        const rate = recent.length + " fps";
        if (view.rate.textContent !== rate) view.rate.textContent = rate;
        const last = intervals.length ? intervals[intervals.length - 1].toFixed(1) + " ms" : "";
        const text = dropped + " of " + (recent.length + dropped) + " frames dropped" + (last ? " · " + last : "");
        if (view.detail.textContent !== text) view.detail.textContent = text;
        const context = view.canvas.getContext("2d");
        if (!context) return;
        const width = view.canvas.width, height = view.canvas.height;
        context.clearRect(0, 0, width, height);
        const bars = intervals.slice(-60);
        const bar = width / 60;
        const ceiling = expected * 4;
        bars.forEach((interval, index) => {
            const tall = Math.max(2, Math.min(1, interval / ceiling) * height);
            context.fillStyle = interval > expected * 1.5 ? "#f28b82" : "#81c995";
            context.fillRect(index * bar, height - tall, Math.max(1, bar - 1), tall);
        });
    };
    const tick = (now) => {
        if (!meter || !current.frameStats) return;
        if (!meter.view && document.documentElement) meter.view = buildMeter();
        if (meter.view && mount(meter.view.host)) {
            if (meter.previous !== null) {
                meter.intervals.push(now - meter.previous);
                if (meter.intervals.length > 240) meter.intervals.splice(0, meter.intervals.length - 240);
            }
            meter.times.push(now);
            drawMeter(now);
        }
        meter.previous = now;
        native.frame(tick);
    };
    const startMeter = () => {
        if (meter) return;
        meter = {view: null, previous: null, times: [], intervals: []};
        native.frame(tick);
    };
    const stopMeter = () => {
        if (meter && meter.view) native.remove.call(meter.view.host);
        meter = null;
    };

    // MARK: Layout shift regions

    const observed = typeof PerformanceObserver === "function" &&
        (PerformanceObserver.supportedEntryTypes || []).includes("layout-shift");
    let shiftLayer = null;
    let shiftObserver = null;
    let estimating = false;
    const flash = (rects) => {
        if (!current.layoutShifts) return;
        const boxes = rects.filter((rect) => rect && rect.width > 0 && rect.height > 0);
        if (!boxes.length) return;
        if (!shiftLayer) shiftLayer = overlay("perch-layout-shifts", "inset: 0;");
        if (!mount(shiftLayer.host)) return;
        for (const rect of boxes) {
            const box = element("div", "position: fixed; box-sizing: border-box; " +
                "left: " + rect.left + "px; top: " + rect.top + "px; width: " + rect.width + "px; height: " + rect.height + "px; " +
                "background: rgba(68, 138, 255, 0.5); border: 1px solid rgba(26, 115, 232, 0.9); " +
                "opacity: 1; transition: opacity 0.4s ease-out 0.4s;");
            native.append.call(shiftLayer.root, box);
            native.frame(() => native.frame(() => { box.style.opacity = "0"; }));
            native.later(() => native.remove.call(box), 1000);
        }
    };
    const startShifts = () => {
        if (observed) {
            if (shiftObserver) return;
            shiftObserver = new PerformanceObserver((list) => {
                for (const entry of list.getEntries()) {
                    if (entry.hadRecentInput) continue;
                    flash((entry.sources || []).map((source) => source.currentRect));
                }
            });
            try { shiftObserver.observe({type: "layout-shift"}); } catch { shiftObserver = null; }
            return;
        }
        if (estimating) return;
        estimating = true;
        estimate({
            active: () => current.layoutShifts,
            onShift: (shift) => flash(shift.elements.map((moved) => native.rect.call(moved))),
            ended: () => { estimating = false; },
        });
    };
    const stopShifts = () => {
        if (shiftObserver) shiftObserver.disconnect();
        shiftObserver = null;
        if (shiftLayer) native.remove.call(shiftLayer.host);
        shiftLayer = null;
    };

    // MARK: Media features

    // Each media list changed, with its text as the page wrote it.
    const touched = new Map();
    const rewriteList = (list) => {
        if (!list || typeof list.mediaText !== "string") return;
        const known = touched.get(list);
        const original = known ? known.original : list.mediaText;
        const wanted = hasMedia() ? rewrite(original, current.media) : original;
        if (known ? known.wanted === wanted : wanted === original) return;
        try { list.mediaText = wanted; } catch { return; }
        if (wanted === original) touched.delete(list);
        else touched.set(list, {original, wanted});
    };
    const walkRules = (rules) => {
        for (const rule of Array.from(rules)) {
            if (rule.media && (rule instanceof CSSMediaRule || rule instanceof CSSImportRule)) rewriteList(rule.media);
            if (rule instanceof CSSImportRule && rule.styleSheet) walkSheet(rule.styleSheet);
            else if (rule.cssRules) walkRules(rule.cssRules);
        }
    };
    const walkSheet = (sheet) => {
        rewriteList(sheet.media);
        let rules = null;
        try { rules = sheet.cssRules; } catch { return; }
        if (rules) walkRules(rules);
    };
    const scan = () => {
        for (const sheet of Array.from(document.styleSheets)) walkSheet(sheet);
        for (const sheet of Array.from(document.adoptedStyleSheets || [])) walkSheet(sheet);
    };
    const restoreMedia = () => {
        for (const [list, {original}] of Array.from(touched)) {
            try { list.mediaText = original; } catch {}
        }
        touched.clear();
    };
    let scheduled = false;
    const rescan = () => {
        if (scheduled || !hasMedia()) return;
        scheduled = true;
        native.later(() => { scheduled = false; if (hasMedia()) scan(); }, 0);
    };
    const watcher = new native.Observer(rescan);
    let watching = false;
    const watch = (on) => {
        if (on === watching) return;
        watching = on;
        if (on) {
            watcher.observe(document, {childList: true, subtree: true});
            for (const type of ["load", "DOMContentLoaded"]) native.listen.call(document, type, rescan, true);
        } else {
            watcher.disconnect();
            for (const type of ["load", "DOMContentLoaded"]) native.unlisten.call(document, type, rescan, true);
        }
    };
    window.matchMedia = function matchMedia(query) {
        if (!hasMedia()) return native.matchMedia.call(window, query);
        const text = String(query);
        const list = native.matchMedia.call(window, rewrite(text, current.media));
        try { Object.defineProperty(list, "media", {value: text, configurable: true}); } catch {}
        return list;
    };

    const api = Object.freeze({
        apply(next) {
            const media = next && next.media && typeof next.media === "object" ? next.media : {};
            current = {frameStats: !!(next && next.frameStats), layoutShifts: !!(next && next.layoutShifts),
                focused: !!(next && next.focused), media};
            if (current.frameStats) startMeter(); else stopMeter();
            if (current.layoutShifts) startShifts(); else stopShifts();
            if (hasMedia()) {
                // A list rewritten for other values is rewritten from what the page wrote.
                for (const [list, {original}] of Array.from(touched)) touched.set(list, {original, wanted: null});
                scan();
                watch(true);
            } else {
                watch(false);
                restoreMedia();
            }
            return true;
        },
    });
    Object.defineProperty(window, key, {value: api});
    return api.apply(state);
}
