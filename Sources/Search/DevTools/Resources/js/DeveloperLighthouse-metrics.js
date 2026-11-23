// The Lighthouse panel's metrics read-back (DeveloperLighthouseModel.swift):
// the body of an async function run with callAsyncJavaScript in the
// panel's content world, after DeveloperLighthouse-observe.js. It gives
// the buffered observers a moment, stops the timer loop, and answers what
// was measured plus the navigation timing, all in milliseconds since the
// navigation started. TBT is worked out in Swift from the tasks. `key`
// names the observer's state: a Timespan run's has its own.
await new Promise((resolve) => setTimeout(resolve, 120));
const state = window[Symbol.for(typeof key === "string" && key ? key : "perch.lighthouse")];
const navigation = performance.getEntriesByType("navigation")[0];
const answer = {
    now: performance.now(),
    fcp: null,
    lcp: null,
    lcpSupported: false,
    lcpElement: null,
    cls: null,
    clsSupported: false,
    clsEstimated: false,
    shifts: 0,
    tasks: [],
    taskSource: "none",
    observed: false,
    started: null,
    inpSupported: false,
    inp: null,
    interactions: 0,
    inpEvent: null,
    inpTarget: null,
    ttfb: null,
    dcl: null,
    load: null,
};
if (state) {
    state.stopped = true;
    answer.fcp = state.fcp;
    answer.lcp = state.lcp;
    answer.lcpSupported = state.lcpSupported;
    answer.lcpURL = state.lcpURL || null;
    answer.cls = state.cls;
    answer.clsSupported = state.clsSupported;
    answer.clsEstimated = !!state.clsEstimated;
    answer.shifts = state.shifts || 0;
    answer.tasks = state.tasks.slice(0, 5000);
    answer.taskSource = state.taskSource;
    answer.observed = true;
    answer.started = state.started;
    answer.inpSupported = !!state.inpSupported;
    // INP as web-vitals counts it: the longest interaction, leaving out
    // one for every 50 (so the 98th percentile on a busy page).
    const interactions = state.interactions ? [...state.interactions.values()] : [];
    answer.interactions = interactions.length;
    if (interactions.length) {
        interactions.sort((a, b) => b.duration - a.duration);
        const worst = interactions[Math.min(interactions.length - 1, Math.floor(interactions.length / 50))];
        answer.inp = worst.duration;
        answer.inpEvent = worst.name;
        const target = worst.target;
        if (target && target.outerHTML) {
            const html = target.outerHTML;
            const close = html.indexOf(">");
            answer.inpTarget = (close >= 0 ? html.slice(0, close + 1) : html).slice(0, 300);
        }
    }
    const element = state.lcpElement;
    if (element && element.outerHTML) {
        const html = element.outerHTML;
        const close = html.indexOf(">");
        answer.lcpElement = (close >= 0 ? html.slice(0, close + 1) : html).slice(0, 300);
        // lcp-lazy-loaded: an image, and whether it was lazily loaded.
        answer.lcpImage = element.localName === "img";
        answer.lcpLazy = answer.lcpImage && (element.getAttribute("loading") || "").toLowerCase() === "lazy";
    }
}
if (answer.fcp === null) {
    const paint = performance.getEntriesByType("paint").find((entry) => entry.name === "first-contentful-paint");
    if (paint) answer.fcp = paint.startTime;
}
if (navigation) {
    if (navigation.responseStart > 0) answer.ttfb = navigation.responseStart - (navigation.requestStart || 0);
    // When the document's first byte came, in the page's clock: lines the
    // Network panel's clock up with the page's for the simulation.
    if (navigation.responseStart > 0) answer.responseStart = navigation.responseStart;
    if (navigation.domContentLoadedEventEnd > 0) answer.dcl = navigation.domContentLoadedEventEnd;
    if (navigation.loadEventEnd > 0) answer.load = navigation.loadEventEnd;
    // redirects: Navigation Timing counts and times same-origin ones only.
    answer.redirects = navigation.redirectCount || 0;
    if (navigation.redirectEnd > 0 && navigation.redirectEnd >= navigation.redirectStart) {
        answer.redirectMs = navigation.redirectEnd - navigation.redirectStart;
    }
}
return answer;
