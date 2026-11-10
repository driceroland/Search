import Foundation

// The page's structure as the DevTools protocol reports it: the accessibility
// tree, the DOM snapshot and the DOM tree itself, and a hit test.
//
// These are operations of the helper in ExtensionDebuggerPage and are pasted
// into it, so they share its node numbers: a node found by one answer is the
// node the next one means. They read the live page, so a closed shadow root
// and a frame of another origin are not in what they give.
enum ExtensionDebuggerTree {
    static let ops = #"""
          axTree(p) {
            if (p.frameId && p.frameId !== p.mainFrame) throw new Failure("No frame for given id found");
            const nodes = [];
            let counter = 0;
            const add = (n) => { n.nodeId = String(++counter); n.ignored = false; n.childIds = n.childIds || []; nodes.push(n); return n; };
            const value = (type, v) => ({ type, value: v });
            const skipTags = new Set(["script", "style", "noscript", "template", "head", "meta", "link", "title", "base"]);
            const idsOf = (el, attr) => (el.getAttribute(attr) || "").split(/\s+/).filter(Boolean)
              .map((id) => el.ownerDocument.getElementById(id)).filter(Boolean);
            const shown = (el) => {
              if (el.getAttribute("aria-hidden") === "true") return false;
              try { return getComputedStyle(el).display !== "none"; } catch (e) { return true; }
            };
            const contentRoles = new Set(["button", "cell", "checkbox", "columnheader", "gridcell", "heading", "link", "menuitem",
              "menuitemcheckbox", "menuitemradio", "option", "radio", "row", "rowheader", "switch", "tab", "tooltip", "treeitem"]);
            const textOf = (el, seen) => {
              let out = "";
              for (const c of el.childNodes) {
                if (c.nodeType === 3) out += c.nodeValue;
                else if (c.nodeType === 1 && !skipTags.has(c.localName) && shown(c)) out += " " + nameInside(c, seen) + " ";
              }
              return out.replace(/\s+/g, " ").trim();
            };
            const nameInside = (el, seen) => {
              if (seen.has(el)) return "";
              seen.add(el);
              const own = ownName(el, seen);
              if (own) return own[0];
              if (el.localName === "input" && ["text", "search", "email", "url", "tel", "number", "password"].includes(el.type)) return el.value || "";
              return textOf(el, seen);
            };
            const ownName = (el, seen) => {
              const by = idsOf(el, "aria-labelledby");
              if (by.length) {
                const v = by.map((x) => nameInside(x, new Set(seen))).join(" ").trim();
                if (v) return [v, "relatedElement", "aria-labelledby"];
              }
              const label = el.getAttribute("aria-label");
              if (label && label.trim()) return [label.trim(), "attribute", "aria-label"];
              const tag = el.localName;
              if (tag === "img" || tag === "area" || (tag === "input" && el.type === "image")) {
                const alt = el.getAttribute("alt");
                if (alt && alt.trim()) return [alt.trim(), "attribute", "alt"];
              }
              if (["input", "select", "textarea", "button", "meter", "progress", "output"].includes(tag) && el.labels && el.labels.length) {
                const v = [...el.labels].map((l) => textOf(l, new Set([el]))).join(" ").replace(/\s+/g, " ").trim();
                if (v) return [v, "relatedElement"];
              }
              if (tag === "input" && ["button", "submit", "reset"].includes(el.type)) {
                const v = el.value || (el.type === "submit" ? "Submit" : el.type === "reset" ? "Reset" : "");
                if (v) return [v, "attribute", "value"];
              }
              if (tag === "fieldset") {
                const legend = [...el.children].find((c) => c.localName === "legend");
                if (legend) return [textOf(legend, new Set([el])), "relatedElement"];
              }
              if (tag === "table") {
                const caption = [...el.children].find((c) => c.localName === "caption");
                if (caption) return [textOf(caption, new Set([el])), "relatedElement"];
              }
              return null;
            };
            const roleOf = (el) => {
              const tag = el.localName;
              const explicit = (el.getAttribute("role") || "").trim().split(/\s+/)[0];
              if (explicit === "presentation" || explicit === "none") return null;
              if (explicit) return explicit;
              switch (tag) {
                case "a": case "area": return el.hasAttribute("href") ? "link" : null;
                case "button": return "button";
                case "input": {
                  const t = (el.type || "text").toLowerCase();
                  if (t === "hidden") return null;
                  if (["button", "submit", "reset", "image", "file", "color"].includes(t)) return "button";
                  if (t === "checkbox") return "checkbox";
                  if (t === "radio") return "radio";
                  if (t === "range") return "slider";
                  if (t === "number") return "spinbutton";
                  if (t === "search") return "searchbox";
                  return el.hasAttribute("list") ? "combobox" : "textbox";
                }
                case "textarea": return "textbox";
                case "select": return el.multiple || el.size > 1 ? "listbox" : "combobox";
                case "option": return "option";
                case "optgroup": return "group";
                case "h1": case "h2": case "h3": case "h4": case "h5": case "h6": return "heading";
                case "img": return el.getAttribute("alt") === "" && !el.hasAttribute("aria-label") ? null : "img";
                case "ul": case "ol": case "menu": return "list";
                case "li": return "listitem";
                case "dl": return null;
                case "table": return "table";
                case "thead": case "tbody": case "tfoot": return "rowgroup";
                case "tr": return "row";
                case "td": return "cell";
                case "th": return el.getAttribute("scope") === "row" ? "rowheader" : "columnheader";
                case "nav": return "navigation";
                case "main": return "main";
                case "header": return el.closest("article,aside,main,nav,section") ? null : "banner";
                case "footer": return el.closest("article,aside,main,nav,section") ? null : "contentinfo";
                case "aside": return "complementary";
                case "section": return el.hasAttribute("aria-label") || el.hasAttribute("aria-labelledby") ? "region" : null;
                case "form": return el.hasAttribute("aria-label") || el.hasAttribute("aria-labelledby") ? "form" : null;
                case "article": return "article";
                case "dialog": return "dialog";
                case "hr": return "separator";
                case "progress": return "progressbar";
                case "meter": return "meter";
                case "label": return "LabelText";
                case "p": return "paragraph";
                case "figure": return "figure";
                case "figcaption": return "Figcaption";
                case "code": return "code";
                case "summary": return "DisclosureTriangle";
                case "details": case "fieldset": return "group";
                case "legend": return "Legend";
                case "iframe": case "frame": return "Iframe";
                case "blockquote": return "blockquote";
                case "time": return "time";
                case "canvas": return "canvas";
                case "svg": return "graphics-document";
                default: return el.isContentEditable && !el.parentElement?.isContentEditable ? "textbox" : null;
              }
            };
            const prop = (name, type, v) => ({ name, value: { type, value: v } });
            const propertiesOf = (el, role) => {
              const out = [];
              const doc = el.ownerDocument;
              const tag = el.localName;
              const disabled = el.disabled === true || el.getAttribute("aria-disabled") === "true";
              const focusable = !disabled && (el.tabIndex >= 0) && (el.matches("a[href],button,input:not([type=hidden]),select,textarea,summary,[tabindex],[contenteditable]") || el.isContentEditable);
              if (focusable) out.push(prop("focusable", "booleanOrUndefined", true));
              if (doc.activeElement === el) out.push(prop("focused", "booleanOrUndefined", true));
              if (disabled) out.push(prop("disabled", "boolean", true));
              if (["checkbox", "radio", "switch", "menuitemcheckbox", "menuitemradio"].includes(role)) {
                const native = tag === "input" && (el.type === "checkbox" || el.type === "radio");
                const state = native ? (el.indeterminate ? "mixed" : String(el.checked)) : el.getAttribute("aria-checked") || "false";
                out.push(prop("checked", "tristate", state));
              }
              const expanded = tag === "details" ? String(el.open) : el.getAttribute("aria-expanded");
              if (expanded === "true" || expanded === "false") out.push(prop("expanded", "booleanOrUndefined", expanded === "true"));
              const selected = tag === "option" ? el.selected : el.getAttribute("aria-selected") === "true" ? true : el.getAttribute("aria-selected") === "false" ? false : undefined;
              if (selected !== undefined) out.push(prop("selected", "booleanOrUndefined", selected));
              const pressed = el.getAttribute("aria-pressed");
              if (pressed) out.push(prop("pressed", "tristate", pressed));
              if (el.required === true || el.getAttribute("aria-required") === "true") out.push(prop("required", "boolean", true));
              if (/^h[1-6]$/.test(tag)) out.push(prop("level", "integer", Number(tag[1])));
              else if (el.getAttribute("aria-level")) out.push(prop("level", "integer", Number(el.getAttribute("aria-level"))));
              if (role === "link" && el.href) out.push(prop("url", "string", el.href));
              if (tag === "textarea") out.push(prop("multiline", "boolean", true));
              if (role === "textbox" || role === "searchbox") out.push(prop("editable", "token", el.readOnly ? "readonly" : "plaintext"));
              if (el.getAttribute("aria-invalid") === "true") out.push(prop("invalid", "token", "true"));
              const popup = el.getAttribute("aria-haspopup");
              if (popup && popup !== "false") out.push(prop("hasPopup", "token", popup === "true" ? "menu" : popup));
              if (role === "slider" || role === "progressbar" || role === "meter" || role === "spinbutton") {
                if (el.min !== undefined && el.min !== "") out.push(prop("valuemin", "number", Number(el.min)));
                if (el.max !== undefined && el.max !== "") out.push(prop("valuemax", "number", Number(el.max)));
              }
              return out;
            };
            const valueOf = (el, role) => {
              if (el.localName === "select") return [...el.selectedOptions].map((o) => o.label || o.textContent).join(", ");
              if (!["textbox", "searchbox", "combobox", "spinbutton", "slider"].includes(role)) return undefined;
              if (typeof el.value !== "string") return el.isContentEditable ? el.textContent : undefined;
              return el.type === "password" ? "•".repeat(el.value.length) : el.value;
            };
            const nameFor = (el, role) => {
              let found = ownName(el, new Set([el]));
              if (!found && contentRoles.has(role)) {
                const v = textOf(el, new Set([el]));
                if (v) found = [v, "contents"];
              }
              if (!found) {
                const ph = el.getAttribute("placeholder");
                if (ph && (el.localName === "input" || el.localName === "textarea")) found = [ph, "placeholder", "placeholder"];
              }
              if (!found && el.getAttribute("title")) found = [el.getAttribute("title"), "attribute", "title"];
              if (!found) return { type: "computedString", value: "" };
              const source = { type: found[1], value: value("computedString", found[0]) };
              if (found[2]) source.attribute = found[2];
              return { type: "computedString", value: found[0], sources: [source] };
            };

            const root = add({ role: value("role", "RootWebArea"), chromeRole: value("internalRole", 144),
              name: { type: "computedString", value: document.title, sources: [{ type: "relatedElement", value: value("computedString", document.title) }] },
              properties: [prop("focusable", "booleanOrUndefined", true)], backendDOMNodeId: backend(document), frameId: p.mainFrame });
            const walk = (node, parent) => {
              if (node.nodeType === 3) {
                const text = node.nodeValue.replace(/\s+/g, " ");
                if (!text.trim()) return;
                const leaf = add({ role: value("role", "StaticText"), chromeRole: value("internalRole", 158), name: { type: "computedString", value: text, sources: [] },
                  properties: [], backendDOMNodeId: backend(node), parentId: parent.nodeId });
                parent.childIds.push(leaf.nodeId);
                return;
              }
              if (node.nodeType !== 1 || skipTags.has(node.localName) || !shown(node)) return;
              const el = node;
              const role = roleOf(el);
              let holder = parent;
              let hiddenSelf = false;
              try { const v = getComputedStyle(el).visibility; hiddenSelf = v === "hidden" || v === "collapse"; } catch (e) {}
              if (role && !hiddenSelf) {
                const made = { role: value("role", role), chromeRole: value("internalRole", 0), name: nameFor(el, role),
                  properties: propertiesOf(el, role), backendDOMNodeId: backend(el), parentId: parent.nodeId };
                const text = valueOf(el, role);
                if (text !== undefined) made.value = value("string", text);
                const described = el.getAttribute("aria-description");
                if (described) made.description = value("computedString", described);
                holder = add(made);
                parent.childIds.push(holder.nodeId);
              }
              if (role === "Iframe" || role === "img" || el.localName === "input" || el.localName === "textarea") return;
              if (el.localName === "select") {
                const popup = add({ role: value("role", "MenuListPopup"), chromeRole: value("internalRole", 0), name: { type: "computedString", value: "" },
                  properties: [], backendDOMNodeId: backend(el), parentId: holder.nodeId });
                holder.childIds.push(popup.nodeId);
                for (const option of el.querySelectorAll("option")) walk(option, popup);
                return;
              }
              if (el.shadowRoot) { for (const c of el.shadowRoot.childNodes) walk(c, holder); return; }
              if (el.localName === "slot") { for (const c of el.assignedNodes({ flatten: true })) walk(c, holder); return; }
              for (const c of el.childNodes) walk(c, holder);
            };
            for (const c of document.childNodes) walk(c, root);
            return { nodes };
          },

