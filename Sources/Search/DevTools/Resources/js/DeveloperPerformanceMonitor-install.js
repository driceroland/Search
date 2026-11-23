// The Performance monitor's ear on WebKit's CPUProfiler, Memory and
// Timeline domains. Runs in the hidden inspector frontend, beside
// perchInspector: it keeps CPUProfiler.trackingUpdate's usage and
// Memory.trackingUpdate's JavaScript heap as they go by on the same
// connection, with the time they came, and counts the Layout and
// RecalculateStyles records in Timeline.eventRecorded (nested ones too).
// While the monitor owns tracking, the trackingStart and trackingComplete
// events stop here: WebKit's own TimelineManager takes them for a
// recording started from the backend and would begin keeping a hidden
// recording of its own. Returns whether it was set up just now, so the
// monitor asks for tracking again after the frontend reloaded.
let fresh = false;
if (!globalThis.perchPerformanceMonitor) {
    const connection = InspectorBackend.Connection?.prototype;
    const dispatch = connection?._dispatchEvent;
    if (typeof dispatch !== "function")
        throw new Error("This version of WebKit can’t report CPU and memory use.");
    const limit = 240;
    let cpu = [];
    let memory = [];
    let layouts = 0;
    let styles = 0;
    let owned = false;
    const bookends = new Set([
        "CPUProfiler.trackingStart", "CPUProfiler.trackingComplete",
        "Memory.trackingStart", "Memory.trackingComplete",
    ]);
    function count(record, depth) {
        if (!record || typeof record !== "object" || depth > 64)
            return;
        if (record.type === "Layout")
            layouts += 1;
        else if (record.type === "RecalculateStyles")
            styles += 1;
        if (Array.isArray(record.children))
            for (const child of record.children.slice(0, 2000))
                count(child, depth + 1);
    }
    connection._dispatchEvent = function(message) {
        try {
            if (owned && bookends.has(message?.method))
                return undefined;
        } catch {
            // Never in WebKit's way.
        }
        const result = dispatch.apply(this, arguments);
        try {
            const method = message?.method;
            const params = message?.params ?? {};
            if (method === "CPUProfiler.trackingUpdate") {
                const usage = params.event?.usage;
                if (typeof usage === "number" && Number.isFinite(usage) && cpu.length < limit)
                    cpu.push({time: performance.now(), usage});
            } else if (method === "Memory.trackingUpdate") {
                const categories = Array.isArray(params.event?.categories) ? params.event.categories : [];
                const js = categories.find((item) => item?.type === "javascript");
                if (typeof js?.size === "number" && Number.isFinite(js.size) && memory.length < limit)
                    memory.push({time: performance.now(), size: js.size});
            } else if (method === "Timeline.eventRecorded") {
                count(params.record, 0);
            }
        } catch {
            // The monitor's copy must never interrupt WebKit's own.
        }
        return result;
    };
    globalThis.perchPerformanceMonitor = Object.freeze({
        drain() {
            const result = {now: performance.now(), cpu, memory, layouts, styles};
            cpu = [];
            memory = [];
            return result;
        },
        own(value) { owned = !!value; },
    });
    fresh = true;
}
