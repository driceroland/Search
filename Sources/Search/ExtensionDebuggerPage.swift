import Foundation

// What the debugger runs inside a page: the half of the DevTools protocol
// that needs the page's own objects (see ExtensionDebugger).
//
// One copy lives in each world a page is asked about, under a symbol
// registered for the purpose. It keeps what Runtime hands out as an
// objectId, tells a value from an object the way the protocol does, and
// measures an element's boxes. Every answer leaves as JSON text, so that
// nothing depends on how WebKit would turn a script's result into Swift.
enum ExtensionDebuggerPage {
    /// A function expression; called with the number of the world it is in,
    /// it gives the helper. Called again in a world that has one, it gives
    /// that one back.
    ///
    /// The page's own script shares the world the helper is in when it is
    /// the page's world, so the helper is held on a property named for the
    /// session (a name only Search made up), and it and its operations are
    /// frozen: a page can neither find it by a name it knows nor swap one of
    /// its operations for its own. What it gives back is still read as the
    /// page's word (see ExtensionDebugger.page).
    static func source(key: String) -> String {
        template.replacingOccurrences(of: "__KEY__", with: ExtensionDebuggerSensor.literal(key))
    }

    private static let template = #"""
    (function (tag) {
      const key = __KEY__;
      if (globalThis[key]) return globalThis[key];
      const objects = new Map(), nodeIds = new WeakMap(), nodes = new Map();
      let next = 0, nextNode = 0;

      class Failure extends Error {
        constructor(message, code) { super(message); this.cdp = true; this.code = code || -32000; }
      }
      const hold = (value, group) => {
        const id = tag + "." + (++next);
        objects.set(id, { value, group: group || "" });
        return id;
      };
      const lookup = (id) => {
        const found = objects.get(id);
        if (!found) throw new Failure("Could not find object with given id");
        return found.value;
      };
      const backend = (node) => {
        let id = nodeIds.get(node);
        if (!id) { id = ++nextNode; nodeIds.set(node, id); nodes.set(id, new WeakRef(node)); }
        return id;
      };
      const nodeFor = (params) => {
        if (params.objectId) {
          const value = lookup(params.objectId);
          if (!(value instanceof Node)) throw new Failure("Object id doesn't reference a Node");
          return value;
        }
        const ref = nodes.get(params.backendNodeId !== undefined ? params.backendNodeId : params.nodeId);
        const node = ref && ref.deref();
        if (!node) throw new Failure("Could not find node with given id");
        return node;
      };

      const subtypeOf = (v) => {
        if (v === null) return "null";
        if (Array.isArray(v)) return "array";
        if (v instanceof Node) return "node";
        if (v instanceof Error) return "error";
        if (v instanceof RegExp) return "regexp";
        if (v instanceof Date) return "date";
        if (v instanceof Map) return "map";
        if (v instanceof Set) return "set";
        if (v instanceof Promise) return "promise";
        if (v instanceof ArrayBuffer) return "arraybuffer";
        return undefined;
      };
      const describe = (v) => {
        try {
          if (typeof v === "function") return Function.prototype.toString.call(v);
          if (v instanceof Error) return v.name + ": " + v.message + (v.stack ? "\n" + v.stack : "");
          if (v instanceof Element) {
            const cls = typeof v.className === "string" && v.className.trim() ? "." + v.className.trim().split(/\s+/).join(".") : "";
            return v.localName + (v.id ? "#" + v.id : "") + cls;
          }
          if (v instanceof Node) return v.nodeName;
          if (Array.isArray(v)) return "Array(" + v.length + ")";
          if (v instanceof RegExp || v instanceof Date) return String(v);
          const name = v && v.constructor && v.constructor.name;
          return name || "Object";
        } catch (e) { return "Object"; }
      };
      const plain = (value) => {
        const seen = new WeakSet();
        const walk = (x, depth) => {
          if (depth > 100) throw new Failure("Object reference chain is too long");
          const t = typeof x;
          if (x === undefined || t === "function" || t === "symbol") return undefined;
          if (x === null || t === "string" || t === "boolean") return x;
          if (t === "number") return Number.isFinite(x) ? x : null;
          if (t === "bigint") return null;
          if (seen.has(x)) throw new Failure("Object reference chain is too long");
          seen.add(x);
          try {
            if (!(x instanceof Node) && typeof x.toJSON === "function") return walk(x.toJSON(), depth + 1);
            if (Array.isArray(x)) return x.map((item) => { const r = walk(item, depth + 1); return r === undefined ? null : r; });
            const out = {};
            for (const k of Object.keys(x)) { const r = walk(x[k], depth + 1); if (r !== undefined) out[k] = r; }
            return out;
          } finally { seen.delete(x); }
        };
        return walk(value, 0);
      };
      const remote = (v, byValue, group) => {
        const t = typeof v;
        if (v === undefined) return { type: "undefined" };
        if (v === null) return { type: "object", subtype: "null", value: null };
        if (t === "number") {
          if (Number.isNaN(v) || !Number.isFinite(v) || Object.is(v, -0)) {
            const text = Object.is(v, -0) ? "-0" : String(v);
            return { type: "number", unserializableValue: text, description: text };
          }
          return { type: "number", value: v, description: String(v) };
        }
        if (t === "string" || t === "boolean") return { type: t, value: v };
        if (t === "bigint") return { type: "bigint", unserializableValue: v + "n", description: v + "n" };
        if (t === "symbol") return { type: "symbol", description: String(v), objectId: hold(v, group) };
        if (byValue && t === "object") {
          const o = { type: "object", value: plain(v) };
          const sub = subtypeOf(v);
          if (sub === "array") o.subtype = sub;
          return o;
        }
        const o = { type: t === "function" ? "function" : "object", className: (v.constructor && v.constructor.name) || "Object",
          description: describe(v), objectId: hold(v, group) };
        const sub = subtypeOf(v);
        if (sub) o.subtype = sub;
        return o;
      };
      const thrown = (e, group) => {
        const object = remote(e, false, group);
        return { result: object, exceptionDetails: { exceptionId: ++next, text: "Uncaught",
          lineNumber: e && e.line ? e.line - 1 : 0, columnNumber: e && e.column ? e.column - 1 : 0, exception: object } };
      };
      const unserializable = { "NaN": NaN, "Infinity": Infinity, "-Infinity": -Infinity, "-0": -0 };
      const argument = (a) => {
        if (a.objectId) return lookup(a.objectId);
        if (a.unserializableValue !== undefined) {
          const text = a.unserializableValue;
          if (/^-?\d+n$/.test(text)) return BigInt(text.slice(0, -1));
          return unserializable[text];
        }
        return a.value;
      };

      // What the page's console was given, kept so the extension can ask
      // about it later; the oldest are let go, as a page can log forever.
      const logged = [];
      const api = {
        remoteArg(v) {
          const o = remote(v, false, "console");
          if (o.objectId) {
            logged.push(o.objectId);
            if (logged.length > 300) objects.delete(logged.shift());
          }
          return o;
        },
        // Runs `compute`; the answer is Runtime's: a RemoteObject, or what was thrown.
        async finish(compute, o) {
          try {
            let value = compute();
            if (o.awaitPromise && value && typeof value.then === "function") value = await value;
            return JSON.stringify({ result: remote(value, o.returnByValue, o.objectGroup) });
          } catch (e) {
            if (e && e.cdp) return JSON.stringify({ error: { code: e.code, message: e.message } });
            return JSON.stringify(thrown(e, o.objectGroup));
          }
        },
        callOn(fn, p) {
          return api.finish(() => {
            const self = p.objectId ? lookup(p.objectId) : globalThis;
            return fn.apply(self, (p.arguments || []).map(argument));
          }, p);
        },
        async run(name, p) {
          try { return JSON.stringify({ result: await api.ops[name](p) }); }
          catch (e) {
            if (e && e.cdp) return JSON.stringify({ error: { code: e.code, message: e.message } });
            return JSON.stringify({ error: { code: -32000, message: String(e && e.message || e) } });
          }
        },
        ops: {
          release(p) { objects.delete(p.objectId); return {}; },
          releaseGroup(p) { for (const [id, o] of objects) if (o.group === p.objectGroup) objects.delete(id); return {}; },
          frame() {
            return { url: location.href, origin: location.origin === "null" ? "" : location.origin,
              mimeType: document.contentType || "text/html", title: document.title };
          },
          viewport() {
            const root = document.documentElement;
            return { scrollX: scrollX, scrollY: scrollY, innerWidth: innerWidth, innerHeight: innerHeight,
              clientWidth: root.clientWidth, clientHeight: root.clientHeight,
              scrollWidth: Math.max(root.scrollWidth, document.body ? document.body.scrollWidth : 0),
              scrollHeight: Math.max(root.scrollHeight, document.body ? document.body.scrollHeight : 0),
              devicePixelRatio: devicePixelRatio };
          },
          describeNode(p) {
            const node = nodeFor(p);
            const out = { nodeId: backend(node), backendNodeId: backend(node), nodeType: node.nodeType, nodeName: node.nodeName,
              localName: node.localName || "", nodeValue: node.nodeValue || "", childNodeCount: node.childNodes.length };
            if (node.attributes) out.attributes = [].concat(...[...node.attributes].map((a) => [a.name, a.value]));
            if (node.nodeType === 9) out.documentURL = node.URL;
            if (node.nodeType === 1 && node.localName === "iframe") out.frameId = undefined;
            return { node: out };
          },
          resolveNode(p) { return { object: remote(nodeFor(p), false, p.objectGroup) }; },
          // Where a node is in the document, as steps any world can follow
          // (a child's place, or -1 for a host's open shadow root), and the
          // way back to it.
          nodePath(p) {
            const path = [];
            let node = nodeFor(p);
            while (node.nodeType !== 9) {
              const parent = node.parentNode;
              if (parent) path.unshift(Array.prototype.indexOf.call(parent.childNodes, node));
              else if (node.nodeType === 11 && node.host) path.unshift(-1);
              else throw new Failure("Node is detached from document");
              node = parent || node.host;
            }
            if (node !== document) throw new Failure("Node is in another frame");
            return { path };
          },
          resolvePath(p) {
            let node = document;
            for (const step of p.path) {
              node = step === -1 ? node.shadowRoot : node.childNodes[step];
              if (!node) throw new Failure("Could not find node with given id");
            }
            return { object: remote(node, false, p.objectGroup) };
          },
          scrollIntoView(p) {
            const node = nodeFor(p);
            const el = node.nodeType === 1 ? node : node.parentElement;
            if (!el) throw new Failure("Node is detached from document");
            el.scrollIntoView({ block: "center", inline: "center", behavior: "instant" });
            return {};
          },
          quads(p) {
            const node = nodeFor(p);
            const el = node.nodeType === 1 ? node : node.parentElement;
            if (!el) throw new Failure("Node is detached from document");
            const quad = (r) => [r.left, r.top, r.right, r.top, r.right, r.bottom, r.left, r.bottom];
            return { quads: [...el.getClientRects()].filter((r) => r.width || r.height).map(quad) };
          },
          boxModel(p) {
            const node = nodeFor(p);
            const el = node.nodeType === 1 ? node : node.parentElement;
            if (!el || !el.isConnected) throw new Failure("Could not compute box model.");
            const r = el.getBoundingClientRect(), s = getComputedStyle(el);
            const px = (n) => parseFloat(s[n]) || 0;
            const grow = (rect, t, rt, b, l) => [rect.left - l, rect.top - t, rect.right + rt, rect.top - t,
              rect.right + rt, rect.bottom + b, rect.left - l, rect.bottom + b];
            const border = { left: r.left, top: r.top, right: r.right, bottom: r.bottom };
            const padding = { left: r.left + px("borderLeftWidth"), top: r.top + px("borderTopWidth"),
              right: r.right - px("borderRightWidth"), bottom: r.bottom - px("borderBottomWidth") };
            const content = { left: padding.left + px("paddingLeft"), top: padding.top + px("paddingTop"),
              right: padding.right - px("paddingRight"), bottom: padding.bottom - px("paddingBottom") };
            return { model: {
              content: grow(content, 0, 0, 0, 0), padding: grow(padding, 0, 0, 0, 0), border: grow(border, 0, 0, 0, 0),
              margin: grow(border, px("marginTop"), px("marginRight"), px("marginBottom"), px("marginLeft")),
              width: Math.round(r.width), height: Math.round(r.height) } };
          },
    \#(ExtensionDebuggerTree.ops)
        },
      };
      Object.freeze(api.ops);
      Object.freeze(api);
      Object.defineProperty(globalThis, key, { value: api, enumerable: false, configurable: false, writable: false });
      return api;
    })
    """#

    /// The start of every call into a page: the helper, and what Swift sent
    /// (as `p`).
    static func prelude(key: String) -> String { "const p = JSON.parse(payload);\nconst cdp = \(source(key: key))(p.tag);\n" }
}
