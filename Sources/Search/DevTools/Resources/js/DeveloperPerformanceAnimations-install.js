// Performance's Animations track: an ear on WebKit's Animation tracking,
// which the Timeline "Animation" instrument turns on for a recording.
// Runs in the hidden inspector frontend, beside perchInspector, and keeps
// each Animation.trackingUpdate as it goes by on the same connection:
// the CSS animation or transition it is about (trackingAnimationId, its
// @keyframes name or transitioned property, its element) and the state it
// moved to (ready, delayed, active, canceled, done), at the timeline's
// own time. The recording's end hands them over. WebKit tracks CSS
// animations and transitions only, not those a script made.
if (!globalThis.perchPerformanceAnimations) {
    const connection = InspectorBackend.Connection?.prototype;
    const dispatch = connection?._dispatchEvent;
    if (typeof dispatch !== "function")
        throw new Error("This version of WebKit can’t report animations.");
    const limit = 6000;
    let updates = [];
    let overflowed = false;
    const text = (value, max) => typeof value === "string" ? value.slice(0, max) : undefined;
    connection._dispatchEvent = function(message) {
        const result = dispatch.apply(this, arguments);
        try {
            if (message?.method === "Animation.trackingUpdate") {
                const params = message.params ?? {};
                const event = params.event ?? {};
                if (typeof params.timestamp === "number" && Number.isFinite(params.timestamp)) {
                    if (updates.length < limit) {
                        updates.push({
                            timestamp: params.timestamp,
                            trackingAnimationId: text(String(event.trackingAnimationId ?? ""), 200),
                            animationState: text(event.animationState, 40),
                            animationName: text(event.animationName, 200),
                            transitionProperty: text(event.transitionProperty, 200),
                            nodeId: typeof event.nodeId === "number" ? event.nodeId : undefined,
                        });
                    } else {
                        overflowed = true;
                    }
                }
            }
        } catch {
            // The track's copy must never interrupt WebKit's own.
        }
        return result;
    };
    globalThis.perchPerformanceAnimations = Object.freeze({
        drain() {
            const result = {updates, overflowed};
            updates = [];
            overflowed = false;
            return result;
        },
        reset() {
            updates = [];
            overflowed = false;
        },
    });
}
