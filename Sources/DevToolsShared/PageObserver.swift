import Foundation

// The one script that watches a page load, shared by Lighthouse, the
// Performance panel's local metrics and a recording's Timings and Layout
// shifts tracks. A user script of the package's own world (never the
// page's), main frame, at document start, put in only while one of those
// is open on the tab. It only watches: what it learns is on
// window.__searchDeveloperLoad, in that world, which the page can't see.
//
// It watches the PerformanceObserver entries this WebKit has, all buffered
// so what came before it is seen too: paint for FCP, largest-contentful-
// paint for LCP, event (over 16 ms) and first-input for INP, layout-shift
// for CLS or, without layout-shift entries, the estimator below; errors
// the page threw; and the main thread's blocking as gaps in a timer loop.
//
// The estimator, where WebKit has no layout-shift entries: each sample
// takes the boxes of up to 1500 elements in document coordinates (so
// scrolling isn't a shift); an element whose top-left moved since the last
// sample is unstable. A sample's score is the impact fraction (the union of
// the unstable elements' old and new boxes, in the viewport, over its area,
// on a 100 × 100 grid) times the distance fraction (the largest move over
// the viewport's larger side); shifts within 500 ms of input are left out.
// Sampled on a 50 ms timer rather than animation frames, which an occluded
// tab doesn't get, for as long as `active()` says.