          snapshot(p) {
            const strings = [], index = new Map();
            const str = (s) => {
              const text = s === null || s === undefined ? "" : String(s);
              let i = index.get(text);
              if (i === undefined) { i = strings.length; strings.push(text); index.set(text, i); }
              return i;
            };
            const names = p.computedStyles || [];
            const documents = [];
            let frames = 0;
            const build = (doc, frameId) => {
              const slot = documents.length;
              documents.push(null);
              const view = doc.defaultView;
              const sx = view ? view.scrollX : 0, sy = view ? view.scrollY : 0;
              const nodes = { parentIndex: [], nodeType: [], shadowRootType: { index: [], value: [] }, nodeName: [], nodeValue: [],
                backendNodeId: [], attributes: [], textValue: { index: [], value: [] }, inputValue: { index: [], value: [] },
                inputChecked: { index: [] }, optionSelected: { index: [] }, contentDocumentIndex: { index: [], value: [] },
                pseudoType: { index: [], value: [] }, pseudoIdentifier: { index: [], value: [] }, isClickable: { index: [] },
                currentSourceURL: { index: [], value: [] }, originURL: { index: [], value: [] } };
              const layout = { nodeIndex: [], styles: [], bounds: [], text: [], stackingContexts: { index: [] }, paintOrders: [],
                offsetRects: [], scrollRects: [], clientRects: [], blendedBackgroundColors: [], textColorOpacities: [] };
              const textBoxes = { layoutIndex: [], bounds: [], start: [], length: [] };
              const visit = (node, parent, shadow) => {
                const i = nodes.nodeName.length;
                nodes.parentIndex.push(parent);
                nodes.nodeType.push(node.nodeType);
                nodes.nodeName.push(str(node.nodeName));
                nodes.nodeValue.push(str(node.nodeType === 3 || node.nodeType === 8 ? node.nodeValue : ""));
                nodes.backendNodeId.push(backend(node));
                nodes.attributes.push(node.attributes ? [].concat(...[...node.attributes].map((a) => [str(a.name), str(a.value)])) : []);
                if (shadow) { nodes.shadowRootType.index.push(i); nodes.shadowRootType.value.push(str(shadow)); }
                if (node.nodeType === 3) {
                  nodes.textValue.index.push(i); nodes.textValue.value.push(str(node.nodeValue));
                  // The text that is drawn: one box around the lines it takes.
                  let box = null;
                  try {
                    const range = doc.createRange();
                    range.selectNodeContents(node);
                    const rect = range.getBoundingClientRect();
                    if (range.getClientRects().length > 0 && (rect.width || rect.height)) box = rect;
                  } catch (e) {}
                  if (box) {
                    textBoxes.layoutIndex.push(layout.nodeIndex.length);
                    textBoxes.bounds.push([box.left + sx, box.top + sy, box.width, box.height]);
                    textBoxes.start.push(0);
                    textBoxes.length.push(node.nodeValue.length);
                    layout.nodeIndex.push(i);
                    layout.bounds.push([box.left + sx, box.top + sy, box.width, box.height]);
                    layout.text.push(str(node.nodeValue));
                    let style = [];
                    if (names.length && node.parentElement) { const cs = getComputedStyle(node.parentElement); for (const n of names) style.push(str(cs.getPropertyValue(n))); }
                    layout.styles.push(style);
                  }
                }
                if (node.nodeType === 1) {
                  const tag = node.localName;
                  if (tag === "input" || tag === "textarea" || tag === "select") { nodes.inputValue.index.push(i); nodes.inputValue.value.push(str(node.value)); }
                  if (tag === "input" && (node.type === "checkbox" || node.type === "radio") && node.checked) nodes.inputChecked.index.push(i);
                  if (tag === "option" && node.selected) nodes.optionSelected.index.push(i);
                  if (tag === "a" && node.hasAttribute("href") || tag === "button" || tag === "input" || tag === "select" || tag === "textarea" || node.onclick) nodes.isClickable.index.push(i);
                  if (tag === "img" && node.currentSrc) { nodes.currentSourceURL.index.push(i); nodes.currentSourceURL.value.push(str(node.currentSrc)); }
                  let boxed = false, rect;
                  try { boxed = node.getClientRects().length > 0; rect = node.getBoundingClientRect(); } catch (e) {}
                  if (boxed) {
                    layout.nodeIndex.push(i);
                    layout.bounds.push([rect.left + sx, rect.top + sy, rect.width, rect.height]);
                    layout.text.push(-1);
                    let style = [];
                    if (names.length) { const cs = getComputedStyle(node); style = names.map((n) => str(cs.getPropertyValue(n))); }
                    layout.styles.push(style);
                  }
                  if (node.shadowRoot) visit(node.shadowRoot, i, node.shadowRoot.mode);
                  if (tag === "iframe" || tag === "frame") {
                    let inner = null;
                    try { inner = node.contentDocument; } catch (e) {}
                    if (inner && inner.documentElement) {
                      nodes.contentDocumentIndex.index.push(i);
                      nodes.contentDocumentIndex.value.push(build(inner, frameId + "." + (++frames)));
                    }
                  }
                }
                if (node.nodeType !== 1 || node.localName !== "template") for (const c of node.childNodes) visit(c, i, null);
              };
              visit(doc, -1, null);
              const root = doc.documentElement;
              documents[slot] = { documentURL: str(doc.URL), title: str(doc.title), baseURL: str(doc.baseURI),
                contentLanguage: str(root ? root.lang : ""), encodingName: str(doc.characterSet), publicId: str(""), systemId: str(""),
                frameId: str(frameId), nodes, layout, textBoxes, scrollOffsetX: sx, scrollOffsetY: sy,
                contentWidth: root ? root.scrollWidth : 0, contentHeight: root ? root.scrollHeight : 0 };
              return slot;
            };
            build(document, p.mainFrame);
            return { documents, strings };
          },

