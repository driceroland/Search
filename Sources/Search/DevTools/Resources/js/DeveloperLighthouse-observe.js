// The Lighthouse panel's load observer (DeveloperLighthouseModel.swift): a
// user script of the panel's own content world, put in the tab at document
// start for one Navigation run and run once more before the metrics are
// read (it does nothing the second time). It watches the
// PerformanceObserver entries this WebKit has (paint, and where supported
// largest-contentful-paint, layout-shift and longtask, all buffered so
// what came before it is seen too). For a Timespan run it is evaluated
// in the tab when the timespan starts, with options set first under
// Symbol.for("perch.lighthouse.options"): a state of its own, entries
// from then on only (not buffered), a longer watch, and the `event`
// entries Interaction to Next Paint is made of where this WebKit has
// them. WebKit has no longtask entries, so
// main-thread blocking is estimated from the gaps in a zero-delay timer
// loop instead: any gap over 50 ms was a task holding the thread. It only
// watches; the page is not changed. A function expression, called with
// DeveloperLayoutShift-estimate.js (DeveloperLayoutShiftEstimator).
(estimateLayoutShifts) => {
    const options = window[Symbol.for("perch.lighthouse.options")] || {};
    const key = Symbol.for(options.key || "perch.lighthouse");
    if (window[key]) return;
    const buffered = options.buffered !== false;
    const limit = options.limit || 60000;
    const state = {
        started: performance.now(),
        fcp: null,
        lcp: null,
        lcpElement: null,
        lcpURL: null,
        cls: 0,
        tasks: [],
        taskSource: "none",
        lcpSupported: false,
        clsSupported: false,
        clsEstimated: false,
        shifts: 0,
        inpSupported: false,
        interactions: new Map(),
        stopped: false,
    };
    window[key] = state;
    const types = (typeof PerformanceObserver !== "undefined" && PerformanceObserver.supportedEntryTypes) || [];
    const observe = (type, callback) => {
        if (!types.includes(type)) return false;
        try {
            new PerformanceObserver((list) => {
                for (const entry of list.getEntries()) callback(entry);
            }).observe({ type, buffered });
            return true;
        } catch (error) {
            return false;
        }
    };
    observe("paint", (entry) => {
        if (entry.name === "first-contentful-paint" && state.fcp === null) state.fcp = entry.startTime;
    });
    state.lcpSupported = observe("largest-contentful-paint", (entry) => {
        state.lcp = entry.renderTime || entry.loadTime || entry.startTime;
        state.lcpElement = entry.element || null;
        // The image's address, for the simulation's LCP graph.
        state.lcpURL = entry.url || null;
    });
    // INP: each interaction's longest event entry (entries of one
    // interaction share its interactionId), from the Event Timing API
    // where this WebKit has it.
    if (types.includes("event")) {
        try {
            new PerformanceObserver((list) => {
                for (const entry of list.getEntries()) {
                    if (!entry.interactionId) continue;
                    // Impossible timings (before the page, or longer than it has existed) aren't interactions.
                    if (!(entry.duration >= 0) || entry.startTime < 0
                        || entry.startTime + entry.duration > performance.now() + 1000) continue;
                    const known = state.interactions.get(entry.interactionId);
                    if (known && known.duration >= entry.duration) continue;
                    state.interactions.set(entry.interactionId, {
                        duration: entry.duration, name: entry.name, start: entry.startTime, target: entry.target || null,
                    });
                }
            }).observe({ type: "event", buffered, durationThreshold: 16 });
            state.inpSupported = true;
        } catch (error) {
            state.inpSupported = false;
        }
    }
    // CLS as Core Web Vitals counts it: the largest session window of
    // shifts (gaps under 1 s, windows at most 5 s), without those right
    // after input.
    let windowValue = 0;
    let windowStart = 0;
    let windowLast = 0;
    state.clsSupported = observe("layout-shift", (entry) => {
        if (entry.hadRecentInput) return;
        if (windowValue > 0 && entry.startTime - windowLast < 1000 && entry.startTime - windowStart < 5000) {
            windowValue += entry.value;
        } else {
            windowValue = entry.value;
            windowStart = entry.startTime;
        }
        windowLast = entry.startTime;
        if (windowValue > state.cls) state.cls = windowValue;
    });
    // No layout-shift entries (WebKit): DeveloperLayoutShift-estimate.js
    // finds them instead, while the observer watches.
    if (!state.clsSupported) {
        state.clsEstimated = true;
        estimateLayoutShifts({
            active: () => !state.stopped && performance.now() - state.started <= limit,
            onShift: (shift) => {
                const at = shift.time;
                if (windowValue > 0 && at - windowLast < 1000 && at - windowStart < 5000) windowValue += shift.value;
                else { windowValue = shift.value; windowStart = at; }
                windowLast = at;
                if (windowValue > state.cls) state.cls = windowValue;
                state.shifts = (state.shifts || 0) + 1;
            },
        });
    }
    if (observe("longtask", (entry) => { state.tasks.push([entry.startTime, entry.duration]); })) {
        state.taskSource = "longtask";
    } else {
        state.taskSource = "gaps";
        let last = performance.now();
        const tick = () => {
            const now = performance.now();
            const gap = now - last;
            // A hidden page's timers are throttled, which isn't blocking.
            if (gap > 50 && document.visibilityState === "visible") state.tasks.push([last, gap]);
            last = now;
            if (!state.stopped && now - state.started < limit) setTimeout(tick, 0);
        };
        setTimeout(tick, 0);
    }
}
