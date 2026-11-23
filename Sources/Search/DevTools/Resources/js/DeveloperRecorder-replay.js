// The Recorder panel's replay of one step (DeveloperRecorderModel.swift),
// the body of an async function run with callAsyncJavaScript in the
// recorder's content world. `lib` (DeveloperRecorder-selectors.js) is
// defined ahead of it; `step` is the step as Chrome's JSON has it and
// `timeout` how long to wait for its element, in milliseconds. It waits
// for the first of the step's selectors that finds an element, scrolls
// it into view and does what the step did, as events the page hears as
// it would a person's: pointer and mouse events around a click, the
// value set through the element's own setter then input and change,
// keyboard events, and Enter and Tab's usual effect when the page
// doesn't take them. Answers {ok: true} or {error: "…"}. Navigation,
// the viewport and closing are the panel's.
const deadline = Date.now() + timeout;
const keyState = (() => {
    const symbol = Symbol.for("perch.recorder.keys");
    if (!window[symbol]) window[symbol] = { shift: false, control: false, alt: false, meta: false };
    return window[symbol];
})();

function sleep(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
}

function describe(selectors) {
    return selectors.map((parts) => parts.join(" >>> ")).join(", ");
}

function visible(el) {
    if (!el.isConnected) return false;
    const rects = el.getClientRects();
    if (!rects.length) return false;
    const style = getComputedStyle(el);
    return style.visibility !== "hidden";
}

async function find(selectors, mustBeVisible) {
    let problem = "";
    for (;;) {
        for (const selector of selectors) {
            try {
                const el = lib.resolve(selector);
                if (el && (!mustBeVisible || visible(el))) return el;
            } catch (e) {
                problem = String((e && e.message) || e);
            }
        }
        if (Date.now() > deadline) {
            throw new Error("Timed out after " + timeout + " ms waiting for " + describe(selectors) + (problem ? " (" + problem + ")" : ""));
        }
        await sleep(100);
    }
}

function deepActive() {
    let el = document.activeElement;
    while (el && el.shadowRoot && el.shadowRoot.activeElement) el = el.shadowRoot.activeElement;
    return el || document.body;
}

function modifiers() {
    return { shiftKey: keyState.shift, ctrlKey: keyState.control, altKey: keyState.alt, metaKey: keyState.meta };
}

function pointer(type, el, x, y, button, buttons, detail) {
    const init = Object.assign({
        bubbles: true, cancelable: true, composed: true, view: window,
        clientX: x, clientY: y, screenX: x + window.screenX, screenY: y + window.screenY,
        button, buttons, detail,
    }, modifiers());
    if (type.startsWith("pointer")) {
        const pointerInit = Object.assign({ pointerId: 1, pointerType: "mouse", isPrimary: true, width: 1, height: 1, pressure: buttons ? 0.5 : 0 }, init);
        return el.dispatchEvent(new PointerEvent(type, pointerInit));
    }
    return el.dispatchEvent(new MouseEvent(type, init));
}

// Where in the element the step pressed, and what's on top there.
async function aim(selectors) {
    const el = await find(selectors, true);
    el.scrollIntoView({ block: "center", inline: "center" });
    await sleep(0);
    const rect = el.getBoundingClientRect();
    const x = rect.left + (typeof step.offsetX === "number" ? step.offsetX : rect.width / 2);
    const y = rect.top + (typeof step.offsetY === "number" ? step.offsetY : rect.height / 2);
    let hit = document.elementFromPoint(x, y);
    while (hit && hit.shadowRoot) {
        const inner = hit.shadowRoot.elementFromPoint(x, y);
        if (!inner || inner === hit) break;
        hit = inner;
    }
    const target = hit && (hit === el || el.contains(hit) || (hit.getRootNode && hit.getRootNode().host && el.contains(hit.getRootNode().host))) ? hit : el;
    return { el, target, x, y };
}

function focusFor(el) {
    let current = el;
    while (current) {
        if (typeof current.focus === "function" && current.matches &&
            current.matches("a[href],button,input,select,textarea,summary,[tabindex],[contenteditable='true'],[contenteditable='']")) {
            current.focus({ preventScroll: true });
            return;
        }
        current = current.parentElement || (current.getRootNode && current.getRootNode().host) || null;
    }
}

async function press(el, target, x, y, button, count) {
    const code = { primary: 0, auxiliary: 1, secondary: 2, back: 3, forward: 4 }[button || "primary"] || 0;
    const mask = [1, 4, 2, 8, 16][code];
    pointer("pointerover", target, x, y, 0, 0, 0);
    pointer("mouseover", target, x, y, 0, 0, 0);
    pointer("pointermove", target, x, y, 0, 0, 0);
    pointer("mousemove", target, x, y, 0, 0, 0);
    for (let click = 1; click <= count; click++) {
        pointer("pointerdown", target, x, y, code, mask, click);
        const allowed = pointer("mousedown", target, x, y, code, mask, click);
        if (allowed && code === 0) focusFor(target);
        if (typeof step.duration === "number" && step.duration > 0) await sleep(step.duration);
        pointer("pointerup", target, x, y, code, 0, click);
        pointer("mouseup", target, x, y, code, 0, click);
        if (code === 0) {
            // The page may have replaced what was pressed on mousedown: the
            // step's own element is clicked then, as .click() does it.
            let clicked = false;
            if (target.isConnected) {
                try {
                    pointer("click", target, x, y, 0, 0, click);
                    clicked = true;
                } catch (e) {}
            }
            if (!clicked && el.isConnected && typeof el.click === "function") el.click();
        } else if (code === 1) {
            pointer("auxclick", target, x, y, 1, 0, click);
        } else if (code === 2) {
            pointer("contextmenu", target, x, y, 2, 0, click);
        }
    }
    if (count === 2 && code === 0) pointer("dblclick", target, x, y, 0, 0, 2);
}

