// The Recorder panel's selectors (DeveloperRecorderModel.swift): what the
// recording script computes for an element it saw used, and what the
// replay script resolves back to an element. Evaluates to an object; the
// two scripts are each handed it. Chrome's Recorder rules, as its
// selector computers apply them:
//   aria/Name or aria/Name[role="button"]   accessible name, role if needed
//   CSS          #id, [data-testid='…'] and the like, else a short
//                nth-child path; one part per shadow root
//   xpath//…     //*[@id="…"] from the nearest id, else a full path
//   pierce/…     CSS that's unique searching through every shadow root
//   text/…       the element's own short text
// Each is kept only when it finds the element itself first.
(() => {
    const testAttributes = ["data-testid", "data-test", "data-qa", "data-cy", "data-test-id", "data-qa-id", "data-testing"];
    const elementLimit = 30000;
    const textLimit = 64;
    const nameLimit = 100;
    const spaces = new RegExp("\\s+", "g");
    const ariaPattern = new RegExp("^([\\s\\S]*?)\\[role=\"([^\"]*)\"\\]$");
    const nameFromContent = new Set([
        "button", "link", "heading", "option", "menuitem", "menuitemcheckbox", "menuitemradio", "tab",
        "checkbox", "radio", "switch", "treeitem", "cell", "gridcell", "columnheader", "rowheader",
        "row", "tooltip", "listitem", "term", "legend", "caption",
    ]);
    const buttonTypes = ["button", "submit", "reset", "image"];
    // Elements whose implicit role doesn't depend on their attributes.
    const fixedRoles = {
        button: "button", textarea: "textbox", h1: "heading", h2: "heading", h3: "heading", h4: "heading", h5: "heading",
        h6: "heading", nav: "navigation", main: "main", aside: "complementary", ul: "list", ol: "list", menu: "list",
        li: "listitem", table: "table", tr: "row", td: "cell", th: "columnheader", option: "option", dialog: "dialog",
        progress: "progressbar", meter: "meter", fieldset: "group", details: "group", summary: "button", hr: "separator",
        article: "article",
    };

    function squash(text) {
        return (text || "").replace(spaces, " ").trim();
    }

    function escapeCSS(text) {
        return window.CSS && CSS.escape ? CSS.escape(text) : text;
    }

    function isElement(node) {
        return !!node && node.nodeType === 1;
    }

    // Every element under a root, shadow roots included, in document order.
    function each(root, visit) {
        let seen = 0;
        function walk(from) {
            const walker = document.createTreeWalker(from, NodeFilter.SHOW_ELEMENT);
            let node = walker.nextNode();
            while (node) {
                if (++seen > elementLimit) return false;
                if (visit(node) === false) return false;
                if (node.shadowRoot && walk(node.shadowRoot) === false) return false;
                node = walker.nextNode();
            }
            return true;
        }
        walk(root);
    }

    function roots(start) {
        const found = [start];
        each(start, (node) => {
            if (node.shadowRoot) found.push(node.shadowRoot);
        });
        return found;
    }

    function deepQueryAll(selector, root) {
        const results = [];
        for (const scope of roots(root || document)) {
            for (const node of scope.querySelectorAll(selector)) results.push(node);
        }
        return results;
    }

    // MARK: ARIA

    function implicitRole(el) {
        const tag = el.localName;
        if (Object.hasOwn(fixedRoles, tag)) return fixedRoles[tag];
        switch (tag) {
        case "a":
        case "area":
            return el.hasAttribute("href") ? "link" : "";
        case "input": {
            const type = (el.getAttribute("type") || "text").toLowerCase();
            if (buttonTypes.includes(type)) return "button";
            if (type === "checkbox") return "checkbox";
            if (type === "radio") return "radio";
            if (type === "range") return "slider";
            if (type === "number") return "spinbutton";
            if (type === "search") return el.hasAttribute("list") ? "combobox" : "searchbox";
            if (["text", "email", "tel", "url", "password"].includes(type)) return el.hasAttribute("list") ? "combobox" : "textbox";
            return "";
        }
        case "select":
            return el.multiple || el.size > 1 ? "listbox" : "combobox";
        case "img":
            return el.getAttribute("alt") === "" ? "presentation" : "img";
        case "form": return el.hasAttribute("aria-label") || el.hasAttribute("aria-labelledby") ? "form" : "";
        case "section": return el.hasAttribute("aria-label") || el.hasAttribute("aria-labelledby") ? "region" : "";
        default: return "";
        }
    }

    function role(el) {
        const explicit = squash(el.getAttribute("role")).split(" ")[0];
        return explicit || implicitRole(el);
    }

    function hidden(el) {
        if (el.getAttribute("aria-hidden") === "true" || el.hidden) return true;
        if (el.localName === "script" || el.localName === "style" || el.localName === "template") return true;
        return false;
    }

    // The text an element's content gives its name: its text, an image's
    // alt and an element's aria-label standing for what's inside.
    function contentText(el, depth) {
        if (depth > 20) return "";
        let text = "";
        for (const child of el.childNodes) {
            if (child.nodeType === 3) {
                text += child.data;
            } else if (isElement(child) && !hidden(child)) {
                const label = child.getAttribute("aria-label");
                if (label) text += " " + label + " ";
                else if (child.localName === "img") text += " " + (child.getAttribute("alt") || "") + " ";
                else text += " " + contentText(child, depth + 1) + " ";
            }
        }
        return text;
    }

    function byIDs(el, ids) {
        const root = el.getRootNode();
        return squash(ids).split(" ").map((id) => {
            const found = root.getElementById ? root.getElementById(id) : document.getElementById(id);
            return found ? squash(found.getAttribute("aria-label") || contentText(found, 0)) : "";
        }).join(" ");
    }

    function accessibleName(el) {
        const labelledBy = el.getAttribute("aria-labelledby");
        if (labelledBy) {
            const name = squash(byIDs(el, labelledBy));
            if (name) return name;
        }
        const label = squash(el.getAttribute("aria-label"));
        if (label) return label;
        const tag = el.localName;
        if (tag === "input" && buttonTypes.includes((el.type || "").toLowerCase())) {
            if (el.type === "image") return squash(el.getAttribute("alt") || el.getAttribute("title"));
            return squash(el.value || (el.type === "submit" ? "Submit" : el.type === "reset" ? "Reset" : ""));
        }
        if (tag === "input" || tag === "textarea" || tag === "select") {
            const labels = el.labels ? Array.from(el.labels).map((each) => squash(each.innerText || each.textContent)) : [];
            const named = squash(labels.join(" "));
            if (named) return named;
            return squash(el.getAttribute("title") || el.getAttribute("placeholder"));
        }
        if (tag === "img" || tag === "area") return squash(el.getAttribute("alt") || el.getAttribute("title"));
        if (nameFromContent.has(role(el))) {
            const name = squash(contentText(el, 0));
            if (name) return name;
        }
        return squash(el.getAttribute("title"));
    }

    function ariaQuery(name, wantedRole, root) {
        const found = [];
        each(root || document, (el) => {
            if (wantedRole && role(el) !== wantedRole) return true;
            if (hidden(el)) return true;
            if (accessibleName(el) === name) found.push(el);
            // Only the first is ever wanted.
            return found.length === 0;
        });
        return found;
    }

    function ariaSelector(el) {
        const name = accessibleName(el);
        if (!name || name.length > nameLimit) return null;
        if (ariaQuery(name, "", document)[0] === el) return ["aria/" + name];
        const r = role(el);
        if (r && ariaQuery(name, r, document)[0] === el) return ["aria/" + name + "[role=\"" + r + "\"]"];
        return null;
    }

    // MARK: CSS

    function uniqueIn(root, selector, el) {
        try {
            const all = root.querySelectorAll(selector);
            return all.length === 1 && all[0] === el;
        } catch (e) {
            return false;
        }
    }

    function attributeSelector(el, root, attributes) {
        for (const name of attributes) {
            if (!name) continue;
            const value = el.getAttribute(name);
            if (value === null) continue;
            const selector = "[" + name + "='" + value.split("\\").join("\\\\").split("'").join("\\'") + "']";
            if (uniqueIn(root, selector, el)) return selector;
        }
        return null;
    }

    function idSelector(el, root) {
        if (!el.id) return null;
        const selector = "#" + escapeCSS(el.id);
        return uniqueIn(root, selector, el) ? selector : null;
    }

    function segment(el) {
        const tag = escapeCSS(el.localName);
        const parent = el.parentElement || el.parentNode;
        if (!parent || !parent.children) return tag;
        const siblings = Array.from(parent.children);
        if (siblings.filter((each) => each.localName === el.localName).length === 1) return tag;
        return tag + ":nth-child(" + (siblings.indexOf(el) + 1) + ")";
    }

    // A selector for an element within its own root (document or shadow root).
    function cssInRoot(el, root, attributes, unique) {
        const own = attributeSelector(el, root, attributes) || idSelector(el, root);
        if (own && unique(own)) return own;
        const parts = [];
        let current = el;
        while (isElement(current) && current.getRootNode() === root) {
            const anchor = current !== el ? (attributeSelector(current, root, attributes) || idSelector(current, root)) : null;
            parts.unshift(anchor || segment(current));
            const selector = parts.join(" > ");
            if (unique(selector)) return selector;
            current = current.parentElement;
        }
        return parts.join(" > ");
    }

    function cssSelector(el, attributes) {
        const chain = [];
        let current = el;
        while (isElement(current)) {
            const root = current.getRootNode();
            const target = current;
            chain.unshift(cssInRoot(current, root, attributes, (selector) => uniqueIn(root, selector, target)));
            current = root.host || null;
        }
        return chain;
    }

    function pierceSelector(el, attributes) {
        const root = el.getRootNode();
        const unique = (selector) => {
            try {
                const all = deepQueryAll(selector, document);
                return all.length === 1 && all[0] === el;
            } catch (e) {
                return false;
            }
        };
        const selector = cssInRoot(el, root, attributes, unique);
        return unique(selector) ? ["pierce/" + selector] : null;
    }

    // MARK: XPath

    function xpathSelector(el) {
        if (el.getRootNode() !== document) return null;
        const steps = [];
        let current = el;
        while (isElement(current)) {
            if (current.id && current.id.indexOf("\"") < 0 && document.querySelectorAll("#" + escapeCSS(current.id)).length === 1) {
                steps.unshift("/*[@id=\"" + current.id + "\"]");
                return ["xpath//" + steps.join("/")];
            }
            const html = current.namespaceURI === "http://www.w3.org/1999/xhtml";
            const name = html ? current.localName : "*[local-name()=\"" + current.localName + "\"]";
            const parent = current.parentElement;
            let step = name;
            if (parent) {
                const same = Array.from(parent.children).filter((each) => each.localName === current.localName);
                if (same.length > 1) step += "[" + (same.indexOf(current) + 1) + "]";
            }
            steps.unshift(step);
            current = parent;
        }
        return ["xpath//" + steps.join("/")];
    }

    // MARK: Text

    function ownText(el) {
        return squash(el.textContent);
    }

    // The deepest elements whose text has it, as Puppeteer's text selector finds them.
    function textQuery(text, root) {
        const found = [];
        each(root || document, (el) => {
            if (hidden(el)) return true;
            if (ownText(el).indexOf(text) < 0) return true;
            const deeper = Array.from(el.children).some((child) => ownText(child).indexOf(text) >= 0);
            if (!deeper) found.push(el);
            return found.length === 0;
        });
        return found;
    }

    function textSelector(el) {
        const text = ownText(el);
        if (!text || text.length > textLimit) return null;
        return textQuery(text, document)[0] === el ? ["text/" + text] : null;
    }

    // MARK: Computing and resolving

    function compute(el, options) {
        const types = new Set(options && options.types ? options.types : ["aria", "css", "xpath", "pierce", "text"]);
        const attributes = [(options && options.attribute) || ""].concat(testAttributes);
        const out = [];
        const add = (type, make) => {
            if (!types.has(type)) return;
            try {
                const selector = make();
                if (selector && selector.length && selector.every((part) => part)) out.push(selector);
            } catch (e) {}
        };
        add("aria", () => ariaSelector(el));
        add("css", () => cssSelector(el, attributes));
        add("xpath", () => xpathSelector(el));
        add("pierce", () => pierceSelector(el, attributes));
        add("text", () => textSelector(el));
        return out;
    }

    function resolveOne(part, root) {
        if (part.startsWith("aria/")) {
            const body = part.slice(5);
            const match = ariaPattern.exec(body);
            return ariaQuery(match ? match[1] : body, match ? match[2] : "", root)[0] || null;
        }
        if (part.startsWith("text/")) return textQuery(part.slice(5), root)[0] || null;
        if (part.startsWith("pierce/")) return deepQueryAll(part.slice(7), root)[0] || null;
        if (part.startsWith("xpath/")) {
            const context = root.nodeType === 9 ? root : root.host || document;
            const result = document.evaluate(part.slice(6), context, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null);
            return result.singleNodeValue;
        }
        return root.querySelector(part);
    }

    // A selector's parts, each found within the shadow root (or frame
    // document) of the one before.
    function resolve(selector) {
        const parts = Array.isArray(selector) ? selector : [selector];
        let root = document;
        let el = null;
        for (let index = 0; index < parts.length; index++) {
            el = resolveOne(parts[index], root);
            if (!el) return null;
            if (index < parts.length - 1) {
                root = el.shadowRoot || el.contentDocument;
                if (!root) return null;
            }
        }
        return el;
    }

    return { compute, resolve, role, accessibleName, deepQueryAll };
})()
