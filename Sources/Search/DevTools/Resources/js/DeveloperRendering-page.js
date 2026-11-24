// Rendering's emulations that WebKit's Page domain doesn't have, run in the
// inspected page's own world (DeveloperRenderingPage.swift): Frame
// rendering stats, Layout shift regions, Scrolling performance issues, Highlight ads,
// device mode's touch emulation, Emulate a focused page and the media features WebKit can't override. Called with the media rewriter
// (DeveloperRendering-media.js), the layout-shift estimator
// (DeveloperLayoutShift-estimate.js) and the state:
//
//     {frameStats, layoutShifts, scrollIssues, highlightAds, touch, ads: {domains, selectors}, autoDark, focused, media: {"forced-colors": "active", ...}, noLocalFonts}
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
//   read) and wrapping matchMedia;
// - Disable local fonts takes `local()` out of the src of the same sheets'
//   @font-face rules, and out of string sources given to FontFace;
// - scrolling issues are the blocking (not passive) wheel and touch
//   listeners added since the script went in (so from the page's start
//   after a reload), on* handlers, and fixed backgrounds, which repaint on
//   scroll; WebKit doesn't say which of these really kept scrolling on the
//   main thread;
// - ads are frames (and embeds) loaded from known ad networks, plus the
//   elements Shield hides as ad slots; Chrome tags frames by its ad
//   filter list and the scripts that made them;
// - touch emulation answers `ontouchstart`, `maxTouchPoints` (1) and,
//   through the media rewrite, `pointer: coarse` and `hover: none` as a
//   touch device, and turns the mouse's presses and drags into touch
//   events (a drag the page doesn't take scrolls, a tap still clicks),
//   where Chrome's input is touch from the start; pages that look for touch
//   as they load see it after a reload;
// - automatic dark mode inverts the page's colours (images, video and
//   canvases inverted back) unless the page declares `color-scheme: dark`
//   or is dark already, where Chrome darkens colour by colour.
(rewrite, estimate, state) => {
    const key = Symbol.for("perch.devtools.rendering");
    const isEmpty = (s) => !s || (!s.frameStats && !s.layoutShifts && !s.scrollIssues && !s.highlightAds && !s.touch && !s.autoDark && !s.focused && !s.noLocalFonts &&
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
        FontFace: window.FontFace,
    };
    let current = {frameStats: false, layoutShifts: false, scrollIssues: false, highlightAds: false, ads: null, touch: false, autoDark: false, focused: false, media: {}, noLocalFonts: false};
    const hasMedia = () => Object.keys(current.media).length > 0;
    // Anything the style sheets are rewritten for.
    const rewriting = () => hasMedia() || current.noLocalFonts;

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
    // A box over `r`, in viewport coordinates.
    const rectBox = (r, css) => element("div", "position: fixed; box-sizing: border-box; " +
        "left: " + r.left + "px; top: " + r.top + "px; width: " + r.width + "px; height: " + r.height + "px; " + css);
    // An outline layer (Scrolling performance issues, Highlight ads), redrawn
    // by `draw(root)` while `on()`, after a scroll or resize or every half
    // second. `eager` starts it over when already on and draws it at once.
    const outlineLayer = (name, on, draw) => {
        let layer = null, drawn = 0, dirty = true, watching = false;
        const mark = () => { dirty = true; };
        const frame = (now) => {
            if (!on()) return;
            if (!layer && document.documentElement) layer = overlay(name, "inset: 0;");
            if (layer && mount(layer.host) && (dirty || now - drawn > 500)) {
                dirty = false;
                drawn = now;
                while (layer.root.firstChild) layer.root.firstChild.remove();
                draw(layer.root);
            }
            native.frame(frame);
        };
        return {
            start(eager) {
                if (eager) dirty = true;
                if (watching) return;
                watching = true;
                dirty = true;
                native.listen.call(window, "scroll", mark, {capture: true, passive: true});
                native.listen.call(window, "resize", mark, {passive: true});
                if (eager) frame(native.now()); else native.frame(frame);
            },
            stop() {
                if (!watching) return;
                watching = false;
                native.unlisten.call(window, "scroll", mark, {capture: true});
                native.unlisten.call(window, "resize", mark);
                if (layer) native.remove.call(layer.host);
                layer = null;
            },
        };
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
            const box = rectBox(rect, "background: rgba(68, 138, 255, 0.5); border: 1px solid rgba(26, 115, 232, 0.9); " +
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

    // MARK: Scrolling performance issues

    // Event types whose listeners can hold scrolling until they return.
    const blocking = {wheel: "wheel", mousewheel: "wheel", touchstart: "touch", touchmove: "touch"};
    const isRoot = (target) => target === window || target === document ||
        target === document.documentElement || target === document.body;
    // Each target's blocking listeners, by "type|capture"; and the targets, held weakly.
    const listeners = new WeakMap();
    const targets = [];
    const optionFlag = (options, name) => typeof options === "object" && options !== null && !!options[name];
    const passiveOf = (target, type, options) => {
        if (typeof options === "object" && options !== null && "passive" in options) return !!options.passive;
        // Touch and wheel listeners on the window, document and body are passive unless they say otherwise.
        return isRoot(target);
    };
    EventTarget.prototype.addEventListener = function addEventListener(type, listener, options) {
        const kind = blocking[type];
        if (kind && listener && !passiveOf(this, type, options)) {
            let map = listeners.get(this);
            if (!map) {
                map = new Map();
                listeners.set(this, map);
                targets.push(typeof WeakRef === "function" ? new WeakRef(this) : {deref: () => this});
            }
            const capture = typeof options === "boolean" ? options : optionFlag(options, "capture");
            const slot = type + "|" + capture;
            if (!map.has(slot)) map.set(slot, new Set());
            map.get(slot).add(listener);
        }
        return native.listen.call(this, type, listener, options);
    };
    EventTarget.prototype.removeEventListener = function removeEventListener(type, listener, options) {
        const map = blocking[type] ? listeners.get(this) : null;
        if (map) {
            const capture = typeof options === "boolean" ? options : optionFlag(options, "capture");
            const set = map.get(type + "|" + capture);
            if (set) set.delete(listener);
        }
        return native.unlisten.call(this, type, listener, options);
    };
    const kindsOf = (target) => {
        const kinds = new Set();
        const map = listeners.get(target);
        if (map) for (const [slot, set] of map) if (set.size) kinds.add(blocking[slot.split("|")[0]]);
        if (target.onwheel || target.onmousewheel) kinds.add("wheel");
        if (target.ontouchstart || target.ontouchmove) kinds.add("touch");
        return kinds;
    };
    const handlerLabels = {wheel: "Blocking wheel event handler", touch: "Blocking touch event handler"};
    // What Chrome's overlay would outline now: [{label, rect, page}], `page`
    // for the window's own handlers, which cover the viewport.
    const scrollIssues = () => {
        const found = new Map();
        const note = (target, label) => {
            if (!found.has(target)) found.set(target, []);
            if (!found.get(target).includes(label)) found.get(target).push(label);
        };
        for (const ref of targets) {
            const target = ref.deref();
            if (!target) continue;
            for (const kind of kindsOf(target)) note(isRoot(target) ? window : target, handlerLabels[kind]);
        }
        for (const target of [window, document, document.documentElement, document.body]) {
            if (target) for (const kind of kindsOf(target)) note(window, handlerLabels[kind]);
        }
        const all = document.getElementsByTagName("*");
        for (let i = 0; i < all.length && i < 5000; i++) {
            const element = all[i];
            if (element.localName === "perch-scroll-issues") continue;
            if (element.onwheel || element.onmousewheel) note(element, handlerLabels.wheel);
            if (element.ontouchstart || element.ontouchmove) note(element, handlerLabels.touch);
            const style = getComputedStyle(element);
            if (style.backgroundImage !== "none" && /fixed/.test(style.backgroundAttachment)) note(element, "Repaints on scroll");
        }
        const issues = [];
        for (const [target, labels] of found) {
            const page = target === window;
            const rect = page ? {left: 0, top: 0, width: innerWidth, height: innerHeight} : native.rect.call(target);
            issues.push({label: labels.join(", "), page,
                rect: {left: rect.left, top: rect.top, width: rect.width, height: rect.height}});
        }
        return issues;
    };
    const scrollLayer = outlineLayer("perch-scroll-issues", () => current.scrollIssues, (root) => {
        for (const issue of scrollIssues()) {
            const r = issue.rect;
            if (r.width <= 0 || r.height <= 0 || r.top + r.height < 0 || r.top > innerHeight) continue;
            const box = rectBox(r, "background: rgba(0, 128, 128, 0.18); border: 1px solid rgba(0, 128, 128, 0.85);");
            const label = element("div", "position: absolute; left: 0; top: 0; max-width: 100%; overflow: hidden; " +
                "white-space: nowrap; text-overflow: ellipsis; font: 11px/1.4 -apple-system, system-ui, sans-serif; " +
                "color: #fff; background: rgba(0, 128, 128, 0.9); padding: 1px 4px;", issue.label);
            native.append.call(box, label);
            native.append.call(root, box);
        }
    });

    // MARK: Highlight ads

    const adHost = (url, domains) => {
        let host = "";
        try { host = new URL(url, location.href).hostname; } catch { return false; }
        return domains.some((d) => host === d || host.endsWith("." + d));
    };
    // What Highlight ads outlines now: [{rect}].
    const adElements = () => {
        const ads = current.ads || {};
        const domains = Array.isArray(ads.domains) ? ads.domains : [];
        const found = new Set();
        for (const frame of document.querySelectorAll("iframe, frame, embed, object")) {
            const url = frame.src || frame.data || "";
            if (url && adHost(url, domains)) found.add(frame);
        }
        for (const selector of Array.isArray(ads.selectors) ? ads.selectors : []) {
            try { for (const element of document.querySelectorAll(selector)) found.add(element); } catch {}
        }
        // An ad inside another ad is the same ad.
        const outer = Array.from(found).filter((e) => {
            for (let p = e.parentElement; p; p = p.parentElement) if (found.has(p)) return false;
            return true;
        });
        const shown = [];
        for (const e of outer) {
            const r = native.rect.call(e);
            if (r.width > 0 && r.height > 0) shown.push({tag: e.localName, rect: {left: r.left, top: r.top, width: r.width, height: r.height}});
        }
        return shown;
    };
    const adLayer = outlineLayer("perch-ad-highlights", () => current.highlightAds, (root) => {
        for (const ad of adElements()) {
            const r = ad.rect;
            if (r.top + r.height < 0 || r.top > innerHeight) continue;
            native.append.call(root, rectBox(r, "background: rgba(255, 0, 0, 0.3); border: 1px solid rgba(255, 0, 0, 0.9);"));
        }
    });

    // MARK: Touch emulation

    const touchGlobals = [];
    const touchHandlers = [];
    const pointsDescriptor = Object.getOwnPropertyDescriptor(Navigator.prototype, "maxTouchPoints");
    const handlerNames = ["ontouchstart", "ontouchmove", "ontouchend", "ontouchcancel"];
    const handlerHosts = () => [window, Document.prototype, HTMLElement.prototype, SVGElement.prototype];
    const handlers = new WeakMap();
    class Touch {
        constructor(init) {
            if (!init || !init.target) throw new TypeError("Failed to construct 'Touch': target is required.");
            this.identifier = init.identifier || 0;
            this.target = init.target;
            for (const k of ["clientX", "clientY", "screenX", "screenY", "pageX", "pageY"]) this[k] = init[k] || 0;
            this.radiusX = init.radiusX ?? 1;
            this.radiusY = init.radiusY ?? 1;
            this.rotationAngle = init.rotationAngle || 0;
            this.force = init.force ?? 1;
        }
    }
    const touchList = (touches) => {
        const list = Array.from(touches || []);
        Object.defineProperty(list, "item", {value: (i) => list[i] || null});
        return Object.freeze(list);
    };
    class TouchEvent extends UIEvent {
        constructor(type, init = {}) {
            super(type, init);
            const lists = {touches: touchList(init.touches), targetTouches: touchList(init.targetTouches),
                changedTouches: touchList(init.changedTouches)};
            for (const k of ["touches", "targetTouches", "changedTouches"]) Object.defineProperty(this, k, {get: () => lists[k]});
            for (const k of ["altKey", "ctrlKey", "metaKey", "shiftKey"]) Object.defineProperty(this, k, {get: () => !!init[k]});
        }
    }
    const handlerProperty = (name) => ({
        configurable: true, enumerable: true,
        get() { return (handlers.get(this) || {})[name] || null; },
        set(value) {
            const own = handlers.get(this) || {};
            const type = name.slice(2);
            if (own[name]) native.unlisten.call(this, type, own[name]);
            own[name] = typeof value === "function" ? value : null;
            if (own[name]) native.listen.call(this, type, own[name]);
            handlers.set(this, own);
        },
    });
    let pressed = null;
    let swallowClick = false;
    const touchAt = (e, target) => new Touch({identifier: 0, target, clientX: e.clientX, clientY: e.clientY,
        screenX: e.screenX, screenY: e.screenY, pageX: e.pageX, pageY: e.pageY});
    // Dispatches a touch event like the mouse event `e`; true when the page prevented it.
    const fireTouch = (type, e, target, down) => {
        const touch = touchAt(e, target);
        const event = new TouchEvent(type, {bubbles: true, cancelable: true, composed: true, view: window,
            touches: down ? [touch] : [], targetTouches: down ? [touch] : [], changedTouches: [touch],
            altKey: e.altKey, ctrlKey: e.ctrlKey, metaKey: e.metaKey, shiftKey: e.shiftKey});
        return !target.dispatchEvent(event);
    };
    const scrollerOf = (target) => {
        for (let el = target instanceof Element ? target : null; el; el = el.parentElement) {
            const style = getComputedStyle(el);
            if (/(auto|scroll)/.test(style.overflowY + style.overflowX) &&
                (el.scrollHeight > el.clientHeight || el.scrollWidth > el.clientWidth)) return el;
        }
        return document.scrollingElement || document.documentElement;
    };
    const editable = (target) => target instanceof Element &&
        !!target.closest("input, textarea, select, option, label, [contenteditable=''], [contenteditable=true]");
    const mute = (e) => { native.stop.call(e); };
    const onDown = (e) => {
        if (!current.touch || !e.isTrusted || e.button !== 0) return;
        mute(e);
        const target = e.target;
        pressed = {target, x: e.clientX, y: e.clientY, lastX: e.clientX, lastY: e.clientY, moved: false,
            scroller: scrollerOf(target), prevented: fireTouch("touchstart", e, target, true)};
        if (pressed.prevented || !editable(target)) e.preventDefault();
    };
    const onMove = (e) => {
        if (!current.touch || !e.isTrusted) return;
        if (!pressed) return;
        mute(e);
        e.preventDefault();
        if (Math.abs(e.clientX - pressed.x) + Math.abs(e.clientY - pressed.y) > 6) pressed.moved = true;
        const prevented = fireTouch("touchmove", e, pressed.target, true);
        if (!prevented && !pressed.prevented && pressed.scroller) {
            pressed.scroller.scrollBy(pressed.lastX - e.clientX, pressed.lastY - e.clientY);
        }
        pressed.lastX = e.clientX;
        pressed.lastY = e.clientY;
    };
    const onUp = (e) => {
        if (!current.touch || !e.isTrusted || !pressed) return;
        mute(e);
        const was = pressed;
        pressed = null;
        const prevented = fireTouch("touchend", e, was.target, false);
        if (prevented || was.prevented || was.moved) { swallowClick = true; return; }
        // A tap: the compatibility mouse events a touch screen sends, then the click.
        const init = {bubbles: true, cancelable: true, composed: true, view: window, clientX: e.clientX,
            clientY: e.clientY, screenX: e.screenX, screenY: e.screenY, button: 0, detail: 1};
        was.target.dispatchEvent(new MouseEvent("mousedown", {...init, buttons: 1}));
        was.target.dispatchEvent(new MouseEvent("mouseup", init));
    };
    const onClick = (e) => {
        if (!current.touch || !e.isTrusted || !swallowClick) return;
        swallowClick = false;
        mute(e);
        e.preventDefault();
    };
    const pointer = "url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='24' height='24'%3E" +
        "%3Ccircle cx='12' cy='12' r='10' fill='rgba(128,128,128,0.45)' stroke='rgba(80,80,80,0.8)'/%3E%3C/svg%3E\") 12 12, auto";
    const mouseHandlers = [["mousedown", onDown], ["mousemove", onMove], ["mouseup", onUp], ["click", onClick]];
    let touchStyle = null;
    let touching = false;
    const startTouch = () => {
        if (!touchStyle && document.documentElement) {
            touchStyle = native.create.call(document, "style");
            touchStyle.setAttribute("data-perch-touch", "");
            touchStyle.textContent = "html, html * { cursor: " + pointer + " !important; }";
        }
        if (touchStyle && !touchStyle.isConnected && document.documentElement) native.append.call(document.documentElement, touchStyle);
        if (touching) return;
        touching = true;
        if (typeof window.TouchEvent === "undefined") {
            for (const [name, value] of [["Touch", Touch], ["TouchEvent", TouchEvent]]) {
                Object.defineProperty(window, name, {value, configurable: true, writable: true});
                touchGlobals.push(name);
            }
            for (const host of handlerHosts()) {
                for (const name of handlerNames) {
                    if (name in host) continue;
                    Object.defineProperty(host, name, handlerProperty(name));
                    touchHandlers.push([host, name]);
                }
            }
        }
        Object.defineProperty(Navigator.prototype, "maxTouchPoints", {configurable: true, enumerable: true, get: () => 1});
        for (const [type, handler] of mouseHandlers) native.listen.call(window, type, handler, true);
        if (!touchStyle) native.listen.call(document, "DOMContentLoaded", startTouch, {once: true});
    };
    const stopTouch = () => {
        if (touchStyle) native.remove.call(touchStyle);
        if (!touching) return;
        touching = false;
        pressed = null;
        for (const name of touchGlobals.splice(0)) delete window[name];
        for (const [host, name] of touchHandlers.splice(0)) delete host[name];
        if (pointsDescriptor) Object.defineProperty(Navigator.prototype, "maxTouchPoints", pointsDescriptor);
        for (const [type, handler] of mouseHandlers) native.unlisten.call(window, type, handler, true);
    };

    // MARK: Automatic dark mode

    // Media gets the page's filter undone exactly: hue-rotate(180deg) is its
    // own inverse, so the reverse order cancels it.
    const darkCSS = "html { filter: invert(1) hue-rotate(180deg) !important; }\n" +
        "img, video, canvas, iframe, embed, object, picture > source, [style*='background-image'] " +
        "{ filter: hue-rotate(180deg) invert(1) !important; }";
    let darkStyle = null;
    let darkTimer = null;
    const luminance = (color) => {
        const parts = /rgba?\(([^)]+)\)/.exec(color || "");
        if (!parts) return null;
        const [r, g, b, a = 1] = parts[1].split(/[ ,/]+/).filter(Boolean).map(Number);
        if (a === 0) return null;
        return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255;
    };
    // A page with its own dark theme is left as it is, as Chrome leaves it.
    const alreadyDark = () => {
        const root = document.documentElement;
        if (!root) return false;
        if (/\bdark\b/.test(getComputedStyle(root).colorScheme || "")) return true;
        const meta = document.querySelector('meta[name="color-scheme" i]');
        if (meta && /\bdark\b/.test(meta.getAttribute("content") || "")) return true;
        for (const element of [root, document.body]) {
            if (!element) continue;
            const light = luminance(getComputedStyle(element).backgroundColor);
            if (light !== null) return light < 0.4;
        }
        return false;
    };
    const syncDark = () => {
        const wanted = current.autoDark && document.documentElement && !alreadyDark();
        if (wanted) {
            if (!darkStyle) {
                darkStyle = native.create.call(document, "style");
                darkStyle.setAttribute("data-perch-auto-dark", "");
                darkStyle.textContent = darkCSS;
            }
            mount(darkStyle);
        } else if (darkStyle && darkStyle.isConnected) {
            native.remove.call(darkStyle);
        }
    };
    const startDark = () => {
        syncDark();
        if (darkTimer) return;
        // The page's own styles and the emulated preference arrive after the script.
        darkTimer = setInterval(syncDark, 500);
        for (const type of ["DOMContentLoaded", "load"]) native.listen.call(document, type, syncDark, true);
    };
    const stopDark = () => {
        if (darkTimer) clearInterval(darkTimer);
        darkTimer = null;
        for (const type of ["DOMContentLoaded", "load"]) native.unlisten.call(document, type, syncDark, true);
        if (darkStyle) native.remove.call(darkStyle);
        darkStyle = null;
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
    // MARK: Local fonts

    // A src list without its local() sources; none left fails to load, as
    // Chrome's skipped local() does.
    const withoutLocal = (src) => {
        const parts = [];
        let depth = 0, quote = "", start = 0;
        for (let i = 0; i < src.length; i++) {
            const c = src[i];
            if (quote) { if (c === "\\") i++; else if (c === quote) quote = ""; continue; }
            if (c === '"' || c === "'") quote = c;
            else if (c === "(") depth++;
            else if (c === ")") depth--;
            else if (c === "," && depth === 0) { parts.push(src.slice(start, i)); start = i + 1; }
        }
        parts.push(src.slice(start));
        const kept = parts.map((part) => part.trim()).filter((part) => part && !/^local\s*\(/i.test(part));
        return kept.length ? kept.join(", ") : 'url("data:font/woff2;base64,")';
    };
    // Each @font-face rule changed, with its src as the page wrote it.
    const fontTouched = new Map();
    const rewriteFontFace = (rule) => {
        const style = rule.style;
        if (!style) return;
        const original = fontTouched.has(rule) ? fontTouched.get(rule) : style.getPropertyValue("src");
        if (!original) return;
        const wanted = current.noLocalFonts ? withoutLocal(original) : original;
        if (style.getPropertyValue("src") === wanted) return;
        try { style.setProperty("src", wanted); } catch { return; }
        if (wanted === original) fontTouched.delete(rule);
        else fontTouched.set(rule, original);
    };
    const restoreFonts = () => {
        for (const [rule, original] of Array.from(fontTouched)) {
            try { rule.style.setProperty("src", original); } catch {}
        }
        fontTouched.clear();
    };
    if (typeof native.FontFace === "function") {
        const Wrapped = function FontFace(family, source, descriptors) {
            const src = typeof source === "string" && current.noLocalFonts ? withoutLocal(source) : source;
            return Reflect.construct(native.FontFace, [family, src, descriptors], new.target || Wrapped);
        };
        Wrapped.prototype = native.FontFace.prototype;
        Object.setPrototypeOf(Wrapped, native.FontFace);
        try { window.FontFace = Wrapped; } catch {}
    }

    const walkRules = (rules) => {
        for (const rule of Array.from(rules)) {
            if (typeof CSSFontFaceRule !== "undefined" && rule instanceof CSSFontFaceRule) { rewriteFontFace(rule); continue; }
            if (rule.media && (rule instanceof CSSMediaRule || rule instanceof CSSImportRule)) rewriteList(rule.media);
            if (rule instanceof CSSImportRule && rule.styleSheet) walkSheet(rule.styleSheet);
            else if (rule.cssRules) walkRules(rule.cssRules);
        }
    };
    const walkSheet = (sheet) => {
        if (hasMedia() || touched.has(sheet.media)) rewriteList(sheet.media);
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
        if (scheduled || !rewriting()) return;
        scheduled = true;
        native.later(() => { scheduled = false; if (rewriting()) scan(); }, 0);
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
            const n = next || {};
            const media = n.media && typeof n.media === "object" ? n.media : {};
            current = {frameStats: !!n.frameStats, layoutShifts: !!n.layoutShifts, scrollIssues: !!n.scrollIssues,
                autoDark: !!n.autoDark, highlightAds: !!n.highlightAds, ads: n.ads || null, touch: !!n.touch,
                focused: !!n.focused, media, noLocalFonts: !!n.noLocalFonts};
            if (current.frameStats) startMeter(); else stopMeter();
            if (current.scrollIssues) scrollLayer.start(false); else scrollLayer.stop();
            if (current.autoDark) startDark(); else stopDark();
            if (current.highlightAds) adLayer.start(true); else adLayer.stop();
            if (current.touch) startTouch(); else stopTouch();
            if (current.layoutShifts) startShifts(); else stopShifts();
            if (!hasMedia()) restoreMedia();
            if (!current.noLocalFonts) restoreFonts();
            if (rewriting()) {
                // A list rewritten for other values is rewritten from what the page wrote.
                for (const [list, {original}] of Array.from(touched)) touched.set(list, {original, wanted: null});
                scan();
                watch(true);
            } else {
                watch(false);
            }
            return true;
        },
        /// What Scrolling performance issues outlines now, for tests.
        scrollIssues,
        /// What Highlight ads outlines now, for tests.
        adElements,
    });
    Object.defineProperty(window, key, {value: api});
    return api.apply(state);
}
