// Performance's local metrics and the page's own timings for a recording
// (DeveloperLiveMetrics.swift). A function expression, called with
// DeveloperLayoutShift-estimate.js (DeveloperLayoutShiftEstimator), in the
// page's world: a user script at document start while the Performance
// panel is open, and again before each read (it does nothing the second
// time). It watches the PerformanceObserver entries this WebKit has, all
// buffered so what came before it is seen too: largest-contentful-paint
// for LCP, event (over 16 ms) and first-input for INP, layout-shift for
// CLS, or, without layout-shift entries, the estimator for as long as
// DevTools keeps reading (or a recording holds it). Everything it calls on
// the page is taken as it starts, and it is kept under a symbol, not
// enumerable, so the page sees nothing of it. It only watches, but for
// console.timeStamp, which it wraps (calling through to WebKit's) to keep
// Chrome's extended calls for the recording's custom tracks.
(estimateLayoutShifts) => {
    const key = Symbol.for("perch.performance.metrics");
    if (window[key]) return true;
    const Observer = window.PerformanceObserver;
    const now = performance.now.bind(performance);
    const entriesByType = performance.getEntriesByType.bind(performance);
    const timeOrigin = performance.timeOrigin;
    const timeStamp = typeof console.timeStamp === "function" ? console.timeStamp.bind(console) : null;
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

    // Chrome's extended console.timeStamp(label, start, end, trackName,
    // trackGroup, color): each call with more than a label is kept (the
    // last 2,000) for a custom track, WebKit's own still called so its
    // TimeStamp record is made. A string start or end names a mark or an
    // earlier timestamp, looked up as it was then (in `names`).
    const stamps = [];
    const stampTimes = new Map();
    const originalTimeStamp = typeof console.timeStamp === "function" ? console.timeStamp : null;
    let timeStampWrapper = null;
    const stampPoint = (value) => {
        if (typeof value === "number") return isFinite(value) ? value : undefined;
        if (typeof value === "string" && value.length <= 200) return value;
        return undefined;
    };
    const lookUp = (value, names) => {
        if (typeof value !== "string" || hasOwn.call(names, value)) return;
        try {
            const marks = entriesByName(value, "mark");
            if (marks.length) {
                names[value] = marks[marks.length - 1].startTime;
                return;
            }
        } catch (error) {}
        if (stampTimes.has(value)) names[value] = stampTimes.get(value);
    };
    const stamped = (args) => {
        if (stopped || !args.length) return;
        const at = now();
        const label = String(args[0]).slice(0, 200);
        if (args.length > 1) {
            const names = {};
            const record = {label, at, names};
            const start = stampPoint(args[1]);
            const end = stampPoint(args[2]);
            lookUp(start, names);
            lookUp(end, names);
            if (start !== undefined) record.start = start;
            if (end !== undefined) record.end = end;
            const fields = [[3, "track"], [4, "trackGroup"], [5, "color"]];
            for (const [index, key] of fields) {
                const value = args[index];
                if (typeof value === "string" && value.length <= 200) record[key] = value;
            }
            stamps.push(record);
            if (stamps.length > 2000) stamps.shift();
        }
        if (!stampTimes.has(label) && stampTimes.size >= 1000) stampTimes.delete(stampTimes.keys().next().value);
        stampTimes.set(label, at);
    };
    if (originalTimeStamp) {
        timeStampWrapper = {
            timeStamp() {
                const result = apply(originalTimeStamp, this, arguments);
                try { stamped(arguments); } catch (error) {}
                return result;
            },
        }.timeStamp;
        try { console.timeStamp = timeStampWrapper; } catch (error) { timeStampWrapper = null; }
    }

    let estimating = false;
    const estimate = () => {
        if (shiftsSupported || estimating || stopped) return;
        estimating = true;
        estimateLayoutShifts({
            active: () => !stopped && (held || now() - lastRead < 15000),
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
            };
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
            if (timeStamp) timeStamp("perch-sync " + at);
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
                stamps: stamps.slice(),
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
            if (timeStampWrapper && console.timeStamp === timeStampWrapper) {
                try { console.timeStamp = originalTimeStamp; } catch (error) {}
            }
            for (const observer of observers) {
                try { observer.disconnect(); } catch (error) {}
            }
            try { delete window[key]; } catch (error) {}
            return true;
        },
    };
    defineProperty(window, key, {value: api, configurable: true, enumerable: false, writable: false});
    return true;
}
