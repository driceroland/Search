// The Recorder panel's recording script (DeveloperRecorderModel.swift).
// Installed as a user script in the recorder's own content world, so it
// runs again in every page the tab loads while recording, and evaluated
// once in the page already open. Called with the selector library
// (DeveloperRecorder-selectors.js) and `{handler, selectorTypes,
// selectorAttribute}`. It listens in the capture phase, before the page
// can stop an event, and posts each step to the panel as it happens:
//   click, doubleClick, right and middle clicks, with offsets in the element
//   change    typing, a select or a contenteditable: the panel folds a
//             field's inputs into one step with the final value
//   keyDown, keyUp   keys that aren't typing into a field
//   scroll    the window or an element, once it has stopped for a moment
//   load      the page itself, which the panel turns into a navigation
(function (lib, config) {
    const key = Symbol.for("perch.recorder");
    if (window[key]) {
        window[key].configure(config);
        return true;
    }
    let options = { types: config.selectorTypes, attribute: config.selectorAttribute || "" };
    const handlers = window.webkit && window.webkit.messageHandlers;
    const channel = handlers ? handlers[config.handler] : null;
    const scrollDelay = 300;
    const interactive = [
        "a[href]", "button", "input", "select", "textarea", "label", "summary", "option",
        "[role]", "[onclick]", "[tabindex]", "[contenteditable='']", "[contenteditable='true']",
    ].join(",");
    const modifierKeys = new Set(["Shift", "Control", "Alt", "Meta", "CapsLock", "Fn"]);
    const editingKeys = new Set(["Backspace", "Delete"]);
    const listeners = [];
    const scrolls = new Map();
    let downAt = 0;

    function post(message) {
        try {
            if (channel) channel.postMessage(message);
        } catch (e) {}
    }

    function step(fields) {
        post({ kind: "step", step: fields });
    }

    function listen(target, type, handler) {
        target.addEventListener(type, handler, { capture: true, passive: true });
        listeners.push([target, type, handler]);
    }

    function parentOf(node) {
        if (node.parentElement) return node.parentElement;
        const root = node.getRootNode && node.getRootNode();
        return root && root.host ? root.host : null;
    }

    function deepTarget(event) {
        const path = event.composedPath ? event.composedPath() : [];
        for (const node of path) {
            if (node && node.nodeType === 1) return node;
        }
        const target = event.target;
        return target && target.nodeType === 1 ? target : target && target.parentElement;
    }

    // What a click acted on: the nearest control or link around the
    // element under the pointer, or that element.
    function actionTarget(event) {
        const start = deepTarget(event);
        let current = start;
        for (let depth = 0; current && depth < 6; depth++) {
            try {
                if (current.matches(interactive)) return current;
            } catch (e) {}
            current = parentOf(current);
        }
        return start;
    }

    function selectors(el) {
        return lib.compute(el, options);
    }

    function round(value) {
        return Math.round(value * 100) / 100;
    }

    function pointerStep(type, event, extra) {
        // A pointer outside the viewport can't have pressed the page; such
        // events come from posted input, not from someone's click.
        if (event.clientX < 0 || event.clientY < 0
            || event.clientX > window.innerWidth || event.clientY > window.innerHeight) return;
        const el = actionTarget(event);
        if (!el) return;
        const rect = el.getBoundingClientRect();
        const fields = {
            type,
            target: "main",
            selectors: selectors(el),
            offsetY: round(event.clientY - rect.top),
            offsetX: round(event.clientX - rect.left),
        };
        if (event.pointerType === "pen" || event.pointerType === "touch") fields.deviceType = event.pointerType;
        Object.assign(fields, extra || {});
        step(fields);
    }

    function editable(el) {
        if (!el) return false;
        const tag = el.localName;
        if (tag === "textarea" || tag === "select") return true;
        if (tag === "input") {
            const type = (el.type || "text").toLowerCase();
            return !["checkbox", "radio", "button", "submit", "reset", "image", "file", "range", "color"].includes(type);
        }
        return !!el.isContentEditable;
    }

    function editableRoot(el) {
        let current = el;
        while (current && current.isContentEditable && current.parentElement && current.parentElement.isContentEditable) {
            current = current.parentElement;
        }
        return current;
    }

    function valueOf(el) {
        if (el.isContentEditable && !("value" in el)) return el.textContent;
        return el.value;
    }

    listen(window, "pointerdown", (event) => {
        if (event.isTrusted) downAt = event.timeStamp;
    });

    listen(window, "click", (event) => {
        // A click with no presses behind it is the keyboard's or a label's
        // forwarding, which the keys or the label's own click already record.
        if (!event.isTrusted || event.detail === 0 || event.button !== 0) return;
        const held = downAt ? event.timeStamp - downAt : 0;
        pointerStep("click", event, held > 500 ? { duration: Math.round(held) } : null);
    });

    listen(window, "dblclick", (event) => {
        if (!event.isTrusted || event.button !== 0) return;
        pointerStep("doubleClick", event, null);
    });

    listen(window, "auxclick", (event) => {
        if (!event.isTrusted || event.button !== 1) return;
        pointerStep("click", event, { button: "auxiliary" });
    });

    listen(window, "contextmenu", (event) => {
        if (!event.isTrusted) return;
        pointerStep("click", event, { button: "secondary" });
    });

    function changed(event) {
        if (!event.isTrusted) return;
        let el = deepTarget(event);
        if (!editable(el)) return;
        if (el.isContentEditable && el.localName !== "input" && el.localName !== "textarea") el = editableRoot(el);
        step({ type: "change", value: valueOf(el), selectors: selectors(el), target: "main" });
    }

    listen(window, "input", changed);
    listen(window, "change", changed);

    function keyStep(type) {
        return (event) => {
            if (!event.isTrusted || event.repeat || event.isComposing) return;
            const target = deepTarget(event);
            if (editable(target)) {
                const typing = event.key.length === 1 && !event.ctrlKey && !event.metaKey && !event.altKey;
                if (typing || modifierKeys.has(event.key) || editingKeys.has(event.key)) return;
            }
            step({ type, target: "main", key: event.key });
        };
    }

    listen(window, "keydown", keyStep("keyDown"));
    listen(window, "keyup", keyStep("keyUp"));

    listen(window, "scroll", (event) => {
        if (!event.isTrusted) return;
        const target = event.target;
        const element = target && target.nodeType === 1 && target !== document.scrollingElement ? target : null;
        const id = element || window;
        clearTimeout(scrolls.get(id));
        scrolls.set(id, setTimeout(() => {
            scrolls.delete(id);
            if (element) {
                step({ type: "scroll", target: "main", selectors: selectors(element), x: round(element.scrollLeft), y: round(element.scrollTop) });
            } else {
                step({ type: "scroll", target: "main", x: round(window.scrollX), y: round(window.scrollY) });
            }
        }, scrollDelay));
    });

    function loaded() {
        post({ kind: "load", url: location.href, title: document.title });
    }

    if (document.readyState === "complete") {
        loaded();
    } else {
        window.addEventListener("load", loaded, { once: true });
    }

    window[key] = {
        configure(next) {
            options = { types: next.selectorTypes, attribute: next.selectorAttribute || "" };
        },
        stop() {
            for (const [target, type, handler] of listeners) target.removeEventListener(type, handler, { capture: true });
            for (const timer of scrolls.values()) clearTimeout(timer);
            window.removeEventListener("load", loaded);
            delete window[key];
        },
    };
    return true;
})
