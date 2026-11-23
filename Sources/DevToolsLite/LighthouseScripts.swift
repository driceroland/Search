import Foundation

// The page side of the Lighthouse audits: three scripts, each run in the
// tools' own world, never the page's. They read the page and change nothing
// in it. What they call is the tools' world's own, so a page that replaces
// querySelector or JSON on its side can't change what they find.
enum LighthouseScripts {
    /// Put in the tab at the start of a Navigation run's load (a user script
    /// of the tools' world, main frame), and taken out after: paint and
    /// largest-contentful-paint entries where this WebKit has them, errors
    /// the page threw, main-thread blocking as the gaps in a zero-delay
    /// timer loop (WebKit has no longtask entries), and layout shifts found
    /// by comparing boxes between samples (it has no layout-shift entries
    /// either). It only watches.
    static let observe = #"""
    (() => {
        if (window.__searchDeveloperLoad) return;
        const state = { started: performance.now(), fcp: null, lcp: null, lcpElement: null, lcpSupported: false,
            cls: 0, shifts: 0, tasks: [], errors: [], stopped: false };
        window.__searchDeveloperLoad = state;
        const limit = 60000;
        const types = (typeof PerformanceObserver !== "undefined" && PerformanceObserver.supportedEntryTypes) || [];
        const observe = (type, callback) => {
            if (!types.includes(type)) return false;
            try {
                new PerformanceObserver((list) => { for (const entry of list.getEntries()) callback(entry); })
                    .observe({ type, buffered: true });
                return true;
            } catch (e) { return false; }
        };
        observe("paint", (entry) => {
            if (entry.name === "first-contentful-paint" && state.fcp === null) state.fcp = entry.startTime;
        });
        state.lcpSupported = observe("largest-contentful-paint", (entry) => {
            state.lcp = entry.renderTime || entry.loadTime || entry.startTime;
            state.lcpElement = entry.element || null;
        });
        const errored = (message, source) => {
            if (state.errors.length < 50) state.errors.push([String(message || "").slice(0, 300), String(source || "").slice(0, 300)]);
        };
        window.addEventListener("error", (event) => {
            if (event.target && event.target !== window) {
                errored("Failed to load resource", event.target.src || event.target.href || "");
            } else {
                errored(event.message, event.filename);
            }
        }, true);
        window.addEventListener("unhandledrejection", (event) => {
            const reason = event.reason;
            errored("Unhandled rejection: " + (reason && reason.message ? reason.message : String(reason)), location.href);
        });
        let last = performance.now();
        const tick = () => {
            const now = performance.now();
            const gap = now - last;
            if (gap > 50 && document.visibilityState === "visible") state.tasks.push([last, gap]);
            last = now;
            if (!state.stopped && now - state.started < limit) setTimeout(tick, 0);
        };
        setTimeout(tick, 0);
        // Layout shifts: each sample takes the boxes of up to 1500 elements
        // in document coordinates; those that moved make a shift worth the
        // share of the viewport they cover times how far they went. Shifts
        // within half a second of input don't count, and the score is the
        // worst run of shifts less than a second apart (five at most), as
        // Core Web Vitals counts it.
        const previous = new WeakMap();
        let lastInput = -Infinity;
        for (const type of ["pointerdown", "keydown", "mousedown"]) {
            window.addEventListener(type, (event) => { if (event.isTrusted) lastInput = performance.now(); }, true);
        }
        let windowValue = 0, windowStart = 0, windowLast = 0;
        const grid = 100;
        const sample = () => {
            if (state.stopped || performance.now() - state.started > limit) return;
            const width = innerWidth, height = innerHeight;
            const root = document.body || document.documentElement;
            if (root && width > 0 && height > 0) {
                const sx = scrollX, sy = scrollY;
                const moved = [];
                let distance = 0;
                const all = root.getElementsByTagName("*");
                for (let i = 0; i < all.length && i < 1500; i++) {
                    const rect = all[i].getBoundingClientRect();
                    if (rect.width === 0 && rect.height === 0) { previous.delete(all[i]); continue; }
                    const now = { x: rect.left + sx, y: rect.top + sy, w: rect.width, h: rect.height };
                    const before = previous.get(all[i]);
                    previous.set(all[i], now);
                    if (!before) continue;
                    const dx = now.x - before.x, dy = now.y - before.y;
                    if (Math.abs(dx) < 1 && Math.abs(dy) < 1) continue;
                    moved.push([before.x - sx, before.y - sy, before.w, before.h], [rect.left, rect.top, rect.width, rect.height]);
                    distance = Math.max(distance, Math.abs(dx), Math.abs(dy));
                    if (moved.length >= 200) break;
                }
                const at = performance.now();
                if (moved.length && at - lastInput > 500) {
                    const cells = new Uint8Array(grid * grid);
                    let covered = 0;
                    for (const [x, y, w, h] of moved) {
                        const x0 = Math.max(0, Math.floor(x / width * grid)), x1 = Math.min(grid, Math.ceil((x + w) / width * grid));
                        const y0 = Math.max(0, Math.floor(y / height * grid)), y1 = Math.min(grid, Math.ceil((y + h) / height * grid));
                        for (let gy = y0; gy < y1; gy++) for (let gx = x0; gx < x1; gx++) {
                            if (!cells[gy * grid + gx]) { cells[gy * grid + gx] = 1; covered++; }
                        }
                    }
                    const value = covered / (grid * grid) * Math.min(1, distance / Math.max(width, height));
                    if (value > 0) {
                        state.shifts += 1;
                        if (windowValue > 0 && at - windowLast < 1000 && at - windowStart < 5000) windowValue += value;
                        else { windowValue = value; windowStart = at; }
                        windowLast = at;
                        if (windowValue > state.cls) state.cls = windowValue;
                    }
                }
            }
            setTimeout(sample, 50);
        };
        setTimeout(sample, 0);
    })();
    """#

    /// After the load: what the observer saw, and the navigation's timing,
    /// in milliseconds from the navigation's start. A function body.
    static let metrics = #"""
    await new Promise((done) => setTimeout(done, 120));
    const state = window.__searchDeveloperLoad;
    const navigation = performance.getEntriesByType("navigation")[0];
    const out = { observed: !!state, fcp: null, lcp: null, lcpSupported: false, cls: 0, shifts: 0, tasks: [], errors: [],
        ttfb: null, load: null, redirects: 0, now: performance.now() };
    if (state) {
        state.stopped = true;
        Object.assign(out, { fcp: state.fcp, lcp: state.lcp, lcpSupported: state.lcpSupported, cls: state.cls,
            shifts: state.shifts, tasks: state.tasks.slice(0, 5000), errors: state.errors.slice(0, 50) });
        const el = state.lcpElement;
        if (el && el.outerHTML) {
            const html = el.outerHTML;
            const close = html.indexOf(">");
            out.lcpElement = (close >= 0 ? html.slice(0, close + 1) : html).slice(0, 300);
            out.lcpLazy = el.localName === "img" && (el.getAttribute("loading") || "").toLowerCase() === "lazy";
        }
    }
    if (out.fcp === null) {
        const paint = performance.getEntriesByType("paint").find((entry) => entry.name === "first-contentful-paint");
        if (paint) out.fcp = paint.startTime;
    }
    if (navigation) {
        if (navigation.responseStart > 0) out.ttfb = navigation.responseStart - (navigation.requestStart || 0);
        if (navigation.loadEventEnd > 0) out.load = navigation.loadEventEnd;
        out.redirects = navigation.redirectCount || 0;
    }
    return out;
    """#

    /// The page as it is: the head's tags, the DOM's checks for the
    /// accessibility, best-practices and SEO audits (each as how many were
    /// checked and which failed), images and resource timing. An element is
    /// sent as [snippet, selector, label]. A function body.
    static let collect = #"""
    const limit = 500;
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
            if (current.id) { parts.unshift(part + "#" + current.id); break; }
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
    const label = (el) => {
        const text = squash((el.textContent || "").slice(0, 400));
        if (text) return text.slice(0, 80);
        const named = el.getAttribute && (el.getAttribute("alt") || el.getAttribute("aria-label") || el.getAttribute("title"));
        return named ? named.slice(0, 80) : el.localName || "";
    };
    const node = (el) => [snippet(el), selector(el), label(el)];
    const visible = (el) => {
        const style = getComputedStyle(el);
        if (style.display === "none" || style.visibility === "hidden" || style.visibility === "collapse") return false;
        return el.getClientRects().length > 0;
    };
    const ariaHidden = (el) => !!el.closest("[aria-hidden=\"true\"]");
    const shown = (el) => visible(el) && !ariaHidden(el);
    const byIds = (el, attribute) => squash((el.getAttribute(attribute) || "").split(/\s+/).filter(Boolean)
        .map((id) => { const t = document.getElementById(id); return t ? t.textContent : ""; }).join(" "));
    const subtree = (el, depth) => {
        if (depth > 30) return "";
        let out = "";
        for (const child of el.childNodes) {
            if (child.nodeType === 3) { out += child.data; continue; }
            if (child.nodeType !== 1 || child.getAttribute("aria-hidden") === "true") continue;
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
                if (style.display !== "none" && style.visibility !== "hidden") out += subtree(child, depth + 1);
            }
        }
        return out;
    };
    const nameOf = (el, content) => {
        const labelled = byIds(el, "aria-labelledby");
        if (labelled) return labelled;
        const aria = squash(el.getAttribute("aria-label"));
        if (aria) return aria;
        if (el.labels && el.labels.length) {
            const text = squash(Array.from(el.labels).map((item) => subtree(item, 0)).join(" "));
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
            const text = squash(subtree(el, 0));
            if (text) return text;
        }
        const title = squash(el.getAttribute("title"));
        if (title) return title;
        if (tag === "input" || tag === "textarea") return squash(el.getAttribute("placeholder"));
        return "";
    };
    const findings = {};
    const check = (id, list, fails, extra) => {
        const failing = [];
        const values = [];
        for (const el of list.slice(0, limit)) {
            const why = fails(el);
            if (why) { failing.push(node(el)); if (extra) values.push(String(why)); }
        }
        findings[id] = { checked: Math.min(list.length, limit), failing: failing.slice(0, 50), values: values.slice(0, 50) };
    };
    const all = (selector) => Array.from(document.querySelectorAll(selector));
    const metas = all("meta");
    const metaNamed = (name) => metas.find((meta) => (meta.getAttribute("name") || "").toLowerCase() === name);
    const rels = (link) => (link.getAttribute("rel") || "").toLowerCase().split(/\s+/);
    const links = all("link[rel]");
    const data = {
        url: location.href,
        title: document.querySelector("title") ? document.title : null,
        lang: document.documentElement.getAttribute("lang"),
        doctype: document.doctype ? document.doctype.name : null,
        compatMode: document.compatMode,
        characterSet: document.characterSet,
        charsetMeta: metas.some((meta) => meta.hasAttribute("charset")
            || ((meta.getAttribute("http-equiv") || "").toLowerCase() === "content-type"
                && (meta.getAttribute("content") || "").toLowerCase().includes("charset"))),
        viewport: metaNamed("viewport") ? metaNamed("viewport").getAttribute("content") || "" : null,
        description: metaNamed("description") ? metaNamed("description").getAttribute("content") || "" : null,
        robots: metas.filter((meta) => ["robots", "googlebot"].includes((meta.getAttribute("name") || "").toLowerCase()))
            .map((meta) => meta.getAttribute("content") || ""),
        canonicals: links.filter((link) => rels(link).includes("canonical")).map((link) => [link.getAttribute("href") || "", link.href || ""]),
        hreflangs: links.filter((link) => rels(link).includes("alternate") && link.hasAttribute("hreflang"))
            .map((link) => [link.getAttribute("hreflang") || "", link.href || ""]),
        userAgent: navigator.userAgent,
        width: innerWidth, height: innerHeight, dpr: devicePixelRatio || 1,
        protocol: location.protocol,
        findings,
    };

    // Accessibility: names and labels.
    const images = all("img").filter(shown);
    check("image-alt", images, (img) => !img.hasAttribute("alt") && !img.getAttribute("aria-label")
        && !img.getAttribute("aria-labelledby") && !["presentation", "none"].includes(img.getAttribute("role")) && "no alt");
    check("input-image-alt", all("input[type=image i]").filter(shown), (el) => !nameOf(el, false) && "no name");
    check("button-name", all("button, [role=button], input[type=button i], input[type=submit i], input[type=reset i]").filter(shown),
        (el) => !nameOf(el, true) && "no name");
    check("link-name", all("a[href], [role=link]").filter(shown), (el) => !nameOf(el, true) && "no name");
    const skipped = new Set(["hidden", "button", "submit", "reset", "image"]);
    check("label", all("input, textarea").filter((el) => !(el.localName === "input" && skipped.has((el.getAttribute("type") || "").toLowerCase()))
        && !/^(none|presentation)$/i.test(el.getAttribute("role") || "")).filter(shown), (el) => !nameOf(el, false) && "no label");
    check("select-name", all("select").filter(shown), (el) => !nameOf(el, false) && "no name");
    check("frame-title", all("iframe, frame").filter(shown), (el) => !nameOf(el, false) && "no title");
    findings["document-title"] = { checked: 1, failing: squash(data.title) ? [] : [node(document.documentElement)], values: [] };
    findings["html-has-lang"] = { checked: 1, failing: squash(data.lang) ? [] : [node(document.documentElement)], values: [] };

    // ARIA.
    const roles = new Set(("alert alertdialog application article banner blockquote button caption cell checkbox code columnheader combobox "
        + "complementary contentinfo definition deletion dialog directory document emphasis feed figure form generic grid gridcell group "
        + "heading img insertion link list listbox listitem log main marquee math menu menubar menuitem menuitemcheckbox menuitemradio meter "
        + "navigation none note option paragraph presentation progressbar radio radiogroup region row rowgroup rowheader scrollbar search "
        + "searchbox separator slider spinbutton status strong subscript superscript switch tab table tablist tabpanel term textbox time "
        + "timer toolbar tooltip tree treegrid treeitem").split(" "));
    const ariaAttributes = new Set(("activedescendant atomic autocomplete braillelabel brailleroledescription busy checked colcount colindex "
        + "colindextext colspan controls current describedby description details disabled dropeffect errormessage expanded flowto grabbed "
        + "haspopup hidden invalid keyshortcuts label labelledby level live modal multiline multiselectable orientation owns placeholder "
        + "posinset pressed readonly relevant required roledescription rowcount rowindex rowindextext rowspan selected setsize sort valuemax "
        + "valuemin valuenow valuetext").split(" ").map((name) => "aria-" + name));
    const withAria = [];
    const withRole = all("[role]");
    let total = 0, deepest = 0, widest = 0;
    const ids = new Map();
    const referenced = new Set();
    const tabbed = [];
    const texts = [];
    const stack = [[document.documentElement, 1]];
    while (stack.length) {
        const [el, depth] = stack.pop();
        total += 1;
        deepest = Math.max(deepest, depth);
        widest = Math.max(widest, el.childElementCount);
        if (total <= 30000) {
            for (const attribute of el.attributes) {
                const name = attribute.name.toLowerCase();
                if (name.startsWith("aria-")) { withAria.push(el); break; }
            }
            for (const name of ["aria-labelledby", "aria-describedby", "aria-controls", "aria-owns", "aria-activedescendant"]) {
                for (const id of (el.getAttribute(name) || "").split(/\s+/)) if (id) referenced.add(id);
            }
            if (el.localName === "label" && el.htmlFor) referenced.add(el.htmlFor);
            if (el.id) { const list = ids.get(el.id); if (list) list.push(el); else ids.set(el.id, [el]); }
            if (el.hasAttribute("tabindex")) tabbed.push(el);
            if (texts.length < 1500 && !["script", "style", "noscript", "title", "option", "head"].includes(el.localName)) {
                let own = false;
                for (const child of el.childNodes) if (child.nodeType === 3 && child.data.trim()) { own = true; break; }
                if (own) texts.push(el);
            }
        }
        for (let i = el.children.length - 1; i >= 0; i--) stack.push([el.children[i], depth + 1]);
    }
    data.dom = { elements: total, depth: deepest, children: widest };
    check("aria-valid-attr", withAria, (el) => {
        const bad = Array.from(el.attributes).map((a) => a.name.toLowerCase()).filter((n) => n.startsWith("aria-") && !ariaAttributes.has(n));
        return bad.length ? bad.join(", ") : false;
    }, true);
    check("aria-roles", withRole, (el) => {
        const bad = (el.getAttribute("role") || "").trim().toLowerCase().split(/\s+/).filter((role) => role && !roles.has(role));
        return bad.length && bad.length === (el.getAttribute("role") || "").trim().split(/\s+/).length ? bad.join(" ") : false;
    }, true);
    findings["aria-hidden-body"] = { checked: document.body ? 1 : 0,
        failing: document.body && document.body.getAttribute("aria-hidden") === "true" ? [node(document.body)] : [], values: [] };
    const duplicated = [];
    for (const [id, list] of ids) if (list.length > 1 && referenced.has(id)) duplicated.push(list[1]);
    findings["duplicate-id-aria"] = { checked: referenced.size, failing: duplicated.slice(0, 50).map(node), values: [] };
    check("tabindex", tabbed, (el) => (parseInt(el.getAttribute("tabindex"), 10) || 0) > 0 && "tabindex > 0");

    // Contrast: each element with its own text against the colours behind it.
    const parse = (color) => {
        const match = /rgba?\(([^)]+)\)/.exec(color || "");
        if (!match) return null;
        const parts = match[1].split(/[\s,\/]+/).filter(Boolean).map(parseFloat);
        return { r: parts[0], g: parts[1], b: parts[2], a: parts.length > 3 ? parts[3] : 1 };
    };
    const over = (top, bottom) => ({ r: top.r * top.a + bottom.r * (1 - top.a), g: top.g * top.a + bottom.g * (1 - top.a),
        b: top.b * top.a + bottom.b * (1 - top.a), a: 1 });
    const luminance = (c) => {
        const channel = (v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); };
        return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
    };
    const behind = (el) => {
        const layers = [];
        for (let current = el, steps = 0; current && current.nodeType === 1 && steps < 40; current = current.parentElement, steps++) {
            const style = getComputedStyle(current);
            if (style.backgroundImage && style.backgroundImage !== "none") return null;
            const color = parse(style.backgroundColor);
            if (color && color.a > 0) { layers.push(color); if (color.a >= 1) break; }
        }
        let base = { r: 255, g: 255, b: 255, a: 1 };
        for (let i = layers.length - 1; i >= 0; i--) base = over(layers[i], base);
        return base;
    };
    check("color-contrast", texts.filter((el) => {
        const style = getComputedStyle(el);
        return style.visibility === "visible" && parseFloat(style.opacity) > 0 && el.getClientRects().length
            && !ariaHidden(el) && !el.disabled && !el.closest("[disabled]");
    }), (el) => {
        const style = getComputedStyle(el);
        const background = behind(el);
        const color = parse(style.color);
        if (!background || !color) return false;
        const text = over(color, background);
        const [hi, lo] = [luminance(text), luminance(background)].sort((a, b) => b - a);
        const ratio = (hi + 0.05) / (lo + 0.05);
        const size = parseFloat(style.fontSize);
        const bold = parseInt(style.fontWeight, 10) >= 700;
        const large = size >= 24 || (bold && size >= 18.66);
        return ratio < (large ? 3 : 4.5) ? ratio.toFixed(2) + ":1" : false;
    }, true);

    // Structure.
    let level = 0;
    check("heading-order", all("h1, h2, h3, h4, h5, h6, [role=heading]").filter(shown), (el) => {
        let now = parseInt(el.getAttribute("aria-level") || "", 10);
        if (!now) now = /^h[1-6]$/.test(el.localName) ? parseInt(el.localName.slice(1), 10) : 2;
        const skips = level > 0 && now > level + 1;
        level = now;
        return skips && "skips a level";
    });
    check("list", all("ul, ol").filter((el) => !el.getAttribute("role") && shown(el)), (el) =>
        Array.from(el.children).some((child) => !["li", "script", "template"].includes(child.localName)
            && !["listitem", "none", "presentation"].includes(child.getAttribute("role") || "")) && "has other children");
    check("listitem", all("li").filter(shown), (el) => {
        const parent = el.parentElement;
        if (!parent) return "no list";
        const role = parent.getAttribute("role");
        return !((["ul", "ol", "menu"].includes(parent.localName) && (!role || role === "list")) || role === "list") && "not in a list";
    });
    const viewport = (data.viewport || "").toLowerCase();
    const scalable = !/user-scalable\s*=\s*(no|0)\b/.test(viewport);
    const maximum = /maximum-scale\s*=\s*([\d.]+)/.exec(viewport);
    findings["meta-viewport"] = { checked: data.viewport === null ? 0 : 1,
        failing: data.viewport !== null && (!scalable || (maximum && parseFloat(maximum[1]) < 5)) ? [node(metaNamed("viewport"))] : [], values: [] };
    check("meta-refresh", metas.filter((meta) => (meta.getAttribute("http-equiv") || "").toLowerCase() === "refresh"),
        (meta) => { const delay = parseInt(meta.getAttribute("content") || "", 10); return delay > 0 && "refreshes after " + delay + " s"; });
    findings["landmark-one-main"] = { checked: 1, failing: all("main, [role=main i]").filter(shown).length === 1 ? [] : [node(document.documentElement)], values: [] };

    // SEO.
    const badText = new Set(["click here", "click this", "go", "here", "information", "learn more", "more", "more info",
        "more information", "right here", "read more", "see more", "start", "this", "link", "details"]);
    const anchors = all("a[href]").filter((el) => !ariaHidden(el));
    check("link-text", anchors.filter(visible).filter((el) => {
        try { const url = new URL(el.href); return url.protocol.startsWith("http"); } catch (e) { return false; }
    }), (el) => badText.has(squash(el.innerText || el.textContent).toLowerCase().replace(/[.!?…]+$/, "")) && squash(el.innerText || el.textContent), true);
    check("crawlable-anchors", all("a").filter((el) => !ariaHidden(el)), (el) => {
        const raw = el.getAttribute("href");
        if (raw === null) return el.hasAttribute("onclick") || el.getAttribute("role") === "link" ? "no href" : false;
        const href = raw.trim().toLowerCase();
        if (href.startsWith("javascript:") && !el.hasAttribute("name")) return raw.slice(0, 80);
        if (href === "" || href === "#") return el.hasAttribute("onclick") ? raw || "empty" : false;
        return false;
    }, true);

    // Best practices.
    check("image-aspect-ratio", images.filter((img) => img.naturalWidth > 5 && img.naturalHeight > 5
        && !/\.svg($|\?)/i.test(img.currentSrc || img.src) && getComputedStyle(img).objectFit === "fill"), (img) => {
        const rect = img.getBoundingClientRect();
        if (rect.width < 5 || rect.height < 5) return false;
        const shownRatio = rect.width / rect.height, natural = img.naturalWidth / img.naturalHeight;
        return Math.abs(shownRatio - natural) / natural > 0.05 && img.naturalWidth + "×" + img.naturalHeight + " shown as "
            + Math.round(rect.width) + "×" + Math.round(rect.height);
    }, true);
    check("unsized-images", images.filter((img) => getComputedStyle(img).position !== "fixed" && getComputedStyle(img).position !== "absolute"),
        (img) => !(img.hasAttribute("width") && img.hasAttribute("height")) && !(img.style.width && img.style.height)
            && (getComputedStyle(img).aspectRatio === "auto" || !getComputedStyle(img).aspectRatio) && "no width and height");

    // Images and requests, for the performance audits.
    data.images = images.slice(0, limit).map((img) => {
        const rect = img.getBoundingClientRect();
        return { n: node(img), src: img.currentSrc || img.src || "", nw: img.naturalWidth, nh: img.naturalHeight,
            dw: rect.width, dh: rect.height, top: rect.top + scrollY, lazy: (img.getAttribute("loading") || "").toLowerCase() === "lazy" };
    });
    data.head = [];
    if (document.head) {
        for (const el of document.head.children) {
            if (el.localName === "script" && el.hasAttribute("src") && !el.async && !el.defer
                && (el.getAttribute("type") || "").toLowerCase() !== "module") {
                data.head.push({ n: node(el), url: el.src });
            } else if (el.localName === "link" && rels(el).includes("stylesheet") && !rels(el).includes("alternate") && !el.disabled) {
                let applies = true;
                try { applies = !el.media || matchMedia(el.media).matches; } catch (e) {}
                if (applies) data.head.push({ n: node(el), url: el.href });
            }
        }
    }
    data.resources = performance.getEntriesByType("resource").slice(0, 800).map((entry) => ({
        name: entry.name, type: entry.initiatorType, start: entry.startTime, end: entry.responseEnd,
        transfer: entry.transferSize || 0, encoded: entry.encodedBodySize || 0, decoded: entry.decodedBodySize || 0 }));
    const navigation = performance.getEntriesByType("navigation")[0];
    if (navigation) data.document = { transfer: navigation.transferSize || 0, encoded: navigation.encodedBodySize || 0,
        decoded: navigation.decodedBodySize || 0 };
    return data;
    """#
}
