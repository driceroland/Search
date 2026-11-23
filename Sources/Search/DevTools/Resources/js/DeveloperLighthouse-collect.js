// The Lighthouse panel's page scan (DeveloperLighthouseModel.swift): run once
// per audit in the page (Runtime.evaluate, main world) after the load. It
// reads, and never changes, the document (its one act is the empty paste
// event Lighthouse also sends each field): the head's tags, the images and
// their sizes, the controls and links with their accessible names (a
// simplified version of the accessible name computation), headings, ARIA
// attributes, list structure, ids, text colours and what's behind them,
// the DOM's size and the Resource Timing entries. Each element it reports
// is kept in `elements` (the returned holder stays in an object group) so
// the panel can highlight or reveal it by index; it is sent as
// [index, snippet, selector, label]. The rules themselves are in Swift
// (DeveloperLighthouseRules.swift).
(() => {
    const listLimit = 500;
    const elementLimit = 30000;
    const elements = [];
    const indexes = new Map();
    const squash = (text) => String(text || "").replace(/\s+/g, " ").trim();

    const snippet = (el) => {
        const html = el.outerHTML || "";
        const close = html.indexOf(">");
        let open = close >= 0 ? html.slice(0, close + 1) : html;
        if (open.length > 200) open = open.slice(0, 196) + "…\">";
        return open;
    };
    const selector = (el) => {
        const parts = [];
        let current = el;
        while (current && current.nodeType === 1 && parts.length < 4) {
            let part = current.localName;
            if (current.id) {
                parts.unshift(part + "#" + current.id);
                break;
            }
            const classes = current.classList ? Array.from(current.classList).slice(0, 2) : [];
            if (classes.length) part += "." + classes.join(".");
            const parent = current.parentElement;
            if (parent) {
                const same = Array.from(parent.children).filter((child) => child.localName === current.localName);
                if (same.length > 1) part += ":nth-of-type(" + (same.indexOf(current) + 1) + ")";
            }
            parts.unshift(part);
            current = parent;
        }
        return parts.join(" > ");
    };
    const nodeLabel = (el) => {
        const text = squash((el.textContent || "").slice(0, 400));
        if (text) return text.slice(0, 80);
        const named = el.getAttribute && (el.getAttribute("alt") || el.getAttribute("aria-label") || el.getAttribute("title"));
        if (named) return named.slice(0, 80);
        return el.localName || "";
    };
    const node = (el) => {
        let index = indexes.get(el);
        if (index === undefined) {
            index = elements.length;
            elements.push(el);
            indexes.set(el, index);
        }
        return [index, snippet(el), selector(el), nodeLabel(el)];
    };

    const visible = (el) => {
        const style = getComputedStyle(el);
        if (style.display === "none" || style.visibility === "hidden" || style.visibility === "collapse") return false;
        return el.getClientRects().length > 0;
    };
    const ariaHidden = (el) => !!el.closest("[aria-hidden=\"true\"]");

    // A simplified accessible name: aria-labelledby, aria-label, labels,
    // alt, the content (for buttons and links), title, placeholder.
    const byIds = (el, attribute) => {
        const ids = (el.getAttribute(attribute) || "").split(/\s+/).filter(Boolean);
        return squash(ids.map((id) => {
            const target = document.getElementById(id);
            return target ? target.textContent : "";
        }).join(" "));
    };
    const subtree = (el) => {
        let out = "";
        const walk = (parent, depth) => {
            if (depth > 30) return;
            for (const child of parent.childNodes) {
                if (child.nodeType === 3) {
                    out += child.data;
                } else if (child.nodeType === 1) {
                    if (child.getAttribute("aria-hidden") === "true") continue;
                    const tag = child.localName;
                    if (tag === "img" || tag === "area" || (tag === "input" && child.type === "image")) {
                        out += " " + (child.getAttribute("alt") || child.getAttribute("aria-label") || "") + " ";
                    } else if (child.getAttribute("aria-label")) {
                        out += " " + child.getAttribute("aria-label") + " ";
                    } else if (tag === "svg") {
                        const title = child.querySelector("title");
                        out += " " + (title ? title.textContent : "") + " ";
                    } else if (tag !== "script" && tag !== "style") {
                        const style = getComputedStyle(child);
                        if (style.display !== "none" && style.visibility !== "hidden") walk(child, depth + 1);
                    }
                }
            }
        };
        walk(el, 0);
        return squash(out);
    };
    const accessibleName = (el, content) => {
        const labelled = byIds(el, "aria-labelledby");
        if (labelled) return labelled;
        const label = squash(el.getAttribute("aria-label"));
        if (label) return label;
        if (el.labels && el.labels.length) {
            const text = squash(Array.from(el.labels).map((item) => subtree(item)).join(" "));
            if (text) return text;
        }
        const tag = el.localName;
        if (tag === "img" || tag === "area" || (tag === "input" && el.type === "image")) {
            const alt = squash(el.getAttribute("alt"));
            if (alt) return alt;
        }
        if (tag === "input" && ["button", "submit", "reset"].includes(el.type)) {
            if (squash(el.value)) return squash(el.value);
            if (el.type !== "button") return el.type === "submit" ? "Submit" : "Reset";
        }
        if (content) {
            const text = subtree(el);
            if (text) return text;
        }
        const title = squash(el.getAttribute("title"));
        if (title) return title;
        if (tag === "input" || tag === "textarea") {
            const placeholder = squash(el.getAttribute("placeholder"));
            if (placeholder) return placeholder;
        }
        return "";
    };
    const attribute = (el, name) => (el.hasAttribute(name) ? el.getAttribute(name) : null);

    const data = {
        url: location.href,
        title: document.querySelector("title") ? document.title : null,
        lang: attribute(document.documentElement, "lang"),
        xmlLang: attribute(document.documentElement, "xml:lang"),
        doctype: document.doctype ? {
            name: document.doctype.name, publicId: document.doctype.publicId, systemId: document.doctype.systemId,
        } : null,
        compatMode: document.compatMode,
        characterSet: document.characterSet,
        userAgent: navigator.userAgent,
        dpr: window.devicePixelRatio || 1,
        width: window.innerWidth,
        height: window.innerHeight,
    };

    // The head.
    const metas = Array.from(document.querySelectorAll("meta"));
    const metaNamed = (name) => metas.find((meta) => (meta.getAttribute("name") || "").toLowerCase() === name);
    data.charsetMeta = metas.some((meta) => meta.hasAttribute("charset")
        || ((meta.getAttribute("http-equiv") || "").toLowerCase() === "content-type"
            && (meta.getAttribute("content") || "").toLowerCase().includes("charset")));
    const viewportMeta = metaNamed("viewport");
    data.viewport = viewportMeta ? viewportMeta.getAttribute("content") || "" : null;
    const description = metaNamed("description");
    data.description = description ? description.getAttribute("content") || "" : null;
    data.robots = metas.filter((meta) => ["robots", "googlebot"].includes((meta.getAttribute("name") || "").toLowerCase()))
        .map((meta) => meta.getAttribute("content") || "");
    const links = Array.from(document.querySelectorAll("link[rel]"));
    const rels = (link) => (link.getAttribute("rel") || "").toLowerCase().split(/\s+/);
    data.canonicals = links.filter((link) => rels(link).includes("canonical"))
        .map((link) => [link.getAttribute("href") || "", link.href || ""]);
    data.hreflangs = links.filter((link) => rels(link).includes("alternate") && link.hasAttribute("hreflang"))
        .map((link) => [link.getAttribute("hreflang") || "", link.getAttribute("href") || "", link.href || ""]);
    data.head = [];
    if (document.head) {
        for (const el of document.head.children) {
            if (el.localName === "script" && el.hasAttribute("src")) {
                const type = (el.getAttribute("type") || "").toLowerCase();
                data.head.push({
                    n: node(el), kind: "script", url: el.src, async: el.async, defer: el.defer, module: type === "module",
                });
            } else if (el.localName === "link" && rels(el).includes("stylesheet") && !rels(el).includes("alternate")) {
                let matches = true;
                try {
                    matches = !el.media || window.matchMedia(el.media).matches;
                } catch (error) {
                    matches = true;
                }
                data.head.push({ n: node(el), kind: "stylesheet", url: el.href, media: matches, disabled: !!el.disabled });
            }
        }
    }

    // Images.
    data.images = [];
    for (const img of Array.from(document.images).slice(0, listLimit)) {
        const rect = img.getBoundingClientRect();
        const style = getComputedStyle(img);
        const inlineSized = !!(img.style.width && img.style.height);
        const ratioSized = style.aspectRatio && style.aspectRatio !== "auto"
            && (img.hasAttribute("width") || img.hasAttribute("height") || !!img.style.width || !!img.style.height);
        data.images.push({
            n: node(img),
            src: img.currentSrc || img.src || "",
            nw: img.naturalWidth, nh: img.naturalHeight, dw: rect.width, dh: rect.height,
            alt: attribute(img, "alt"), role: attribute(img, "role"), name: accessibleName(img, false),
            wa: img.hasAttribute("width"), ha: img.hasAttribute("height"), css: inlineSized || !!ratioSized,
            position: style.position, fit: style.objectFit || "fill",
            pixelated: style.imageRendering === "pixelated" || style.imageRendering === "crisp-edges",
            visible: visible(img), hidden: ariaHidden(img),
            inViewport: rect.bottom > 0 && rect.right > 0 && rect.top < window.innerHeight && rect.left < window.innerWidth,
            // In the document as if scrolled to the top (offscreen-images).
            rect: [rect.top + window.scrollY, rect.left + window.scrollX, rect.bottom + window.scrollY, rect.right + window.scrollX],
            lazy: (img.getAttribute("loading") || "").toLowerCase() === "lazy",
        });
    }

    // Controls, by what names them.
    const named = (list, content) => list.slice(0, listLimit).map((el) => ({
        n: node(el), name: accessibleName(el, content), role: attribute(el, "role"),
    }));
    const shown = (el) => visible(el) && !ariaHidden(el);
    data.inputImages = named(Array.from(document.querySelectorAll("input[type=image i]")).filter(shown), false);
    data.buttons = named(Array.from(document.querySelectorAll("button, [role=button], input[type=button i], input[type=submit i], input[type=reset i]"))
        .filter(shown), true);
    const fieldSkip = new Set(["hidden", "button", "submit", "reset", "image"]);
    // axe's label rule takes inputs and text areas; select-name takes selects.
    data.selects = named(Array.from(document.querySelectorAll("select"))
        .filter((el) => !(el.getAttribute("role") || "").match(/^(none|presentation)$/i)).filter(shown), false);
    data.fields = named(Array.from(document.querySelectorAll("input, textarea"))
        .filter((el) => !(el.localName === "input" && fieldSkip.has((el.getAttribute("type") || "").toLowerCase()))
            && !(el.getAttribute("role") || "").match(/^(none|presentation)$/i))
        .filter(shown), false);
    data.frames = named(Array.from(document.querySelectorAll("iframe, frame")).filter(shown), false);

    // Links: every anchor (for crawlability), and other role=link elements.
    data.links = [];
    const anchors = Array.from(document.querySelectorAll("a, area[href], [role=link]")).slice(0, 1500);
    for (const el of anchors) {
        if (ariaHidden(el)) continue;
        data.links.push({
            n: node(el), tag: el.localName, name: accessibleName(el, true), text: squash((el.innerText || el.textContent || "").slice(0, 300)),
            raw: attribute(el, "href"), href: el.href ? String(el.href) : "", role: attribute(el, "role"),
            onclick: el.hasAttribute("onclick"), nameAttr: el.hasAttribute("name"),
            visible: visible(el),
        });
    }

    // Headings in document order.
    data.headings = [];
    for (const el of Array.from(document.querySelectorAll("h1, h2, h3, h4, h5, h6, [role=heading]")).slice(0, listLimit)) {
        if (!shown(el)) continue;
        let level = parseInt(el.getAttribute("aria-level") || "", 10);
        if (!level) level = /^h[1-6]$/.test(el.localName) ? parseInt(el.localName.slice(1), 10) : 2;
        data.headings.push({ n: node(el), level });
    }

    // HTML-AAM's implicit roles, for aria-allowed-attr; null where an
    // element's role depends on more than is worked out here.
    const implicitRole = (el) => {
        const tag = el.localName;
        const type = (el.getAttribute("type") || "text").toLowerCase();
        const landmarkScoped = () => !!el.parentElement && !!el.parentElement.closest("article, aside, main, nav, section");
        switch (tag) {
            case "a": case "area": return el.hasAttribute("href") ? "link" : "generic";
            case "article": return "article";
            case "aside": return "complementary";
            case "button": return "button";
            case "datalist": return "listbox";
            case "details": case "fieldset": case "optgroup": return "group";
            case "dialog": return "dialog";
            case "div": case "span": case "b": case "i": case "u": case "small": case "bdi": case "bdo": case "data":
            case "q": case "samp": case "pre": return "generic";
            case "figure": return "figure";
            case "footer": return landmarkScoped() ? "generic" : "contentinfo";
            case "header": return landmarkScoped() ? "generic" : "banner";
            case "form": return "form";
            case "h1": case "h2": case "h3": case "h4": case "h5": case "h6": return "heading";
            case "hr": return "separator";
            case "img": return el.getAttribute("alt") === "" ? "presentation" : "img";
            case "input":
                if (["button", "submit", "reset", "image"].includes(type)) return "button";
                if (type === "checkbox") return "checkbox";
                if (type === "radio") return "radio";
                if (type === "range") return "slider";
                if (type === "number") return "spinbutton";
                if (type === "search") return el.hasAttribute("list") ? "combobox" : "searchbox";
                if (["text", "email", "tel", "url"].includes(type)) return el.hasAttribute("list") ? "combobox" : "textbox";
                return null;
            case "li": return "listitem";
            case "main": return "main";
            case "menu": case "ol": case "ul": return "list";
            case "nav": return "navigation";
            case "option": return "option";
            case "output": return "status";
            case "p": return "paragraph";
            case "progress": return "progressbar";
            case "meter": return "meter";
            case "select": return el.multiple || el.size > 1 ? "listbox" : "combobox";
            case "table": return "table";
            case "tbody": case "thead": case "tfoot": return "rowgroup";
            case "td": return "cell";
            case "th": return (el.getAttribute("scope") || "").toLowerCase() === "row" ? "rowheader" : "columnheader";
            case "tr": return "row";
            case "textarea": return "textbox";
            default: return null;
        }
    };

    // One walk over every element: ARIA, tabindex, ids, the DOM's size and
    // text colours.
    const nativeTags = new Set(["input", "select", "textarea", "progress", "meter", "option"]);
    const referencing = ["aria-labelledby", "aria-describedby", "aria-controls", "aria-owns", "aria-activedescendant",
        "aria-flowto", "aria-errormessage", "aria-details"];
    data.aria = [];
    data.tabindex = [];
    data.texts = [];
    const ids = new Map();
    const referenced = new Set();
    let total = 0;
    let deepest = 0;
    let deepestNode = null;
    let widest = 0;
    let widestNode = null;
    const backgroundsOf = (el) => {
        const layers = [];
        let current = el;
        let steps = 0;
        while (current && current.nodeType === 1 && steps < 40) {
            const style = getComputedStyle(current);
            if (style.backgroundImage && style.backgroundImage !== "none") return null;
            const color = style.backgroundColor;
            if (color && color !== "transparent" && color !== "rgba(0, 0, 0, 0)") {
                layers.push(color);
                if (!/rgba|\/|hsla/.test(color) || /,\s*1\)$/.test(color)) break;
            }
            current = current.parentElement;
            steps += 1;
        }
        return layers;
    };
    const hasOwnText = (el) => {
        for (const child of el.childNodes) {
            if (child.nodeType === 3 && child.data.trim()) return true;
        }
        return false;
    };
    const stack = document.documentElement ? [[document.documentElement, 1]] : [];
    while (stack.length) {
        const [el, depth] = stack.pop();
        total += 1;
        if (depth > deepest) {
            deepest = depth;
            deepestNode = el;
        }
        if (el.childElementCount > widest) {
            widest = el.childElementCount;
            widestNode = el;
        }
        if (total <= elementLimit) {
            const names = [];
            for (const attr of el.attributes) {
                const name = attr.name.toLowerCase();
                if (name.startsWith("aria-")) names.push(name);
                if (referencing.includes(name)) for (const id of attr.value.split(/\s+/)) if (id) referenced.add(id);
            }
            if ((names.length || el.hasAttribute("role")) && data.aria.length < 2000) {
                data.aria.push({
                    n: node(el), tag: el.localName, role: attribute(el, "role"), attrs: names, native: nativeTags.has(el.localName),
                    implicit: implicitRole(el),
                });
            }
            if (el.hasAttribute("tabindex") && data.tabindex.length < listLimit) {
                data.tabindex.push({ n: node(el), value: parseInt(el.getAttribute("tabindex"), 10) || 0 });
            }
            if (el.id) {
                const list = ids.get(el.id);
                if (list) list.push(el);
                else ids.set(el.id, [el]);
            }
            if (el.localName === "label" && el.htmlFor) referenced.add(el.htmlFor);
            if (data.texts.length < 1500 && hasOwnText(el) && !["script", "style", "noscript", "title", "option"].includes(el.localName)) {
                const style = getComputedStyle(el);
                if (style.display !== "none" && style.visibility === "visible" && parseFloat(style.opacity) > 0
                    && el.getClientRects().length && !ariaHidden(el) && !el.disabled && !el.closest("[disabled]")) {
                    data.texts.push({
                        n: node(el), color: style.color, backgrounds: backgroundsOf(el),
                        fontSize: style.fontSize, fontWeight: style.fontWeight,
                    });
                }
            }
        }
        const children = el.children;
        for (let i = children.length - 1; i >= 0; i--) stack.push([children[i], depth + 1]);
    }
    data.dom = {
        elements: total, depth: deepest, children: widest,
        depthNode: deepestNode ? node(deepestNode) : null, widestNode: widestNode ? node(widestNode) : null,
    };
    data.duplicateIds = [];
    for (const [id, list] of ids) {
        if (list.length < 2 || data.duplicateIds.length >= 200) continue;
        data.duplicateIds.push({ id, referenced: referenced.has(id), nodes: list.slice(0, 10).map(node) });
    }

    // Lists and list items.
    data.lists = [];
    for (const el of Array.from(document.querySelectorAll("ul, ol")).slice(0, listLimit)) {
        const role = (el.getAttribute("role") || "").toLowerCase();
        if (role && role !== "list") continue;
        if (!shown(el)) continue;
        data.lists.push({ n: node(el), children: Array.from(el.children).map((child) => [child.localName, attribute(child, "role")]) });
    }
    data.listItems = [];
    for (const el of Array.from(document.querySelectorAll("li")).slice(0, listLimit * 2)) {
        if (!shown(el)) continue;
        const parent = el.parentElement;
        data.listItems.push({
            n: node(el), role: attribute(el, "role"),
            parent: parent ? parent.localName : "", parentRole: parent ? attribute(parent, "role") : null,
        });
    }

    // Landmarks and the body (bypass, landmark-one-main, aria-hidden-body).
    data.mains = Array.from(document.querySelectorAll("main, [role=main i]")).filter(shown).length;
    if (document.body) {
        data.body = node(document.body);
        data.bodyHidden = document.body.getAttribute("aria-hidden") === "true";
    }

    // Touch targets (target-size): widgets in the viewport's coordinates,
    // leaving out links inline in a run of text, as axe does.
    data.targets = [];
    const targetSelector = "a[href], button, input:not([type=hidden i]), select, textarea, summary, "
        + "[role=button i], [role=link i], [role=checkbox i], [role=radio i], [role=switch i], [role=tab i], "
        + "[role=menuitem i], [role=menuitemcheckbox i], [role=menuitemradio i], [role=option i], [role=slider i]";
    const inTextBlock = (el) => {
        const style = getComputedStyle(el);
        if (style.display !== "inline") return false;
        const parent = el.parentElement;
        if (!parent) return false;
        const own = squash(el.textContent).length;
        return squash(parent.textContent).length > own;
    };
    for (const el of Array.from(document.querySelectorAll(targetSelector)).slice(0, 600)) {
        if (!shown(el) || el.disabled || el.closest("[inert]")) continue;
        if (inTextBlock(el)) continue;
        const rect = el.getBoundingClientRect();
        if (rect.width <= 0 || rect.height <= 0) continue;
        data.targets.push({ n: node(el), x: rect.left, y: rect.top, w: rect.width, h: rect.height });
    }

    // Table cells naming their headers (td-headers-attr).
    data.headersCells = [];
    for (const cell of Array.from(document.querySelectorAll("td[headers], th[headers]")).slice(0, listLimit)) {
        const table = cell.closest("table");
        if (!table) continue;
        const headers = (cell.getAttribute("headers") || "").split(/\s+/).filter(Boolean);
        if (!headers.length) continue;
        const found = headers.filter((id) => {
            const target = document.getElementById(id);
            return !!target && target !== cell && /^t[dh]$/.test(target.localName) && target.closest("table") === table;
        });
        data.headersCells.push({ n: node(cell), headers, found, id: cell.id || "" });
    }

    // Languages of parts of the page (valid-lang) and timed refreshes (meta-refresh).
    data.langs = [];
    for (const el of Array.from(document.querySelectorAll("[lang], [xml\\:lang]")).slice(0, listLimit)) {
        if (el === document.documentElement) continue;
        const lang = el.getAttribute("lang") ?? el.getAttribute("xml:lang") ?? "";
        data.langs.push({ n: node(el), lang });
    }
    data.metaRefresh = metas.filter((meta) => (meta.getAttribute("http-equiv") || "").toLowerCase() === "refresh"
        && meta.hasAttribute("content")).map((meta) => ({ n: node(meta), content: meta.getAttribute("content") || "" }));
    data.metaCSP = metas.filter((meta) => (meta.getAttribute("http-equiv") || "").toLowerCase() === "content-security-policy")
        .map((meta) => meta.getAttribute("content") || "");
    data.preconnects = links.filter((link) => rels(link).includes("preconnect") || rels(link).includes("dns-prefetch"))
        .map((link) => link.href || "").filter(Boolean);

    // @font-face rules the page can read (font-display); sheets from other
    // origins are only counted.
    data.fontFaces = [];
    data.unreadableSheets = 0;
    const seenSheets = new Set();
    const fontURLs = (src, base) => {
        const urls = [];
        const pattern = /url\(\s*(["']?)(.*?)\1\s*\)/g;
        let match;
        while ((match = pattern.exec(src || "")) && urls.length < 20) {
            try {
                urls.push(new URL(match[2], base).href);
            } catch (error) {}
        }
        return urls;
    };
    const visitSheet = (sheet, depth) => {
        if (!sheet || seenSheets.has(sheet) || depth > 10 || data.fontFaces.length >= 200) return;
        seenSheets.add(sheet);
        let rules;
        try {
            rules = sheet.cssRules;
        } catch (error) {
            data.unreadableSheets += 1;
            return;
        }
        if (!rules) return;
        const base = sheet.href || location.href;
        const walkRules = (list) => {
            for (const rule of list) {
                if (typeof CSSFontFaceRule === "function" && rule instanceof CSSFontFaceRule) {
                    data.fontFaces.push({
                        family: rule.style.getPropertyValue("font-family"),
                        display: rule.style.getPropertyValue("font-display"),
                        urls: fontURLs(rule.style.getPropertyValue("src"), base),
                    });
                } else if (typeof CSSImportRule === "function" && rule instanceof CSSImportRule) {
                    visitSheet(rule.styleSheet, depth + 1);
                } else if (rule.cssRules) {
                    walkRules(rule.cssRules);
                }
            }
        };
        walkRules(rules);
    };
    try {
        for (const sheet of document.styleSheets) visitSheet(sheet, 0);
        for (const sheet of document.adoptedStyleSheets || []) visitSheet(sheet, 0);
    } catch (error) {}

    // Fields that cancel a paste (paste-preventing-inputs): as Lighthouse
    // does, a cancelable paste event is dispatched at each and the page's
    // handlers decide. Nothing is pasted: the event carries no data.
    data.pasteBlocked = [];
    for (const el of Array.from(document.querySelectorAll("input, textarea")).slice(0, listLimit)) {
        if (el.localName === "input" && ["hidden", "button", "submit", "reset", "image", "checkbox", "radio", "file", "range", "color"]
            .includes((el.getAttribute("type") || "").toLowerCase())) continue;
        try {
            const event = new ClipboardEvent("paste", { cancelable: true });
            if (!el.dispatchEvent(event)) data.pasteBlocked.push(node(el));
        } catch (error) {}
    }

    // Permission requests the page made as it loaded, as the panel's
    // page-world watcher (DeveloperLighthouseModel) saw them; absent
    // unless a Navigation run put the watcher in.
    const permissionLog = window[Symbol.for("perch.lighthouse.permissions")];
    if (Array.isArray(permissionLog)) data.permissionCalls = permissionLog.slice(0, 50);

    // Resource Timing, in the page's clock.
    data.resources = performance.getEntriesByType("resource").slice(0, 800).map((entry) => ({
        name: entry.name, type: entry.initiatorType, start: entry.startTime, end: entry.responseEnd,
        transfer: entry.transferSize || 0, encoded: entry.encodedBodySize || 0, decoded: entry.decodedBodySize || 0,
        blocking: entry.renderBlockingStatus || null,
    }));

    return { data, elements };
})()
