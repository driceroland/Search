// The Animations drawer's hook in the page's own world, for what WebKit's
// Animation domain doesn't tell: document.startViewTransition calls. Each
// call is noted; once the transition's pseudo-elements are built (its
// `ready` promise), their ::view-transition animations are read with the
// Web Animations API and kept until the drawer collects them. Also says
// what this WebKit supports: view transitions, ScrollTimeline and
// ViewTimeline. Run again, it only hands over what was noted since.
(() => {
    const key = Symbol.for("perch.animations.page");
    let state = window[key];
    if (!state) {
        const proto = typeof Document === "function" ? Document.prototype : null;
        const native = proto ? proto.startViewTransition : undefined;
        state = {
            viewTransitions: typeof native === "function",
            scrollTimelines: typeof ScrollTimeline === "function",
            viewTimelines: typeof ViewTimeline === "function",
            pending: [],
            serial: 0,
        };
        Object.defineProperty(window, key, {value: state, configurable: true});
        if (state.viewTransitions) {
            const number = (value, fallback) => typeof value === "number" ? (Number.isFinite(value) ? value : -1) : fallback;
            const text = (value, max) => typeof value === "string" ? value.slice(0, max) : "";
            const read = (record) => {
                const found = [];
                try {
                    for (const animation of document.getAnimations()) {
                        const effect = animation.effect;
                        const pseudo = effect && typeof effect.pseudoElement === "string" ? effect.pseudoElement : "";
                        if (!pseudo.startsWith("::view-transition")) continue;
                        const timing = typeof effect.getTiming === "function" ? effect.getTiming() : {};
                        found.push({
                            name: text(animation.animationName || animation.id || "", 200),
                            pseudo: text(pseudo, 200),
                            duration: number(timing.duration, 0),
                            delay: number(timing.delay, 0),
                            endDelay: number(timing.endDelay, 0),
                            iterations: number(timing.iterations, 1),
                            easing: text(timing.easing, 200),
                            direction: text(timing.direction, 40),
                            fill: text(timing.fill, 40),
                        });
                        if (found.length >= 200) break;
                    }
                } catch {
                    // Nothing read: the transition is still listed.
                }
                record.animations = found;
                if (state.pending.length < 100) state.pending.push(record);
            };
            const descriptor = Object.getOwnPropertyDescriptor(proto, "startViewTransition");
            const wrapped = {
                startViewTransition() {
                    const transition = native.apply(this, arguments);
                    const record = {id: ++state.serial, time: Date.now(), animations: [], skipped: false};
                    const ready = transition && transition.ready;
                    if (ready && typeof ready.then === "function") {
                        ready.then(() => read(record), () => {
                            record.skipped = true;
                            if (state.pending.length < 100) state.pending.push(record);
                        });
                    } else {
                        read(record);
                    }
                    return transition;
                },
            }.startViewTransition;
            Object.defineProperty(proto, "startViewTransition", {
                value: wrapped, writable: true, configurable: true,
                enumerable: descriptor ? descriptor.enumerable : true,
            });
        }
    }
    const transitions = state.pending;
    state.pending = [];
    return {
        viewTransitions: state.viewTransitions, scrollTimelines: state.scrollTimelines,
        viewTimelines: state.viewTimelines, transitions,
    };
})()
