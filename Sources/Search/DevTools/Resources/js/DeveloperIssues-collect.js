// The Issues drawer's scan of the page's forms and ARIA attributes, and
// whether it is cross-origin isolated: run in the page
// (Runtime.evaluate, main world) after it loads and again when its form
// fields change. It reads, and never changes, the document's fields,
// labels and ids, and whether it is in Quirks Mode. The first run also
// leaves a MutationObserver that counts changes to them (debounced), so
// DevTools can ask cheaply whether to scan again: it reads the count off
// the returned state object (Runtime.getProperties) without running any
// script. The state lives under a symbol on window, gone when the page
// navigates. The judging is done in Swift (DeveloperIssueRules.forms);
// the elements stay behind in the returned holder so the drawer can
// reveal one by its index.
(() => {
    const key = Symbol.for("perch.devtools.issues");
    let state = window[key];
    if (!state) {
        state = {version: 0, timer: 0};
        try {
            Object.defineProperty(window, key, {value: state, configurable: true});
        } catch {
            window[key] = state;
        }
        // Only changes that can change an issue: form fields and labels
        // added or taken away, and the attributes the rules read.
        const fieldSelector = "input, select, textarea, label, form";
        const touchesFields = (node) => node.nodeType === 1
            && (node.matches(fieldSelector) || !!node.querySelector(fieldSelector));
        const bump = (records) => {
            const relevant = records.some((record) => record.type === "attributes"
                || Array.prototype.some.call(record.addedNodes, touchesFields)
                || Array.prototype.some.call(record.removedNodes, touchesFields));
            if (!relevant)
                return;
            clearTimeout(state.timer);
            state.timer = setTimeout(() => { state.version += 1; }, 500);
        };
        try {
            new MutationObserver(bump).observe(document, {
                subtree: true, childList: true, attributes: true,
                attributeFilter: ["id", "name", "for", "type", "form", "autocomplete", "aria-label", "aria-labelledby", "title",
                    "role", "aria-hidden", "aria-describedby", "aria-controls", "tabindex"],
            });
        } catch {}
    }

    const limit = 2000;
    const idLimit = 10000;
    const elements = [];
    const label = (element) => {
        let text = (element.localName || element.nodeName || "").toLowerCase();
        if (element.id) text += "#" + element.id;
        const type = element.localName === "input" ? element.getAttribute("type") : null;
        if (type) text += "[type=" + type + "]";
        const name = element.getAttribute("name");
        if (name) text += "[name=" + name + "]";
        return text.slice(0, 160);
    };
    const attribute = (element, name) => (element.getAttribute(name) || "").slice(0, 300);

    const forms = new Map;
    const fields = [];
    let truncated = false;
    for (const element of document.querySelectorAll("input, select, textarea")) {
        if (fields.length >= limit) { truncated = true; break; }
        const type = element.localName === "input" ? (element.getAttribute("type") || "text").toLowerCase() : "";
        if (type === "hidden")
            continue;
        let form = -1;
        if (element.form) {
            if (!forms.has(element.form)) forms.set(element.form, forms.size);
            form = forms.get(element.form);
        }
        elements.push(element);
        fields.push({
            i: elements.length - 1, tag: element.localName, type,
            id: (element.id || "").slice(0, 300), name: attribute(element, "name"),
            autocomplete: element.hasAttribute("autocomplete") ? attribute(element, "autocomplete") : null,
            labels: element.labels ? element.labels.length : 0,
            ariaLabel: attribute(element, "aria-label"), ariaLabelledBy: attribute(element, "aria-labelledby"),
            title: attribute(element, "title"), form, label: label(element),
        });
    }

    const labels = [];
    for (const element of document.querySelectorAll("label")) {
        if (labels.length >= limit) { truncated = true; break; }
        elements.push(element);
        labels.push({
            i: elements.length - 1,
            for: element.hasAttribute("for") ? attribute(element, "for") : null,
            hasField: !!element.querySelector("input:not([type=hidden]), select, textarea, button, meter, output, progress"),
            label: label(element),
        });
    }

    // Elements with a role or an aria-* attribute, for the ARIA rules:
    // the attributes as written, and whether the element or something in
    // it can take keyboard focus (for aria-hidden).
    const focusableSelector = "a[href], area[href], button:not([disabled]), input:not([disabled]):not([type=hidden]), "
        + "select:not([disabled]), textarea:not([disabled]), iframe, summary, [contenteditable]:not([contenteditable=false]), "
        + "[tabindex]";
    const tabbable = (element) => element.matches(focusableSelector) && element.getAttribute("tabindex") !== "-1";
    const aria = [];
    const walker = document.createTreeWalker(document.documentElement || document, NodeFilter.SHOW_ELEMENT);
    let visited = 0;
    for (let element = walker.currentNode; element; element = walker.nextNode()) {
        if (++visited > 50000 || aria.length >= limit) { truncated = true; break; }
        if (element.nodeType !== 1)
            continue;
        const attributes = [];
        for (const attribute of element.attributes) {
            if (attribute.name.startsWith("aria-") && attributes.length < 40)
                attributes.push([attribute.name, attribute.value.slice(0, 300)]);
        }
        const role = element.hasAttribute("role") ? element.getAttribute("role").slice(0, 200) : null;
        if (!attributes.length && role === null)
            continue;
        const hidden = (element.getAttribute("aria-hidden") || "").trim().toLowerCase() === "true";
        let inner = false;
        if (hidden && !element.inert) {
            for (const child of element.querySelectorAll(focusableSelector)) {
                if (tabbable(child) && !child.inert) { inner = true; break; }
            }
        }
        elements.push(element);
        aria.push({
            i: elements.length - 1, label: label(element), role, attributes,
            focusable: !element.inert && tabbable(element),
            containsFocusable: inner, field: element.matches("input, select, textarea"),
        });
    }

    const ids = [];
    for (const element of document.querySelectorAll("[id]")) {
        if (ids.length >= idLimit) { truncated = true; break; }
        ids.push(element.id.slice(0, 300));
    }

    return {
        elements,
        state,
        data: {
            version: state.version, fields, labels, ids, aria, quirks: document.compatMode === "BackCompat", truncated,
            isolated: typeof crossOriginIsolated === "boolean" ? crossOriginIsolated : null,
        },
    };
})()