          document(p) {
            const depth = p.depth === undefined ? 1 : p.depth;
            const make = (node, d, parentId, shadow) => {
              const id = backend(node);
              const o = { nodeId: id, backendNodeId: id, nodeType: node.nodeType, nodeName: node.nodeName, localName: node.localName || "",
                nodeValue: node.nodeType === 3 || node.nodeType === 8 ? node.nodeValue : "" };
              if (parentId) o.parentId = parentId;
              const kids = [...node.childNodes];
              o.childNodeCount = kids.length;
              if (node.attributes) o.attributes = [].concat(...[...node.attributes].map((a) => [a.name, a.value]));
              if (shadow) o.shadowRootType = shadow;
              if (node.nodeType === 9) {
                o.documentURL = node.URL; o.baseURL = node.baseURI; o.xmlVersion = "";
                o.compatibilityMode = node.compatMode === "CSS1Compat" ? "NoQuirksMode" : "QuirksMode";
              }
              if (node.nodeType === 10) { o.publicId = node.publicId; o.systemId = node.systemId; }
              if (node.nodeType === 1) {
                if (node.shadowRoot && d !== 0) o.shadowRoots = [make(node.shadowRoot, d - 1, id, node.shadowRoot.mode)];
                if (node.localName === "iframe" || node.localName === "frame") {
                  let inner = null;
                  try { inner = node.contentDocument; } catch (e) {}
                  if (inner && p.pierce && d !== 0) o.contentDocument = make(inner, d - 1, id);
                }
              }
              if (d !== 0 && kids.length) o.children = kids.map((c) => make(c, d - 1, id));
              return o;
            };
            return { root: make(document, depth, 0) };
          },

          nodeAt(p) {
            // Where the page is, not where the window is: the hit test is
            // given in the page's own coordinates.
            const x = p.x - scrollX, y = p.y - scrollY;
            let el = document.elementFromPoint(x, y);
            if (!el) throw new Failure("No node found at given location");
            while (el.shadowRoot) {
              const inner = el.shadowRoot.elementFromPoint(x, y);
              if (!inner || inner === el) break;
              el = inner;
            }
            const id = backend(el);
            return { backendNodeId: id, nodeId: id, frameId: p.mainFrame };
          },
"""#
}
