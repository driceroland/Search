// The Animations drawer's ear on WebKit's Animation domain. Runs in the
// hidden inspector frontend, beside perchInspector: it listens on the same
// connection, keeps the domain's events with the time they came, and
// hands them over in batches. Returns whether it was set up just now, so
// the drawer enables the domain again after the frontend reloaded.
let fresh = false;
if (!globalThis.perchAnimations) {
    const connection = InspectorBackend.Connection?.prototype;
    const dispatch = connection?._dispatchEvent;
    if (typeof dispatch !== "function")
        throw new Error("This version of WebKit can’t report animations.");
    const limit = 2000;
    let pending = [];
    // Infinity doesn't cross to the app; -1 stands for it, as WebKit's own
    // protocol sends an endless iteration count.
    const number = (value) => typeof value === "number" ? (Number.isFinite(value) ? value : -1) : undefined;
    const text = (value, max) => typeof value === "string" ? value.slice(0, max) : undefined;
    function effect(raw) {
        if (!raw || typeof raw !== "object")
            return undefined;
        return {
            startDelay: number(raw.startDelay), endDelay: number(raw.endDelay),
            // WebKit sends -1 for an endless count, or null where it once
            // wrote Infinity into JSON; Web Inspector reads both as endless.
            iterationCount: raw.iterationCount === null ? -1 : number(raw.iterationCount),
            iterationStart: number(raw.iterationStart),
            iterationDuration: number(raw.iterationDuration), timingFunction: text(raw.timingFunction, 200),
            playbackDirection: text(raw.playbackDirection, 40), fillMode: text(raw.fillMode, 40),
            keyframes: Array.isArray(raw.keyframes) ? raw.keyframes.slice(0, 64).map((frame) => ({
                offset: number(frame?.offset), easing: text(frame?.easing, 200), style: text(frame?.style, 400),
            })) : undefined,
        };
    }
    function project(method, params) {
        switch (method) {
        case "Animation.animationCreated": {
            const raw = params.animation ?? {};
            return {animation: {
                animationId: text(String(raw.animationId ?? ""), 200), name: text(raw.name, 200),
                cssAnimationName: text(raw.cssAnimationName, 200),
                cssTransitionProperty: text(raw.cssTransitionProperty, 200), effect: effect(raw.effect),
            }};
        }
        case "Animation.nameChanged":
            return {animationId: String(params.animationId ?? ""), name: text(params.name, 200)};
        case "Animation.effectChanged":
            return {animationId: String(params.animationId ?? ""), effect: effect(params.effect)};
        case "Animation.targetChanged":
        case "Animation.animationDestroyed":
            return {animationId: String(params.animationId ?? "")};
        default:
            return null;
        }
    }
    connection._dispatchEvent = function(message) {
        const result = dispatch.apply(this, arguments);
        try {
            const method = message?.method;
            if (typeof method === "string" && method.startsWith("Animation.") && pending.length < limit) {
                const params = project(method, message.params ?? {});
                if (params) {
                    const event = {method, params, time: performance.now()};
                    if (typeof this.target?.identifier === "string")
                        event.targetId = this.target.identifier;
                    pending.push(event);
                }
            }
        } catch {
            // The drawer's copy must never interrupt WebKit's own.
        }
        return result;
    };
    globalThis.perchAnimations = Object.freeze({
        drain() {
            const events = pending;
            pending = [];
            return {now: performance.now(), events};
        },
    });
    fresh = true;
}