function setValue(el, value) {
    el.focus({ preventScroll: true });
    const tag = el.localName;
    if (tag === "select") {
        const setter = Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, "value").set;
        setter.call(el, value);
    } else if (tag === "input" || tag === "textarea") {
        const proto = tag === "input" ? HTMLInputElement.prototype : HTMLTextAreaElement.prototype;
        const setter = Object.getOwnPropertyDescriptor(proto, "value").set;
        setter.call(el, value);
    } else if (el.isContentEditable) {
        el.textContent = value;
    } else {
        throw new Error("The element for this change isn't a field.");
    }
    el.dispatchEvent(new InputEvent("input", { bubbles: true, composed: true, inputType: "insertText", data: value }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
}

function focusables() {
    const all = Array.from(document.querySelectorAll("a[href],button,input,select,textarea,summary,[tabindex],[contenteditable='true']"));
    return all.filter((el) => !el.disabled && el.tabIndex >= 0 && visible(el));
}

function keyboard(type, key) {
    const target = deepActive();
    const upper = key.toUpperCase();
    let code = key;
    if (key.length === 1) {
        if (upper >= "A" && upper <= "Z") code = "Key" + upper;
        else if (key >= "0" && key <= "9") code = "Digit" + key;
        else if (key === " ") code = "Space";
        else code = "";
    }
    const init = Object.assign({ key, code, bubbles: true, cancelable: true, composed: true, view: window }, modifiers());
    const allowed = target.dispatchEvent(new KeyboardEvent(type, init));
    if (type === "keydown") {
        if (key === "Shift") keyState.shift = true;
        if (key === "Control") keyState.control = true;
        if (key === "Alt") keyState.alt = true;
        if (key === "Meta") keyState.meta = true;
    } else {
        if (key === "Shift") keyState.shift = false;
        if (key === "Control") keyState.control = false;
        if (key === "Alt") keyState.alt = false;
        if (key === "Meta") keyState.meta = false;
    }
    if (type !== "keydown" || !allowed) return;
    if (key === "Enter") {
        if (target.localName === "input" && target.form) {
            const form = target.form;
            if (form.requestSubmit) form.requestSubmit(); else form.submit();
        } else if (target.localName === "a" || target.localName === "button" || target.getAttribute("role") === "button") {
            target.click();
        }
    } else if (key === "Tab") {
        const list = focusables();
        const index = list.indexOf(target);
        const next = list[(index + (keyState.shift ? list.length - 1 : 1)) % Math.max(1, list.length)];
        if (next) next.focus();
    } else if (key.length === 1 && !keyState.control && !keyState.meta && (target.localName === "input" || target.localName === "textarea")) {
        const start = target.selectionStart != null ? target.selectionStart : target.value.length;
        const end = target.selectionEnd != null ? target.selectionEnd : target.value.length;
        setValue(target, target.value.slice(0, start) + key + target.value.slice(end));
    }
}

async function run() {
    const selectors = Array.isArray(step.selectors) ? step.selectors.map((each) => (Array.isArray(each) ? each : [each])) : [];
    switch (step.type) {
    case "click": {
        const { el, target, x, y } = await aim(selectors);
        await press(el, target, x, y, step.button, 1);
        break;
    }
    case "doubleClick": {
        const { el, target, x, y } = await aim(selectors);
        await press(el, target, x, y, step.button, 2);
        break;
    }
    case "hover": {
        const { target, x, y } = await aim(selectors);
        pointer("pointerover", target, x, y, 0, 0, 0);
        pointer("pointerenter", target, x, y, 0, 0, 0);
        pointer("mouseover", target, x, y, 0, 0, 0);
        pointer("mouseenter", target, x, y, 0, 0, 0);
        pointer("pointermove", target, x, y, 0, 0, 0);
        pointer("mousemove", target, x, y, 0, 0, 0);
        break;
    }
    case "change": {
        const el = await find(selectors, false);
        el.scrollIntoView({ block: "center", inline: "center" });
        setValue(el, String(step.value == null ? "" : step.value));
        break;
    }
    case "keyDown":
        keyboard("keydown", String(step.key || ""));
        break;
    case "keyUp":
        keyboard("keyup", String(step.key || ""));
        break;
    case "scroll": {
        const x = Number(step.x || 0);
        const y = Number(step.y || 0);
        if (selectors.length) {
            const el = await find(selectors, false);
            el.scrollTo({ left: x, top: y });
        } else {
            window.scrollTo({ left: x, top: y });
        }
        break;
    }
    case "waitForElement": {
        const count = typeof step.count === "number" ? step.count : 1;
        const operator = step.operator || ">=";
        for (;;) {
            let found = 0;
            for (const selector of selectors) {
                try {
                    const el = lib.resolve(selector);
                    if (el && (step.visible === false || visible(el))) found = Math.max(found, 1);
                } catch (e) {}
            }
            const met = operator === "==" ? found === count : operator === "<=" ? found <= count : found >= count;
            if (met) break;
            if (Date.now() > deadline) throw new Error("Timed out after " + timeout + " ms waiting for " + describe(selectors));
            await sleep(100);
        }
        break;
    }
    case "waitForExpression": {
        const check = new Function("return (" + String(step.expression || "true") + ");");
        for (;;) {
            if (await check()) break;
            if (Date.now() > deadline) throw new Error("Timed out after " + timeout + " ms waiting for " + step.expression);
            await sleep(100);
        }
        break;
    }
    default:
        throw new Error("Replay can't run a " + step.type + " step in the page.");
    }
}

try {
    await run();
    return { ok: true };
} catch (e) {
    return { error: String((e && e.message) || e) };
}