enum PageObserver {
    static let source = ##"""
(() => {
    const estimateLayoutShifts = (options) => {
    const active = options.active;
    const onShift = options.onShift;
    const ended = options.ended || (() => {});
    const now = performance.now.bind(performance);
    const later = setTimeout.bind(window);
    const rectOf = Element.prototype.getBoundingClientRect;
    const byTag = Element.prototype.getElementsByTagName;
    const HTML = window.HTMLElement;
    const offset = (name) => Object.getOwnPropertyDescriptor(HTML.prototype, name).get;
    const [offsetLeft, offsetTop, offsetWidth, offsetHeight, offsetParent] =
        ["offsetLeft", "offsetTop", "offsetWidth", "offsetHeight", "offsetParent"].map(offset);
    // An element's layout box, transforms left out: document coordinates,
    // or the viewport's for a fixed element (whose chain ends short of the
    // body), as that's where it stays put. Other elements (SVG) by their
    // bounding box.
    const boxOf = (element, sx, sy) => {
        if (!(element instanceof HTML)) {
            const rect = rectOf.call(element);
            return {x: rect.left + sx, y: rect.top + sy, w: rect.width, h: rect.height, vx: rect.left, vy: rect.top};
        }
        let x = 0, y = 0, node = element, last = element;
        while (node) { x += offsetLeft.call(node); y += offsetTop.call(node); last = node; node = offsetParent.call(node); }
        // A chain ends at the body, unless it ends at a fixed element.
        const fixed = last !== document.body && last !== document.documentElement;
        return fixed
            ? {x, y, w: offsetWidth.call(element), h: offsetHeight.call(element), vx: x, vy: y}
            : {x, y, w: offsetWidth.call(element), h: offsetHeight.call(element), vx: x - sx, vy: y - sy};
    };
    const listen = EventTarget.prototype.addEventListener;
    const unlisten = EventTarget.prototype.removeEventListener;
    const previous = new WeakMap();
    let lastInput = -Infinity;
    const input = (event) => { if (event.isTrusted) lastInput = now(); };
    const inputs = ["pointerdown", "keydown", "mousedown"];
    for (const type of inputs) listen.call(window, type, input, true);
    const grid = 100;
    const frame = () => {
        if (!active()) {
            for (const type of inputs) unlisten.call(window, type, input, true);
            ended();
            return;
        }
        const width = innerWidth, height = innerHeight;
        const root = document.body || document.documentElement;
        if (root && width > 0 && height > 0) {
            const sx = scrollX, sy = scrollY;
            const moved = [];
            const elements = new Set();
            let distance = 0;
            const all = byTag.call(root, "*");
            for (let i = 0; i < all.length && i < 1500; i++) {
                const element = all[i];
                const current = boxOf(element, sx, sy);
                if (current.w === 0 && current.h === 0) { previous.delete(element); continue; }
                const before = previous.get(element);
                previous.set(element, current);
                if (!before) continue;
                const dx = current.x - before.x, dy = current.y - before.y;
                if (Math.abs(dx) < 1 && Math.abs(dy) < 1) continue;
                // The old box where it would be in today's viewport.
                moved.push([before.x - (current.x - current.vx), before.y - (current.y - current.vy), before.w, before.h],
                           [current.vx, current.vy, current.w, current.h]);
                elements.add(element);
                distance = Math.max(distance, Math.abs(dx), Math.abs(dy));
                if (moved.length >= 200) break;
            }
            if (moved.length && now() - lastInput > 500) {
                const cells = new Uint8Array(grid * grid);
                let covered = 0;
                for (const [x, y, w, h] of moved) {
                    const x0 = Math.max(0, Math.floor(x / width * grid)), x1 = Math.min(grid, Math.ceil((x + w) / width * grid));
                    const y0 = Math.max(0, Math.floor(y / height * grid)), y1 = Math.min(grid, Math.ceil((y + h) / height * grid));
                    for (let gy = y0; gy < y1; gy++) for (let gx = x0; gx < x1; gx++) {
                        if (!cells[gy * grid + gx]) { cells[gy * grid + gx] = 1; covered++; }
                    }
                }
                const value = (covered / (grid * grid)) * Math.min(1, distance / Math.max(width, height));
                if (value > 0) {
                    const sources = [];
                    for (const element of elements) {
                        if (elements.has(element.parentElement)) continue;
                        sources.push(element);
                        if (sources.length >= 5) break;
                    }
                    onShift({value, time: now(), elements: sources});
                }
            }
        }
        later(frame, 50);
    };
    later(frame, 0);
};

    if (window.__searchDeveloperLoad) return true;
    const Observer = window.PerformanceObserver;
    const now = performance.now.bind(performance);
    const entriesByType = performance.getEntriesByType.bind(performance);
    const timeOrigin = performance.timeOrigin;
    const timeStamp = typeof console.timeStamp === "function" ? console.timeStamp.bind(console) : null;
    const started = now();
    const includes = Array.prototype.includes;
    const WeakReference = typeof WeakRef === "function" ? WeakRef : null;
    const deref = WeakReference ? WeakReference.prototype.deref : null;
    const defineProperty = Object.defineProperty;
    const entriesByName = performance.getEntriesByName.bind(performance);
    const isArray = Array.isArray;
    const stringify = JSON.stringify;
    const hasOwn = Object.prototype.hasOwnProperty;
    const apply = Reflect.apply;
    const types = (Observer && Observer.supportedEntryTypes) || [];
    const supports = (type) => includes.call(types, type);
    const hold = (element) => {
        if (!element) return null;
        return WeakReference ? new WeakReference(element) : element;
    };
    const release = (held) => {
        if (!held) return null;
        return deref ? deref.call(held) || null : held;
    };
    const describe = (element) => {
        if (!element || typeof element.localName !== "string") return null;
        let text = element.localName;
        if (element.id) text += "#" + element.id;
        const classes = typeof element.className === "string" ? element.className.trim().split(/\s+/).filter(Boolean) : [];
        for (const name of classes.slice(0, 3)) text += "." + name;
        return text.slice(0, 120);
    };
    const observers = [];
    const observe = (type, extra, callback) => {
        if (!supports(type)) return false;
        try {
            const observer = new Observer((list) => {
                for (const entry of list.getEntries()) {
                    try { callback(entry); } catch (error) {}
                }
            });
            observer.observe(Object.assign({type, buffered: true}, extra));
            observers.push(observer);
            return true;
        } catch (error) {
            return false;
        }
    };

    let stopped = false;
    let held = false;
    let lastRead = now();
    let lcp = null;
    let lcpElement = null;

    // INP as Core Web Vitals counts it: each interaction's longest event,
    // and of them the worst, less one for every 50 interactions.
    let interactionCount = 0;
    const interactionsSeen = new Map();
    const recent = [];
    let shiftLogFrom = 0;
    let worst = [];
    const interaction = (entry) => {
        const id = entry.interactionId;
        if (!id) return;
        // An entry that starts before the page or lasts longer than it has
        // existed can't be real: WebKit gives such durations to events
        // posted with a timestamp from another clock.
        if (!(entry.duration >= 0) || entry.startTime < 0 || entry.startTime + entry.duration > performance.now() + 1000) return;
        const known = interactionsSeen.get(id);
        if (known === undefined) {
            interactionCount += 1;
            if (interactionsSeen.size >= 1000) interactionsSeen.delete(interactionsSeen.keys().next().value);
        }
        if (known !== undefined && known >= entry.duration) return;
        interactionsSeen.set(id, entry.duration);
        const record = {id, name: entry.name, target: hold(entry.target), duration: entry.duration, time: entry.startTime};
        const logged = recent.findIndex((item) => item.id === id);
        if (logged >= 0) recent[logged] = record;
        else {
            recent.push(record);
            if (recent.length > 50) recent.shift();
        }
        worst = worst.filter((item) => item.id !== id);
        worst.push({id, duration: entry.duration, name: entry.name, target: hold(entry.target)});
        worst.sort((a, b) => b.duration - a.duration);
        if (worst.length > 10) worst.length = 10;
    };

    // CLS: the largest session window of shifts (gaps under 1 s, windows
    // at most 5 s), without those right after input. Each shift is kept
    // for the recording's Layout shifts track, with up to five of the
    // elements that moved; the oldest go past 500.
    let cls = 0;
    let windowValue = 0;
    let windowStart = 0;
    let windowLast = 0;
    const shifts = [];
    let shiftBase = 0;
    const shifted = (value, time, elements) => {
        if (windowValue > 0 && time - windowLast < 1000 && time - windowStart < 5000) windowValue += value;
        else { windowValue = value; windowStart = time; }
        windowLast = time;
        if (windowValue > cls) cls = windowValue;
        shifts.push({time, value, elements: elements.slice(0, 5).map(hold)});
        if (shifts.length > 500) { shifts.shift(); shiftBase += 1; }
    };

    // Lighthouse's: first contentful paint, errors the page threw, and the
    // main thread's blocking, as gaps in a zero-delay timer loop over the
    // load's first minute (WebKit has no longtask entries).
    let fcp = null;
    const tasks = [];
    const errors = [];
    observe("paint", {}, (entry) => {
        if (entry.name === "first-contentful-paint" && fcp === null) fcp = entry.startTime;
    });
    const errored = (message, source) => {
        if (errors.length < 50) errors.push([String(message || "").slice(0, 300), String(source || "").slice(0, 300)]);
    };
    window.addEventListener("error", (event) => {
        if (event.target && event.target !== window) {
            errored("Failed to load resource", event.target.src || event.target.href || "");
        } else {
            errored(event.message, event.filename);
        }
    }, true);
    window.addEventListener("unhandledrejection", (event) => {
        const reason = event.reason;
        errored("Unhandled rejection: " + (reason && reason.message ? reason.message : String(reason)), location.href);
    });
    let last = now();
    const tick = () => {
        const at = now();
        const gap = at - last;
        if (gap > 50 && document.visibilityState === "visible") tasks.push([last, gap]);
        last = at;
        if (!stopped && at - started < 60000 && tasks.length < 5000) setTimeout(tick, 0);
    };
    setTimeout(tick, 0);

    const lcpSupported = observe("largest-contentful-paint", {}, (entry) => {
        lcp = entry.renderTime || entry.loadTime || entry.startTime;
        lcpElement = hold(entry.element);
    });
    const eventSupported = observe("event", {durationThreshold: 16}, interaction);
    observe("first-input", {}, interaction);
    const shiftsSupported = observe("layout-shift", {}, (entry) => {
        if (entry.hadRecentInput) return;
        const sources = Array.isArray(entry.sources) ? entry.sources : Array.from(entry.sources || []);
        shifted(entry.value, entry.startTime, sources.map((source) => source && source.node).filter(Boolean));
    });
    // Chrome's Performance extensibility: a mark's or measure's
    // detail.devtools, copied to plain strings (DeveloperPerformanceExtensions
    // checks them). Too long a string, too many properties or too much in
    // all marks the copy oversized, and it's ignored.
    const devtoolsText = (value) => {
        if (typeof value === "string") return value;
        if (typeof value === "number" || typeof value === "boolean") return String(value);
        if (value === null || value === undefined) return undefined;
        try {
            const text = stringify(value);
            return typeof text === "string" ? text : undefined;
        } catch (error) {
            return undefined;
        }
    };
    const copyDevtools = (devtools) => {
        if (!devtools || typeof devtools !== "object" || isArray(devtools)) return null;
        const copy = {};
        let size = 0;
        const keep = (value, limit) => {
            const text = devtoolsText(value);
            if (text === undefined) return undefined;
            size += text.length;
            if (text.length > limit || size > 8192) {
                copy.oversized = true;
                return undefined;
            }
            return text;
        };
        for (const key of ["dataType", "track", "trackGroup", "color", "tooltipText"]) {
            const value = devtools[key];
            if (typeof value !== "string") continue;
            const text = keep(value, key === "tooltipText" ? 1000 : 200);
            if (text !== undefined) copy[key] = text;
        }
        const properties = devtools.properties;
        if (isArray(properties)) {
            if (properties.length > 50) copy.oversized = true;
            const pairs = [];
            for (let index = 0; index < properties.length && index < 50; index += 1) {
                const pair = properties[index];
                if (!isArray(pair) || pair.length < 2) continue;
                const name = keep(pair[0], 200);
                const value = keep(pair[1], 1000);
                if (name !== undefined && value !== undefined) pairs.push([name, value]);
            }
            copy.properties = pairs;
        }
        return copy;
    };
    const devtoolsOf = (entry) => {
        try {
            const detail = entry.detail;
            if (!detail || typeof detail !== "object") return null;
            return copyDevtools(detail.devtools);
        } catch (error) {
            return null;
        }
    };

    let estimating = false;
    const estimate = () => {
        if (shiftsSupported || estimating || stopped) return;
        estimating = true;
        estimateLayoutShifts({
            // Lighthouse's load (its first minute), a recording, or Performance
            // reading in the last 15 s.
            active: () => !stopped && (held || now() - lastRead < 15000 || (!api.lighthouseDone && now() - started < 60000)),
            onShift: (shift) => shifted(shift.value, shift.time, shift.elements),
            ended: () => { estimating = false; },
        });
    };
    estimate();

    const inp = () => {
        if (!worst.length) return null;
        const pick = worst[Math.min(worst.length - 1, Math.floor(interactionCount / 50))];
        return {value: pick.duration, name: pick.name, target: describe(release(pick.target))};
    };

    const api = {
        lighthouseDone: false,
        // What Lighthouse reads as the load ends (LighthouseScripts.metrics).
        get fcp() { return fcp; },
        get lcp() { return lcp; },
        get lcpElement() { return release(lcpElement); },
        lcpSupported,
        get cls() { return cls; },
        get shifts() { return shifts.length + shiftBase; },
        tasks,
        errors,
        // Local metrics, as Performance's landing view shows them.
        read() {
            lastRead = now();
            estimate();
            return {
                url: location.href,
                lcpSupported,
                lcp,
                lcpElement: describe(release(lcpElement)),
                clsEstimated: !shiftsSupported,
                cls,
                inpSupported: eventSupported,
                inp: inp(),
                interactions: interactionCount,
                interactionLog: recent.map((entry) => ({
                    name: entry.name, target: describe(release(entry.target)), duration: entry.duration, time: entry.time,
                })),
                shiftLog: shifts.slice(Math.max(0, shiftLogFrom - shiftBase)).slice(-50).map((shift) => ({
                    time: shift.time, value: shift.value,
                    elements: shift.elements.map((node) => describe(release(node))).filter(Boolean),
                })),
            };
        },
        clearLogs() {
            recent.length = 0;
            shiftLogFrom = shiftBase + shifts.length;
            return true;
        },
        lcpNode() { return release(lcpElement); },
        shiftNode(index, node) {
            const shift = shifts[index - shiftBase];
            return shift ? release(shift.elements[node]) : null;
        },
        // A recording keeps the estimator going while nothing reads.
        hold(value) {
            held = !!value;
            lastRead = now();
            estimate();
            return true;
        },
        // For a recording's Timings and Layout shifts tracks: a timestamp
        // on the timeline to line the page's clock up with WebKit's, then
        // the page's marks, measures, paints, navigation milestones, LCP
        // and shifts, in milliseconds on the page's clock.
        recording() {
            const at = now();
            if (timeStamp) timeStamp("search-sync " + at);
            const entries = [];
            const add = (kind, name, start, end) => {
                if (entries.length < 2000 && typeof start === "number" && isFinite(start)) {
                    entries.push({kind, name: String(name).slice(0, 200), start, end: typeof end === "number" && isFinite(end) ? end : start});
                }
            };
            // Marks and measures with a detail.devtools, for the custom
            // tracks and markers, apart from the plain ones.
            const extensions = [];
            const extend = (kind, entry, devtools) => {
                const start = entry.startTime;
                if (typeof start !== "number" || !isFinite(start)) return;
                const end = kind === "measure" ? start + entry.duration : start;
                extensions.push({kind, name: String(entry.name).slice(0, 200), start, end: isFinite(end) ? end : start, devtools});
            };
            try {
                const marks = [];
                const measures = [];
                for (const entry of entriesByType("mark").slice(-5000)) {
                    const devtools = devtoolsOf(entry);
                    if (devtools) extend("mark", entry, devtools); else marks.push(entry);
                }
                for (const entry of entriesByType("measure").slice(-5000)) {
                    const devtools = devtoolsOf(entry);
                    if (devtools) extend("measure", entry, devtools); else measures.push(entry);
                }
                for (const entry of marks.slice(-500)) add("mark", entry.name, entry.startTime);
                for (const entry of measures.slice(-500)) add("measure", entry.name, entry.startTime, entry.startTime + entry.duration);
                for (const entry of entriesByType("paint")) {
                    if (entry.name === "first-paint") add("FP", "First Paint", entry.startTime);
                    else if (entry.name === "first-contentful-paint") add("FCP", "First Contentful Paint", entry.startTime);
                }
                const navigation = entriesByType("navigation")[0];
                if (navigation) {
                    if (navigation.domContentLoadedEventStart > 0) add("DCL", "DOMContentLoaded event", navigation.domContentLoadedEventStart);
                    if (navigation.loadEventStart > 0) add("L", "Onload event", navigation.loadEventStart);
                }
            } catch (error) {}
            if (lcp !== null) add("LCP", "Largest Contentful Paint", lcp);
            extensions.sort((a, b) => a.start - b.start);
            if (extensions.length > 2000) extensions.splice(0, extensions.length - 2000);
            return {
                now: at,
                timeOrigin,
                entries,
                extensions,
                stamps: [],
                shifts: shifts.map((shift, index) => ({
                    index: shiftBase + index,
                    time: shift.time,
                    value: shift.value,
                    nodes: shift.elements.map((element) => describe(release(element)) || "(removed)"),
                })),
            };
        },
        stop() {
            stopped = true;
            for (const observer of observers) {
                try { observer.disconnect(); } catch (error) {}
            }
            try { delete window.__searchDeveloperLoad; } catch (error) {}
            return true;
        },
    };
    window.__searchDeveloperLoad = api;
    return true;

})();
"""##
}
