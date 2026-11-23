// The CSS overview drawer's capture: run once in the page (Runtime.evaluate,
// main world) when Capture overview is clicked. It reads, and never
// changes, the document: every element's computed colours, fonts and the
// few properties the unused-declaration checks look at, and the
// same-origin style sheets' rules, selectors and media queries. What it
// finds goes back as plain data (strings interned in a table to keep the
// answer small); the elements stay behind in the returned holder so the
// drawer can ask for one by index to reveal or highlight it. All the
// counting, colour parsing and contrast is done in Swift
// (DeveloperCSSOverview.swift).
(() => {
    const elementLimit = 25000;
    const selectorLimit = 60000;
    const fields = [
        "color", "backgroundColor", "borderTopColor", "borderRightColor", "borderBottomColor", "borderLeftColor",
        "fill", "fontFamily", "fontSize", "fontWeight", "lineHeight", "display", "position",
        "top", "right", "bottom", "left", "width", "height", "verticalAlign",
        "marginTop", "marginRight", "marginBottom", "marginLeft",
    ];
    const strings = [];
    const stringIndex = new Map();
    const intern = (value) => {
        const text = typeof value === "string" ? value.slice(0, 300) : "";
        let index = stringIndex.get(text);
        if (index === undefined) {
            index = strings.length;
            strings.push(text);
            stringIndex.set(text, index);
        }
        return index;
    };
    intern("");

    const label = (element) => {
        let text = (element.localName || element.nodeName || "").toLowerCase();
        if (element.id) text += "#" + element.id;
        const classes = element.classList ? Array.from(element.classList).slice(0, 3) : [];
        if (classes.length) text += "." + classes.join(".");
        return text.slice(0, 160);
    };
    const hasOwnText = (element) => {
        for (const child of element.childNodes) {
            if (child.nodeType === 3 && child.data.trim()) return true;
        }
        return false;
    };
    const sides = ["Top", "Right", "Bottom", "Left"];
    const svgShapes = new Set(["path", "rect", "circle", "ellipse", "line", "polyline", "polygon", "text", "tspan", "textPath", "use"]);
    const svgNamespace = "http://www.w3.org/2000/svg";

    // Elements in tree order, into open shadow roots; each one's parent
    // as an index, for the effective background behind its text.
    const elements = [];
    const rows = [];
    let total = 0;
    const walk = (root) => {
        const stack = [[root, -1]];
        while (stack.length) {
            const [node, parent] = stack.pop();
            let index = parent;
            if (node.nodeType === 1) {
                total += 1;
                if (elements.length < elementLimit) {
                    const style = getComputedStyle(node);
                    index = elements.length;
                    elements.push(node);
                    // flags: 1 own text, 2 rendered, 4 background image, 8 SVG shape
                    let flags = 0;
                    if (hasOwnText(node)) flags |= 1;
                    if (style.display !== "none" && style.visibility !== "hidden" && node.getClientRects().length > 0) flags |= 2;
                    if (style.backgroundImage && style.backgroundImage !== "none") flags |= 4;
                    const shape = node.namespaceURI === svgNamespace && svgShapes.has(node.localName);
                    if (shape) flags |= 8;
                    const row = [parent, flags, intern(label(node))];
                    for (const field of fields) {
                        let value = style[field];
                        if (field === "fill" && !shape) value = "";
                        if (field.startsWith("border")) {
                            const side = sides.find((name) => field === "border" + name + "Color");
                            const width = parseFloat(style["border" + side + "Width"]) || 0;
                            const kind = style["border" + side + "Style"];
                            if (width <= 0 || kind === "none" || kind === "hidden") value = "";
                        }
                        row.push(intern(value));
                    }
                    rows.push(row);
                }
            }
            // Children pushed last first, so they come off in document
            // order; a shadow root's after the light children.
            const children = [];
            for (let child = node.firstElementChild; child; child = child.nextElementSibling) children.push(child);
            if (node.shadowRoot) {
                for (let child = node.shadowRoot.firstElementChild; child; child = child.nextElementSibling) children.push(child);
            }
            for (let i = children.length - 1; i >= 0; i--) stack.push([children[i], index]);
        }
    };
    walk(document);

    // The style sheets: external and inline, and the rules of those that
    // can be read (cross-origin ones can't).
    let externalSheets = 0;
    let inlineSheets = 0;
    let unreadableSheets = 0;
    let styleRules = 0;
    const selectors = [];
    const media = [];
    const seenSheets = new Set();
    const readRules = (rules, depth) => {
        if (!rules || depth > 20) return;
        for (const rule of rules) {
            if (rule instanceof CSSStyleRule) {
                styleRules += 1;
                if (selectors.length < selectorLimit) selectors.push(String(rule.selectorText || "").slice(0, 400));
                if (rule.cssRules && rule.cssRules.length) readRules(rule.cssRules, depth + 1);
            } else if (typeof CSSMediaRule !== "undefined" && rule instanceof CSSMediaRule) {
                media.push(String(rule.conditionText || rule.media?.mediaText || "").slice(0, 300));
                readRules(rule.cssRules, depth + 1);
            } else if (typeof CSSImportRule !== "undefined" && rule instanceof CSSImportRule) {
                readSheet(rule.styleSheet, depth + 1);
            } else if (rule.cssRules) {
                readRules(rule.cssRules, depth + 1);
            }
        }
    };
    const readSheet = (sheet, depth) => {
        if (!sheet || seenSheets.has(sheet)) return;
        seenSheets.add(sheet);
        let rules = null;
        try {
            rules = sheet.cssRules;
        } catch {
            unreadableSheets += 1;
            return;
        }
        readRules(rules, depth);
    };
    const sheets = [];
    const collectSheets = (root) => {
        for (const sheet of Array.from(root.styleSheets || [])) sheets.push(sheet);
        for (const sheet of Array.from(root.adoptedStyleSheets || [])) sheets.push(sheet);
    };
    collectSheets(document);
    for (const element of elements) {
        if (element.shadowRoot) collectSheets(element.shadowRoot);
    }
    for (const sheet of sheets) {
        if (seenSheets.has(sheet)) continue;
        if (sheet.href) externalSheets += 1;
        else inlineSheets += 1;
        readSheet(sheet, 0);
    }

    return {
        elements,
        data: {
            fields,
            strings,
            rows,
            total,
            truncated: total > elements.length,
            externalSheets,
            inlineSheets,
            unreadableSheets,
            styleRules,
            selectors,
            media,
        },
    };
})()
