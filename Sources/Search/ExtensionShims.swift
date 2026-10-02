import AppKit
import WebKit
import Combine
import NaturalLanguage
import UserNotifications
import IOKit.pwr_mgt
import CryptoKit

// The Chrome APIs WebKit doesn't have, filled in by the browser itself.
//
// Safari's extension engine covers tabs, storage, scripting, request rules,
// cookies, menus, alarms and messaging. Chrome extensions also reach for
// bookmarks, history, downloads, the side panel, offscreen documents, tab
// groups and OAuth — and fall over when those are undefined.
//
// So when an extension is installed, a small script is put at the front of
// its background and of every page it ships: `chrome.bookmarks` and the rest
// are defined there, and every call becomes a native message to this app,
// which answers from its own bookmarks, history and downloads. To the
// extension it looks like Chrome. The files are changed after the store's
// signature has been checked, and only by adding.

@available(macOS 15.4, *)
@MainActor
enum ExtensionShims {
    /// The name native messages to the browser itself go to.
    static let application = "search"
    nonisolated static let file = "search-shim.js"
    /// Search's passkey patch, put first in every script an extension runs in
    /// a page's own world (see Passkeys.swift, and `first` in the script).
    nonisolated static let passkeys = "search-passkeys.js"
    /// The first line of a worker that already carries the shim.
    nonisolated static let marker = "/* Search: Chrome APIs WebKit lacks, filled in (ExtensionShims.swift) */"
    nonisolated static let ender = "/* Search: end of shim */"

    // MARK: - at install

    /// Written beside a prepared extension: which shim it carries. The same
    /// one needs nothing redone, which matters at launch — preparing reads
    /// every script and page an extension ships.
    nonisolated static let stamp = ".search-shim"
    nonisolated static let version: String = {
        SHA256.hash(data: Data((script + PasskeyRelay.page).utf8)).prefix(8).map { String(format: "%02x", $0) }.joined() + (Store.testing ? "-test" : "")
    }()

    /// `fresh`: a package just unpacked or copied in. What only Search writes
    /// beside an extension — which permissions it added, which shim it
    /// carries — is Search's to say, never the package's: anything by those
    /// names that came inside it goes before a word of it is read.
    nonisolated static func prepare(_ folder: URL, fresh: Bool = false) throws {
        let files = FileManager.default
        if fresh {
            for name in [stamp, ".search-added"] { try? files.removeItem(at: folder.appendingPathComponent(name)) }
        }
        let stampURL = folder.appendingPathComponent(stamp)
        if (try? String(contentsOf: stampURL, encoding: .utf8)) == version { return }
        defer { try? version.write(to: stampURL, atomically: true, encoding: .utf8) }
        let manifestURL = folder.appendingPathComponent("manifest.json")
        guard var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        else { throw Crx.Refused.unpack }

        let script = shim(for: folder)
        try script.write(to: folder.appendingPathComponent(file), atomically: true, encoding: .utf8)
        try PasskeyRelay.page.write(to: folder.appendingPathComponent(passkeys), atomically: true, encoding: .utf8)

        // Native messaging is how the shim reaches the browser; user scripts
        // are carried out through WebKit's registered content scripts, which
        // need scripting. What is added is written down, so the extension is
        // described by what it asked for, not by what Search gave it.
        var permissions = manifest["permissions"] as? [Any] ?? []
        let asked = Set(permissions.compactMap { $0 as? String })
        var added = (try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent(".search-added")))) as? [String] ?? []
        for needed in ["nativeMessaging"] + (asked.contains("userScripts") ? ["scripting"] : []) where !asked.contains(needed) {
            permissions.append(needed)
            added.append(needed)
        }
        manifest["permissions"] = permissions
        if let data = try? JSONSerialization.data(withJSONObject: Array(Set(added)).sorted()) {
            try? data.write(to: folder.appendingPathComponent(".search-added"))
        }

        // The background, whichever kind it is, gets the shim first. A
        // classic service worker gets it written at the top of its own file;
        // a module one imports it first, as its imports run before anything
        // written above them.
        if var background = manifest["background"] as? [String: Any] {
            // A manifest is not a way out of its own package: a worker path
            // that resolves outside the folder, or is a link, is left alone.
            if let worker = background["service_worker"] as? String,
               let path = inside(worker, of: folder) {
                if var source = try? String(contentsOf: path, encoding: .utf8) {
                    // Already carrying one: take the old one off, so a newer
                    // Search puts its newer shim in its place.
                    if source.hasPrefix(marker), let end = source.range(of: ender) {
                        source = String(source[end.upperBound...]).trimmingPrefix("\n").description
                    }
                    // A copy from before there was an end marker: it ends
                    // where its function does, the first `})();` that
                    // starts a line.
                    while source.hasPrefix(marker), let end = source.range(of: "\n})();\n") {
                        source = String(source[end.upperBound...])
                    }
                    let first = "import \"/\(file)\";\n"
                    while source.hasPrefix(first) { source.removeFirst(first.count) }
                    let module = (background["type"] as? String) == "module"
                    try (module ? first + source : marker + "\n" + script + "\n" + ender + "\n" + source).write(to: path, atomically: true, encoding: .utf8)
                }
            }
            // Scripts, alone or beside a worker — WebKit runs them as a page
            // when a manifest names both.
            if var scripts = background["scripts"] as? [String] {
                if scripts.first != file { scripts.insert(file, at: 0) }
                background["scripts"] = scripts
            }
            manifest["background"] = background
        }

        // Content scripts too — there only Chrome's behaviour is mended. One
        // that runs in the page's own world has Search's passkey patch before
        // it: a password manager's there keeps a reference to
        // navigator.credentials as it finds it, and that has to be Search's,
        // not WebKit's (see Passkeys.swift).
        if let entries = manifest["content_scripts"] as? [[String: Any]] {
            manifest["content_scripts"] = entries.map { entry -> [String: Any] in
                var entry = entry
                if var js = entry["js"] as? [String] {
                    if !js.contains(file) { js.insert(file, at: 0) }
                    if (entry["world"] as? String)?.uppercased() == "MAIN", !js.contains(passkeys) { js.insert(passkeys, at: 0) }
                    entry["js"] = js
                }
                return entry
            }
        }

        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: manifestURL, options: .atomic)

        // Every page it ships — popup, options, background page, side panel.
        let walker = files.enumerator(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey])
        while let url = walker?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                  ["html", "htm"].contains(url.pathExtension.lowercased()),
                  var html = try? String(contentsOf: url, encoding: .utf8),
                  !html.contains(file)
            else { continue }
            let tag = "<script src=\"/\(file)\"></script>"
            if let head = html.range(of: "<head[^>]*>", options: [.regularExpression, .caseInsensitive]) {
                html.insert(contentsOf: tag, at: head.upperBound)
            } else {
                html = tag + html
            }
            try? html.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// A path a package names, resolved and kept inside the folder it came
    /// in: `..` in a manifest is not a way out of the package. Nor is a
    /// symbolic link, which a folder install keeps as it is: the worker is
    /// read through it and written back over it as a regular file, so a
    /// link to a file elsewhere would put that file's bytes in the package.
    /// A folder on the way that is a link is caught by where it resolves.
    nonisolated private static func inside(_ name: String, of folder: URL) -> URL? {
        let path = folder.appendingPathComponent(name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).standardizedFileURL
        guard path.path.hasPrefix(folder.standardizedFileURL.path + "/"),
              (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              path.resolvingSymlinksInPath().path.hasPrefix(folder.resolvingSymlinksInPath().path + "/")
        else { return nil }
        return path
    }

    /// The shim as this extension gets it: with the events its code mentions
    /// — `chrome.tabs.onUpdated`, `e.runtime.onInstalled` — so its worker
    /// can take their listeners late (see the end of the script).
    nonisolated static func shim(for folder: URL) -> String {
        var found = Set<String>()
        let pattern = try! NSRegularExpression(pattern: #"\.([a-zA-Z]+)\.(on[A-Z][A-Za-z]+)\b"#)
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "js", url.lastPathComponent != file,
                  var text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            // Not the shim's own words, in a worker that already carries it.
            if text.hasPrefix(marker), let end = text.range(of: ender) { text = String(text[end.upperBound...]) }
            let range = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: range) {
                guard let a = Range(match.range(at: 1), in: text), let b = Range(match.range(at: 2), in: text) else { continue }
                found.insert("\(text[a]).\(text[b])")
            }
        }
        let list = (try? JSONSerialization.data(withJSONObject: found.sorted())).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        // And the scripts it ships, so its worker can be told at once that
        // one isn't there (see importScripts in the script).
        var scripts: [String] = []
        let all = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        while let url = all?.nextObject() as? URL {
            guard url.pathExtension == "js" else { continue }
            let path = String(url.standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count))
            // An empty one is marked: there is nothing to run in it.
            let empty = ((try? String(contentsOf: url, encoding: .utf8)) ?? "x").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            scripts.append((empty ? "-" : "") + path)
        }
        let shipped = (try? JSONSerialization.data(withJSONObject: scripts.sorted())).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return script.replacingOccurrences(of: "__SEARCH_EVENTS__", with: list)
            .replacingOccurrences(of: "__SEARCH_SCRIPTS__", with: shipped)
            .replacingOccurrences(of: "__SEARCH_CHROME__", with: Crx.chromeVersion)
            .replacingOccurrences(of: "__SEARCH_VERBOSE__", with: Store.testing ? "true" : "false")
    }

    /// Defines only what is missing, so the day WebKit implements an API,
    /// WebKit's is the one used.
    nonisolated static let script = #"""
    (() => {
      const root = globalThis;
      // Taken now, not looked up at each use: a sandbox that later locks
      // the globals away (MetaMask's LavaMoat) would break the shim's own
      // code that needs them — every fetch of a Request, every import.
      const { URL, FileReader, Response, Blob, File, DOMException, HTMLImageElement, HTMLAnchorElement, Element } = root;
      const chrome = root.chrome || root.browser;
      // A page's own world, where an extension's MAIN-world script runs with
      // this before it, has no extension APIs. Nothing to mend there, and
      // nothing may be left there for a page to see: Safari leaves nothing.
      // (There, Search's passkey patch holds navigator.credentials.)
      const ours = (() => { try { return !!(chrome && chrome.runtime && chrome.runtime.id); } catch (e) { return false; } })();
      if (!ours || root.__searchShim) return;
      // Bitwarden's bundled TypeScript uses these as computed class keys
      // before it registers disposable resources. Define them before any
      // extension code runs; Symbol.for keeps the key shared by its frames.
      const symbol = root.Symbol;
      for (const name of ["dispose", "asyncDispose"]) {
        if (symbol[name] === undefined) Object.defineProperty(symbol, name, { value: symbol.for("Symbol." + name) });
      }
      // WebKit reverted `requestIdleCallback` after a page-load regression
      // (bug 287681), leaving Proton Pass's form detection without it.
      const nativeIdle = typeof root.requestIdleCallback === "function"
        ? root.requestIdleCallback.bind(root) : null;
      const nativeCancelIdle = typeof root.cancelIdleCallback === "function"
        ? root.cancelIdleCallback.bind(root) : null;
      if (!nativeIdle || !nativeCancelIdle) {
        const idle = new Map();
        let idleId = 0;
        root.requestIdleCallback = (callback, options) => {
          const id = ++idleId;
          if (nativeIdle) {
            const nativeId = nativeIdle((deadline) => {
              if (!idle.delete(id)) return;
              callback(deadline);
            }, options);
            idle.set(id, { nativeId });
          } else {
            // Let the requesting script finish first. Chrome's maximum
            // idle deadline is 50 ms; this fallback uses the full budget.
            const timer = setTimeout(() => {
              if (!idle.delete(id)) return;
              const start = Date.now();
              callback({ didTimeout: false, timeRemaining: () => Math.max(0, 50 - (Date.now() - start)) });
            }, 1);
            idle.set(id, { timer });
          }
          return id;
        };
        root.cancelIdleCallback = (id) => {
          const request = idle.get(id);
          if (request === undefined) {
            if (nativeCancelIdle) nativeCancelIdle(id);
            return;
          }
          idle.delete(id);
          if (request.timer !== undefined) clearTimeout(request.timer);
          else if (nativeCancelIdle) nativeCancelIdle(request.nativeId);
        };
      }
      // Keep the first credentials container alive so extension hooks
      // survive WebKit replacing an unreferenced container.
      const credentials = root.navigator && root.navigator.credentials;
      if (credentials && !Object.prototype.hasOwnProperty.call(root, "__searchCredentials")) {
        Object.defineProperty(root, "__searchCredentials", { value: credentials });
      }
      Object.defineProperty(root, "__searchShim", { value: true });
      // WebKit finds a page's extension APIs through the `chrome` and
      // `browser` globals when it delivers an event. A sandbox that locks
      // every global away (MetaMask's LavaMoat) cuts it off: nothing arrives
      // any more. Made fixed accessors, they can't be taken away, and code
      // that assigns its own polyfill to them still can.
      for (const key of ["browser", "chrome"]) {
        // SingleFile installs its own browser getter with __defineGetter__.
        // Keep chrome fixed for WebKit's listeners, but leave browser open
        // for that getter to replace it without killing the worker.
        if (key === "browser" && root.chrome?.runtime?.id === "mpiodijhokgodhhofbcjdecpffjipkle") continue;
        const d = Object.getOwnPropertyDescriptor(root, key);
        if (!d || !d.configurable) continue;
        let value = root[key];
        // A replacement that hides the APIs — a Proxy some extensions put
        // there to keep them from other code (Proton Pass) — would hide them
        // from WebKit too, and nothing would reach the extension again. A
        // replacement that still carries them is taken.
        const carries = (v) => { try { return !!(v && v.runtime && v.runtime.id); } catch (e) { return false; } };
        try { Object.defineProperty(root, key, { configurable: false, enumerable: d.enumerable, get: () => value, set: (v) => { if (carries(v)) value = v; } }); } catch (e) {}
      }
      // On a web page this is a content script: only Chrome's behaviour is
      // mended there, no API that Chrome doesn't give content scripts either.
      const inContent = typeof location !== "undefined" && !/^(chrome|webkit)-extension:$/.test(location.protocol);
      // One of the extension's pages in a frame of a website — Vimium's bar,
      // the list iCloud Passwords opens under a field. WebKit runs it in the
      // website's process, which it trusts with no more than a content
      // script: a single call to tabs, windows, scripting… and WebKit takes
      // the process for compromised and ends it. The page reloads, and a
      // frame that makes the call as it loads reloads it for ever. Chrome
      // gives such a frame everything, so here the worker makes those calls
      // for it (see `__searchCall`).
      const embedded = !inContent && typeof window !== "undefined" && window.top !== window && (() => {
        try { const a = location.ancestorOrigins; if (a && a.length) return [...a].some((o) => o !== location.origin); } catch (e) {}
        try { return window.top.location.origin !== location.origin; } catch (e) { return true; }
      })();
      const runtime = chrome.runtime;

      // WebKit's objects are kept — WebKit finds an extension's listeners
      // through them, and a replacement would hide them. Members are set on
      // them instead: a method lives on the prototype, so an own property of
      // the same name takes its place.
      // WebKit's namespace and event objects are wrappers it doesn't keep
      // alive: once no script holds one, it is collected, and the next
      // `chrome.tabs` is a fresh object without what was set on it. So every
      // object touched here is held for good.
      const kept = new Set();
      try { Object.defineProperty(root, "__searchKept", { value: kept }); } catch (e) {}
      const put = (target, key, value) => {
        if (target && (typeof target === "object" || typeof target === "function")) kept.add(target);
        try { Object.defineProperty(target, key, { value, configurable: true, writable: true, enumerable: true }); }
        catch (e) { try { target[key] = value; } catch (e2) {} }
      };
      // Held from the start, before the extension's own code runs — its
      // polyfills set things on these objects too.
      const spaces = new Set(Object.keys(chrome));
      for (let o = Object.getPrototypeOf(chrome); o && o !== Object.prototype; o = Object.getPrototypeOf(o)) Object.getOwnPropertyNames(o).forEach((k) => spaces.add(k));
      for (const space of spaces) {
        let ns; try { ns = chrome[space]; } catch (e) { continue; }
        if (!ns || typeof ns !== "object") continue;
        kept.add(ns);
        // And the same object every time it is asked for: WebKit can hand
        // out a fresh one, without what was set on the last.
        if (!Object.prototype.hasOwnProperty.call(chrome, space) || Object.getOwnPropertyDescriptor(chrome, space).get) {
          try { Object.defineProperty(chrome, space, { value: ns, configurable: true, writable: true, enumerable: true }); } catch (e) {}
        }
        for (let o = ns; o && o !== Object.prototype; o = Object.getPrototypeOf(o)) {
          for (const key of Object.getOwnPropertyNames(o)) {
            if (!/^on[A-Z]/.test(key)) continue;
            try { const ev = ns[key]; if (ev && typeof ev === "object") kept.add(ev); } catch (e) {}
          }
        }
        for (const sub of ["local", "sync", "session", "managed"]) { try { if (ns[sub] && typeof ns[sub] === "object") kept.add(ns[sub]); } catch (e) {} }
      }
      const withLastError = (error, callback) => {
        put(runtime, "lastError", { message: String(error && error.message || error) });
        try { callback(); } finally { try { delete runtime.lastError; } catch (e) {} }
      };
      const native = (api, args) =>
        runtime.sendNativeMessage("search", { api, args: JSON.parse(JSON.stringify(args ?? [])) })
          .then((reply) => {
            if (reply && reply.error) throw new Error(reply.error);
            return reply ? reply.value : undefined;
          });
      // Chrome's APIs take a callback last, or return a promise without one.
      const call = (api) => (...args) => {
        const callback = args.length && typeof args[args.length - 1] === "function" ? args.pop() : null;
        const promise = native(api, args);
        if (!callback) return promise;
        promise.then((value) => callback(value), (error) => withLastError(error, callback));
      };
      // Where a tab is, as Search can find it: its place in its window's row
      // and that window's frame. WebKit's window numbers mean nothing to
      // Search, and windows.getAll gives the frames they go with.
      const frames = async () => {
        const all = chrome.windows && typeof chrome.windows.getAll === "function"
          ? await Promise.resolve(chrome.windows.getAll()).catch(() => []) : [];
        return new Map((all || []).map((w) => [w.id, { left: w.left, top: w.top, width: w.width, height: w.height }]));
      };
      const placeOf = (t, known) => ({ i: t.index, w: known.get(t.windowId) });
      const event = () => {
        const listeners = new Set();
        return {
          addListener: (f) => listeners.add(f), removeListener: (f) => listeners.delete(f),
          hasListener: (f) => listeners.has(f), hasListeners: () => listeners.size > 0,
          listeners,
        };
      };

      // Several onMessage listeners: WebKit takes the first one's return —
      // usually undefined — as the answer, where Chrome waits for whichever
      // calls sendResponse or returns true. So the extension's listeners are
      // gathered behind a single one of WebKit's that follows Chrome's rule.
      const worker = typeof ServiceWorkerGlobalScope !== "undefined" && root instanceof ServiceWorkerGlobalScope;
      // The extension's background, whichever WebKit runs: the worker, or a
      // page — it picks the page when a manifest names scripts as well.
      const background = worker || (!inContent && typeof document !== "undefined" && (() => {
        try { return chrome.extension && typeof chrome.extension.getBackgroundPage === "function" && chrome.extension.getBackgroundPage() === root; }
        catch (e) { return false; }
      })());
      const manifest = (() => { try { return runtime.getManifest(); } catch (e) { return {}; } })();
      const backgroundPage = manifest.background || {};
      const hasWorker = !!(backgroundPage.service_worker || backgroundPage.scripts || backgroundPage.page);
      const offscreenCapable = [...(manifest.permissions || []), ...(manifest.optional_permissions || [])].includes("offscreen");
      // A script a worker imports that isn't there: Chrome throws at once.
      // WebKit goes looking for it first, and while it does, runs the
      // promises already waiting — code that notes "still starting" until
      // its first promise settles (Tampermonkey) then thinks startup is
      // over, and refuses its own listeners. The extension's files are
      // known, so a missing one is refused the way Chrome refuses it, and
      // an empty one — Tampermonkey's test.js — isn't fetched at all.
      // The static routing API of Chrome's service workers (install
      // event.addRoutes) — a speed-up, so nothing is lost without it.
      if (worker && typeof root.InstallEvent === "function" && !InstallEvent.prototype.addRoutes) {
        InstallEvent.prototype.addRoutes = () => Promise.resolve();
      }
      // clients.matchAll() in an extension's worker: Chrome lists the
      // extension's own pages that are open — its popup, its pages in tabs.
      // WebKit lists none, so an extension that checks whether its popup is
      // open before sending it news always hears no: 1Password's popup
      // stays on "connecting to the app" for ever, the answer from the app
      // never passed on. The browser knows which pages are open, so they
      // are added to the list; a message posted to one reaches it through
      // a channel the pages listen on, as a message from the worker.
      // The other way round, a page reaches the worker through
      // navigator.serviceWorker, and the worker answers the page a message
      // came from — ScriptCat's worker hands each GM_xmlhttpRequest to its
      // offscreen document so. Here no worker controls the extension's
      // pages, so a page is given one that posts to the worker over the same
      // channel, and a message either way says who sent it. A port handed
      // over with a message can't cross the channel: it stays with the
      // sender, and what is posted to the one the other side is given comes
      // back over the channel to it.
      const clientsChannel = typeof BroadcastChannel === "function" && !inContent && !embedded ? new BroadcastChannel("search-clients") : null;
      const heldPorts = new Map();
      const handOver = (transfer) => (Array.isArray(transfer) ? transfer : (transfer && transfer.transfer) || [])
        .filter((p) => p instanceof MessagePort)
        .map((port) => { const key = Math.random().toString(36).slice(2); heldPorts.set(key, port); return key; });
      const answered = (data) => {
        if (typeof data.port !== "string") return false;
        const port = heldPorts.get(data.port);
        if (port) port.postMessage(data.data);
        return true;
      };
      const messageFrom = (source, data, keys) => {
        const ports = (Array.isArray(keys) ? keys : []).map((key) => {
          const pair = new MessageChannel();
          pair.port1.onmessage = (e) => clientsChannel.postMessage({ port: key, data: e.data });
          return pair.port2;
        });
        const event = new MessageEvent("message", { data, ports, origin: location.origin });
        if (source) Object.defineProperty(event, "source", { value: source });
        return event;
      };
      if (worker && clientsChannel && root.clients && typeof root.clients.matchAll === "function") {
        const matchAll = root.clients.matchAll.bind(root.clients);
        const client = (p) => ({
          id: "search-" + p.id, url: p.url, type: "window", frameType: "top-level",
          visibilityState: p.visible ? "visible" : "hidden", focused: !!p.focused,
          postMessage: (data, transfer) => { try { clientsChannel.postMessage({ url: p.url, data, ports: handOver(transfer) }); } catch (e) {} },
          focus() { return Promise.resolve(this); },
          navigate: () => Promise.resolve(null),
        });
        put(root.clients, "matchAll", async (options) => {
          const found = [...await matchAll(options)];
          const type = (options && options.type) || "window";
          if (type !== "window" && type !== "all") return found;
          let pages = [];
          try { pages = (await native("clients.pages", [])) || []; } catch (e) {}
          const listed = new Set(found.map((c) => c.url));
          return found.concat(pages.filter((p) => p && typeof p.url === "string" && !listed.has(p.url)).map(client));
        });
        clientsChannel.onmessage = ({ data }) => {
          if (!data || answered(data) || typeof data.from !== "string") return;
          root.dispatchEvent(messageFrom(client({ id: data.from, url: data.from }), data.data, data.ports));
        };
      } else if (clientsChannel && !background && typeof navigator !== "undefined" && navigator.serviceWorker) {
        const container = navigator.serviceWorker;
        const script = (() => { try { return (runtime.getManifest().background || {}).service_worker; } catch (e) { return null; } })();
        const controller = script && !container.controller ? {
          scriptURL: new URL(script, location.origin + "/").href, state: "activated", onstatechange: null, onerror: null,
          postMessage: (data, transfer) => { try { clientsChannel.postMessage({ from: location.href, data, ports: handOver(transfer) }); } catch (e) {} },
          addEventListener: () => {}, removeEventListener: () => {}, dispatchEvent: () => true,
        } : null;
        clientsChannel.onmessage = ({ data }) => {
          if (!data || answered(data) || data.url !== location.href) return;
          try { container.dispatchEvent(messageFrom(controller, data.data, data.ports)); } catch (e) {}
        };
        // Only the controller: `ready` is left as WebKit has it, since a
        // made-up registration has none of a real one's methods
        // (showNotification…), and a page calling them would throw where it
        // used to wait.
        if (controller) {
          kept.add(container);
          try { Object.defineProperty(container, "controller", { configurable: true, get: () => controller }); } catch (e) {}
        }
      }
      // WebKit runs an extension's worker on its web process's main thread,
      // and a worker's WebSocket waits there for the main thread to set up
      // its channel — for itself, for ever: the worker and every page of the
      // extension freeze. 1Password opens one as a sign-in succeeds. So a
      // worker's socket is made by the browser (ExtensionSocket.swift) and
      // its frames come and go over a native port.
      if (worker && typeof root.WebSocket === "function" && runtime && typeof runtime.connectNative === "function") {
        const connectNative = runtime.connectNative.bind(runtime);
        const encode = (bytes) => { let s = ""; for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000)); return btoa(s); };
        const decode = (text) => { const s = atob(text), bytes = new Uint8Array(s.length); for (let i = 0; i < s.length; i++) bytes[i] = s.charCodeAt(i); return bytes.buffer; };
        const states = { CONNECTING: 0, OPEN: 1, CLOSING: 2, CLOSED: 3 };
        class WebSocket extends EventTarget {
          #port; #state = 0; #queue = Promise.resolve(); #origin; #hello;
          constructor(url, protocols) {
            super();
            let parsed;
            try { parsed = new URL(url, location.href); } catch (e) { throw new DOMException("The URL '" + url + "' is invalid.", "SyntaxError"); }
            if (parsed.protocol === "http:") parsed.protocol = "ws:";
            if (parsed.protocol === "https:") parsed.protocol = "wss:";
            if (!/^wss?:$/.test(parsed.protocol) || parsed.hash) throw new DOMException("The URL '" + url + "' is invalid.", "SyntaxError");
            const list = protocols === undefined ? [] : (Array.isArray(protocols) ? protocols : [protocols]).map(String);
            Object.defineProperty(this, "url", { value: parsed.href, enumerable: true });
            this.#origin = parsed.origin;
            this.protocol = ""; this.extensions = ""; this.binaryType = "blob"; this.bufferedAmount = 0;
            this.onopen = null; this.onmessage = null; this.onerror = null; this.onclose = null;
            this.#hello = { open: this.url, protocols: list, userAgent: navigator.userAgent };
            this.#connect();
          }
          // WebKit drops what a worker posts on a port it has only just
          // opened, without a word either way. So the opening is said again,
          // on the same port, until the browser answers anything at all.
          #connect() {
            const port = connectNative("search.socket");
            let ready = false, tries = 0;
            this.#port = port;
            const again = () => {
              if (ready || this.#state === 3) return;
              if (tries++ >= 20) { this.#fire("error"); this.#closed(1006, "", false); return; }
              try { port.postMessage(this.#hello); } catch (e) {}
              setTimeout(again, 100 * Math.min(tries, 5));
            };
            port.onMessage.addListener((m) => {
              if (!ready) ready = true;
              if (m && m.ready === true) return;
              this.#take(m);
            });
            port.onDisconnect.addListener(() => {
              if (this.#state === 3) return;
              this.#fire("error");
              this.#closed(1006, "", false);
            });
            again();
          }
          get readyState() { return this.#state; }
          #fire(type, init) {
            let event;
            if (type === "message") event = new MessageEvent("message", init);
            else if (type === "close" && typeof CloseEvent === "function") event = new CloseEvent("close", init);
            else { event = new Event(type); if (init) for (const k in init) Object.defineProperty(event, k, { value: init[k] }); }
            const handler = this["on" + type];
            if (typeof handler === "function") { try { handler.call(this, event); } catch (e) { setTimeout(() => { throw e; }); } }
            this.dispatchEvent(event);
          }
          #closed(code, reason, wasClean) {
            this.#state = 3;
            try { this.#port.disconnect(); } catch (e) {}
            this.#fire("close", { code, reason, wasClean });
          }
          #take(m) {
            if (!m || this.#state === 3) return;
            if ("opened" in m) { this.protocol = m.opened; this.#state = 1; this.#fire("open"); }
            else if ("text" in m) this.#fire("message", { data: m.text, origin: this.#origin });
            else if ("binary" in m) {
              const buffer = decode(m.binary);
              this.#fire("message", { data: this.binaryType === "arraybuffer" ? buffer : new Blob([buffer]), origin: this.#origin });
            }
            else if ("failed" in m) this.#fire("error");
            else if ("closed" in m) this.#closed(m.closed, m.reason || "", !!m.clean);
          }
          send(data) {
            if (this.#state === 0) throw new DOMException("WebSocket is still in CONNECTING state.", "InvalidStateError");
            if (this.#state !== 1) return;
            const post = (message) => { try { this.#port.postMessage(message); } catch (e) {} };
            if (typeof data === "string") { this.#queue = this.#queue.then(() => post({ send: data })); return; }
            const bytes = data instanceof ArrayBuffer ? Promise.resolve(new Uint8Array(data))
              : ArrayBuffer.isView(data) ? Promise.resolve(new Uint8Array(data.buffer, data.byteOffset, data.byteLength))
              : data instanceof Blob ? data.arrayBuffer().then((b) => new Uint8Array(b))
              : Promise.resolve(null);
            this.#queue = this.#queue.then(() => bytes).then((b) => b ? post({ sendBinary: encode(b) }) : post({ send: String(data) }));
          }
          close(code, reason) {
            if (code !== undefined && code !== 1000 && !(code >= 3000 && code <= 4999)) {
              throw new DOMException("The close code must be either 1000, or between 3000 and 4999. " + code + " is neither.", "InvalidAccessError");
            }
            if (this.#state >= 2) return;
            this.#state = 2;
            const message = { close: code === undefined ? 1000 : code, reason: reason === undefined ? "" : String(reason) };
            this.#queue = this.#queue.then(() => { try { this.#port.postMessage(message); } catch (e) {} });
          }
        }
        for (const [k, v] of Object.entries(states)) { Object.defineProperty(WebSocket, k, { value: v }); Object.defineProperty(WebSocket.prototype, k, { value: v }); }
        Object.defineProperty(root, "WebSocket", { value: WebSocket, configurable: true, writable: true });
      }
      // The same loss meets a worker's port to an app on the Mac: what it
      // posts in its first moments never reaches the app, and comes back to
      // the worker's own listeners instead. iCloud Passwords says hello to
      // its helper that way, and without the helper's answer asks for the
      // code again and again. So on such a port, what the extension posts
      // is held from its first message until the browser says the port has
      // arrived — asked on the same port, as the socket asks — and then sent
      // in order. WebKit won't let connectNative be replaced in a worker, so
      // this is done on what every port shares, found through a port to the
      // browser itself; the question and the answer are kept from the
      // extension's listeners, and never reach the app.
      if (worker && runtime && typeof runtime.connectNative === "function") {
        let found = null;
        try { found = runtime.connectNative("search"); found.disconnect(); } catch (e) {}
        const portProto = found && Object.getPrototypeOf(found);
        const eventProto = found && found.onMessage && Object.getPrototypeOf(found.onMessage);
        if (portProto && eventProto && typeof portProto.postMessage === "function" && typeof eventProto.addListener === "function") {
          // Ports that go to the extension's own pages or tabs, not an app.
          const toPages = new WeakSet();
          for (const [space, name] of [[runtime, "connect"], [chrome.tabs, "connect"]]) {
            const connect = space && space[name];
            if (typeof connect !== "function") continue;
            put(space, name, (...args) => { const port = connect.apply(space, args); try { toPages.add(port); } catch (e) {} return port; });
          }
          const post = portProto.postMessage, add = eventProto.addListener, remove = eventProto.removeListener, has = eventProto.hasListener;
          const ours = (m) => !!m && typeof m === "object" && "__searchNative" in m;
          // Ports seen, each with what waits to be sent (null once it may go).
          const ports = new WeakMap();
          const start = (port) => {
            const state = { held: [] };
            let tries = 0;
            const flush = () => { const list = state.held; state.held = null; for (const m of list || []) post.call(port, m); };
            const again = () => {
              if (!state.held) return;
              // Unanswered, they go anyway: no worse than before.
              if (tries++ >= 20) { flush(); return; }
              try { post.call(port, { __searchNative: "here?" }); } catch (e) {}
              setTimeout(again, 100 * Math.min(tries, 5));
            };
            add.call(port.onMessage, (m) => {
              if (m && m.__searchNative === "here" && state.held) flush();
              // WebKit keeps a worker only while it has posted on an open
              // port in the last two minutes; what arrives on one doesn't
              // count. The browser's word now and then is answered on the
              // port, so a worker holding a port to an app stays, as in
              // Chrome — iCloud Passwords otherwise forgets it was paired.
              if (m && m.__searchNative === "alive") { try { post.call(port, { __searchNative: "beat" }); } catch (e) {} }
            });
            add.call(port.onDisconnect, () => { state.held = null; });
            again();
            return state;
          };
          put(portProto, "postMessage", function (message) {
            let state = ports.get(this);
            if (!state) {
              const native = !toPages.has(this) && this.sender == null && typeof this.name === "string" && !/^search(\.|$)/.test(this.name);
              state = native ? start(this) : { held: null };
              ports.set(this, state);
            }
            if (state.held) { state.held.push(message); return; }
            return post.call(this, message);
          });
          // A port's listeners, and only a port's (the namespaces' own
          // events are kept as they are), each behind one that lets the
          // question and the answer pass by.
          const wrapped = new WeakMap();
          const wrapper = (event, f, make) => {
            let byEvent = wrapped.get(event);
            if (!byEvent) { byEvent = new Map(); if (make) wrapped.set(event, byEvent); }
            let w = byEvent.get(f);
            if (!w && make) { w = function (m, ...rest) { if (ours(m)) return; return f.call(this, m, ...rest); }; byEvent.set(f, w); }
            return w;
          };
          put(eventProto, "addListener", function (f) {
            if (kept.has(this) || typeof f !== "function") return add.call(this, f);
            return add.call(this, wrapper(this, f, true));
          });
          put(eventProto, "removeListener", function (f) {
            const w = !kept.has(this) && typeof f === "function" && wrapper(this, f, false);
            if (!w) return remove.call(this, f);
            wrapped.get(this).delete(f);
            return remove.call(this, w);
          });
          put(eventProto, "hasListener", function (f) {
            const w = !kept.has(this) && typeof f === "function" && wrapper(this, f, false);
            return has.call(this, w || f);
          });
        }
      }
      // WebKit gives a worker the user agent of the last web page that set
      // one — Safari's, as Search's tabs send — not the Chrome one the
      // extension's pages have. Code that picks its path by it then takes
      // the Safari one: Bitwarden's asks a Safari app for a reply thousands
      // of times a second and floods the browser.
      // Its pages too: an extension reads navigator.userAgent to pick a code
      // path, a download, a welcome page, and finds nothing it knows in
      // Safari's. (Not WebKit's setting: see Extensions.init.)
      if (!inContent && typeof navigator !== "undefined" && !/ Chrome\//.test(navigator.userAgent)) {
        const chromeUA = navigator.userAgent.replace(/ Version\/[\d.]+.*$/, "").replace(/ Safari\/[\d.]+$/, "") + " Chrome/__SEARCH_CHROME__ Safari/537.36";
        const proto = typeof WorkerNavigator !== "undefined" && worker ? WorkerNavigator.prototype : typeof Navigator !== "undefined" ? Navigator.prototype : null;
        try {
          if (proto) {
            Object.defineProperty(proto, "userAgent", { get: () => chromeUA, configurable: true });
            Object.defineProperty(proto, "appVersion", { get: () => chromeUA.replace(/^Mozilla\//, ""), configurable: true });
            Object.defineProperty(proto, "vendor", { get: () => "Google Inc.", configurable: true });
            if (!("userAgentData" in navigator)) {
              const major = "__SEARCH_CHROME__".split(".")[0];
              const brands = [{ brand: "Chromium", version: major }, { brand: "Google Chrome", version: major }, { brand: "Not.A/Brand", version: "99" }];
              const low = { brands, mobile: false, platform: "macOS" };
              const mac = (chromeUA.match(/Mac OS X (\d+)[_.](\d+)(?:[_.](\d+))?/) || []).slice(1).map((n) => n || "0").join(".") || "10.15.7";
              const high = {
                architecture: "arm", bitness: "64", model: "", platformVersion: mac, wow64: false,
                fullVersionList: brands.map((b) => ({ brand: b.brand, version: b.version === major ? "__SEARCH_CHROME__" : b.version + ".0.0.0" })),
                uaFullVersion: "__SEARCH_CHROME__",
              };
              const pick = (hints) => Object.assign({}, low, ...(Array.isArray(hints) ? hints : []).filter((h) => h in high).map((h) => ({ [h]: high[h] })));
              const data = Object.assign({}, low, { getHighEntropyValues: (hints) => Promise.resolve(pick(hints)), toJSON: () => low });
              Object.defineProperty(proto, "userAgentData", { get: () => data, configurable: true });
            }
          }
        } catch (e) {}
      }
      if (worker && typeof root.importScripts === "function") {
        const shipped = new Set(), empty = new Set();
        for (const p of __SEARCH_SCRIPTS__) p.startsWith("-") ? empty.add(p.slice(1)) : shipped.add(p);
        const load = root.importScripts.bind(root);
        root.importScripts = (...urls) => {
          const wanted = [];
          for (const u of urls) {
            let url; try { url = new URL(u, location.href); } catch (e) { wanted.push(u); continue; }
            const path = decodeURIComponent(url.pathname);
            if (url.origin === location.origin && empty.has(path)) continue;
            if (url.origin === location.origin && !shipped.has(path)) {
              throw new DOMException("Failed to execute 'importScripts' on 'WorkerGlobalScope': The script at '" + url.href + "' failed to load.", "NetworkError");
            }
            wanted.push(u);
          }
          if (wanted.length) return load(...wanted);
        };
      }
      // The tab an extension's framed page is in, asked once (see __searchToFrame).
      let ownTab = null;
      // Who has something to say about a message, told between the
      // extension's worker and its own pages on a channel they share (one
      // origin): each says, as soon as its listeners have run, whether it
      // answers or lets the message pass, and the sender says so of what
      // it sends. A page with nothing to say can then stay silent only
      // as long as someone else may still answer (see the end of `dispatch`).
      // A page in a website's frame is on the website's side of the
      // channel and takes no part; it waits, as before.
      const channel = !inContent && !embedded && typeof BroadcastChannel === "function" ? new BroadcastChannel("search-messages") : null;
      const me = Math.random().toString(36).slice(2);
      const peers = new Set();
      const verdicts = new Map();
      const waiting = new Set();
      const present = new Set();
      // Pages that are there but didn't hear the last message sent to all —
      // WebKit doesn't bring every message to every page. Not waited for
      // until they say something about one they heard.
      const deaf = new Set();
      const keyOf = (message) => { try { const k = JSON.stringify(message); return k && k.length < 4000 ? k : null; } catch (e) { return null; } };
      const tell = (message, verdict, heard) => {
        const key = channel && keyOf(message);
        if (key) channel.postMessage({ key, from: background ? "worker" : me, verdict, heard, at: Date.now() });
      };
      // WebKit hands none of the extension's pages a message its worker or another of its pages sent, and Bitwarden's
      // sync and passkey window wait on those. so each one also goes over the channel, and a page that didn't hear it
      // from WebKit takes it from there.
      // Each message's copies are paired by count, keyed on all of it, and
      // only with what the extension's own pages and worker sent: one WebKit
      // delivered cancels one relayed copy still to come, and one relayed
      // cancels a late one from WebKit. A content script's message, however
      // alike, is never taken for one, and an unpaired copy is forgotten
      // after a few seconds (Security).
      const relayKey = (message) => {
        try { const text = JSON.stringify(message); return text === undefined ? null : text; } catch (e) { return null; }
      };
      const ownPlace = (() => { try { return runtime.getURL(""); } catch (e) { return ""; } })();
      const fromOwnPages = (sender) => !!sender && sender.id === runtime.id && typeof sender.url === "string" && !!ownPlace
        && (sender.url + "/").startsWith(ownPlace.replace(/\/$/, "") + "/");
      const heardNatively = new Map(), heardRelayed = new Map();
      const count = (map, key, by) => {
        const now = Date.now();
        for (const [k, v] of map) if (now - v.at > 5000) map.delete(k);
        const n = ((map.get(key) || {}).n || 0) + by;
        if (n > 0) { if (map.size > 200) map.clear(); map.set(key, { n, at: now }); } else map.delete(key);
      };
      const pending = (map, key) => { const v = map.get(key); return !!v && Date.now() - v.at <= 5000 && v.n > 0; };
      let deliverRelayed = null, relaying = false;
      const relay = (message) => { if (channel && !inContent) try { channel.postMessage({ relay: message, from: me, url: location.href }); } catch (e) {} };
      if (channel) {
        channel.onmessage = ({ data }) => {
          if (!data || data.from === me) return;
          if (data.relay !== undefined) {
            const key = relayKey(data.relay);
            if (!background && deliverRelayed) setTimeout(() => {
              if (key && pending(heardNatively, key)) { count(heardNatively, key, -1); return; }
              if (key) count(heardRelayed, key, 1);
              relaying = true;
              try { deliverRelayed(data.relay, { id: runtime.id, url: data.url, origin: location.origin }); } finally { relaying = false; }
            }, 50);
            return;
          }
          // The pages that listen, as they come and go.
          if (!background && data.hello) {
            const known = peers.has(data.from);
            peers.add(data.from);
            if (!known && listening) channel.postMessage({ hello: true, from: me, where: location.pathname });
            return;
          }
          if (data.bye) { peers.delete(data.from); waiting.forEach((check) => check()); return; }
          // A popup that closes is thrown away without a word; so a page
          // left waiting asks who is still there.
          if (data.roll) { if (listening && !background) channel.postMessage({ here: true, from: me, to: data.from }); return; }
          if (data.here) { if (data.to === me) present.forEach((hear) => hear(data.from)); return; }
          if (typeof data.key !== "string") return;
          const now = Date.now();
          for (const [k, v] of verdicts) { if (now - v.at > 30000) verdicts.delete(k); else break; }
          const entry = verdicts.get(data.key) || { at: now, worker: null, pages: new Map() };
          verdicts.delete(data.key);
          verdicts.set(data.key, entry);
          entry.at = now;
          if (data.from === "worker") entry.worker = data;
          else { peers.add(data.from); if (data.heard) deaf.delete(data.from); entry.pages.set(data.from, data); }
          waiting.forEach((check) => check());
        };
        if (!background) try { root.addEventListener("pagehide", () => leave()); } catch (e) {}
      }
      // Only a page that listens for messages is waited for: one that
      // doesn't never hears them, so never says anything about them.
      let listening = false;
      const join = () => { if (channel && !background && !listening) { listening = true; channel.postMessage({ hello: true, from: me, where: location.pathname }); } };
      const leave = () => { if (channel && !background && listening) { listening = false; channel.postMessage({ bye: true, from: me }); } };
      // Who sent a message from the extension's popup, as Chrome says it:
      // no tab. WebKit only carries a page's messages when it can name the
      // tab the page is in, so the popup is one (see PopupPage) — a tab at
      // no place in the window's row (its index comes as NaN), its own
      // page at the top. Passbolt's worker takes a port that comes with a
      // tab for one of its frames in a website, and turned its popup's
      // away: the popup stayed empty.
      const untabbed = (sender) => {
        const tab = sender && sender.tab;
        if (!tab || tab.index >= 0 || sender.frameId || tab.url !== sender.url
          || !runtime || !String(sender.url).startsWith(runtime.getURL(""))) return sender;
        const plain = { ...sender };
        delete plain.tab;
        return plain;
      };
      const gather = (event, told) => {
        if (!event || typeof event.addListener !== "function") return;
        const add = event.addListener.bind(event);
        const remove = event.removeListener.bind(event);
        const internalMessages = event === runtime.onMessage;
        const relayHost = internalMessages && offscreenCapable && !hasWorker;
        const listeners = new Set();
        let attached = false;
        const dispatch = function (message, sender, respond, local = false) {
          if (!local && !background && !relaying && fromOwnPages(sender)) {
            const k = relayKey(message);
            if (k && pending(heardRelayed, k)) { count(heardRelayed, k, -1); return; }
            if (k) count(heardNatively, k, 1);
          }
          let settled = false, keep = false;
          const sendResponse = (value) => { if (!settled) { settled = true; respond(value); } };
          // WebKit excludes the sender's whole page from runtime delivery,
          // so an offscreen iframe cannot reach its parent directly. Another
          // context of the same extension carries that delivery to the browser.
          if (!local && message && message.__searchOffscreenRelay === true && sender.id === runtime.id) {
            native("offscreen.sendMessage", [message.token, message.message, sender])
              .then(sendResponse, (error) => sendResponse({ relayError: String(error) }));
            return true;
          }
          // Only the worker answers; any other page stays out of it.
          if (message && message.__searchPing === true) {
            if (background) { sendResponse("pong"); return; }
            return true;
          }
          // Search's own envelopes come from this extension only: another
          // extension (onMessageExternal) could otherwise speak as one of its
          // user scripts, or as a frame of its own.
          const fromHere = !!(sender && sender.id === runtime.id);
          if (message && (message.__searchUserScript === true || message.__searchToFrame) && !fromHere) return;
          if (message && message.__searchUserScript === true) {
            const route = root.__searchUserScriptMessage;
            return route && route(message.message, sender, sendResponse) && !settled ? true : undefined;
          }
          // A tab's message, handed on by the worker (see alsoFramed): taken
          // by the frame it names, in the tab it names; every other page lets
          // it pass without answering, as it would a message not for it.
          if (message && message.__searchToFrame) {
            const to = message.__searchToFrame;
            if (!embedded || !(to.urls || []).includes(location.href)) {
              if (!background) setTimeout(() => sendResponse(undefined), 10000);
              return background ? undefined : true;
            }
            if (!ownTab) ownTab = Promise.resolve(runtime.sendMessage({ __searchCall: { space: "tabs", method: "getCurrent", args: [] } }))
              .then((reply) => reply && reply.value ? reply.value.id : null, () => null);
            ownTab.then((id) => {
              if (id !== to.tabId) return setTimeout(() => sendResponse(undefined), 10000);
              let kept = false;
              for (const listener of [...listeners]) {
                let result;
                try { result = listener(to.message, sender, sendResponse); } catch (e) { setTimeout(() => { throw e; }); continue; }
                if (result === true) kept = true;
                else if (result && typeof result.then === "function") { kept = true; result.then(sendResponse, () => sendResponse(undefined)); }
              }
              if (!kept) sendResponse(undefined);
            });
            return true;
          }
          // A call one of the extension's pages in a website's frame can't
          // make itself (see `embedded`), made here for it — and only for
          // one of its pages: a content script gets no more than Chrome
          // gives it.
          if (message && message.__searchCall) {
            if (!background) return true;
            const { space, method, args } = message.__searchCall;
            const own = (() => { try { return new URL(sender.url).origin === location.origin; } catch (e) { return false; } })();
            if (!own) { sendResponse({ error: "chrome." + space + " isn't available to content scripts" }); return; }
            if (space === "tabs" && method === "getCurrent") { sendResponse({ value: sender.tab }); return; }
            let ns; try { ns = chrome[space]; } catch (e) {}
            if (!ns || typeof ns[method] !== "function") { sendResponse({ error: "chrome." + space + "." + method + " isn't available" }); return; }
            Promise.resolve().then(async () => {
              if (space === "scripting" && method === "executeScript" && typeof args?.[0]?.__searchFunction === "string") {
                const { __searchFunction, args: functionArgs, ...details } = args[0];
                if (details.files) throw new Error("Cannot specify both 'func' and 'files'");
                const file = await native("scripting.file", [__searchFunction, functionArgs || []]);
                return ns[method]({ ...details, files: [file] });
              }
              return ns[method](...(args || []));
            })
              .then((value) => sendResponse({ value }), (e) => sendResponse({ error: String(e && e.message || e) }));
            return true;
          }
          sender = untabbed(sender);
          for (const listener of [...listeners]) {
            let result;
            try { result = listener(message, sender, sendResponse); } catch (e) { setTimeout(() => { throw e; }); continue; }
            if (result === true) keep = true;
            else if (result && typeof result.then === "function") { keep = true; result.then(sendResponse, () => sendResponse(undefined)); }
          }
          if (!local && !inContent) tell(message, keep || settled ? "answers" : "passes", true);
          if (keep || settled) return keep && !settled ? true : undefined;
          // A direct offscreen delivery has no other local receiver to wait for.
          if (local) return undefined;
          // Nothing here answers it. In Chrome that leaves the question to
          // the extension's other pages and its worker; WebKit takes the
          // first reply from any of them, and an empty one from a page that
          // only listens for something else — an offscreen document, an
          // options page — would arrive before the worker's real answer. So
          // a page that has nothing to say steps aside, and says nothing
          // only once everyone else has had ample time — or as soon as the
          // worker and every other open page have said they let it pass too,
          // or the worker sent it itself. Bitwarden's offscreen document
          // keeps its storage and answers a save with nothing: ten seconds
          // on each one got in the way of signing in.
          if (!background && !inContent) {
            const received = Date.now();
            const key = channel && keyOf(message);
            let check = () => {}, roll = null;
            const done = () => { waiting.delete(check); clearTimeout(late); clearTimeout(roll); };
            const late = setTimeout(() => { done(); sendResponse(undefined); }, 10000);
            if (key) {
              // Only what was said about this message, not an identical one
              // a while ago.
              const fresh = (said) => said && said.at >= received - 2000;
              check = () => {
                const entry = verdicts.get(key);
                if (settled || !entry) return;
                const worker = entry.worker;
                if (fresh(worker) && worker.verdict === "answers") { done(); return; }
                const said = [...peers].filter((id) => !deaf.has(id) || entry.pages.has(id)).map((id) => entry.pages.get(id));
                if (said.some((p) => fresh(p) && p.verdict === "answers")) { done(); return; }
                if (!fresh(worker) || said.some((p) => !fresh(p))) return;
                done();
                sendResponse(undefined);
              };
              waiting.add(check);
              check();
              // Still waiting on someone after a moment: those who don't say
              // they are here within a second are gone, and those who do but
              // still have said nothing about this message didn't hear it.
              roll = setTimeout(() => {
                if (settled) return;
                const heard = new Set();
                const hear = (id) => heard.add(id);
                present.add(hear);
                channel.postMessage({ roll: true, from: me });
                setTimeout(() => {
                  present.delete(hear);
                  for (const id of [...peers]) if (!heard.has(id)) peers.delete(id);
                  const entry = verdicts.get(key);
                  for (const id of peers) { const p = entry && entry.pages.get(id); if (!p || p.at < received - 2000) deaf.add(id); }
                  check();
                }, 1000);
              }, 200);
            }
            return true;
          }
          return undefined;
        };
        if (internalMessages) {
          put(root, "__searchOffscreenDispatch", (message, sender) => new Promise((resolve) => {
            const timer = setTimeout(() => resolve({ handled: false }), 30000);
            const done = (result) => { clearTimeout(timer); resolve(result); };
            const waiting = dispatch(message, sender, (value) => done({ handled: true, value }), true);
            if (waiting !== true) done({ handled: false });
          }));
        }
        put(event, "addListener", (listener) => {
          listeners.add(listener);
          if (told) { join(); deliverRelayed = (m, s) => dispatch(m, s, () => {}); }
          if (!attached) { attached = true; add(dispatch); }
        });
        put(event, "removeListener", (listener) => {
          listeners.delete(listener);
          if (told && listeners.size === 0 && !relayHost) leave();
          if (attached && listeners.size === 0 && !(internalMessages && (background || relayHost))) {
            attached = false; remove(dispatch);
          }
        });
        put(event, "hasListener", (listener) => listeners.has(listener));
        put(event, "hasListeners", () => listeners.size > 0);
        // A worker may only add listeners while it starts; one that adds its
        // first later would be refused. So in a worker the one listener is
        // WebKit's from the start.
        if (background || relayHost) { attached = true; add(dispatch); if (told) join(); }
      };
      if (runtime) {
        const names = new Set();
        for (let o = runtime; o && o !== Object.prototype; o = Object.getPrototypeOf(o)) Object.getOwnPropertyNames(o).forEach((k) => names.add(k));
        for (const name of names) {
          if (name === "constructor" || /^on[A-Z]/.test(name)) continue;
          let f; try { f = runtime[name]; } catch (e) { continue; }
          if (typeof f === "function") put(runtime, name, f.bind(runtime));
        }
      }
      if (inContent) {
        // A frame inside this extension's own page — its offscreen
        // document reading a site, say — is part of that page's tab, and
        // WebKit brings none of its messages to the page around it. So a
        // copy goes by way of another of the extension's contexts, which
        // hands it to the page (see offscreen.sendMessage). Only there: in a
        // frame of a website, the page above is the website's, and a second
        // send would only cost every message a round trip (#192).
        const insideOwnPage = (() => {
          try {
            const above = location.ancestorOrigins;
            return window !== window.top && !!above && above.length > 0 && above[above.length - 1] + "/" === runtime.getURL("");
          } catch (e) { return false; }
        })();
        if (offscreenCapable && insideOwnPage && runtime && typeof runtime.sendMessage === "function") {
          const send = runtime.sendMessage.bind(runtime);
          let sequence = 0;
          const prefix = Array.from(crypto.getRandomValues(new Uint32Array(4)), (n) => n.toString(16)).join("-");
          put(runtime, "sendMessage", (...args) => {
            const callback = typeof args[args.length - 1] === "function" ? args.pop() : null;
            const options = args[1];
            const isOptions = options == null || (typeof options === "object" && !Array.isArray(options)
              && Object.keys(options).every((key) => key === "includeTlsChannelId"));
            const explicit = args.length >= 3 || (args.length === 2 && typeof args[0] === "string" && !isOptions);
            const own = !explicit || !args[0] || args[0] === runtime.id;
            const original = send(...args);
            let answer = original;
            if (own && args.length) {
              const relay = send({ __searchOffscreenRelay: true, token: prefix + ":" + (++sequence),
                message: args[explicit ? 1 : 0] }).then((reply) => {
                  if (reply && reply.relayError) throw new Error(reply.relayError);
                  return reply && reply.handled ? reply.value : undefined;
                });
              // An empty native reply must not beat the parent document's
              // reply. Preserve the first actual response from either route.
              answer = new Promise((resolve, reject) => {
                let left = 2, failure;
                const done = (value) => {
                  if (value !== undefined) resolve(value);
                  if (--left === 0) failure ? reject(failure) : resolve(undefined);
                };
                for (const response of [original, relay]) response.then(done, (error) => { failure = error; done(); });
              });
            }
            if (!callback) return answer;
            answer.then(callback, (error) => withLastError(error, callback));
          });
        }
        return;
      }

      // In a website's frame, everything WebKit keeps to the extension's own
      // process goes through the worker instead. What stays direct is what
      // WebKit lets a content script call too. Namespaces the shim adds
      // itself further down answer through the browser, which is allowed.
      if (embedded) {
        const direct = new Set(["runtime", "storage", "i18n", "extension", "permissions", "dom", "test"]);
        const ask = (space, method, args) => {
          while (args.length && args[args.length - 1] === undefined) args.pop();
          // A function cannot cross the message channel. Keep its source
          // separately so the worker can inject it from an extension file.
          if (space === "scripting" && method === "executeScript" && typeof (args[0] && args[0].func) === "function") {
            args = [{ ...args[0], func: undefined, __searchFunction: args[0].func.toString() }, ...args.slice(1)];
          }
          let payload;
          try { payload = JSON.parse(JSON.stringify(args)); } catch (e) { return Promise.reject(e); }
          return Promise.resolve(chrome.runtime.sendMessage({ __searchCall: { space, method, args: payload } })).then((reply) => {
            if (!reply) throw new Error("chrome." + space + "." + method + " had no answer from the extension's background");
            if (reply.error) throw new Error(reply.error);
            return reply.value;
          });
        };
        for (const space of spaces) {
          if (direct.has(space)) continue;
          let ns; try { ns = chrome[space]; } catch (e) { continue; }
          if (!ns || typeof ns !== "object") continue;
          const names = new Set();
          for (let o = ns; o && o !== Object.prototype; o = Object.getPrototypeOf(o)) Object.getOwnPropertyNames(o).forEach((k) => names.add(k));
          for (const name of names) {
            if (name === "constructor" || /^on[A-Z]/.test(name)) continue;
            let f; try { f = ns[name]; } catch (e) { continue; }
            if (typeof f !== "function") continue;
            // A port can't be carried over: one that closes at once, as
            // Chrome's does when nothing answers, rather than a dead process.
            if (name === "connect") {
              put(ns, name, (...args) => {
                const port = { name: (args.find((a) => a && typeof a === "object") || {}).name || "", sender: undefined,
                  postMessage: () => {}, disconnect: () => {}, onMessage: event(), onDisconnect: event() };
                setTimeout(() => {
                  put(runtime, "lastError", { message: "Could not establish connection. Receiving end does not exist." });
                  try { for (const f of [...port.onDisconnect.listeners]) f(port); } finally { try { delete runtime.lastError; } catch (e) {} }
                });
                return port;
              });
              continue;
            }
            put(ns, name, (...args) => {
              const callback = args.length && typeof args[args.length - 1] === "function" ? args.pop() : null;
              const answer = ask(space, name, args);
              if (!callback) return answer;
              answer.then((value) => callback(value), (error) => withLastError(error, callback));
            });
          }
        }
      }

      // WebKit unloads an extension's worker after half a minute idle, and
      // starts it again for an event only if it remembers a listener for
      // it — which it does for messages, the worker's listener being in
      // place from its first line (see gather).
      //
      // A reply that never came is answered Chrome's way: in callback
      // form, with lastError set — WebKit calls back with nothing and no
      // error, and code that pings a tab to see if its script is there
      // waits for ever.
      const replied = (promise, callback, gone) => {
        if (typeof callback !== "function") return promise;
        promise.then((r) => r === undefined ? withLastError(new Error(gone), callback) : callback(r),
          (e) => withLastError(e, callback));
      };
      let checkWorker = () => {};
      // When the worker was last heard from — a reply, a port message.
      let heard = 0;
      if (runtime && typeof runtime.sendMessage === "function") {
        const page = typeof document !== "undefined";
        // WebKit's own, looked up at each call — not held from the page's
        // first moment, when the page isn't yet the tab or popup it will be.
        const original = Object.getPrototypeOf(runtime).sendMessage;
        const send = (...args) => original.apply(chrome.runtime, args);
        // WebKit can also lose a worker without knowing — its process
        // stopped along with a tab's — and then answers every message with
        // nothing, for good. So after waking it, a page asks the worker
        // itself (its shim answers) at most every few seconds; no answer,
        // and the browser takes the extension up afresh.
        // The message itself doesn't wait on the answer: a worker busy
        // starting up can take seconds. An empty reply means gone; silence
        // for a quarter of a minute does too.
        let asking = false;
        const check = () => {
          if (!hasWorker || asking || Date.now() - heard < 5000) return;
          asking = true;
          // Asked three times, a second apart, then once more after waking
          // it — only then taken for gone: a restart has consequences
          // (welcome pages, a popup loading again), and a question can go
          // unanswered for reasons that pass. Waking a worker that runs
          // starts it over, so that is kept for last.
          const ping = Object.getPrototypeOf(runtime).sendMessage;
          const ask = () => Promise.race([ping.call(runtime, { __searchPing: true }), new Promise((r) => setTimeout(() => r("late"), 15000))]).catch(() => undefined);
          const pause = (ms) => new Promise((w) => setTimeout(w, ms));
          const tries = [() => ask(), () => pause(1000).then(ask), () => pause(1000).then(ask),
            () => native("background.wake", []).catch(() => {}).then(() => pause(1000)).then(ask)];
          const attempt = (i, last) => i >= tries.length || last === "pong" ? Promise.resolve(last) : tries[i]().then((r) => attempt(i + 1, r));
          const started = Date.now();
          attempt(0).then((r) => {
            // Any real answer from the worker meanwhile says it runs, too:
            // the question alone can go unheard from a page that listens.
            if (r === "pong" || heard >= started) heard = Math.max(heard, Date.now());
            else {
              if (__SEARCH_VERBOSE__) native("debug.error", ["worker check: " + String(r) + " from " + location.pathname]).catch(() => {});
              native("background.revive", []).catch(() => {});
            }
          }).finally(() => { asking = false; });
        };
        checkWorker = page ? check : () => {};
        put(runtime, "sendMessage", (...args) => {
          const callback = typeof args[args.length - 1] === "function" ? args.pop() : null;
          // Never heard back by the one that sends it, so said for it.
          if (!inContent) tell(typeof args[0] === "string" && args.length > 1 && typeof args[1] !== "function" ? args[1] : args[0], "passes");
          checkWorker();
          const answer = send(...args).then((r) => { if (r !== undefined) heard = Date.now(); return r; });
          if (typeof args[0] !== "string" && !(args[0] && Object.keys(args[0]).some((k) => k.startsWith("__search")))) relay(args[0]);
          return replied(answer, callback, "The message port closed before a response was received.");
        });
      }
      // A message for a tab reaches only its content scripts in WebKit. In
      // Chrome it reaches the extension's own pages framed in that tab too —
      // 1Password's sign-in banner is one, told this way to offer a passkey
      // instead of a password, and without it the site's request failed. So
      // the worker hands it to those frames as well, and the first answer
      // from either wins.
      const alsoFramed = (answer, tabId, message, options) => {
        const nav = chrome.webNavigation;
        if (!nav || typeof nav.getAllFrames !== "function" || typeof tabId !== "number") return answer;
        const own = runtime.getURL("");
        const wanted = options && typeof options.frameId === "number" ? options.frameId : null;
        const framed = Promise.resolve(nav.getAllFrames({ tabId })).then((frames) => {
          const urls = (frames || []).filter((f) => f.url && f.url.startsWith(own) && f.frameId !== 0 && (wanted === null || f.frameId === wanted)).map((f) => f.url);
          if (!urls.length) return undefined;
          return Object.getPrototypeOf(runtime).sendMessage.call(runtime, { __searchToFrame: { tabId, urls, message } });
        }, () => undefined);
        return new Promise((resolve, reject) => {
          let left = 2, failure = null;
          const none = () => { if (--left === 0) failure ? reject(failure) : resolve(undefined); };
          answer.then((v) => v !== undefined ? resolve(v) : none(), (e) => { failure = e; none(); });
          framed.then((v) => v !== undefined ? resolve(v) : none(), () => none());
        });
      };
      if (chrome.tabs && typeof chrome.tabs.sendMessage === "function") {
        const send = chrome.tabs.sendMessage.bind(chrome.tabs);
        put(chrome.tabs, "sendMessage", (tabId, message, options, callback) => {
          if (typeof options === "function") { callback = options; options = undefined; }
          const p = options === undefined ? send(tabId, message) : send(tabId, message, options);
          return replied(background ? alsoFramed(p, tabId, message, options) : p, callback, "Could not establish connection. Receiving end does not exist.");
        });
      }
      if (typeof document !== "undefined" && runtime && typeof runtime.connect === "function") {
        const connect = runtime.connect.bind(runtime);
        put(runtime, "connect", (...args) => {
          checkWorker();
          const port = connect(...args);
          try { port.onMessage.addListener(() => { heard = Date.now(); }); } catch (e) {}
          return port;
        });
      }

      gather(runtime && runtime.onMessage, true);
      gather(runtime && runtime.onMessageExternal);

      // Whole namespaces WebKit lacks, answered by the browser.
      const define = (name, methods, events = [], extra = {}) => {
        if (chrome[name]) return;
        const api = Object.assign({}, extra);
        for (const m of methods) api[m] = call(name + "." + m);
        for (const e of events) api[e] = event();
        put(chrome, name, api);
        if (root.browser && root.browser !== chrome && !root.browser[name]) put(root.browser, name, api);
      };
      define("bookmarks",
        ["get", "getChildren", "getRecent", "getSubTree", "getTree", "search", "create", "move", "update", "remove", "removeTree"],
        ["onCreated", "onRemoved", "onChanged", "onMoved", "onChildrenReordered", "onImportBegan", "onImportEnded"]);
      define("history",
        ["search", "getVisits", "addUrl", "deleteUrl", "deleteRange", "deleteAll"],
        ["onVisited", "onVisitRemoved"]);
      define("downloads",
        ["download", "search", "pause", "resume", "cancel", "open", "show", "showDefaultFolder", "erase", "removeFile", "getFileIcon"],
        ["onCreated", "onChanged", "onErased", "onDeterminingFilename"]);
      // A blob URL made in an extension worker belongs to that worker. The
      // page WebKit uses to perform downloads cannot read it. Hand WebKit a
      // data URL instead, then tell the extension when Search has saved it.
      // SingleFile waits for downloads.onChanged before ending its save task.
      if (chrome.downloads?.onChanged?.listeners) {
        const downloads = chrome.downloads;
        const start = downloads.download;
        const search = downloads.search;
        put(downloads, "download", (options, ...rest) => {
          const callback = typeof rest[rest.length - 1] === "function" ? rest.pop() : null;
          const pending = (async () => {
            let request = options;
            if (typeof options?.url === "string" && options.url.startsWith("blob:")) {
              const blob = await (await fetch(options.url)).blob();
              // Held whole in the worker as it is turned into a data: address:
              // past half a gigabyte it is refused, not tried (Security).
              if (blob.size > 512 * 1024 * 1024) throw new Error("This file is too large to save from an extension's worker (over 512 MB).");
              const bytes = new Uint8Array(await blob.arrayBuffer());
              let binary = "";
              for (let i = 0; i < bytes.length; i += 8192) binary += String.fromCharCode(...bytes.subarray(i, i + 8192));
              request = { ...options, url: "data:" + (blob.type || "application/octet-stream") + ";base64," + btoa(binary) };
            }
            const id = await start.call(downloads, request, ...rest);
            const deadline = Date.now() + 120000;
            const completed = async () => {
              try {
                const items = await search.call(downloads, { id });
                if (items?.some((item) => item.id === id && item.state === "complete" && item.exists)) {
                  for (const listener of [...downloads.onChanged.listeners]) listener({ id, state: { current: "complete", previous: "in_progress" } });
                  return;
                }
              } catch (e) {}
              if (Date.now() >= deadline) {
                for (const listener of [...downloads.onChanged.listeners]) listener({ id, state: { current: "interrupted", previous: "in_progress" }, error: { current: "NETWORK_FAILED" } });
                return;
              }
              setTimeout(completed, 250);
            };
            setTimeout(completed, 0);
            return id;
          })();
          if (!callback) return pending;
          pending.then((id) => callback(id), (error) => withLastError(error, callback));
        });
      }
      define("sidePanel", ["open", "setOptions", "getOptions", "setPanelBehavior", "getPanelBehavior"]);
      define("offscreen", ["createDocument", "closeDocument", "hasDocument"], [],
        { Reason: new Proxy({}, { get: (_, key) => String(key) }) });
      define("tabGroups", ["get", "query", "update", "move"],
        ["onCreated", "onRemoved", "onUpdated", "onMoved"], { TAB_GROUP_ID_NONE: -1,
          // Read as the worker starts: Claude's lists its colours in a class.
          Color: { GREY: "grey", BLUE: "blue", RED: "red", YELLOW: "yellow", GREEN: "green",
            PINK: "pink", PURPLE: "purple", CYAN: "cyan", ORANGE: "orange" } });
      // Groups change in Search's hands, where no event reaches the
      // extension: while it listens, they are asked for every few seconds
      // and what changed is told as Chrome tells it — and at once after the
      // extension changes one itself.
      let groupsChanged = () => {};
      if (chrome.tabGroups && chrome.tabGroups.onCreated && chrome.tabGroups.onCreated.listeners) {
        const groups = chrome.tabGroups, told = ["onCreated", "onRemoved", "onUpdated"];
        let known = null, timer = null;
        // What an update changes; the order of the keys is the browser's.
        const shape = (g) => JSON.stringify([g.title, g.collapsed, g.color]);
        const tell = (name, group) => {
          for (const f of groups[name].listeners) try { f(group); } catch (e) { setTimeout(() => { throw e; }); }
        };
        groupsChanged = () => {
          if (!told.some((name) => groups[name].listeners.size)) return;
          native("tabGroups.query", [{}]).then((now) => {
            const next = new Map((now || []).map((g) => [g.id, g]));
            if (known) {
              for (const [id, g] of next) {
                if (!known.has(id)) tell("onCreated", g);
                else if (shape(known.get(id)) !== shape(g)) tell("onUpdated", g);
              }
              for (const [id, g] of known) if (!next.has(id)) tell("onRemoved", g);
            }
            known = next;
          }, () => {});
        };
        for (const name of told) {
          const add = groups[name].addListener;
          groups[name].addListener = (f) => {
            add(f);
            if (timer) return;
            groupsChanged();
            timer = setInterval(groupsChanged, 3000);
          };
        }
        put(groups, "update", (id, props, callback) => {
          if (typeof props === "function") { callback = props; props = {}; }
          const p = native("tabGroups.update", [id, props || {}]).then((g) => { groupsChanged(); return g; });
          if (typeof callback !== "function") return p;
          p.then((g) => callback(g), (e) => withLastError(e, callback));
        });
      }
      define("fontSettings",
        ["getFontList", "getFont", "setFont", "clearFont", "getDefaultFontSize", "setDefaultFontSize",
         "clearDefaultFontSize", "getDefaultFixedFontSize", "setDefaultFixedFontSize", "clearDefaultFixedFontSize",
         "getMinimumFontSize", "setMinimumFontSize", "clearMinimumFontSize"],
        ["onFontChanged", "onDefaultFontSizeChanged", "onDefaultFixedFontSizeChanged", "onMinimumFontSizeChanged"]);
      define("management", ["getSelf", "getAll", "get", "setEnabled", "uninstallSelf"],
        ["onInstalled", "onUninstalled", "onEnabled", "onDisabled"]);
      define("notifications", ["create", "update", "clear", "getAll", "getPermissionLevel"],
        ["onClicked", "onClosed", "onButtonClicked", "onPermissionLevelChanged", "onShowSettings"]);
      define("tts", ["speak", "stop", "pause", "resume", "isSpeaking", "getVoices"], ["onVoicesChanged"]);
      define("identity",
        ["launchWebAuthFlow", "getAuthToken", "getProfileUserInfo", "removeCachedAuthToken", "clearAllCachedAuthTokens"],
        ["onSignInChanged"],
        { getRedirectURL: (path = "") => "https://" + runtime.id + ".chromiumapp.org/" + String(path).replace(/^\//, "") });

      // Chrome's settings objects: get, set and clear, and an event.
      const setting = (name) => ({
        get: call("setting.get:" + name), set: call("setting.set:" + name),
        clear: call("setting.clear:" + name), onChange: event(),
      });
      const settings = (prefix, names) =>
        Object.fromEntries(names.map((n) => [n, setting(prefix + "." + n)]));
      const put2 = (name, api) => {
        if (chrome[name]) return;
        put(chrome, name, api);
        if (root.browser && root.browser !== chrome && !root.browser[name]) put(root.browser, name, api);
      };
      // Something only Chrome can do, answered the way Chrome answers when
      // it can't: a rejection, or lastError for a callback.
      const refuse = (what) => (...args) => {
        const callback = args.length && typeof args[args.length - 1] === "function" ? args.pop() : null;
        const error = new Error(what + " isn't available in Search");
        if (!callback) return Promise.reject(error);
        withLastError(error, callback);
      };

      define("search", ["query"]);
      define("idle", ["queryState", "getAutoLockDelay"], [],
        { IdleState: { ACTIVE: "active", IDLE: "idle", LOCKED: "locked" } });
      if (chrome.idle && !chrome.idle.onStateChanged) {
        // Asked every so often while anyone listens, the way Chrome
        // notices on its own.
        const changed = event(), add = changed.addListener;
        let every = 60, state = "active", timer = null;
        changed.addListener = (f) => {
          add(f);
          if (timer) return;
          timer = setInterval(() => native("idle.queryState", [every]).then((now) => {
            if (now === state) return;
            state = now;
            for (const g of changed.listeners) try { g(now); } catch (e) { setTimeout(() => { throw e; }); }
          }).catch(() => {}), 15000);
        };
        put(chrome.idle, "onStateChanged", changed);
        put(chrome.idle, "setDetectionInterval", (seconds) => { every = Math.max(15, Number(seconds) || 60); });
      }
      define("power", ["requestKeepAwake", "releaseKeepAwake", "reportActivity"]);
      define("browsingData",
        ["remove", "removeAppcache", "removeCache", "removeCacheStorage", "removeCookies", "removeDownloads",
         "removeFileSystems", "removeFormData", "removeHistory", "removeIndexedDB", "removeLocalStorage",
         "removePasswords", "removeServiceWorkers", "removeWebSQL", "settings"]);
      define("sessions", ["getRecentlyClosed", "getDevices", "restore"], ["onChanged"], { MAX_SESSION_RESULTS: 25 });
      define("topSites", ["get"]);
      define("readingList", ["query", "addEntry", "removeEntry", "updateEntry"],
        ["onEntryAdded", "onEntryRemoved", "onEntryUpdated"]);
      put2("system", {
        cpu: { getInfo: call("system.cpu.getInfo") },
        memory: { getInfo: call("system.memory.getInfo") },
        storage: { getInfo: call("system.storage.getInfo"), ejectDevice: refuse("system.storage.ejectDevice"),
                   getAvailableCapacity: refuse("system.storage.getAvailableCapacity"), onAttached: event(), onDetached: event() },
        display: { getInfo: call("system.display.getInfo"), onDisplayChanged: event() },
      });
      put2("privacy", {
        services: settings("privacy.services", ["alternateErrorPagesEnabled", "autofillAddressEnabled",
          "autofillCreditCardEnabled", "autofillEnabled", "passwordSavingEnabled", "safeBrowsingEnabled",
          "safeBrowsingExtendedReportingEnabled", "searchSuggestEnabled", "spellingServiceEnabled", "translationServiceEnabled"]),
        network: settings("privacy.network", ["networkPredictionEnabled", "webRTCIPHandlingPolicy"]),
        websites: settings("privacy.websites", ["adMeasurementEnabled", "doNotTrackEnabled", "fledgeEnabled",
          "hyperlinkAuditingEnabled", "protectedContentEnabled", "referrersEnabled", "relatedWebsiteSetsEnabled",
          "thirdPartyCookiesAllowed", "topicsEnabled"]),
        IPHandlingPolicy: { DEFAULT: "default", DEFAULT_PUBLIC_AND_PRIVATE_INTERFACES: "default_public_and_private_interfaces",
          DEFAULT_PUBLIC_INTERFACE_ONLY: "default_public_interface_only", DISABLE_NON_PROXIED_UDP: "disable_non_proxied_udp" },
      });
      const contentSetting = () => ({
        get: (details, cb) => { const v = { setting: "allow" }; if (cb) cb(v); else return Promise.resolve(v); },
        set: (details, cb) => { if (cb) cb(); else return Promise.resolve(); },
        clear: (details, cb) => { if (cb) cb(); else return Promise.resolve(); },
        getResourceIdentifiers: (cb) => { if (cb) cb([]); else return Promise.resolve([]); },
      });
      put2("contentSettings", Object.fromEntries(["automaticDownloads", "autoVerify", "camera", "clipboard", "cookies",
        "images", "javascript", "location", "microphone", "notifications", "plugins", "popups", "sound"]
        .map((n) => [n, contentSetting()])));
      put2("proxy", { settings: setting("proxy.settings"), onProxyError: event() });
      put2("omnibox", { setDefaultSuggestion: () => {}, onInputStarted: event(), onInputChanged: event(),
        onInputEntered: event(), onInputCancelled: event(), onDeleteSuggestion: event() });
      // Screen recording (see ExtensionCapture.swift). Chrome's picker is
      // Search's question, then the Mac's own; the stream id it hands back is
      // an id Search gives once, which getUserMedia in the extension's page
      // turns into the stream. Defined only for an extension that asks for
      // it, as in Chrome: Awesome Screenshot records with getDisplayMedia
      // when there is no desktopCapture.
      const declares = (name) => [...(manifest.permissions || []), ...(manifest.optional_permissions || [])].includes(name);
      const recorder = !inContent && !worker && typeof navigator !== "undefined" && !!navigator.mediaDevices
        && typeof root.MediaDevices === "function";
      // Only an extension's own page, at the top: Search checks that too.
      const captureChannel = (() => {
        try { return recorder && !embedded && window.top === window ? root.webkit.messageHandlers.searchCapture : null; } catch (e) { return null; }
      })();
      const askCapture = (op, body) => captureChannel
        ? Promise.resolve(captureChannel.postMessage(Object.assign({ op }, body)))
        : Promise.resolve({ error: "NotAllowedError", message: "Recording isn't available here" });
      const refused = (reply) => new DOMException(String(reply && reply.message || "Permission denied"), String(reply && reply.error || "NotAllowedError"));
      // What WebKit's getDisplayMedia takes: no min, no exact.
      const displayVideo = (v) => {
        if (!v || typeof v !== "object") return true;
        const out = {};
        for (const k of ["width", "height", "frameRate"]) {
          const x = v[k] ?? (v.mandatory && v.mandatory["max" + k[0].toUpperCase() + k.slice(1)]);
          if (typeof x === "number") out[k] = { max: x };
          else if (x && typeof x === "object") {
            const y = {};
            if (x.max !== undefined) y.max = x.max;
            if (x.ideal !== undefined) y.ideal = x.ideal;
            if (Object.keys(y).length) out[k] = y;
          }
        }
        return Object.keys(out).length ? out : true;
      };
      if (recorder) {
        const P = root.MediaDevices.prototype;
        const realGUM = P.getUserMedia, realGDM = P.getDisplayMedia;
        const held = new Map();
        // Called by Search alone (ExtensionCapture.record). WebKit counts an
        // app's call as a click, and only until its first await, so the
        // page's own getDisplayMedia — kept before any of the extension's
        // code ran — is called at once.
        if (typeof realGDM === "function") {
          Object.defineProperty(root, Symbol.for("search.capture"), { value: (token, video) => {
            let started;
            try { started = realGDM.call(navigator.mediaDevices, { video: video == null ? true : video, audio: false }); }
            catch (e) { return Promise.resolve({ error: e.name, message: String(e.message) }); }
            return started.then((stream) => {
              held.set(token, stream);
              // An id never taken is stopped, not left recording.
              setTimeout(() => {
                if (held.get(token) !== stream) return;
                held.delete(token);
                stream.getTracks().forEach((t) => t.stop());
              }, 60000);
              return { ok: true };
            }, (e) => ({ error: e.name, message: String(e.message) }));
          } });
        }
        // Chrome's desktop and tab constraints, which WebKit would read as a
        // plain camera request.
        const desktopId = (c) => {
          if (!c || typeof c !== "object") return null;
          const m = c.mandatory || c;
          return /^(desktop|screen|window|tab)$/.test(String(m.chromeMediaSource || "")) ? String(m.chromeMediaSourceId || "") : null;
        };
        // Chrome's older constraints (mandatory, optional, goog…) in the
        // standard form.
        const standard = (t) => {
          if (!t || typeof t !== "object" || !(t.mandatory || t.optional)) return t;
          const out = {};
          for (const [k, v] of Object.entries(t)) if (k !== "mandatory" && k !== "optional") out[k] = v;
          const set = (name, part, v) => { const x = out[name] && typeof out[name] === "object" ? out[name] : {}; x[part] = v; out[name] = x; };
          const read = (k, v, strong) => {
            const m = /^(min|max)(Width|Height|FrameRate|AspectRatio)$/.exec(k);
            if (m) return set(m[2][0].toLowerCase() + m[2].slice(1), m[1], v);
            if (k === "sourceId" || k === "deviceId") return set("deviceId", strong ? "exact" : "ideal", v);
            const goog = { googEchoCancellation: "echoCancellation", googAutoGainControl: "autoGainControl", googNoiseSuppression: "noiseSuppression" }[k];
            if (goog) out[goog] = v;
          };
          for (const [k, v] of Object.entries(t.mandatory || {})) read(k, v, true);
          for (const o of t.optional || []) for (const [k, v] of Object.entries(o || {})) read(k, v, false);
          return Object.keys(out).length ? out : true;
        };
        const take = async (id, c) => {
          let stream = held.get(id);
          if (!stream && id) {
            const reply = await askCapture("consume", { token: id, video: displayVideo(c.video) });
            if (!reply || !reply.ok) throw refused(reply);
            stream = held.get(id);
          }
          held.delete(id);
          if (!stream) throw refused();
          // The sound of a screen or a tab alone: WebKit records none.
          if (desktopId(c.video) === null) {
            stream.getTracks().forEach((t) => t.stop());
            throw new DOMException("Search can't record the sound of a screen or a tab", "NotFoundError");
          }
          const [track] = stream.getVideoTracks();
          const want = displayVideo(c.video);
          if (track && want !== true) try { await track.applyConstraints(want); } catch (e) {}
          return stream;
        };
        put(P, "getUserMedia", function (c) {
          const asked = c || {};
          const id = desktopId(asked.video) ?? desktopId(asked.audio);
          if (id !== null) return take(id, asked);
          const self = this;
          // An offscreen document is lent to the pill first (see
          // ExtensionCapture, "lend"); one not made to record is refused.
          return askCapture("lend", {}).then((reply) => {
            if (captureChannel && (!reply || !reply.ok)) throw refused(reply);
            return realGUM.call(self, { audio: standard(asked.audio), video: standard(asked.video) });
          });
        });
        if (typeof realGDM === "function") {
          put(P, "getDisplayMedia", function (c) {
            const asked = c || {};
            const surface = asked.video && typeof asked.video === "object" ? String(asked.video.displaySurface || "") : "";
            return askCapture("display", { video: displayVideo(asked.video), surface }).then((reply) => {
              const stream = reply && reply.ok && held.get(reply.token);
              if (!stream) throw refused(reply);
              held.delete(reply.token);
              return stream;
            });
          });
        }
        // Chrome's older callback form, which Loom still records with.
        const legacy = function (c, ok, fail) {
          navigator.mediaDevices.getUserMedia(c).then(ok, (e) => { if (typeof fail === "function") fail(e); });
        };
        for (const name of ["getUserMedia", "webkitGetUserMedia"]) {
          if (typeof navigator[name] !== "function") put(root.Navigator.prototype, name, legacy);
        }
      }
      if (declares("desktopCapture")) {
        let asks = 0;
        const cancelled = new Set();
        put2("desktopCapture", {
          chooseDesktopMedia: (sources, tab, cb) => {
            const f = typeof tab === "function" ? tab : cb;
            const id = ++asks;
            const done = (token) => { if (!cancelled.has(id) && typeof f === "function") f(token || "", { canRequestAudioTrack: false }); };
            // From a page: asked and recorded there at once, so a cancelled
            // picker is an empty id, as in Chrome. From the worker, which has
            // nothing to record in: an id for one of its pages to use.
            const asked = worker || background || !captureChannel
              ? native("capture.grant", [sources || []])
              : askCapture("choose", { sources: sources || [] }).then((r) => (r && r.ok ? r.token : ""));
            Promise.resolve(asked).then(done, () => done(""));
            return id;
          },
          cancelChooseDesktopMedia: (id) => { cancelled.add(id); },
          DesktopCaptureSourceType: { SCREEN: "screen", WINDOW: "window", TAB: "tab", AUDIO: "audio" },
        });
      }
      // A tab alone can't be recorded in Search: an extension that falls back
      // to the screen, as Loom does, records the window instead.
      if (declares("tabCapture")) {
        put2("tabCapture", { capture: refuse("tabCapture.capture"), getMediaStreamId: refuse("tabCapture.getMediaStreamId"),
          getCapturedTabs: (cb) => { if (cb) cb([]); else return Promise.resolve([]); }, onStatusChanged: event() });
      }
      put2("pageCapture", { saveAsMHTML: refuse("pageCapture.saveAsMHTML") });
      put2("debugger", { attach: refuse("debugger.attach"), detach: refuse("debugger.detach"),
        sendCommand: refuse("debugger.sendCommand"), getTargets: (cb) => { if (cb) cb([]); else return Promise.resolve([]); },
        onEvent: event(), onDetach: event() });
      put2("gcm", { register: refuse("gcm.register"), unregister: refuse("gcm.unregister"), send: refuse("gcm.send"),
        onMessage: event(), onMessagesDeleted: event(), onSendError: event() });
      put2("instanceID", { getID: refuse("instanceID.getID"), getToken: refuse("instanceID.getToken"),
        deleteID: refuse("instanceID.deleteID"), deleteToken: refuse("instanceID.deleteToken"),
        getCreationTime: refuse("instanceID.getCreationTime"), onTokenRefresh: event() });
      // Rules that show a button on matching pages: every button is always
      // shown in Search, so there is nothing for them to do.
      const rules = () => ({ addRules: (r, cb) => { if (cb) cb(r || []); }, removeRules: (i, cb) => { if (cb) cb(); },
        getRules: (i, cb) => { const f = typeof i === "function" ? i : cb; if (f) f([]); } });
      put2("declarativeContent", { onPageChanged: rules(),
        PageStateMatcher: function (o) { Object.assign(this, o); }, ShowAction: function () {}, ShowPageAction: function () {},
        SetIcon: function (o) { Object.assign(this, o); }, RequestContentScript: function (o) { Object.assign(this, o); } });

      // WebKit serves an extension's .wasm files without the application/wasm
      // type, so compiling one as it streams in fails. Most code falls back
      // to fetching it whole, with a warning; some has no fallback and
      // stops. The whole file is what they get from the start.
      if (root.WebAssembly && typeof WebAssembly.instantiateStreaming === "function") {
        const own = (r) => r && typeof r.url === "string" && /^(chrome|webkit)-extension:/.test(r.url);
        const instantiate = WebAssembly.instantiateStreaming.bind(WebAssembly);
        WebAssembly.instantiateStreaming = async (source, imports) => {
          const response = await source;
          return own(response) ? WebAssembly.instantiate(await response.arrayBuffer(), imports) : instantiate(response, imports);
        };
        if (typeof WebAssembly.compileStreaming === "function") {
          const compile = WebAssembly.compileStreaming.bind(WebAssembly);
          WebAssembly.compileStreaming = async (source) => {
            const response = await source;
            return own(response) ? WebAssembly.compile(await response.arrayBuffer()) : compile(response);
          };
        }
      }

      // Members Chrome has on the namespaces WebKit has too, that WebKit
      // leaves out. Plenty are read at the top of a worker — an enum, an
      // event to listen to — where one missing member is a TypeError that
      // stops the whole worker before it has done anything.
      const fill = (name, members) => {
        const target = chrome[name];
        if (!target) return;
        for (const [key, value] of Object.entries(members)) {
          let there;
          try { there = target[key]; } catch (e) {}
          if (there === undefined) put(target, key, value);
        }
      };
      const resolve = (value) => (...args) => {
        const callback = args.length && typeof args[args.length - 1] === "function" ? args.pop() : null;
        const v = typeof value === "function" ? value(...args) : value;
        if (!callback) return Promise.resolve(v);
        setTimeout(() => callback(v));
      };
      const enumOf = (...values) => Object.fromEntries(values.map((v) => [v.toUpperCase().replace(/[-.]/g, "_").replace(/([a-z])([A-Z])/g, "$1_$2").toUpperCase(), v]));
      const resourceTypes = enumOf("main_frame", "sub_frame", "stylesheet", "script", "image", "font", "object",
        "xmlhttprequest", "ping", "csp_report", "media", "websocket", "webtransport", "webbundle", "other");
      fill("runtime", {
        onUpdateAvailable: event(), onRestartRequired: event(), onSuspend: event(), onSuspendCanceled: event(),
        onBrowserUpdateAvailable: event(), onConnectNative: event(), onUserScriptConnect: event(), onUserScriptMessage: event(),
        requestUpdateCheck: (callback) => {
          if (typeof callback === "function") { setTimeout(() => callback("no_update", {})); return; }
          return Promise.resolve({ status: "no_update" });
        },
        restart: () => {}, restartAfterDelay: resolve(undefined),
        getPackageDirectoryEntry: refuse("runtime.getPackageDirectoryEntry"),
        OnInstalledReason: enumOf("install", "update", "chrome_update", "shared_module_update"),
        OnRestartRequiredReason: enumOf("app_update", "os_update", "periodic"),
        PlatformArch: { ARM: "arm", ARM64: "arm64", X86_32: "x86-32", X86_64: "x86-64", MIPS: "mips", MIPS64: "mips64" },
        PlatformNaclArch: { ARM: "arm", X86_32: "x86-32", X86_64: "x86-64", MIPS: "mips", MIPS64: "mips64" },
        PlatformOs: { MAC: "mac", WIN: "win", ANDROID: "android", CROS: "cros", LINUX: "linux", OPENBSD: "openbsd", FUCHSIA: "fuchsia" },
        RequestUpdateCheckStatus: enumOf("throttled", "no_update", "update_available"),
        ContextType: { TAB: "TAB", POPUP: "POPUP", BACKGROUND: "BACKGROUND", OFFSCREEN_DOCUMENT: "OFFSCREEN_DOCUMENT",
          SIDE_PANEL: "SIDE_PANEL", DEVELOPER_TOOLS: "DEVELOPER_TOOLS" },
      });
      // The popup Search shows is a page of its own, known to WebKit as a
      // tab with no place in the row (no index). Chrome has no current
      // tab in a popup, and lists it among the popup views; extensions lay
      // themselves out by that (Bitwarden, Proton Pass: or else they fill
      // the window as if in a tab).
      if (typeof document !== "undefined") {
        // Known at once for the manifest's popup page — pages lay themselves
        // out before any answer can come back — and settled by what WebKit
        // says of the tab.
        let popup = (() => {
          try {
            const m = runtime.getManifest(), a = m.action || m.browser_action || {};
            return !!a.default_popup && new URL(a.default_popup, location.origin + "/").pathname === location.pathname;
          } catch (e) { return false; }
        })();
        // Not in a website's frame: never the popup, and asking costs the
        // worker a message for every frame the extension opens.
        if (!embedded && chrome.tabs && typeof chrome.tabs.getCurrent === "function") {
          const getCurrent = chrome.tabs.getCurrent.bind(chrome.tabs);
          const current = () => Promise.resolve(getCurrent()).then((t) => {
            if (t && !(t.index >= 0 && t.index < 1e6)) { popup = true; return undefined; }
            if (t) popup = false;
            return t;
          });
          current().catch(() => {});
          put(chrome.tabs, "getCurrent", (callback) => {
            const p = current();
            if (typeof callback !== "function") return p;
            p.then((t) => callback(t), (e) => withLastError(e, callback));
          });
        }
        if (chrome.extension && typeof chrome.extension.getViews === "function") {
          const extension = chrome.extension;
          const getViews = extension.getViews.bind(extension);
          const views = (properties = {}) => {
            let list = [...(getViews(properties) || [])];
            if (popup && properties.type === "tab") list = list.filter((v) => v !== root);
            if (popup && (!properties.type || properties.type === "popup") && !list.includes(root)) list.push(root);
            return list;
          };
          put(extension, "getViews", views);
          // WebKit's getViews is read-only, and so is chrome.extension: both
          // ignore any redefinition without a word. The popup page's code
          // is then handed a `chrome` of its own, built on WebKit's, whose
          // extension namespace answers getViews and passes everything else
          // on (Malwarebytes lays itself out as a tab otherwise).
          if (popup && extension.getViews !== views) {
            const bound = new Map();
            const ownExtension = Object.create(extension);
            for (const key of Object.getOwnPropertyNames(extension)) {
              if (key === "getViews") continue;
              Object.defineProperty(ownExtension, key, { configurable: true, enumerable: true, get: () => {
                const v = extension[key];
                if (typeof v !== "function") return v;
                if (!bound.has(key)) bound.set(key, v.bind(extension));
                return bound.get(key);
              } });
            }
            Object.defineProperty(ownExtension, "getViews", { value: views, configurable: true, writable: true, enumerable: true });
            const ownChrome = Object.create(chrome);
            Object.defineProperty(ownChrome, "extension", { value: ownExtension, configurable: true, writable: true, enumerable: true });
            for (const key of ["chrome", "browser"]) {
              try { if (root[key] === chrome) root[key] = ownChrome; } catch (e) {}
            }
          }
        }
      }
      fill("extension", {
        getURL: (path) => runtime.getURL(path), ViewType: { TAB: "tab", POPUP: "popup" },
        sendRequest: (...args) => runtime.sendMessage(...args), onRequest: event(), onRequestExternal: event(),
        getExtensionTabs: () => [], setUpdateUrlData: () => {},
      });
      fill("tabs", {
        TabStatus: enumOf("unloaded", "loading", "complete"), MutedInfoReason: enumOf("user", "capture", "extension"),
        WindowType: enumOf("normal", "popup", "panel", "app", "devtools"),
        ZoomSettingsMode: enumOf("automatic", "manual", "disabled"),
        ZoomSettingsScope: { PER_ORIGIN: "per-origin", PER_TAB: "per-tab" },
        MAX_CAPTURE_VISIBLE_TAB_CALLS_PER_SECOND: 2, TAB_INDEX_NONE: -1,
        getZoomSettings: resolve({ mode: "automatic", scope: "per-origin", defaultZoomFactor: 1 }),
        setZoomSettings: resolve(undefined), onZoomChange: event(),
        onSelectionChanged: event(), onActiveChanged: event(), onHighlightChanged: event(),
        getSelected: (windowId, callback) => {
          const f = typeof windowId === "function" ? windowId : callback;
          chrome.tabs.query({ active: true, currentWindow: true }).then((t) => f && f(t[0]));
        },
        getAllInWindow: (windowId, callback) => {
          const f = typeof windowId === "function" ? windowId : callback;
          chrome.tabs.query({ currentWindow: true }).then((t) => f && f(t));
        },
      });
      if (chrome.tabs) {
        // Moving, sleeping and bringing forward tabs, by where they are in
        // the row — the one thing both sides agree on.
        const settle = () => new Promise((r) => setTimeout(r, 60));
        const byIndex = (api) => async (ids, extra) => {
          const out = [];
          for (const id of Array.isArray(ids) ? ids : [ids]) {
            const tab = await chrome.tabs.get(id);
            await native(api, [placeOf(tab, await frames()), extra]);
            await settle();
            out.push(await chrome.tabs.get(id).catch(() => tab));
          }
          return Array.isArray(ids) ? out : out[0];
        };
        const withCallback = (f) => (...args) => {
          const callback = args.length && typeof args[args.length - 1] === "function" ? args.pop() : null;
          const p = f(...args);
          if (!callback) return p;
          p.then((v) => callback(v), (e) => withLastError(e, callback));
        };
        const indexes = async (ids) => {
          const known = await frames();
          return Promise.all((Array.isArray(ids) ? ids : [ids]).map((id) => chrome.tabs.get(id).then((t) => placeOf(t, known))));
        };
        fill("tabs", {
          // Into a group, a new one or one named by its number, or out of
          // one. A group left with no tab is gone, as in Chrome.
          group: withCallback(async (options = {}) => {
            const id = await native("tabs.group", [await indexes(options.tabIds), options.groupId ?? -1]);
            groupsChanged();
            return id;
          }),
          ungroup: withCallback(async (ids) => {
            await native("tabs.ungroup", [await indexes(ids)]);
            groupsChanged();
          }),
          move: withCallback(async (ids, props = {}) => {
            const list = Array.isArray(ids) ? ids : [ids];
            const out = [];
            let at = props.index ?? -1;
            for (const id of list) {
              out.push(await byIndex("tabs.move")(id, at));
              if (at !== -1) at++;
            }
            return Array.isArray(ids) ? out : out[0];
          }),
          discard: withCallback((id) => id === undefined
            ? chrome.tabs.query({ active: false, currentWindow: true }).then((t) => t[0] && byIndex("tabs.discard")(t[0].id))
            : byIndex("tabs.discard")(id)),
          highlight: withCallback(async (info = {}) => {
            const first = Array.isArray(info.tabs) ? info.tabs[0] : info.tabs;
            const window = info.windowId ?? (await chrome.windows.getCurrent()).id;
            await native("tabs.activate", [{ i: first, w: (await frames()).get(window) }]);
            await settle();
            return chrome.windows ? chrome.windows.getCurrent({ populate: true }) : undefined;
          }),
        });
      }
      fill("windows", {
        // Chrome's, and not WebKit's: an extension subscribing to it at
        // start — Session Buddy, inside a try — threw there and never
        // reached the rest, its button's listener included. Never fired:
        // a window's bounds are read when they are asked for.
        onBoundsChanged: event(),
        CreateType: enumOf("normal", "popup", "panel"), WindowType: enumOf("normal", "popup", "panel", "app", "devtools"),
        WindowState: { NORMAL: "normal", MINIMIZED: "minimized", MAXIMIZED: "maximized", FULLSCREEN: "fullscreen", LOCKED_FULLSCREEN: "locked-fullscreen" },
      });
      fill("storage", {
        managed: { get: resolve({}), getBytesInUse: resolve(0), onChanged: event() },
        AccessLevel: { TRUSTED_CONTEXTS: "TRUSTED_CONTEXTS", TRUSTED_AND_UNTRUSTED_CONTEXTS: "TRUSTED_AND_UNTRUSTED_CONTEXTS" },
      });
      // A page at the address of the extension's popup hears no events
      // from WebKit: WebKit takes it for its own popup, and Search's popup
      // is a view of Search's. The one that matters, storage.onChanged —
      // Bitwarden learns a self-hosted server's address from it — is passed
      // on by the background, which does hear it, to such pages: the popup,
      // and the same page opened in a tab ("pop out"). They keep their
      // address, which extensions check (Dark Reader only answers its popup
      // at its own).
      {
        const manifest = (() => { try { return runtime.getManifest() || {}; } catch (e) { return {}; } })();
        const action = manifest.action || manifest.browser_action || {};
        let popupPath = null;
        try { if (typeof action.default_popup === "string" && action.default_popup) popupPath = new URL(action.default_popup, location.origin + "/").pathname; } catch (e) {}
        const relay = popupPath && !embedded && typeof BroadcastChannel === "function" ? new BroadcastChannel("search-storage") : null;
        if (relay && background && chrome.storage && chrome.storage.onChanged) {
          kept.add(chrome.storage.onChanged);
          chrome.storage.onChanged.addListener((changes, area) => {
            try { relay.postMessage({ changes, area }); } catch (e) {}
          });
        } else if (relay && !background && typeof location !== "undefined" && location.pathname === popupPath && chrome.storage) {
          const all = new Set(), byArea = {};
          const mend = (ev, set) => {
            if (!ev || typeof ev !== "object") return;
            put(ev, "addListener", (f) => { if (typeof f === "function") set.add(f); });
            put(ev, "removeListener", (f) => { set.delete(f); });
            put(ev, "hasListener", (f) => set.has(f));
            put(ev, "hasListeners", () => set.size > 0);
          };
          mend(chrome.storage.onChanged, all);
          for (const area of ["local", "sync", "session", "managed"]) {
            const store = chrome.storage[area];
            if (store && store.onChanged) mend(store.onChanged, byArea[area] = new Set());
          }
          relay.onmessage = ({ data }) => {
            if (!data || !data.changes) return;
            for (const f of [...all]) { try { f(data.changes, data.area); } catch (e) { console.error(e); } }
            for (const f of [...(byArea[data.area] || [])]) { try { f(data.changes); } catch (e) { console.error(e); } }
          };
        }
      }
      // Items built with Object.create(null) — Chrome stores them, WebKit
      // throws that an object is expected.
      for (const area of ["local", "sync", "session"]) {
        const store = chrome.storage && chrome.storage[area];
        if (!store || typeof store.set !== "function") continue;
        const set = store.set.bind(store);
        put(store, "set", (items, ...rest) => set(items && typeof items === "object" && Object.getPrototypeOf(items) !== Object.prototype ? Object.assign({}, items) : items, ...rest));
      }
      fill("scripting", {
        ExecutionWorld: { ISOLATED: "ISOLATED", MAIN: "MAIN", USER_SCRIPT: "USER_SCRIPT" },
        StyleOrigin: { AUTHOR: "AUTHOR", USER: "USER" },
      });
      // The popup an extension sets for its button, told to the browser too:
      // Search opens a popup itself (see Extensions.press), and has to know
      // which page it is now.
      for (const name of ["action", "browserAction"]) {
        const a = chrome[name];
        if (!a || typeof a.setPopup !== "function") continue;
        const setPopup = a.setPopup.bind(a);
        put(a, "setPopup", (details = {}, callback) => {
          const tell = (index) => native("action.popup", [details.popup || "", index]).catch(() => {});
          if (typeof details.tabId === "number" && chrome.tabs) chrome.tabs.get(details.tabId).then((t) => tell(t.index), () => {});
          else tell(-1);
          return setPopup(details, callback);
        });
      }
      fill("action", {
        getUserSettings: resolve({ isOnToolbar: true }), onUserSettingsChanged: event(),
        setBadgeTextColor: resolve(undefined), getBadgeTextColor: resolve([255, 255, 255, 255]),
      });
      fill("webNavigation", {
        onCreatedNavigationTarget: event(), onHistoryStateUpdated: event(), onReferenceFragmentUpdated: event(), onTabReplaced: event(),
        TransitionType: enumOf("link", "typed", "auto_bookmark", "auto_subframe", "manual_subframe", "generated",
          "start_page", "form_submit", "reload", "keyword", "keyword_generated"),
        TransitionQualifier: enumOf("client_redirect", "server_redirect", "forward_back", "from_address_bar"),
      });
      fill("webRequest", {
        OnBeforeRequestOptions: { BLOCKING: "blocking", REQUEST_BODY: "requestBody", EXTRA_HEADERS: "extraHeaders" },
        OnBeforeSendHeadersOptions: { REQUEST_HEADERS: "requestHeaders", BLOCKING: "blocking", EXTRA_HEADERS: "extraHeaders" },
        OnSendHeadersOptions: { REQUEST_HEADERS: "requestHeaders", EXTRA_HEADERS: "extraHeaders" },
        OnHeadersReceivedOptions: { BLOCKING: "blocking", RESPONSE_HEADERS: "responseHeaders", EXTRA_HEADERS: "extraHeaders" },
        OnAuthRequiredOptions: { RESPONSE_HEADERS: "responseHeaders", BLOCKING: "blocking", ASYNC_BLOCKING: "asyncBlocking", EXTRA_HEADERS: "extraHeaders" },
        OnResponseStartedOptions: { RESPONSE_HEADERS: "responseHeaders", EXTRA_HEADERS: "extraHeaders" },
        OnBeforeRedirectOptions: { RESPONSE_HEADERS: "responseHeaders", EXTRA_HEADERS: "extraHeaders" },
        OnCompletedOptions: { RESPONSE_HEADERS: "responseHeaders", EXTRA_HEADERS: "extraHeaders" },
        OnErrorOccurredOptions: { EXTRA_HEADERS: "extraHeaders" },
        ResourceType: resourceTypes, MAX_HANDLER_BEHAVIOR_CHANGED_CALLS_PER_10_MINUTES: 20,
        handlerBehaviorChanged: resolve(undefined), onActionIgnored: event(),
      });
      fill("declarativeNetRequest", {
        GUARANTEED_MINIMUM_STATIC_RULES: 30000, MAX_NUMBER_OF_REGEX_RULES: 1000, MAX_NUMBER_OF_SESSION_RULES: 5000,
        MAX_NUMBER_OF_UNSAFE_DYNAMIC_RULES: 5000, MAX_NUMBER_OF_UNSAFE_SESSION_RULES: 5000,
        MAX_GETMATCHEDRULES_CALLS_PER_INTERVAL: 20, GETMATCHEDRULES_QUOTA_INTERVAL: 10,
        DYNAMIC_RULESET_ID: "_dynamic", SESSION_RULESET_ID: "_session",
        getAvailableStaticRuleCount: resolve(30000), getDisabledRuleIds: resolve([]), updateStaticRules: resolve(undefined),
        testMatchOutcome: refuse("declarativeNetRequest.testMatchOutcome"), onRuleMatchedDebug: event(),
        RuleActionType: { BLOCK: "block", REDIRECT: "redirect", ALLOW: "allow", UPGRADE_SCHEME: "upgradeScheme",
          MODIFY_HEADERS: "modifyHeaders", ALLOW_ALL_REQUESTS: "allowAllRequests" },
        ResourceType: resourceTypes, HeaderOperation: enumOf("append", "set", "remove"),
        DomainType: { FIRST_PARTY: "firstParty", THIRD_PARTY: "thirdParty" },
        RequestMethod: enumOf("connect", "delete", "get", "head", "options", "patch", "post", "put", "other"),
        UnsupportedRegexReason: { SYNTAX_ERROR: "syntaxError", MEMORY_LIMIT_EXCEEDED: "memoryLimitExceeded" },
      });
      const contextTypes = enumOf("all", "page", "frame", "selection", "link", "editable", "image", "video", "audio",
        "launcher", "browser_action", "page_action", "action");
      fill("contextMenus", { ContextType: contextTypes, ItemType: enumOf("normal", "checkbox", "radio", "separator") });
      fill("menus", { ContextType: contextTypes, ItemType: enumOf("normal", "checkbox", "radio", "separator") });

      // Rules WebKit can't carry out — a header it doesn't know how to set,
      // say — are refused one by one, where Chrome would take them all. The
      // rest still go in: one rule Search can't honour shouldn't cost an
      // extension every other rule, or its startup.
      const dnr = chrome.declarativeNetRequest;
      // Before WebKit sees them, rules are put the way it takes them: a
      // redirect to one of the extension's own files by path rather than by
      // address, and without the resource types it has no name for.
      const unknownTypes = new Set(["webtransport", "webbundle", "object"]);
      const base = (() => { try { return runtime.getURL(""); } catch (e) { return ""; } })();
      const mendRule = (rule) => {
        if (!rule || typeof rule !== "object") return rule;
        const r = { ...rule, action: rule.action && { ...rule.action }, condition: rule.condition && { ...rule.condition } };
        const redirect = r.action && r.action.redirect;
        if (redirect && typeof redirect.url === "string" && base && redirect.url.startsWith(base)) {
          r.action.redirect = { extensionPath: "/" + redirect.url.slice(base.length) };
        }
        const c = r.condition;
        if (c && Array.isArray(c.resourceTypes)) {
          c.resourceTypes = c.resourceTypes.filter((t) => !unknownTypes.has(t));
          if (!c.resourceTypes.length) return null;
        }
        if (c && Array.isArray(c.excludedResourceTypes)) c.excludedResourceTypes = c.excludedResourceTypes.filter((t) => !unknownTypes.has(t));
        return r;
      };
      if (dnr && typeof dnr.isRegexSupported === "function") {
        const original = dnr.isRegexSupported.bind(dnr);
        put(dnr, "isRegexSupported", (options, callback) => {
          const p = Promise.resolve(original(options)).then((r) => r || { isSupported: false, reason: "syntaxError" },
            () => ({ isSupported: false, reason: "syntaxError" }));
          if (typeof callback !== "function") return p;
          p.then((r) => callback(r));
        });
      }
      // WebKit's rules take a narrow kind of regular expression: no `|` and
      // no `(?:`. Tampermonkey's rule for .user.js links has both, so a
      // script couldn't be installed from a link (idea 197). A pattern
      // that can be written without them, matching exactly the same
      // addresses, becomes that many rules; one that can't (a choice inside
      // a repeated group, a look-around) is left out as before. Nothing is
      // widened: every rule matches what its pattern matched.
      const expandRegex = (source, limit = 24) => {
        let i = 0;
        // An atom repeated a counted number of times, a{2,4}, written out
        // as a a a? a?: the same strings, without the braces WebKit refuses.
        const counted = (atom) => {
          const m = /^\{(\d+)(,(\d*))?\}/.exec(source.slice(i));
          if (!m) return atom;
          const least = Number(m[1]), most = m[2] === undefined ? least : m[3] === "" ? null : Number(m[3]);
          if (most === null || most < least || most > 12) return null;
          i += m[0].length;
          return atom.repeat(least) + (atom + "?").repeat(most - least);
        };
        const alternatives = () => {
          let options = [""];
          const all = [];
          while (i < source.length) {
            const c = source[i];
            if (c === "\\") {
              const kind = source[i + 1];
              const size = kind === "x" ? 4 : kind === "c" ? 3
                : kind === "u" ? (source[i + 2] === "{" ? source.indexOf("}", i) + 1 - i : 6) : 2;
              if (size < 2 || /[1-9]/.test(kind || "")) return null;
              const t = source.slice(i, i + size);
              i += size;
              const piece = counted(t);
              if (piece === null) return null;
              options = options.map((o) => o + piece);
              continue;
            }
            if (c === "[") {
              let j = i + 1;
              if (source[j] === "^") j++;
              if (source[j] === "]") j++;
              while (j < source.length && source[j] !== "]") { if (source[j] === "\\") j++; j++; }
              const t = source.slice(i, j + 1);
              i = j + 1;
              const piece = counted(t);
              if (piece === null) return null;
              options = options.map((o) => o + piece);
              continue;
            }
            if (c === "|") { all.push(...options); options = [""]; i++; continue; }
            if (c === ")") break;
            if (c === "(") {
              i++;
              if (source.startsWith("?:", i)) i += 2;
              else if (source[i] === "?") return null;
              const inner = alternatives();
              if (inner === null || source[i] !== ")") return null;
              i++;
              if (/^[*+?{]/.test(source[i] || "")) {
                if (inner.length > 1 || source[i] === "{") return null;
                options = options.map((o) => o + "(" + inner[0] + ")");
                continue;
              }
              options = options.flatMap((o) => inner.map((x) => o + x));
              if (options.length > limit) return null;
              continue;
            }
            i++;
            const piece = /[.\w/:-]/.test(c) ? counted(c) : c;
            if (piece === null) return null;
            options = options.map((o) => o + piece);
          }
          all.push(...options);
          return all.length > limit ? null : all;
        };
        const out = alternatives();
        return out === null || i !== source.length ? null : out;
      };
      // The rules made from one are kept out of sight: the extension sees its
      // own, and taking it away takes them too. Their ids come from the
      // rule's own, so nothing has to be remembered — a relaunch, a worker
      // started afresh or a second page all know which they are (Security).
      const madeBase = 1000000000, madeStride = 32;
      const madeIds = (id) => Number.isInteger(id) && id >= 1 && id < 30000000
        ? Array.from({ length: madeStride - 1 }, (_, k) => madeBase + id * madeStride + k + 1) : [];
      const madeFrom = (id, present) => {
        if (!Number.isInteger(id) || id <= madeBase) return null;
        const offset = id - madeBase, k = offset % madeStride, from = (offset - k) / madeStride;
        return k && present.has(from) ? from : null;
      };
      const spread = (name, rule, taken) => {
        const c = rule && rule.condition;
        const pattern = c && c.regexFilter;
        if (typeof pattern !== "string" || !/\||\(\?:|\{\d/.test(pattern)) return [rule];
        const substitution = rule.action && rule.action.redirect && rule.action.redirect.regexSubstitution;
        if (typeof substitution === "string" && /\\[1-9]/.test(substitution)) return [rule];
        const patterns = expandRegex(pattern);
        if (!patterns || !patterns.length) return [rule];
        const ids = madeIds(rule.id);
        // An id past what the scheme holds, or one already an extension's
        // own: this rule isn't written out, and is left out as before.
        if (patterns.length > 1 && (ids.length < patterns.length - 1 || ids.slice(0, patterns.length - 1).some((id) => taken.has(id)))) return [rule];
        return patterns.map((regexFilter, k) => ({ ...rule, id: k === 0 ? rule.id : ids[k - 1], condition: { ...c, regexFilter } }));
      };
      const rawGet = {};
      for (const [get, name] of [["getSessionRules", "updateSessionRules"], ["getDynamicRules", "updateDynamicRules"]]) {
        if (!dnr || typeof dnr[get] !== "function") continue;
        const original = dnr[get].bind(dnr);
        rawGet[name] = () => Promise.resolve(original()).then((r) => r || []);
        put(dnr, get, (filter, callback) => {
          if (typeof filter === "function") { callback = filter; filter = undefined; }
          const p = rawGet[name]().then((all) => {
            const present = new Set(all.map((r) => r.id));
            const own = all.filter((r) => madeFrom(r.id, present) === null);
            const ids = filter && Array.isArray(filter.ruleIds) ? new Set(filter.ruleIds) : null;
            return ids ? own.filter((r) => ids.has(r.id)) : own;
          });
          if (typeof callback !== "function") return p;
          p.then((r) => callback(r), (e) => withLastError(e, callback));
        });
      }
      if (dnr) for (const name of ["updateSessionRules", "updateDynamicRules"]) {
        if (typeof dnr[name] !== "function") continue;
        const original = dnr[name].bind(dnr);
        put(dnr, name, (options = {}, callback) => {
          const ready = (rawGet[name] ? rawGet[name]() : Promise.resolve([])).catch(() => []).then((all) => {
            const present = new Set(all.map((r) => r.id));
            if (options && Array.isArray(options.removeRuleIds)) {
              const gone = new Set(options.removeRuleIds);
              const extra = all.map((r) => r.id).filter((id) => gone.has(madeFrom(id, present)));
              if (extra.length) options = { ...options, removeRuleIds: options.removeRuleIds.concat(extra) };
            }
            if (options && Array.isArray(options.addRules)) {
              const leaving = new Set(options.removeRuleIds || []);
              const taken = new Set([...present].filter((id) => !leaving.has(id) && !leaving.has(madeFrom(id, present))));
              options.addRules.forEach((r) => r && taken.add(r.id));
              options = { ...options, addRules: options.addRules.map(mendRule).filter(Boolean).flatMap((r) => spread(name, r, taken)) };
            }
          });
          const attempt = async (opts, left) => {
            try { return await original(opts); }
            catch (e) {
              // WebKit builds one content blocker of an extension's rules,
              // and it can't hold rules for some sites beside rules for all
              // but some: Tampermonkey's rule for any .user.js link, all but
              // its own sites, kept every other rule from loading. The
              // all-but rules are left out, as a refused rule is.
              if (/Unable to load declarativeNetRequest rules/.test(String(e && e.message)) && Array.isArray(opts.addRules) && left > 0) {
                const excluding = (r) => { const c = r && r.condition; return !!(c && (c.excludedRequestDomains || c.excludedInitiatorDomains || c.excludedDomains)); };
                const narrowing = (r) => { const c = r && r.condition; return !!(c && (c.requestDomains || c.initiatorDomains || c.domains)); };
                if (opts.addRules.some(excluding) && opts.addRules.some(narrowing)) {
                  for (const rule of opts.addRules.filter(excluding)) {
                    const kind = rule && rule.action && rule.action.type || "?";
                    try { native("debug.error", ["declarativeNetRequest: " + kind + " rule " + (rule && rule.id) + " left out — it excludes sites beside rules for given sites, which WebKit can't load together"]).catch(() => {}); } catch (x) {}
                  }
                  return attempt({ ...opts, addRules: opts.addRules.filter((r) => !excluding(r)) }, left - 1);
                }
              }
              const at = /rule at index (\d+)/.exec(String(e && e.message));
              if (!at || !Array.isArray(opts.addRules) || left <= 0) throw e;
              const index = Number(at[1]);
              const rule = opts.addRules[index];
              try { native("debug.error", ["declarativeNetRequest: rule " + (rule && rule.id) + " left out — " + e.message]).catch(() => {}); } catch (x) {}
              return attempt({ ...opts, addRules: opts.addRules.filter((_, i) => i !== index) }, left - 1);
            }
          };
          const p = ready.then(() => attempt(options, 100));
          // In a test run, an update that still fails is said, not only
          // handed back to an extension that may drop it.
          if (__SEARCH_VERBOSE__) p.catch((e) => { try { native("debug.error", ["declarativeNetRequest: " + name + " failed — " + (e && e.message)]).catch(() => {}); } catch (x) {} });
          if (typeof callback !== "function") return p;
          p.then(() => callback(), (e) => withLastError(e, callback));
        });
      }

      // Context menu entries for places Search has no menu for — the old
      // toolbar button contexts are the button's menu now, and there is no
      // app launcher at all.
      for (const name of ["contextMenus", "menus"]) {
        const menus = chrome[name];
        if (!menus || typeof menus.create !== "function") continue;
        const mend = (props) => {
          if (!props || !Array.isArray(props.contexts)) return props;
          const contexts = [...new Set(props.contexts.map((c) => c === "browser_action" || c === "page_action" ? "action" : c).filter((c) => c !== "launcher"))];
          return { ...props, contexts: contexts.length ? contexts : ["page"] };
        };
        const create = menus.create.bind(menus), update = menus.update.bind(menus);
        put(menus, "create", (props, callback) => create(mend(props), callback));
        put(menus, "update", (id, props, callback) => update(id, mend(props), callback));
      }

      // webRequest listeners with options WebKit doesn't take — blocking
      // needs a policy-installed extension in Chrome's MV3 too; extra headers
      // WebKit reports anyway — are added with the options it does take.
      if (chrome.webRequest) for (const key of Object.keys(chrome.webRequest)) {
        const target = chrome.webRequest[key];
        if (!/^on[A-Z]/.test(key) || !target || typeof target.addListener !== "function") continue;
        const add = target.addListener.bind(target);
        put(target, "addListener", (listener, filter, spec) => {
          // WebKit can't read ws:// and wss:// patterns, and refuses the
          // whole listener over one; Chrome watches sockets too. The
          // listener is kept for everything else.
          if (filter && Array.isArray(filter.urls)) {
            const urls = filter.urls.filter((u) => !/^wss?:/i.test(u));
            if (!urls.length) return;
            filter = { ...filter, urls };
          }
          // Added after a worker's startup, WebKit refuses it; Chrome takes
          // it. It isn't heard, but neither does it stop the code that added
          // it — a listener for every request can't join the late list
          // (it would wake the worker for all of them).
          const late = (e) => { if (!/startup/i.test(String(e && e.message))) throw e; };
          try {
            if (!Array.isArray(spec)) return add(listener, filter);
            const kept = spec.filter((s) => s === "requestHeaders" || s === "responseHeaders" || s === "requestBody");
            try { return add(listener, filter, kept); } catch (e) { if (/startup/i.test(String(e && e.message))) throw e; return add(listener, filter); }
          } catch (e) { late(e); }
        });
      }

      // Tabs as Chrome describes them. Every tab has a groupId, which code
      // tests before anything else: -1 when in no group, and the group's
      // number, asked of the browser, for an extension that asked for
      // "tabGroups" — only those have any use for it, so the others are
      // spared the question. With the "tabs" permission an extension sees
      // every tab's address and title, where WebKit shows them only for
      // sites it has host access to.
      if (chrome.tabs) {
        const permissions = (() => { try { return runtime.getManifest().permissions || []; } catch (e) { return []; } })();
        const seesTabs = permissions.includes("tabs"), seesGroups = permissions.includes("tabGroups");
        const isTab = (t) => t && typeof t === "object" && typeof t.id === "number";
        // Mends in place; a promise only when the browser has to be asked.
        const mend = (list) => {
          const tabs = list.filter(isTab);
          for (const t of tabs) if (t.groupId === undefined) try { t.groupId = -1; } catch (e) {}
          const blind = seesTabs ? tabs.filter((t) => !t.url && t.index >= 0) : [];
          const placed = seesGroups ? tabs.filter((t) => t.index >= 0) : [];
          if (!blind.length && !placed.length) return null;
          return frames().then((known) => Promise.all([
            blind.length && native("tabs.describe", [blind.map((t) => placeOf(t, known))]).then((info) => {
              blind.forEach((t, i) => {
                const d = info && info[i];
                if (!d) return;
                try {
                  if (d.url) t.url = d.url;
                  if (d.title && !t.title) t.title = d.title;
                  if (d.favIconUrl && !t.favIconUrl) t.favIconUrl = d.favIconUrl;
                } catch (e) {}
              });
            }, () => {}),
            placed.length && native("tabs.groups", [placed.map((t) => placeOf(t, known))]).then((ids) => {
              placed.forEach((t, i) => {
                if (ids && typeof ids[i] === "number") try { t.groupId = ids[i]; } catch (e) {}
              });
            }, () => {}),
          ]));
        };
        const tabsIn = (value) => Array.isArray(value) ? value.flatMap(tabsIn)
          : isTab(value) ? [value] : value && Array.isArray(value.tabs) ? value.tabs : [];
        const mendResult = (target, name) => {
          if (!target || typeof target[name] !== "function") return;
          const original = target[name].bind(target);
          put(target, name, (...args) => {
            const callback = typeof args[args.length - 1] === "function" ? args.pop() : null;
            const p = Promise.resolve(original(...args)).then(async (r) => { await mend(tabsIn(r)); return r; });
            if (!callback) return p;
            p.then((r) => callback(r), (e) => withLastError(e, callback));
          });
        };
        for (const name of ["query", "get", "getCurrent", "create", "update", "duplicate", "move", "reload"]) mendResult(chrome.tabs, name);
        // A query for a group's tabs: WebKit knows no groupId, so it is asked
        // without one and the tabs are sorted out after.
        if (seesGroups && typeof chrome.tabs.query === "function") {
          const query = chrome.tabs.query.bind(chrome.tabs);
          put(chrome.tabs, "query", (info, callback) => {
            if (typeof info === "function") { callback = info; info = {}; }
            const wanted = info && info.groupId;
            let p;
            if (wanted === undefined) p = query(info || {});
            else {
              const rest = Object.assign({}, info);
              delete rest.groupId;
              p = Promise.resolve(query(rest)).then((tabs) => tabs.filter((t) => t.groupId === wanted));
            }
            if (typeof callback !== "function") return p;
            p.then((r) => callback(r), (e) => withLastError(e, callback));
          });
        }
        for (const name of ["get", "getAll", "getCurrent", "getLastFocused", "create"]) mendResult(chrome.windows, name);
        // WebKit's windows.getCurrent ignores which extension page called
        // it and returns the frontmost window. In a top-level extension page
        // opened in a tab — a popup window's page among them (Bitwarden's
        // passkey window) — find that page's current tab each time and ask
        // for its window instead. When there is no real tab, as in a toolbar
        // action popup or an offscreen page, keep WebKit's answer; workers
        // and content scripts never enter here. From #408, by lulkebit.
        if (!inContent && !embedded && typeof document !== "undefined"
            && chrome.windows && typeof chrome.windows.getCurrent === "function"
            && typeof chrome.windows.get === "function" && typeof chrome.tabs.getCurrent === "function") {
          const getCurrentWindow = chrome.windows.getCurrent.bind(chrome.windows);
          const getWindow = chrome.windows.get.bind(chrome.windows);
          const getCurrentTab = chrome.tabs.getCurrent.bind(chrome.tabs);
          put(chrome.windows, "getCurrent", (...args) => {
            const callback = typeof args[args.length - 1] === "function" ? args.pop() : null;
            const getInfo = typeof args[0] === "function" ? undefined : args[0];
            const options = getInfo === undefined ? [] : [getInfo];
            const p = Promise.resolve().then(() => getCurrentTab()).then((tab) => {
              const windowId = tab && tab.windowId;
              const hasPlace = tab && Number.isInteger(tab.index) && tab.index >= 0 && tab.index < 1e6
                && Number.isInteger(windowId) && windowId >= 0;
              return hasPlace ? getWindow(windowId, ...options) : getCurrentWindow(...options);
            }, () => getCurrentWindow(...options));
            if (!callback) return p;
            p.then((window) => callback(window), (error) => withLastError(error, callback));
          });
        }
        // Listeners given a tab: the tab is mended before they see it.
        const mendArgs = (target, positions, told, skip) => {
          if (!target || typeof target.addListener !== "function") return;
          const add = target.addListener.bind(target), remove = target.removeListener.bind(target);
          const wrapped = new Map();
          put(target, "addListener", (listener, ...rest) => {
            const state = new Map();
            const w = function (...args) {
              if (skip && skip(args)) return;
              const pending = mend(positions.map((i) => args[i]));
              if (!pending) { if (told) told(args, state); return listener.apply(this, args); }
              pending.then(() => { if (told) told(args, state); listener.apply(this, args); });
            };
            wrapped.set(listener, w);
            return add(w, ...rest);
          });
          put(target, "removeListener", (listener) => { const w = wrapped.get(listener); wrapped.delete(listener); return remove(w || listener); });
          put(target, "hasListener", (listener) => wrapped.has(listener));
        };
        // An offscreen document is a tab to WebKit, so that its frames'
        // content scripts can name it, but in no window: the extension
        // never hears of it coming or going, as in Chrome (#192).
        mendArgs(chrome.tabs.onCreated, [0], null, (args) => isTab(args[0]) && args[0].windowId === -1);
        mendArgs(chrome.tabs.onRemoved, [], null, (args) => !!args[1] && args[1].windowId === -1);
        // What changed, in onUpdated's changeInfo. Without host access
        // WebKit blanks url and title there ("") and leaves favIconUrl out,
        // and a tab manager, or an extension watching its sign-in tab, reads
        // them there. A blanked one is filled from the tab; one left out is
        // added when it differs from what this listener last saw of the tab.
        const told = seesTabs ? (args, state) => {
          const info = args[1], tab = args[2];
          if (!info || typeof info !== "object" || !isTab(tab) || !tab.url) return;
          const before = state.get(tab.id);
          const fill = (key, changed) => {
            const value = tab[key];
            if (value && (info[key] === "" || (info[key] === undefined && changed))) try { info[key] = value; } catch (e) {}
          };
          fill("url", before ? before.url !== tab.url : info.status === "loading");
          fill("title", !!before && before.title !== tab.title);
          fill("favIconUrl", !!before && before.favIconUrl !== tab.favIconUrl);
          state.set(tab.id, { url: tab.url, title: tab.title, favIconUrl: tab.favIconUrl });
        } : null;
        mendArgs(chrome.tabs.onUpdated, [2], told);
        mendArgs(chrome.action && chrome.action.onClicked, [0]);
        mendArgs(chrome.contextMenus && chrome.contextMenus.onClicked, [1]);
        mendArgs(chrome.menus && chrome.menus.onClicked, [1]);
        mendArgs(chrome.commands && chrome.commands.onCommand, [1]);
      }

      // Permissions. WebKit knows its own and throws on any other name,
      // where Chrome answers false. The ones Search answers itself are
      // Search's to grant: those a manifest names are granted, optional
      // ones are asked for.
      if (chrome.permissions) {
        const webkit = new Set(["activeTab", "alarms", "clipboardWrite", "contextMenus", "cookies", "declarativeNetRequest",
          "declarativeNetRequestFeedback", "declarativeNetRequestWithHostAccess", "menus", "nativeMessaging", "scripting",
          "storage", "tabs", "unlimitedStorage", "webNavigation", "webRequest"]);
        const ours = new Set(["bookmarks", "history", "downloads", "downloads.open", "downloads.shelf", "downloads.ui",
          "tabGroups", "sidePanel", "offscreen", "notifications", "tts", "fontSettings", "management", "identity",
          "identity.email", "idle", "power", "privacy", "browsingData", "sessions", "topSites", "search", "system.cpu",
          "system.memory", "system.storage", "system.display", "readingList", "contentSettings", "proxy", "favicon",
          "clipboardRead", "geolocation", "userScripts"]);
        const manifest = (() => { try { return runtime.getManifest() || {}; } catch (e) { return {}; } })();
        const declared = new Set(manifest.permissions || []);
        const split = (list = []) => ({
          theirs: list.filter((p) => webkit.has(p)), mine: list.filter((p) => ours.has(p)),
          unknown: list.filter((p) => !webkit.has(p) && !ours.has(p)),
        });
        const p = chrome.permissions;
        const contains = p.contains.bind(p), request = p.request.bind(p), getAll = p.getAll.bind(p), remove = p.remove.bind(p);
        const granted = () => native("permissions.granted", []).then((list) => new Set([...declared, ...(list || [])]));
        const withCb = (f) => (arg, callback) => {
          const pr = f(arg || {});
          if (typeof callback !== "function") return pr;
          pr.then((v) => callback(v), (e) => withLastError(e, callback));
        };
        // Extension pages are never an extension's to reach, as in Chrome,
        // where such a pattern isn't even valid (see
        // Extensions.reachesExtensions): never held, never asked for.
        const extensionPages = (origins) => origins.some((o) => /^(chrome|webkit)-extension:/i.test(String(o)));
        put(p, "contains", withCb(async ({ permissions = [], origins = [] }) => {
          const { theirs, mine, unknown } = split(permissions);
          if (unknown.length || extensionPages(origins)) return false;
          if (mine.length) { const have = await granted(); if (!mine.every((m) => have.has(m))) return false; }
          return theirs.length || origins.length ? contains({ permissions: theirs, origins }) : true;
        }));
        put(p, "request", withCb(async ({ permissions = [], origins = [] }) => {
          const { theirs, mine, unknown } = split(permissions);
          if (unknown.length || extensionPages(origins)) return false;
          if (mine.length) {
            const have = await granted();
            const missing = mine.filter((m) => !have.has(m));
            if (missing.length && !(await native("permissions.request", [missing]))) return false;
          }
          if (!theirs.length && !origins.length) return true;
          // Asked from a click on the extension's button: when filling in
          // the tab it was given (mend) cost WebKit the click, Search
          // knows it was one and asks the same question.
          return Promise.resolve(request({ permissions: theirs, origins })).catch((e) =>
            /user gesture/i.test(String(e && e.message)) ? native("permissions.afterClick", [theirs, origins]) : Promise.reject(e));
        }));
        put(p, "getAll", (callback) => {
          const pr = (async () => {
            const all = await getAll();
            const have = await granted();
            return { ...all, permissions: [...new Set([...(all.permissions || []), ...[...have].filter((m) => ours.has(m))])] };
          })();
          if (typeof callback !== "function") return pr;
          pr.then((v) => callback(v), (e) => withLastError(e, callback));
        });
        put(p, "remove", withCb(async ({ permissions = [], origins = [] }) => {
          const { theirs, mine } = split(permissions);
          if (mine.length) await native("permissions.remove", [mine]);
          return theirs.length || origins.length ? remove({ permissions: theirs, origins }) : true;
        }));
      }

      // chrome.userScripts — what Tampermonkey, Violentmonkey and the
      // advanced rules of the ad blockers run on — carried out through
      // WebKit's registered content scripts. The browser writes each script
      // into a file of the extension's (content scripts come from files),
      // wrapped so the globs Chrome takes are honoured and, for Chrome's
      // USER_SCRIPT world, so its messages reach onUserScriptMessage rather
      // than the extension's own onMessage. The list lives with the browser,
      // and is registered again whenever the worker starts.
      const scripting = chrome.scripting;
      // What an extension registers for a page's own world has Search's
      // passkey patch before it, as its manifest's do (see prepare): a
      // password manager keeps a reference to navigator.credentials as it
      // finds it, and falls back to that. An update that names no world gets
      // it too; in any other world the patch does nothing.
      if (scripting) {
        const first = (scripts, updating) => Array.isArray(scripts) ? scripts.map((s) => {
          if (!s || !Array.isArray(s.js) || s.js.includes("search-passkeys.js")) return s;
          const world = String(s.world || "").toUpperCase();
          return world === "MAIN" || (updating && !world) ? { ...s, js: ["search-passkeys.js", ...s.js] } : s;
        }) : scripts;
        for (const name of ["registerContentScripts", "updateContentScripts"]) {
          const original = scripting[name];
          if (typeof original === "function") {
            put(scripting, name, function (scripts, ...rest) { return original.call(scripting, first(scripts, name === "updateContentScripts"), ...rest); });
          }
        }
      }
      const wantsUserScripts = (() => { try { return (runtime.getManifest().permissions || []).includes("userScripts"); } catch (e) { return false; } })();
      if (!chrome.userScripts && wantsUserScripts && scripting && typeof scripting.registerContentScripts === "function") {
        const tag = "search-us-";
        const content = async (script) => ({
          id: tag + script.id,
          matches: script.matches && script.matches.length ? script.matches : ["*://*/*"],
          excludeMatches: script.excludeMatches || [],
          js: [await native("userScripts.file", [script])],
          runAt: script.runAt || "document_idle",
          allFrames: !!script.allFrames,
          world: script.world === "MAIN" ? "MAIN" : "ISOLATED",
          persistAcrossSessions: false,
        });
        const registered = async () => (await scripting.getRegisteredContentScripts()).filter((s) => s.id.startsWith(tag));
        const list = () => native("userScripts.list", []).then((l) => l || []);
        const save = (l) => native("userScripts.save", [l]);
        const sync = async () => {
          const want = await list();
          const have = new Set((await registered()).map((s) => s.id));
          const missing = want.filter((s) => !have.has(tag + s.id));
          if (!missing.length) return;
          const scripts = await Promise.all(missing.map(content));
          // Two starts of the worker racing each other: the later one takes
          // the registration over.
          await scripting.registerContentScripts(scripts).catch(async (e) => {
            if (!/duplicate/i.test(String(e && e.message))) throw e;
            await scripting.unregisterContentScripts({ ids: scripts.map((s) => s.id) }).catch(() => {});
            await scripting.registerContentScripts(scripts);
          });
        };
        const pick = (filter, l) => filter && Array.isArray(filter.ids) ? l.filter((s) => filter.ids.includes(s.id)) : l;
        const api = {
          register: async (scripts) => {
            const l = await list();
            for (const s of scripts) if (l.some((o) => o.id === s.id)) throw new Error("Duplicate script id '" + s.id + "'");
            await scripting.registerContentScripts(await Promise.all(scripts.map(content)));
            await save([...l, ...scripts]);
          },
          update: async (scripts) => {
            const l = await list();
            const merged = scripts.map((s) => {
              const old = l.find((o) => o.id === s.id);
              if (!old) throw new Error("Script with id '" + s.id + "' does not exist");
              return { ...old, ...s };
            });
            await scripting.unregisterContentScripts({ ids: merged.map((s) => tag + s.id) }).catch(() => {});
            await scripting.registerContentScripts(await Promise.all(merged.map(content)));
            await save(l.map((o) => merged.find((m) => m.id === o.id) || o));
          },
          unregister: async (filter) => {
            const l = await list();
            const gone = pick(filter, l);
            const ids = (await registered()).map((s) => s.id).filter((id) => gone.some((g) => tag + g.id === id));
            if (ids.length) await scripting.unregisterContentScripts({ ids });
            await save(l.filter((o) => !gone.includes(o)));
          },
          getScripts: async (filter) => pick(filter, await list()),
          configureWorld: (properties) => native("userScripts.world", [properties || {}]),
          getWorldConfigurations: () => native("userScripts.worlds", []),
          resetWorldConfiguration: (worldId) => native("userScripts.world", [{ worldId, reset: true }]),
          execute: async (injection) => {
            const file = await native("userScripts.file", [{ id: "execute-" + Date.now(), js: injection.js || [], world: injection.world }]);
            return scripting.executeScript({ target: injection.target, files: [file], world: injection.world === "MAIN" ? "MAIN" : "ISOLATED",
              injectImmediately: !!injection.injectImmediately });
          },
        };
        const callbacks = Object.fromEntries(Object.entries(api).map(([k, f]) => [k, (...args) => {
          const callback = args.length && typeof args[args.length - 1] === "function" ? args.pop() : null;
          const p = f(...args);
          if (!callback) return p;
          p.then((v) => callback(v), (e) => withLastError(e, callback));
        }]));
        put2("userScripts", { ...callbacks, ExecutionWorld: { MAIN: "MAIN", USER_SCRIPT: "USER_SCRIPT" } });
        if (background) sync().catch((e) => { try { native("debug.error", ["userScripts: " + e.message]).catch(() => {}); } catch (x) {} });

        // Messages from the USER_SCRIPT world come tagged (see the file's
        // wrapper); they go to onUserScriptMessage and onUserScriptConnect.
        const onMessage = runtime.onUserScriptMessage, onConnect = runtime.onUserScriptConnect;
        root.__searchUserScriptMessage = (message, sender, respond) => {
          let keep = false;
          for (const f of [...onMessage.listeners]) {
            const r = f(message, sender, respond);
            if (r === true) keep = true;
            else if (r && typeof r.then === "function") { keep = true; r.then(respond); }
          }
          return keep;
        };
        if (runtime.onConnect && typeof runtime.onConnect.addListener === "function") {
          const marker = "search-us:";
          const add = runtime.onConnect.addListener.bind(runtime.onConnect);
          const remove = runtime.onConnect.removeListener.bind(runtime.onConnect);
          const wrapped = new Map();
          try {
            add((port) => {
              if (!String(port.name).startsWith(marker)) return;
              const view = Object.create(port, { name: { value: port.name.slice(marker.length) } });
              for (const f of [...onConnect.listeners]) f(view);
            });
          } catch (e) {}
          put(runtime.onConnect, "addListener", (listener) => {
            const w = (port) => { if (!String(port.name).startsWith(marker)) return listener(port); };
            wrapped.set(listener, w);
            return add(w);
          });
          put(runtime.onConnect, "removeListener", (listener) => { const w = wrapped.get(listener); if (w) { wrapped.delete(listener); remove(w); } });
        }
      }

      // WebKit says "install" again when an extension is taken up afresh in
      // the same session — after a Reload, or a worker brought back — where
      // Chrome says "update"; extensions open their welcome page on
      // "install". The first one of a session is marked, and any later one
      // told as the update it is.
      if (background && runtime.onInstalled && typeof runtime.onInstalled.addListener === "function") {
        let decided = null;
        const seenBefore = () => decided || (decided = native("background.loadedBefore", []).then((v) => !!v, () => false));
        const add = runtime.onInstalled.addListener.bind(runtime.onInstalled);
        const remove = runtime.onInstalled.removeListener.bind(runtime.onInstalled);
        const wrapped = new Map();
        put(runtime.onInstalled, "addListener", (listener) => {
          const w = (details) => {
            if (!details || details.reason !== "install") return listener(details);
            seenBefore().then((seen) => listener(seen ? { ...details, reason: "update", previousVersion: runtime.getManifest().version } : details));
          };
          wrapped.set(listener, w);
          return add(w);
        });
        put(runtime.onInstalled, "removeListener", (listener) => { const w = wrapped.get(listener); wrapped.delete(listener); return remove(w || listener); });
        put(runtime.onInstalled, "hasListener", (listener) => wrapped.has(listener));
      }

      // A worker may add listeners only while it starts; WebKit throws for
      // one added later, where Chrome takes it. So for every event this
      // extension's code mentions, the worker has one listener of WebKit's
      // from the start, and a late one joins the list behind it. Events it
      // never mentions still take late listeners without throwing — they
      // just aren't heard. (Request events are left alone: a listener for
      // all of them would wake the worker for every request.)
      if (background) {
        const mentioned = new Set(__SEARCH_EVENTS__);
        for (const space of Object.keys(chrome)) {
          if (space === "webRequest") continue;
          let ns; try { ns = chrome[space]; } catch (e) { continue; }
          if (!ns || typeof ns !== "object") continue;
          const names = new Set();
          for (let o = ns; o && o !== Object.prototype; o = Object.getPrototypeOf(o)) Object.getOwnPropertyNames(o).forEach((k) => names.add(k));
          for (const key of names) {
            if (!/^on[A-Z]/.test(key) || (space === "runtime" && /^onMessage/.test(key))) continue;
            let target; try { target = ns[key]; } catch (e) { continue; }
            if (!target || typeof target.addListener !== "function" || target.listeners) continue;
            const add = target.addListener.bind(target), remove = target.removeListener.bind(target);
            const late = new Set();
            if (mentioned.has(space + "." + key)) {
              try {
                add(function (...args) {
                  let answer;
                  for (const f of [...late]) { try { const r = f(...args); if (r !== undefined) answer = r; } catch (e) { setTimeout(() => { throw e; }); } }
                  return answer;
                });
              } catch (e) {}
            }
            put(target, "addListener", (listener, ...rest) => {
              try { return add(listener, ...rest); }
              catch (e) { if (/startup/i.test(String(e && e.message))) late.add(listener); else throw e; }
            });
            put(target, "removeListener", (listener) => { late.delete(listener); try { remove(listener); } catch (e) {} });
          }
        }
      }

      // What one of the extension's pages or its worker posts to another
      // before their port has opened — at once after connect, or from inside
      // onConnect — WebKit keeps until the other end takes the port, then
      // hands on once for each end's world: between two of the extension's
      // own, the same world, so twice. iCloud Passwords' popup asks its
      // worker for its state that way, and was answered twice. So between
      // the extension's own ends every message goes numbered by the end
      // that sends it, and a number already heard is let go by. A content
      // script's port, or an app's, goes as it is.
      if (runtime && typeof runtime.connect === "function" && runtime.onConnect) {
        const own = runtime.getURL("");
        const numbered = new WeakSet();
        // Set on the port itself, not with `put`, which holds what it touches
        // for good: a port is the extension's to let go. Its onMessage is held
        // by what is set here, so it isn't made afresh without it.
        const set = (target, key, value) => { try { Object.defineProperty(target, key, { value, configurable: true, writable: true }); } catch (e) {} };
        const number = (port) => {
          const event = port && port.onMessage, post = port && port.postMessage;
          if (!event || typeof event.addListener !== "function" || typeof post !== "function" || numbered.has(port)) return port;
          numbered.add(port);
          const me = Math.random().toString(36).slice(2);
          let sent = 0;
          const heard = new Map();
          const listeners = new Set();
          event.addListener.call(event, (message, ...rest) => {
            const tag = message && typeof message === "object" ? message.__searchPort : null;
            if (Array.isArray(tag)) {
              if (tag[1] <= (heard.get(tag[0]) || 0)) return;
              heard.set(tag[0], tag[1]);
              message = message.message;
            }
            for (const f of [...listeners]) { try { f(message, ...rest); } catch (e) { setTimeout(() => { throw e; }); } }
          });
          // WebKit makes a port's onMessage afresh once nothing holds it, and
          // a fresh one has none of what is set below: a listener added to it
          // later would hear the numbered wrapper. Held on the port, it stays.
          set(port, "onMessage", event);
          set(port, "postMessage", (message) => post.call(port, { __searchPort: [me, ++sent], message }));
          set(event, "addListener", (f) => { listeners.add(f); });
          set(event, "removeListener", (f) => { listeners.delete(f); });
          set(event, "hasListener", (f) => listeners.has(f));
          set(event, "hasListeners", () => listeners.size > 0);
          return port;
        };
        const connect = runtime.connect;
        // Only a port to the extension itself: another extension would hear
        // the numbered wrapper, not the message.
        put(runtime, "connect", (...args) => {
          const port = connect.apply(runtime, args);
          return typeof args[0] === "string" && args[0] !== runtime.id ? port : number(port);
        });
        const onConnect = runtime.onConnect;
        const add = onConnect.addListener, remove = onConnect.removeListener, has = onConnect.hasListener;
        const wrapped = new WeakMap();
        // The worker's sender is the bare origin, with no slash after it.
        const fromOwn = (port) => !!port && !!port.sender && (String(port.sender.url) + "/").startsWith(own);
        put(onConnect, "addListener", (listener, ...rest) => {
          if (typeof listener !== "function") return add.call(onConnect, listener, ...rest);
          let w = wrapped.get(listener);
          if (!w) {
            w = (port) => {
              const given = port && port.sender, sender = untabbed(given);
              port = fromOwn(port) ? number(port) : port;
              // WebKit makes a port's sender afresh at each look, over
              // anything set on the port: the port is seen through a proxy.
              if (sender !== given) {
                port = new Proxy(port, { get: (target, key) => {
                  if (key === "sender") return sender;
                  const value = target[key];
                  return typeof value === "function" ? value.bind(target) : value;
                } });
              }
              return listener(port);
            };
            wrapped.set(listener, w);
          }
          return add.call(onConnect, w, ...rest);
        });
        put(onConnect, "removeListener", (listener) => remove.call(onConnect, wrapped.get(listener) || listener));
        put(onConnect, "hasListener", (listener) => has.call(onConnect, wrapped.get(listener) || listener));
      }

      // Members of namespaces WebKit has.
      if (chrome.i18n && !chrome.i18n.detectLanguage) put(chrome.i18n, "detectLanguage", call("i18n.detectLanguage"));
      if (runtime && !runtime.getContexts) put(runtime, "getContexts", call("runtime.getContexts"));

      // Chrome's old FileSystem API — requestFileSystem, entries, FileWriter and
      // `filesystem:` URLs — which WebKit never had. Extensions still save to it:
      // GoFullPage writes every capture there and shows, copies and downloads it
      // by a `filesystem:<origin>/persistent/...` URL it builds itself. So it is
      // rebuilt on the origin private file system: PERSISTENT and TEMPORARY are
      // the folders "persistent" and "temporary" at its root, so a filesystem: URL
      // and the file it names have the same path. WebKit can't load that scheme,
      // so where such a URL is handed to something that loads it is swapped for
      // the file: a blob: URL in an image, a link or fetch; a data: URL for a
      // download or a new tab, which the browser loads outside this page.
      // Extension pages only: a worker has no DOM to mend, and a content script
      // shares the page's origin.
      (() => {
        const root = globalThis;
        if (root.requestFileSystem || root.webkitRequestFileSystem || typeof document === "undefined"
            || !(root.navigator && navigator.storage && navigator.storage.getDirectory)) return;

        const TEMPORARY = 0, PERSISTENT = 1;
        const kinds = ["temporary", "persistent"];
        // Chrome answers with DOMExceptions whose name says what went wrong; the
        // legacy code comes with the name (NotFoundError is 8, and so on).
        const fail = (name, message) => new DOMException(message || name, name);
        const asError = (e) => e instanceof DOMException ? e : fail(e && e.name || "InvalidStateError", e && e.message || String(e));
        // Chrome calls back later, never in the same turn, success or not.
        // A callback that throws is reported as uncaught, not as a rejection.
        const invoke = (f, v) => { try { f(v); } catch (e) { setTimeout(() => { throw e; }); } };
        const settle = (promise, success, error) => {
          promise.then((v) => { if (typeof success === "function") invoke(success, v); },
            (e) => { if (typeof error === "function") invoke(error, asError(e)); });
        };

        // Paths are kept as their segments; "/a/b" is ["a", "b"].
        const segments = (base, path) => {
          path = String(path ?? "");
          const out = path.startsWith("/") ? [] : base.split("/").filter(Boolean);
          for (const part of path.split("/")) {
            if (!part || part === ".") continue;
            if (part === "..") out.pop(); else out.push(part);
          }
          return out;
        };
        const join = (segs) => "/" + segs.join("/");

        const top = [];
        const folder = (type) => top[type] || (top[type] = navigator.storage.getDirectory()
          .then((d) => d.getDirectoryHandle(kinds[type], { create: true })));
        const walk = async (type, segs, create = false) => {
          let dir = await folder(type);
          for (const name of segs) dir = await dir.getDirectoryHandle(name, { create });
          return dir;
        };
        // The handle at a path, whichever kind it is, or null.
        const lookup = async (type, segs) => {
          if (!segs.length) return folder(type);
          const dir = await walk(type, segs.slice(0, -1));
          const name = segs[segs.length - 1];
          try { return await dir.getFileHandle(name); } catch (e) {
            if (e.name !== "TypeMismatchError") { if (e.name === "NotFoundError") return null; throw e; }
          }
          return dir.getDirectoryHandle(name);
        };
        const need = async (type, segs) => {
          const handle = await lookup(type, segs).catch((e) => { if (e.name === "NotFoundError") return null; throw e; });
          if (!handle) throw fail("NotFoundError", "A requested file or directory could not be found.");
          return handle;
        };

        // OPFS files come without a type; a blob: URL or download wants one.
        const types = { png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg", gif: "image/gif", webp: "image/webp",
          svg: "image/svg+xml", pdf: "application/pdf", txt: "text/plain", html: "text/html", json: "application/json",
          mp4: "video/mp4", webm: "video/webm" };
        const typed = (file) => {
          const type = file.type || types[(file.name.split(".").pop() || "").toLowerCase()] || "";
          return type === file.type ? file : new File([file], file.name, { type, lastModified: file.lastModified });
        };

        // blob: URLs already made, by "<type>:<path>", so the same file set on an
        // image twice gets the same URL, and at once. Changing a file drops its.
        const made = new Map();
        const forget = (type, path) => {
          for (const [key, url] of made) {
            const [t, p] = [Number(key[0]), key.slice(2)];
            if (t === type && (p === path || p.startsWith(path === "/" ? "/" : path + "/"))) {
              made.delete(key);
              Promise.resolve(url).then((u) => { if (u) setTimeout(() => URL.revokeObjectURL(u), 60000); }, () => {});
            }
          }
        };

        const systems = [];
        const system = (type) => systems[type] || (systems[type] = (() => {
          const fs = { name: location.host + ":" + (type ? "Persistent" : "Temporary") };
          fs.root = new DirectoryEntry(fs, type, "/");
          return fs;
        })());

        class Entry {
          constructor(fs, type, path) {
            Object.defineProperty(this, "_type", { value: type });
            this.filesystem = fs;
            this.fullPath = path;
            this.name = path === "/" ? "" : path.split("/").pop();
          }
          get _segs() { return segments("/", this.fullPath); }
          toURL() {
            return "filesystem:" + location.origin + "/" + kinds[this._type]
              + (this.fullPath === "/" ? "/" : this._segs.map(encodeURIComponent).map((s) => "/" + s).join(""));
          }
          toInternalURL() { return this.toURL(); }
          getParent(success, error) {
            settle(Promise.resolve(new DirectoryEntry(this.filesystem, this._type, join(this._segs.slice(0, -1)))), success, error);
          }
          getMetadata(success, error) {
            settle((async () => {
              const handle = await need(this._type, this._segs);
              if (handle.kind === "directory") return { modificationTime: new Date(), size: 0 };
              const file = await handle.getFile();
              return { modificationTime: new Date(file.lastModified), size: file.size };
            })(), success, error);
          }
          remove(success, error) {
            settle((async () => {
              const segs = this._segs;
              if (!segs.length) throw fail("InvalidModificationError", "The root directory cannot be removed.");
              const handle = await need(this._type, segs);
              // Not recursive: a directory with something in it is refused, as in
              // Chrome — WebKit says UnknownError there, Chrome InvalidModificationError.
              await (await walk(this._type, segs.slice(0, -1))).removeEntry(segs[segs.length - 1]).catch((e) => {
                throw handle.kind === "directory" && e.name !== "NotFoundError" ? fail("InvalidModificationError", "The directory is not empty.") : e;
              });
              forget(this._type, this.fullPath);
            })(), success, error);
          }
          moveTo(parent, name, success, error) { settle(this._transfer(parent, name, true), success, error); }
          copyTo(parent, name, success, error) { settle(this._transfer(parent, name, false), success, error); }
          async _transfer(parent, name, move) {
            if (!(parent instanceof DirectoryEntry)) throw fail("TypeMismatchError", "The parent is not a directory.");
            name = name == null || name === "" ? this.name : String(name);
            if (!name || name.includes("/") || name === "." || name === "..") throw fail("EncodingError", "Invalid name.");
            const from = this._segs, to = [...parent._segs, name];
            const same = parent._type === this._type;
            if (!from.length) throw fail("InvalidModificationError", "The root directory cannot be moved or copied.");
            if (same && (join(to) === this.fullPath || join(to).startsWith(this.fullPath + "/")))
              throw fail("InvalidModificationError", "An entry cannot be moved or copied onto or into itself.");
            const handle = await need(this._type, from);
            const into = await need(parent._type, parent._segs);
            if (into.kind !== "directory") throw fail("NotFoundError");
            // What is already there is replaced if it is a file over a file, or an
            // empty directory over a directory; otherwise Chrome refuses.
            const there = await lookup(parent._type, to).catch(() => null);
            if (there) {
              if (there.kind !== handle.kind) throw fail("InvalidModificationError", "An entry of another kind is in the way.");
              await into.removeEntry(name).catch(() => { throw fail("InvalidModificationError", "The directory in the way is not empty."); });
              forget(parent._type, join(to));
            }
            let moved = false;
            if (move && same && typeof handle.move === "function") {
              try { await handle.move(into, name); moved = true; } catch (e) {}
            }
            if (!moved) {
              await copy(handle, into, name);
              if (move) await (await walk(this._type, from.slice(0, -1))).removeEntry(from[from.length - 1], { recursive: true });
            }
            if (move) forget(this._type, this.fullPath);
            const Kind = this.isDirectory ? DirectoryEntry : FileEntry;
            return new Kind(parent.filesystem, parent._type, join(to));
          }
        }
        const copy = async (handle, into, name) => {
          if (handle.kind === "file") {
            const w = await (await into.getFileHandle(name, { create: true })).createWritable();
            await w.write(await handle.getFile());
            return w.close();
          }
          const dir = await into.getDirectoryHandle(name, { create: true });
          for await (const [child, h] of handle.entries()) await copy(h, dir, child);
        };

        class DirectoryEntry extends Entry {
          get isFile() { return false; }
          get isDirectory() { return true; }
          createReader() { return new DirectoryReader(this); }
          getFile(path, options, success, error) { settle(this._get(path, options, "file"), success, error); }
          getDirectory(path, options, success, error) { settle(this._get(path, options, "directory"), success, error); }
          async _get(path, options, kind) {
            const create = !!(options && options.create), exclusive = !!(options && options.exclusive);
            const segs = segments(this.fullPath, path);
            if (!segs.length) {
              if (kind === "file") throw fail("TypeMismatchError", "The root is a directory.");
              if (create && exclusive) throw fail("InvalidModificationError", "The directory already exists.");
              return this.filesystem.root;
            }
            const dir = await walk(this._type, segs.slice(0, -1)).catch((e) => {
              throw e.name === "TypeMismatchError" ? fail("NotFoundError") : e;
            });
            const name = segs[segs.length - 1];
            if (create && exclusive) {
              const there = await lookup(this._type, segs).catch(() => null);
              if (there) throw fail("InvalidModificationError", "The entry already exists.");
            }
            await (kind === "file" ? dir.getFileHandle(name, { create }) : dir.getDirectoryHandle(name, { create }));
            const Kind = kind === "file" ? FileEntry : DirectoryEntry;
            return new Kind(this.filesystem, this._type, join(segs));
          }
          removeRecursively(success, error) {
            settle((async () => {
              const segs = this._segs;
              if (!segs.length) throw fail("InvalidModificationError", "The root directory cannot be removed.");
              await need(this._type, segs);
              await (await walk(this._type, segs.slice(0, -1))).removeEntry(segs[segs.length - 1], { recursive: true });
              forget(this._type, this.fullPath);
            })(), success, error);
          }
        }

        // Chrome hands a directory's entries over in batches, then an empty one to
        // say it's done; callers loop until they see it.
        class DirectoryReader {
          constructor(dir) { this._dir = dir; this._left = null; }
          readEntries(success, error) {
            settle((async () => {
              const dir = this._dir;
              if (!this._left) {
                const handle = await need(dir._type, dir._segs);
                this._left = [];
                for await (const [name, h] of handle.entries()) {
                  const Kind = h.kind === "file" ? FileEntry : DirectoryEntry;
                  this._left.push(new Kind(dir.filesystem, dir._type, join([...dir._segs, name])));
                }
              }
              return this._left.splice(0, 100);
            })(), success, error);
          }
        }

        class FileEntry extends Entry {
          get isFile() { return true; }
          get isDirectory() { return false; }
          file(success, error) {
            settle((async () => {
              const handle = await need(this._type, this._segs);
              if (handle.kind !== "file") throw fail("TypeMismatchError");
              return typed(await handle.getFile());
            })(), success, error);
          }
          createWriter(success, error) {
            settle((async () => {
              const handle = await need(this._type, this._segs);
              if (handle.kind !== "file") throw fail("TypeMismatchError");
              return new FileWriter(this, handle, (await handle.getFile()).size);
            })(), success, error);
          }
        }

        // One write or truncate at a time, each a writable opened on the file as it
        // is and closed — OPFS commits on close — with Chrome's events around it:
        // writestart, write, writeend, or error then writeend.
        class FileWriter extends EventTarget {
          constructor(entry, handle, length) {
            super();
            Object.defineProperty(this, "_entry", { value: entry });
            Object.defineProperty(this, "_handle", { value: handle });
            Object.defineProperty(this, "_token", { value: null, writable: true });
            this.readyState = 0; this.position = 0; this.length = length; this.error = null;
            this.onwritestart = this.onprogress = this.onwrite = this.onabort = this.onerror = this.onwriteend = null;
          }
          _fire(type, loaded, total) {
            const event = new ProgressEvent(type, { lengthComputable: true, loaded, total });
            this.dispatchEvent(event);
            const handler = this["on" + type];
            if (typeof handler === "function") handler.call(this, event);
          }
          _run(size, work, after) {
            if (this.readyState === 1) throw fail("InvalidStateError", "A write is already in progress.");
            this.readyState = 1; this.error = null;
            const run = this._token = {};
            setTimeout(async () => {
              if (this._token !== run) return;
              this._fire("writestart", 0, size);
              try {
                const w = await this._handle.createWritable({ keepExistingData: true });
                try { await work(w); await w.close(); } catch (e) { await w.abort().catch(() => {}); throw e; }
                if (this._token !== run) return;
                after();
                forget(this._entry._type, this._entry.fullPath);
                this.readyState = 2;
                this._fire("progress", size, size);
                this._fire("write", size, size);
              } catch (e) {
                if (this._token !== run) return;
                this.error = asError(e);
                this.readyState = 2;
                this._fire("error", 0, size);
              }
              this._fire("writeend", this.readyState === 2 ? size : 0, size);
            });
          }
          write(data) {
            if (!(data instanceof Blob)) throw new TypeError("Failed to execute 'write' on 'FileWriter': parameter 1 is not of type 'Blob'.");
            const at = this.position;
            this._run(data.size, (w) => w.write({ type: "write", position: at, data }), () => {
              this.position = at + data.size;
              this.length = Math.max(this.length, this.position);
            });
          }
          truncate(size) {
            size = Math.max(0, Number(size) || 0);
            this._run(0, (w) => w.truncate(size), () => {
              this.length = size;
              this.position = Math.min(this.position, size);
            });
          }
          seek(offset) {
            if (this.readyState === 1) throw fail("InvalidStateError", "A write is in progress.");
            offset = Number(offset) || 0;
            if (offset < 0) offset = Math.max(0, this.length + offset);
            this.position = Math.min(offset, this.length);
          }
          abort() {
            if (this.readyState !== 1) return;
            this._token = null;
            this.readyState = 2;
            this.error = fail("AbortError", "The write was aborted.");
            this._fire("abort", 0, 0);
            this._fire("writeend", 0, 0);
          }
        }
        for (const [k, v] of [["INIT", 0], ["WRITING", 1], ["DONE", 2]]) {
          Object.defineProperty(FileWriter, k, { value: v });
          Object.defineProperty(FileWriter.prototype, k, { value: v });
        }

        const requestFileSystem = (type, size, success, error) => {
          type = Number(type);
          settle(type === TEMPORARY || type === PERSISTENT
            ? folder(type).then(() => system(type))
            : Promise.reject(fail("InvalidModificationError", "Unknown file system type.")), success, error);
        };

        // filesystem:<this origin>/<persistent|temporary>/<path>, or null.
        const parse = (url) => {
          const s = String(url);
          if (!s.startsWith("filesystem:")) return null;
          const m = /^filesystem:([^/]+:\/\/[^/]+)\/(temporary|persistent)(\/[^?#]*)?/i.exec(s);
          if (!m || m[1] !== location.origin) return null;
          let segs;
          try { segs = segments("/", (m[3] || "/").split("/").map(decodeURIComponent).join("/")); } catch (e) { return null; }
          return { type: kinds.indexOf(m[2].toLowerCase()), segs };
        };
        const resolveURL = (url, success, error) => {
          settle((async () => {
            const at = parse(url);
            if (!at) throw fail(String(url).startsWith("filesystem:") ? "SecurityError" : "EncodingError", "Not a filesystem: URL of this origin.");
            const handle = await need(at.type, at.segs);
            const fs = system(at.type);
            if (!at.segs.length) return fs.root;
            return new (handle.kind === "file" ? FileEntry : DirectoryEntry)(fs, at.type, join(at.segs));
          })(), success, error);
        };

        const fileAt = async (url) => {
          const at = parse(url);
          if (!at) throw fail("NotFoundError");
          const handle = await need(at.type, at.segs);
          if (handle.kind !== "file") throw fail("NotFoundError");
          return typed(await handle.getFile());
        };
        // The blob: URL now standing for a filesystem: URL, made once per file.
        const blobURL = (url) => {
          const at = parse(url);
          if (!at) return Promise.reject(fail("NotFoundError"));
          const key = at.type + ":" + join(at.segs);
          if (!made.has(key)) {
            const p = fileAt(url).then((file) => { const u = URL.createObjectURL(file); made.set(key, u); return u; });
            made.set(key, p);
            p.catch(() => { if (made.get(key) === p) made.delete(key); });
          }
          return Promise.resolve(made.get(key));
        };
        const ready = (url) => { const at = parse(url); const u = at && made.get(at.type + ":" + join(at.segs)); return typeof u === "string" ? u : null; };
        const dataURL = (url) => fileAt(url).then((file) => new Promise((resolve, reject) => {
          const reader = new FileReader();
          reader.onload = () => resolve(reader.result);
          reader.onerror = () => reject(reader.error);
          reader.readAsDataURL(file);
        }));

        const define = (target, key, value) => {
          try { Object.defineProperty(target, key, { value, configurable: true, writable: true, enumerable: true }); } catch (e) {}
        };
        define(root, "TEMPORARY", TEMPORARY);
        define(root, "PERSISTENT", PERSISTENT);
        define(root, "requestFileSystem", requestFileSystem);
        define(root, "webkitRequestFileSystem", requestFileSystem);
        define(root, "resolveLocalFileSystemURL", resolveURL);
        define(root, "webkitResolveLocalFileSystemURL", resolveURL);
        // Code for this API asks for quota first; OPFS has its own, so any is granted.
        const quota = {
          requestQuota: (size, success, error) => settle(Promise.resolve(size), success, error),
          queryUsageAndQuota: (success, error) => settle(navigator.storage.estimate().then((e) => [e.usage || 0, e.quota || 0]),
            (v) => typeof success === "function" && success(v[0], v[1]), error),
        };
        if (!navigator.webkitPersistentStorage) define(navigator, "webkitPersistentStorage", quota);
        if (!navigator.webkitTemporaryStorage) define(navigator, "webkitTemporaryStorage", quota);
        for (const [name, Kind] of [["FileSystemEntry", Entry], ["FileSystemDirectoryEntry", DirectoryEntry],
          ["FileSystemFileEntry", FileEntry], ["FileSystemDirectoryReader", DirectoryReader]]) {
          // WebKit has these for dropped files; its instanceof checks keep its own.
          if (!root[name]) define(root, name, Kind);
        }
        if (!root.FileWriter) define(root, "FileWriter", FileWriter);

        // Where a filesystem: URL is loaded. An image or link gets the blob: URL
        // once it's made — at once when it already was, so a src set again stays
        // put — and reads back the filesystem: URL, as in Chrome. A file that
        // isn't there leaves the URL as it was, so the image fails as it would.
        const shown = new WeakMap();
        const hook = (proto, prop) => {
          const d = proto && Object.getOwnPropertyDescriptor(proto, prop);
          if (!d || !d.set || !d.get) return;
          Object.defineProperty(proto, prop, Object.assign({}, d, {
            get() {
              const value = d.get.call(this), was = shown.get(this);
              return was && was.blob === value ? was.url : value;
            },
            set(value) {
              const url = typeof value === "string" ? value : null;
              if (!url || !url.startsWith("filesystem:") || !parse(url)) { shown.delete(this); return d.set.call(this, value); }
              const now = ready(url);
              if (now) { shown.set(this, { url, blob: now }); return d.set.call(this, now); }
              const was = { url, blob: null };
              shown.set(this, was);
              blobURL(url).then((blob) => {
                if (shown.get(this) !== was) return;
                was.blob = blob;
                d.set.call(this, blob);
              }, () => { if (shown.get(this) === was) { shown.delete(this); d.set.call(this, url); } });
            },
          }));
        };
        hook(root.HTMLImageElement && HTMLImageElement.prototype, "src");
        hook(root.HTMLAnchorElement && HTMLAnchorElement.prototype, "href");
        // React and templates set the attribute, not the property.
        const setAttribute = Element.prototype.setAttribute;
        Element.prototype.setAttribute = function (name, value) {
          if (typeof value === "string" && value.startsWith("filesystem:")) {
            const n = String(name).toLowerCase();
            if ((n === "src" && this instanceof HTMLImageElement) || (n === "href" && this instanceof HTMLAnchorElement)) {
              this[n] = value;
              return;
            }
          }
          return setAttribute.call(this, name, value);
        };

        if (typeof root.fetch === "function") {
          const fetch = root.fetch;
          root.fetch = function (input, init) {
            const url = typeof input === "string" ? input : input instanceof URL ? input.href : null;
            if (!url || !url.startsWith("filesystem:") || !parse(url)) return fetch.apply(this, arguments);
            return fileAt(url).then((file) => new Response(file, { status: 200, headers: { "Content-Type": file.type || "application/octet-stream", "Content-Length": String(file.size) } }),
              () => { throw new TypeError("Load failed"); });
          };
        }

        // The browser downloads and opens tabs from outside this page, where a blob:
        // URL of this page means nothing: those get the file itself, as a data: URL.
        const chrome = root.chrome || root.browser;
        const lastError = (e, callback) => {
          const runtime = chrome && chrome.runtime;
          try { Object.defineProperty(runtime, "lastError", { value: { message: String(e && e.message || e) }, configurable: true }); } catch (x) {}
          try { callback(); } finally { try { delete runtime.lastError; } catch (x) {} }
        };
        const held = [];
        const swap = (space, method, urls) => {
          const ns = chrome && chrome[space];
          const original = ns && ns[method];
          if (typeof original !== "function") return;
          held.push(ns); // WebKit's namespace objects are dropped when nothing holds them, and what was set with them.
          define(ns, method, function (options, ...rest) {
            const list = options && urls(options);
            if (!list || !list.some((u) => typeof u === "string" && parse(u))) return original.call(this, options, ...rest);
            const callback = typeof rest[rest.length - 1] === "function" ? rest.pop() : null;
            const p = Promise.all(list.map((u) => typeof u === "string" && parse(u) ? dataURL(u) : u)).then((done) => {
              const copy = Object.assign({}, options, { url: Array.isArray(options.url) ? done : done[0] });
              return original.call(this, copy, ...rest);
            });
            if (!callback) return p;
            p.then((v) => callback(v), (e) => lastError(e, callback));
          });
        };
        const one = (o) => typeof o.url === "string" ? [o.url] : Array.isArray(o.url) ? o.url : null;
        swap("downloads", "download", one);
        swap("tabs", "create", one);
        swap("windows", "create", one);
      })();

      // Errors in an extension's own pages and worker are told to the browser,
      // which lists them — the only window onto a worker there is.
      if (root.addEventListener) {
        const tell = (text) => { try { native("debug.error", [String(text).slice(0, 2000)]).catch(() => {}); } catch (e) {} };
        root.addEventListener("error", (e) => tell((e.message || "error") + " @ " + String(e.filename || "").split("/").slice(3).join("/") + ":" + e.lineno));
        root.addEventListener("unhandledrejection", (e) => tell("unhandled: " + (e.reason && ((e.reason.message || "") + " — " + (e.reason.stack || "")) || e.reason)));
        // In a test run, what the extension says went wrong, too.
        if (__SEARCH_VERBOSE__ && root.console) {
          let told = 0;
          for (const level of ["error", "warn"]) {
            const original = console[level].bind(console);
            console[level] = (...args) => {
              original(...args);
              if (told++ < 60) tell("console." + level + ": " + args.map((a) => {
                if (a instanceof Error) return a.message + " — " + (a.stack || "");
                try { return typeof a === "string" ? a : JSON.stringify(a); } catch (e) { return String(a); }
              }).join(" "));
            };
          }
        }
      }
    })();
    """#

    // MARK: - answering

    /// Remembered per extension: the side panel it set, and whether its
    /// button should open it.
    static var panelPath: [String: String] = [:]
    static var panelOnClick: Set<String> = []
    /// One voice for every extension that reads aloud.
    static let speaker = NSSpeechSynthesizer()

    static func answer(_ message: Any, from context: WKWebExtensionContext, owner: Extensions) async throws -> Any? {
        guard let body = message as? [String: Any], let api = body["api"] as? String else {
            return ["error": "Not a Search message"]
        }
        let args = body["args"] as? [Any] ?? []
        do {
            return ["value": try await run(api, args, context: context, owner: owner) ?? NSNull()]
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    /// The groups an extension is shown: none while groups are off, and
    /// never one without a tab.
    private static func listedGroups(_ browser: Browser) -> [TabGroup] {
        guard browser.prefs.usesTabGroups else { return [] }
        return browser.tabGroups.filter { !browser.tabs(in: $0.id).isEmpty }
    }

    private static func listedGroup(_ number: Any?, in browser: Browser) throws -> TabGroup {
        guard let number = number as? Int,
              let group = listedGroups(browser).first(where: { TabGroup.number($0.id) == number })
        else { throw Unsupported(what: "No group with id: \(number.map { "\($0)" } ?? "none").") }
        return group
    }

    /// A group as Chrome describes it. Search's groups have no colour; grey
    /// is Chrome's first.
    private static func chromeGroup(_ group: TabGroup) -> [String: Any] {
        ["id": TabGroup.number(group.id), "title": group.name, "collapsed": group.collapsed,
         "color": "grey", "windowId": 1, "shared": false]
    }

    struct Unsupported: LocalizedError {
        let what: String
        var errorDescription: String? { what }
    }

    /// The families whose answers leave the extension's own origin: what the
    /// browser knows about the person using it. WebKit keeps no permission
    /// object for them, they are the APIs this shim exists to supply, so the
    /// gate reads the names the extension's own manifest asked for.
    private static let gates: [String: String] = [
        "bookmarks": "bookmarks",
        "history": "history",
        "downloads": "downloads",
        "sessions": "sessions",
        "topSites": "topSites",
        "browsingData": "browsingData",
        "readingList": "readingList",
        "userScripts": "userScripts",
        "identity": "identity",
        "search": "search",
        "notifications": "notifications",
        "idle": "idle",
        "power": "power",
        "tts": "tts",
        "tabGroups": "tabGroups",
    ]

    /// What this extension asked for: the names in its manifest and any
    /// optional ones granted since. The checks inside the shim are a
    /// courtesy to honest code, the shim runs beside the extension's own,
    /// so the one that counts is here. The manifest is the one WebKit
    /// already holds, not the file read again on every call.
    /// A tab's icon for favIconUrl: the picture the tab wears, as a small
    /// PNG. Search keeps icons as pictures, not addresses, and Chrome's
    /// favIconUrl may be a data: URL. Made once per site and kept.
    /// A tab as the shim names it: `i`, its place in its window's row as
    /// extensions see it, and `w`, that window's frame from windows.getAll()
    /// (see Extensions.tab(windowFrame:index:)). A bare number, or no frame,
    /// is only understood while there is one window.
    private static func located(_ place: Any?, owner: Extensions) -> Tab? {
        let spec = place as? [String: Any]
        guard let index = (place as? NSNumber)?.intValue ?? (spec?["i"] as? NSNumber)?.intValue else { return nil }
        let number = { (value: Any?) in (value as? NSNumber)?.doubleValue }
        if let w = spec?["w"] as? [String: Any], let left = number(w["left"]), let top = number(w["top"]),
           let width = number(w["width"]), let height = number(w["height"]) {
            return owner.tab(windowFrame: CGRect(x: left, y: top, width: width, height: height), index: index)
        }
        guard Browsers.all.count <= 1 else { return nil }
        let visible = owner.visibleTabs
        return visible.indices.contains(index) ? visible[index] : nil
    }

    private static var favIcons: [String: String] = [:]
    static func forgetIcons() { favIcons.removeAll() }

    private static func favIconURL(_ tab: Tab) -> String? {
        guard let host = tab.address.flatMap(Favicons.site), let icon = tab.icon ?? Favicons.shared.cached(host) else { return nil }
        if let known = favIcons[host] { return known }
        let side = 32
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        let url = "data:image/png;base64," + png.base64EncodedString()
        if favIcons.count > 500 { favIcons.removeAll() }
        favIcons[host] = url
        return url
    }

    static func allowed(_ id: String, context: WKWebExtensionContext) -> Set<String> {
        let asked = (context.webExtension.manifest["permissions"] as? [Any] ?? []).compactMap { $0 as? String }
        return Set(asked + (Store.settings.stringArray(forKey: "extensions.granted.\(id)") ?? []))
    }

    private static func run(_ api: String, _ args: [Any], context: WKWebExtensionContext, owner: Extensions) async throws -> Any? {
        guard let browser = owner.browser else { throw Unsupported(what: "No browser window") }
        let first = args.first
        let id = context.uniqueIdentifier

        if api.hasPrefix("setting.") {
            // A browser setting (chrome.privacy…) belongs to the family its
            // name starts with, and only an extension that asked for that
            // family may read or change it, as in Chrome.
            let name = api.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            let family = String(name.prefix(while: { $0 != "." }))
            guard !family.isEmpty, allowed(id, context: context).contains(family) else {
                throw Unsupported(what: "The extension never asked for \u{201C}\(family)\u{201D}")
            }
            return setting(api, first as? [String: Any] ?? [:], extension: id, owner: owner)
        }

        // What leaves this app is answered here, not in the injected script:
        // the shim runs beside the extension's own code, so its checks stop
        // only the honest. A family this extension never asked for is an
        // error, the way Chrome answers a call to an API it lacks.
        // `tabs.describe` is the one call inside a family WebKit does own
        // where the permission guards reading a tab rather than moving or
        // selecting it. WebKit keeps that permission, optional grants
        // included, so it is asked.
        if api == "tabs.describe", !context.hasPermission(.tabs) {
            throw Unsupported(what: "The extension never asked for \u{201C}tabs\u{201D}")
        }
        if let needed = gates[String(api.prefix(while: { $0 != "." }))], !allowed(id, context: context).contains(needed) {
            throw Unsupported(what: "The extension never asked for \u{201C}\(needed)\u{201D}")
        }

        switch api {
        // MARK: bookmarks
        case "bookmarks.getTree":
            return [root(browser.bookmarks.roots)]
        case "bookmarks.getSubTree":
            guard let key = first as? String else { return [] }
            if key == "0" { return [root(browser.bookmarks.roots)] }
            if key == "1" { return [bar(browser.bookmarks.roots)] }
            return find(key, in: browser.bookmarks.roots).map { [node($0.node, parent: $0.parent, index: $0.index, deep: true)] } ?? []
        case "bookmarks.getChildren":
            let key = first as? String ?? "1"
            if key == "0" { return [bar(browser.bookmarks.roots, deep: false)] }
            let kids = key == "1" ? browser.bookmarks.roots : (find(key, in: browser.bookmarks.roots)?.node.children ?? [])
            return kids.enumerated().map { node($1, parent: key, index: $0, deep: false) }
        case "bookmarks.get":
            let keys = (first as? [String]) ?? (first as? String).map { [$0] } ?? []
            return keys.compactMap { key in
                find(key, in: browser.bookmarks.roots).map { node($0.node, parent: $0.parent, index: $0.index, deep: false) }
            }
        case "bookmarks.getRecent":
            let count = (first as? Int) ?? 10
            return flat(browser.bookmarks.roots).filter { !$0.node.isFolder }.suffix(count).reversed()
                .map { node($0.node, parent: $0.parent, index: $0.index, deep: false) }
        case "bookmarks.search":
            let query = (first as? String) ?? ((first as? [String: Any])?["query"] as? String) ?? ""
            let wantURL = (first as? [String: Any])?["url"] as? String
            let wantTitle = (first as? [String: Any])?["title"] as? String
            let words = query.lowercased().split(separator: " ").map(String.init)
            return flat(browser.bookmarks.roots).filter { hit in
                let n = hit.node
                if let wantURL, n.url != wantURL { return false }
                if let wantTitle, n.title != wantTitle { return false }
                let hay = (n.title + " " + (n.url ?? "")).lowercased()
                return words.allSatisfy { hay.contains($0) }
            }.map { node($0.node, parent: $0.parent, index: $0.index, deep: false) }
        case "bookmarks.create":
            let spec = first as? [String: Any] ?? [:]
            let title = spec["title"] as? String ?? ""
            let parent = (spec["parentId"] as? String).flatMap(UUID.init(uuidString:))
            let index = spec["index"] as? Int
            let made: Bookmark
            if let url = (spec["url"] as? String).flatMap(URL.init(string:)) {
                made = browser.bookmarks.insert(.site(title, url), into: parent, at: index)
            } else {
                made = browser.bookmarks.insert(.folder(title, []), into: parent, at: index)
            }
            return find(made.id.uuidString, in: browser.bookmarks.roots).map { node($0.node, parent: $0.parent, index: $0.index, deep: false) }
        case "bookmarks.update":
            guard let key = first as? String, let uuid = UUID(uuidString: key) else { throw Unsupported(what: "No such bookmark") }
            let changes = args.count > 1 ? args[1] as? [String: Any] ?? [:] : [:]
            browser.bookmarks.update(uuid, title: changes["title"] as? String, url: changes["url"] as? String)
            return find(key, in: browser.bookmarks.roots).map { node($0.node, parent: $0.parent, index: $0.index, deep: false) }
        case "bookmarks.move":
            guard let key = first as? String, let uuid = UUID(uuidString: key) else { throw Unsupported(what: "No such bookmark") }
            let spec = (args.count > 1 ? args[1] as? [String: Any] : nil) ?? [:]
            // No parent named keeps it in the folder it is in, as in Chrome;
            // "1", the bar, is the top level.
            let target = (spec["parentId"] as? String).map(UUID.init(uuidString:)) ?? browser.bookmarks.parent(of: uuid)
            browser.bookmarks.move(uuid, into: target, at: spec["index"] as? Int)
            return find(key, in: browser.bookmarks.roots).map { node($0.node, parent: $0.parent, index: $0.index, deep: false) }
        case "bookmarks.remove", "bookmarks.removeTree":
            guard let key = first as? String, let uuid = UUID(uuidString: key) else { throw Unsupported(what: "No such bookmark") }
            browser.bookmarks.remove(uuid)
            return nil

        // MARK: history
        case "history.search":
            let spec = first as? [String: Any] ?? [:]
            let text = spec["text"] as? String ?? ""
            let start = (spec["startTime"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
                ?? Date().addingTimeInterval(-24 * 3600)
            let end = (spec["endTime"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantFuture
            let limit = spec["maxResults"] as? Int ?? 100
            return browser.history.everything(matching: text)
                .filter { $0.last >= start && $0.last <= end }
                .sorted { $0.last > $1.last }
                .prefix(limit)
                .map(visit)
        case "history.getVisits":
            let url = (first as? [String: Any])?["url"] as? String ?? ""
            return browser.history.everything().filter { $0.url.absoluteString == url }.map { trace in
                ["id": trace.key, "visitId": "1", "visitTime": trace.last.timeIntervalSince1970 * 1000,
                 "referringVisitId": "0", "transition": "link"]
            }
        case "history.addUrl":
            if let url = ((first as? [String: Any])?["url"] as? String).flatMap(URL.init(string:)) {
                browser.history.record(url, title: "")
            }
            return nil
        case "history.deleteUrl":
            let url = (first as? [String: Any])?["url"] as? String ?? ""
            for trace in browser.history.everything() where trace.url.absoluteString == url {
                browser.history.forget(trace.key)
            }
            return nil
        case "history.deleteRange":
            let spec = first as? [String: Any] ?? [:]
            let start = Date(timeIntervalSince1970: (spec["startTime"] as? Double ?? 0) / 1000)
            let end = Date(timeIntervalSince1970: (spec["endTime"] as? Double ?? 0) / 1000)
            for trace in browser.history.everything() where trace.last >= start && trace.last <= end {
                browser.history.forget(trace.key)
            }
            return nil
        case "history.deleteAll":
            browser.history.forget()
            return nil

        // MARK: downloads
        case "downloads.download":
            let spec = first as? [String: Any] ?? [:]
            guard let url = (spec["url"] as? String).flatMap(URL.init(string:)) else { throw Unsupported(what: "No url to download") }
            guard let web = browser.active?.built ?? browser.tabs.lazy.compactMap(\.built).first else {
                throw Unsupported(what: "No page to download through")
            }
            if let name = spec["filename"] as? String, !name.isEmpty {
                // A name it asks for, which may carry folders: only the last part is kept.
                browser.namedDownloads[url] = (name as NSString).lastPathComponent
            }
            ExtensionShims.askedDownloads[url] = id
            let download = await web.startDownload(using: URLRequest(url: url))
            browser.keep(download)
            return browser.loot.kept.count + 1
        case "downloads.search":
            return browser.loot.kept.enumerated().map { index, keep in
                ["id": index + 1, "url": keep.url.absoluteString, "finalUrl": keep.url.absoluteString,
                 "filename": keep.path, "state": "complete", "exists": keep.stillThere,
                 "startTime": ISO8601DateFormatter().string(from: keep.date), "mime": ""] as [String: Any]
            }
        case "downloads.open", "downloads.show":
            guard let index = first as? Int, browser.loot.kept.indices.contains(index - 1) else { return nil }
            let keep = browser.loot.kept[index - 1]
            if api == "downloads.open" {
                // As in Chrome, opening asks for its own permission; and only
                // a file this extension downloaded itself, not any of yours.
                guard allowed(id, context: context).contains("downloads.open") else {
                    throw Unsupported(what: "The extension never asked for \u{201C}downloads.open\u{201D}")
                }
                // Only when you have just done something in it, as Chrome
                // asks: never on its own, from its worker.
                guard Extensions.justUsed(id) else {
                    throw Unsupported(what: "downloads.open() may only be called in response to a user gesture.")
                }
                guard ExtensionShims.ownDownloads[id]?.contains(keep.path) == true else {
                    throw Unsupported(what: "Only a download this extension started can be opened by it")
                }
                browser.loot.open(keep)
            } else {
                browser.loot.reveal(keep)
            }
            return nil
        case "downloads.showDefaultFolder":
            NSWorkspace.shared.open(browser.prefs.downloads)
            return nil
        case "downloads.erase":
            return []
        case "downloads.pause", "downloads.resume", "downloads.cancel", "downloads.removeFile", "downloads.getFileIcon":
            throw Unsupported(what: "\(api) isn't available in Search yet")

        // MARK: side panel — a tab of its own, since this window has one column
        case "sidePanel.setOptions":
            if let path = (first as? [String: Any])?["path"] as? String { panelPath[id] = path }
            return nil
        case "sidePanel.getOptions":
            return ["enabled": true, "path": panelPath[id] ?? defaultPanel(context) ?? ""]
        case "sidePanel.setPanelBehavior":
            if let on = (first as? [String: Any])?["openPanelOnActionClick"] as? Bool {
                if on { panelOnClick.insert(id) } else { panelOnClick.remove(id) }
            }
            return nil
        case "sidePanel.getPanelBehavior":
            return ["openPanelOnActionClick": panelOnClick.contains(id)]
        case "sidePanel.open":
            openPanel(context, owner: owner)
            return nil

        // MARK: offscreen — a page with a DOM for a worker that has none
        // MARK: capture — a stream id for the worker's chooseDesktopMedia
        case "capture.grant":
            return await ExtensionCapture.shared.grant(for: context)

        case "offscreen.createDocument":
            guard let path = (first as? [String: Any])?["url"] as? String
            else { throw Unsupported(what: "No page for the offscreen document") }
            let reasons = (first as? [String: Any])?["reasons"] as? [String] ?? []
            try await ExtensionOffscreen.create(path, reasons: reasons, for: context)
            return nil
        case "offscreen.closeDocument":
            ExtensionOffscreen.close(for: id)
            return nil
        case "offscreen.hasDocument":
            return ExtensionOffscreen.hasDocument(for: id)
        case "offscreen.sendMessage":
            guard args.count == 3, let token = first as? String,
                  let sender = args[2] as? [String: Any] else { return ["handled": false] }
            return try await ExtensionOffscreen.send(args[1], sender: sender, token: token, for: id)

        // MARK: fonts — what the Mac has; the page's own fonts stay the page's
        case "fontSettings.getFontList":
            return NSFontManager.shared.availableFontFamilies.map { ["fontId": $0, "displayName": $0] }
        case "fontSettings.getFont":
            return ["fontId": "", "levelOfControl": "not_controllable"]
        case "fontSettings.getDefaultFontSize":
            return ["pixelSize": 16, "levelOfControl": "not_controllable"]
        case "fontSettings.getDefaultFixedFontSize":
            return ["pixelSize": 13, "levelOfControl": "not_controllable"]
        case "fontSettings.getMinimumFontSize":
            return ["pixelSize": 0, "levelOfControl": "not_controllable"]
        case _ where api.hasPrefix("fontSettings.set") || api.hasPrefix("fontSettings.clear"):
            return nil

        // MARK: management — only itself
        case "management.getSelf", "management.get":
            let found = context.webExtension
            return ["id": id, "name": found.displayName ?? "", "shortName": found.displayShortName ?? "",
                    "version": found.version ?? "", "description": found.displayDescription ?? "",
                    "enabled": true, "type": "extension", "installType": id.hasPrefix("local-") ? "development" : "normal",
                    "mayDisable": true, "offlineEnabled": true, "isApp": false, "hostPermissions": [], "permissions": []]
        case "management.getAll":
            return []
        case "management.setEnabled", "management.uninstallSelf":
            throw Unsupported(what: "Extensions are turned on and off in Settings › Extensions")

        // MARK: language
        case "i18n.detectLanguage":
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(first as? String ?? "")
            let guesses = recognizer.languageHypotheses(withMaximum: 3)
            return ["isReliable": (guesses.values.max() ?? 0) > 0.6,
                    "languages": guesses.sorted { $0.value > $1.value }.map { ["language": $0.key.rawValue, "percentage": Int($0.value * 100)] }]
        case "runtime.getContexts":
            // The extension's own pages that Chrome would list: its worker,
            // its popup while it is up, its offscreen document. Bitwarden
            // asks for these to know where to send its messages.
            let filter = first as? [String: Any] ?? [:]
            let types = filter["contextTypes"] as? [String]
            let urls = filter["documentUrls"] as? [String]
            var found: [[String: Any]] = []
            func add(_ type: String, _ url: URL?) {
                guard types == nil || types!.contains(type) else { return }
                let address = url?.absoluteString ?? ""
                guard urls == nil || urls!.contains(address) else { return }
                found.append([
                    "contextType": type, "contextId": "\(id)-\(type)", "tabId": -1, "windowId": -1,
                    "frameId": type == "BACKGROUND" ? -1 : 0, "documentUrl": address,
                    "documentOrigin": url.map { "\($0.scheme ?? "")://\($0.host ?? "")" } ?? "",
                    "incognito": false,
                ])
            }
            if context.webExtension.hasBackgroundContent {
                let manifest = context.webExtension.manifest["background"] as? [String: Any] ?? [:]
                let script = manifest["service_worker"] as? String ?? manifest["page"] as? String
                add("BACKGROUND", script.map { context.baseURL.appendingPathComponent($0) })
            }
            if ExtensionPopup.shared.extensionID == id { add("POPUP", ExtensionPopup.shared.view?.url) }
            found += ExtensionOffscreen.contexts(for: id, matching: filter)
            return found

        // MARK: notifications — the Mac's own
        case "notifications.create":
            let named = first as? String
            let options = (named == nil ? first : (args.count > 1 ? args[1] : nil)) as? [String: Any] ?? [:]
            let key = named ?? UUID().uuidString
            let center = UNUserNotificationCenter.current()
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            let content = UNMutableNotificationContent()
            content.title = options["title"] as? String ?? (context.webExtension.displayName ?? "")
            content.body = options["message"] as? String ?? ""
            content.subtitle = context.webExtension.displayName ?? ""
            try? await center.add(UNNotificationRequest(identifier: "\(id).\(key)", content: content, trigger: nil))
            return key
        case "notifications.clear":
            if let key = first as? String {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["\(id).\(key)"])
            }
            return true
        case "notifications.getAll":
            return [String: Any]()
        case "notifications.getPermissionLevel":
            return "granted"
        case "notifications.update":
            return false

        // MARK: speech
        case "tts.speak":
            let options = (args.count > 1 ? args[1] : nil) as? [String: Any] ?? [:]
            if !(options["enqueue"] as? Bool ?? false) { speaker.stopSpeaking() }
            if let voice = options["voiceName"] as? String,
               let match = NSSpeechSynthesizer.availableVoices.first(where: { NSSpeechSynthesizer.attributes(forVoice: $0)[.name] as? String == voice }) {
                speaker.setVoice(match)
            }
            if let rate = options["rate"] as? Double { speaker.rate = Swift.Float(180 * rate) }
            speaker.startSpeaking(first as? String ?? "")
            return nil
        case "tts.stop":
            speaker.stopSpeaking()
            return nil
        case "tts.pause":
            speaker.pauseSpeaking(at: .immediateBoundary)
            return nil
        case "tts.resume":
            speaker.continueSpeaking()
            return nil
        case "tts.isSpeaking":
            return speaker.isSpeaking
        case "tts.getVoices":
            return NSSpeechSynthesizer.availableVoices.map { voice -> [String: Any] in
                let attributes = NSSpeechSynthesizer.attributes(forVoice: voice)
                return ["voiceName": attributes[.name] as? String ?? voice.rawValue,
                        "lang": (attributes[.localeIdentifier] as? String ?? "").replacingOccurrences(of: "_", with: "-"),
                        "remote": false, "eventTypes": ["start", "end"]]
            }

        // MARK: the worker, up before a page talks to it
        case "background.wake":
            guard context.webExtension.hasBackgroundContent else { return nil }
            // WebKit sometimes fails to start a worker again after unloading
            // it, and then never tries again: every message waits for ever.
            // Tried twice more, then the extension is taken up afresh.
            for attempt in 0..<3 {
                // WebKit never calls back after some failed starts; eight
                // seconds without an answer counts as a failure.
                let error: Error? = await withCheckedContinuation { done in
                    var finished = false
                    let finish: (Error?) -> Void = { result in
                        guard !finished else { return }
                        finished = true
                        done.resume(returning: result)
                    }
                    context.loadBackgroundContent { error in MainActor.assumeIsolated { finish(error) } }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { finish(Unsupported(what: "no answer from WebKit")) }
                }
                guard error != nil else { return nil }
                if attempt < 2 { try? await Task.sleep(for: .milliseconds(400)) }
            }
            owner.revive(id, because: "its worker wouldn't start")
            return nil
        // Whether this extension was loaded before in this run of the
        // browser — an "install" then is really a restart (see the shim).
        case "background.loadedBefore":
            return owner.loadedBefore.contains(id)
        // A page found the worker gone though WebKit believes it runs (see
        // the shim's ping).
        case "background.revive":
            owner.revive(id, because: "its worker stopped answering")
            return nil

        // MARK: what went wrong inside
        case "debug.error":
            owner.noteError(first as? String ?? "?", for: id)
            return nil

        // MARK: its own pages, for clients.matchAll() (see the shim)
        case "clients.pages":
            var pages: [[String: Any]] = []
            if let popup = ExtensionPopup.shared.client(of: id) { pages.append(popup) }
            for tab in browser.tabs {
                guard let web = tab.built, let url = web.url, Browser.extensionHost(of: url) == id else { continue }
                let shown = tab.id == browser.activeID && web.window?.occlusionState.contains(.visible) == true
                pages.append(["id": tab.id.uuidString, "url": url.absoluteString, "visible": shown, "focused": shown && web.window?.isKeyWindow == true])
            }
            // Its offscreen document too, as Chrome lists it.
            if let url = ExtensionOffscreen.url(for: id) { pages.append(["id": "offscreen", "url": url.absoluteString, "visible": false, "focused": false]) }
            return pages

        // MARK: the button's popup
        case "action.popup":
            let path = first as? String ?? ""
            let index = args.dropFirst().first as? Int ?? -1
            if index >= 0, owner.visibleTabs.indices.contains(index) {
                popups[id, default: [:]][owner.visibleTabs[index].id.uuidString] = path
            } else {
                popups[id, default: [:]]["*"] = path
                popups[id] = popups[id]?.filter { $0.key == "*" }
            }
            return nil

        // MARK: script injection and user scripts
        case "scripting.file":
            return try scriptingFile(first as? String ?? "", arguments: args.dropFirst().first as? [Any] ?? [], in: Extensions.folder(for: id))
        case "userScripts.file":
            return try userScriptFile(first as? [String: Any] ?? [:], in: Extensions.folder(for: id))
        case "userScripts.list":
            return (try? JSONSerialization.jsonObject(with: Data(contentsOf: Extensions.folder(for: id).appendingPathComponent("_search/userscripts.json")))) ?? []
        case "userScripts.save":
            let folder = Extensions.folder(for: id).appendingPathComponent("_search", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let scripts = first as? [[String: Any]] ?? []
            try JSONSerialization.data(withJSONObject: scripts).write(to: folder.appendingPathComponent("userscripts.json"), options: .atomic)
            // Files no saved script is written in any more, once a moment
            // has passed — one being injected right now is left alone.
            let keep = Set(scripts.compactMap { try? userScriptFile($0, in: Extensions.folder(for: id)) }.map { URL(fileURLWithPath: $0).lastPathComponent })
            for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            where file.lastPathComponent.hasPrefix("us-") && !keep.contains(file.lastPathComponent) {
                let age = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { -$0.timeIntervalSinceNow } ?? 999
                if age > 60 { try? FileManager.default.removeItem(at: file) }
            }
            return nil
        case "userScripts.world", "userScripts.worlds":
            let url = Extensions.folder(for: id).appendingPathComponent("_search/worlds.json")
            var worlds = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [[String: Any]] ?? []
            if api == "userScripts.worlds" { return worlds }
            let props = first as? [String: Any] ?? [:]
            let world = props["worldId"] as? String ?? ""
            worlds.removeAll { ($0["worldId"] as? String ?? "") == world }
            if props["reset"] as? Bool != true { worlds.append(props) }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: worlds).write(to: url, options: .atomic)
            return nil

        // MARK: permissions Search grants itself
        case "permissions.granted":
            return Store.settings.stringArray(forKey: "extensions.granted.\(id)") ?? []
        case "permissions.request":
            let wanted = (first as? [String]) ?? []
            // As in Chrome: only what the manifest named, as a permission or
            // an optional one. What was agreed to at install still describes
            // the extension; it can't ask later for something it never named.
            let manifest = context.webExtension.manifest
            let named = Set(((manifest["permissions"] as? [Any] ?? []) + (manifest["optional_permissions"] as? [Any] ?? [])).compactMap { $0 as? String })
            guard wanted.allSatisfy(named.contains) else {
                throw Unsupported(what: "Only permissions specified in the manifest may be requested.")
            }
            // Those Chrome grants without a word, having nothing to warn of.
            let silent: Set<String> = ["tabGroups", "sidePanel", "offscreen", "idle", "power", "fontSettings", "search",
                                       "system.cpu", "system.memory", "system.display", "favicon"]
            let names = wanted.map { $0.replacingOccurrences(of: ".", with: " ") }.joined(separator: ", ")
            let yes = wanted.allSatisfy(silent.contains) ? true : await owner.ask(more: names, context: context)
            guard yes else { return false }
            let had = Store.settings.stringArray(forKey: "extensions.granted.\(id)") ?? []
            Store.settings.set(Array(Set(had + wanted)).sorted(), forKey: "extensions.granted.\(id)")
            return true
        case "permissions.afterClick":
            // permissions.request for WebKit's own permissions and sites,
            // made from a click on the extension's button whose moment
            // WebKit lost while the shim filled in the tab it was given
            // (see `mend`). Only within seconds of that click, once, and
            // only what the manifest names, asked as WebKit would ask it.
            guard let when = Extensions.clicked[id], Date().timeIntervalSince(when) < 10 else {
                throw Unsupported(what: "Invalid call to permissions.request(). Must be called during a user gesture.")
            }
            Extensions.clicked[id] = nil
            let found = context.webExtension
            let wanted = ((first as? [String]) ?? []).map { WKWebExtension.Permission(rawValue: $0) }
            let origins = ((args.dropFirst().first as? [String]) ?? []).compactMap { try? WKWebExtension.MatchPattern(string: $0) }
                .filter { !Extensions.reachesExtensions($0) }
            let named = found.requestedPermissions.union(found.optionalPermissions)
            // Sites as the manifest names them, optional ones included —
            // which allRequestedMatchPatterns leaves out.
            let places = Set(found.allRequestedMatchPatterns.union(found.optionalPermissionMatchPatterns).map(\.string))
            guard wanted.allSatisfy(named.contains), origins.allSatisfy({ places.contains($0.string) }) else {
                throw Unsupported(what: "Only permissions specified in the manifest may be requested.")
            }
            let missing = wanted.filter { context.permissionStatus(for: $0) != .grantedExplicitly }
            let unreached = origins.filter { context.permissionStatus(for: $0) != .grantedExplicitly }
            guard !missing.isEmpty || !unreached.isEmpty else { return true }
            let every = unreached.contains { $0.matchesAllHosts || $0.matchesAllURLs }
            let sites = every ? "every website" : unreached.map(\.string).sorted().joined(separator: ", ")
            let question = unreached.isEmpty ? "asks for more access" : "wants to read and change \(sites)"
            let detail = missing.isEmpty ? "Until you remove the extension." : missing.map(\.rawValue).sorted().joined(separator: ", ")
            guard await owner.ask(question, detail: detail, context: context) else { return false }
            for permission in missing { context.setPermissionStatus(.grantedExplicitly, for: permission) }
            for pattern in unreached { context.setPermissionStatus(.grantedExplicitly, for: pattern) }
            Extensions.fence(context)
            return true
        case "permissions.remove":
            let gone = Set((first as? [String]) ?? [])
            let had = Store.settings.stringArray(forKey: "extensions.granted.\(id)") ?? []
            Store.settings.set(had.filter { !gone.contains($0) }, forKey: "extensions.granted.\(id)")
            return true

        // MARK: tabs, by where they are in the row
        case "tabs.describe":
            let places: [Any] = first as? [Any] ?? []
            return places.map { place -> Any in
                guard let tab = located(place, owner: owner) else { return NSNull() }
                // A private tab stays blank to an extension not let into
                // them, as WebKit is told (see ExtensionTab.hidden).
                if tab.shy, !context.hasAccessToPrivateData { return ["url": "", "title": ""] }
                // Another extension's page stays blank, as WebKit keeps it
                // (see the refusal in Extensions.load); its own are its own.
                if let url = tab.address, let scheme = url.scheme?.lowercased(),
                   [Extensions.scheme, Extensions.formerScheme].contains(scheme), url.host() != id {
                    return ["url": "", "title": ""]
                }
                var described: [String: Any] = ["url": tab.address?.absoluteString ?? "", "title": tab.title]
                if let icon = favIconURL(tab) { described["favIconUrl"] = icon }
                return described
            }
        case "tabs.move", "tabs.discard", "tabs.activate":
            guard let tab = located(first, owner: owner), let browser = owner.browser(of: tab) else { throw Unsupported(what: "No tab there") }
            let visible = owner.visibleTabs(of: browser)
            switch api {
            case "tabs.move":
                let wanted = args.dropFirst().first as? Int ?? -1
                let target = visible[wanted < 0 || wanted >= visible.count ? visible.count - 1 : wanted]
                if let index = browser.tabs.firstIndex(where: { $0.id == target.id }) { browser.move(tab, to: index) }
            case "tabs.discard":
                if tab.id != browser.activeID { browser.sleep(tab) }
            default:
                browser.activateForExtension(tab)
            }
            return nil

        // MARK: search
        case "search.query":
            let spec = first as? [String: Any] ?? [:]
            // Words to search for, as in Chrome — never an address, file:
            // and data: included, which the address field would take.
            guard let url = browser.searchURL(for: spec["text"] as? String ?? "") else { return nil }
            switch spec["disposition"] as? String {
            case "NEW_TAB", "NEW_WINDOW": browser.open(url, foreground: true)
            default: browser.visit(url)
            }
            return nil

        // MARK: idle
        case "idle.queryState":
            let threshold = (first as? Double) ?? 60
            if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
               session["CGSSessionScreenIsLocked"] as? Bool == true { return "locked" }
            let quiet = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
            return quiet >= threshold ? "idle" : "active"
        case "idle.getAutoLockDelay":
            return 0

        // MARK: power
        case "power.requestKeepAwake":
            let display = (first as? String) == "display"
            if let old = awake[id] { IOPMAssertionRelease(old) }
            var assertion: IOPMAssertionID = 0
            let kind = (display ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep) as CFString
            if IOPMAssertionCreateWithName(kind, IOPMAssertionLevel(kIOPMAssertionLevelOn), "An extension in Search" as CFString, &assertion) == kIOReturnSuccess {
                awake[id] = assertion
            }
            return nil
        case "power.releaseKeepAwake":
            if let old = awake.removeValue(forKey: id) { IOPMAssertionRelease(old) }
            return nil
        case "power.reportActivity":
            var assertion: IOPMAssertionID = 0
            IOPMAssertionDeclareUserActivity("An extension in Search" as CFString, kIOPMUserActiveLocal, &assertion)
            return nil

        // MARK: browsing data
        case "browsingData.settings":
            return ["options": ["since": 0], "dataToRemove": [:], "dataRemovalPermitted": [
                "cache": true, "cookies": true, "history": true, "downloads": true, "localStorage": true,
                "indexedDB": true, "serviceWorkers": true, "cacheStorage": true, "fileSystems": true, "webSQL": true,
            ]]
        case let api where api.hasPrefix("browsingData."):
            let options = first as? [String: Any] ?? [:]
            let what: [String: Bool]
            if api == "browsingData.remove" {
                what = (args.dropFirst().first as? [String: Any] ?? [:]).compactMapValues { $0 as? Bool }
            } else {
                let key = String(api.dropFirst("browsingData.remove".count))
                what = [key.prefix(1).lowercased() + key.dropFirst(): true]
            }
            try await clear(what, options: options, browser: browser)
            return nil

        // MARK: sessions — the tabs you closed
        case "sessions.getRecentlyClosed":
            let limit = (first as? [String: Any])?["maxResults"] as? Int ?? 25
            return browser.ghosts.reversed().prefix(limit).map { ghost in
                ["lastModified": Int(Date().timeIntervalSince1970),
                 "tab": ["sessionId": ghost.id.uuidString, "url": ghost.url.absoluteString, "title": ghost.title,
                         "index": ghost.index, "windowId": 1, "active": false, "pinned": false, "highlighted": false,
                         "incognito": false, "selected": false, "discarded": false, "autoDiscardable": true, "groupId": -1]] as [String: Any]
            }
        case "sessions.getDevices":
            return []
        case "sessions.restore":
            let ghost = (first as? String).flatMap { key in browser.ghosts.first { $0.id.uuidString == key } } ?? browser.ghosts.last
            guard let ghost else { throw Unsupported(what: "Nothing to restore") }
            browser.reopen(ghost)
            return ["lastModified": Int(Date().timeIntervalSince1970),
                    "tab": ["url": ghost.url.absoluteString, "title": ghost.title, "index": ghost.index, "windowId": 1]]

        // MARK: top sites — the most visited in history
        case "topSites.get":
            var visits: [String: (url: URL, title: String, count: Int)] = [:]
            for trace in browser.history.everything() {
                guard let host = trace.url.host() else { continue }
                visits[host, default: (trace.url, trace.title, 0)].count += 1
            }
            return visits.values.sorted { $0.count > $1.count }.prefix(10).map {
                ["url": $0.url.absoluteString, "title": $0.title]
            }

        // MARK: reading list — none kept
        case "readingList.query":
            return []
        case "readingList.addEntry", "readingList.removeEntry", "readingList.updateEntry":
            throw Unsupported(what: "Search has no reading list")

        // MARK: system
        case "system.cpu.getInfo":
            #if arch(x86_64)
            let (arch, model) = ("x86_64", "Intel")
            #else
            let (arch, model) = ("arm64", "Apple silicon")
            #endif
            return ["numOfProcessors": ProcessInfo.processInfo.processorCount, "archName": arch,
                    "modelName": model, "features": [], "processors": [], "temperatures": []]
        case "system.memory.getInfo":
            return ["capacity": Double(ProcessInfo.processInfo.physicalMemory), "availableCapacity": Double(ProcessInfo.processInfo.physicalMemory) / 2]
        case "system.storage.getInfo":
            return []
        case "system.display.getInfo":
            return NSScreen.screens.enumerated().map { index, screen in
                let f = screen.frame, v = screen.visibleFrame
                return ["id": String(index), "name": screen.localizedName, "isPrimary": index == 0, "isInternal": index == 0,
                        "isEnabled": true, "dpiX": 96 * screen.backingScaleFactor, "dpiY": 96 * screen.backingScaleFactor,
                        "rotation": 0, "bounds": ["left": f.minX, "top": f.minY, "width": f.width, "height": f.height],
                        "workArea": ["left": v.minX, "top": v.minY, "width": v.width, "height": v.height]] as [String: Any]
            }

        // MARK: tab groups
        // Only while they are on (Settings › Tabs): off, they sleep, for
        // extensions as on screen. A group without a tab is never shown.
        case "tabs.groups":
            let places: [Any] = first as? [Any] ?? []
            return places.map { place -> Int in
                guard browser.prefs.usesTabGroups, let tab = located(place, owner: owner),
                      let home = owner.browser(of: tab), let group = home.group(of: tab) else { return -1 }
                return TabGroup.number(group)
            }
        case "tabGroups.query":
            let spec = first as? [String: Any] ?? [:]
            return listedGroups(browser).filter { group in
                (spec["title"] as? String).map { $0 == group.name } ?? true
                    && (spec["collapsed"] as? Bool).map { $0 == group.collapsed } ?? true
                    && (spec["color"] as? String).map { $0 == "grey" } ?? true
            }.map(chromeGroup)
        case "tabGroups.get":
            return chromeGroup(try listedGroup(first, in: browser))
        case "tabGroups.update":
            let group = try listedGroup(first, in: browser)
            let props = args.dropFirst().first as? [String: Any] ?? [:]
            if let title = props["title"] as? String { browser.renameTabGroup(group.id, to: title) }
            if let collapsed = props["collapsed"] as? Bool, collapsed != group.collapsed { browser.toggleTabGroup(group.id) }
            return chromeGroup(browser.tabGroups.first { $0.id == group.id } ?? group)
        case "tabGroups.move":
            throw Unsupported(what: "Search can't move a tab group for an extension")
        case "tabs.group":
            guard browser.prefs.usesTabGroups else { throw Unsupported(what: "Tab groups are off in Search's settings") }
            let places: [Any] = first as? [Any] ?? []
            let tabs = places.compactMap { located($0, owner: owner) }
            guard !tabs.isEmpty else { throw Unsupported(what: "No tabs to group") }
            // A group is one window's, as in Chrome.
            guard let browser = owner.browser(of: tabs[0]), tabs.allSatisfy({ owner.browser(of: $0) === browser }) else {
                throw Unsupported(what: "Tabs from different windows can't share a group")
            }
            // Pins and private tabs are never in a group in Search.
            guard tabs.allSatisfy({ $0.pin == nil && !$0.shy }) else {
                throw Unsupported(what: "Pinned and private tabs can't be grouped")
            }
            let target: UUID
            if let number = args.dropFirst().first as? Int, number != -1 {
                target = try listedGroup(number, in: browser).id
            } else {
                // A new group, as its menu makes one, without its name to type.
                target = browser.addTabGroup(containing: tabs[0])
                browser.editingGroupID = nil
            }
            for tab in tabs { browser.move(tab, toGroup: target) }
            return TabGroup.number(target)
        case "tabs.ungroup":
            guard browser.prefs.usesTabGroups else { return nil }
            let places: [Any] = first as? [Any] ?? []
            for tab in places.compactMap({ located($0, owner: owner) }) {
                owner.browser(of: tab)?.move(tab, toGroup: nil)
            }
            return nil

        // MARK: identity
        case "identity.launchWebAuthFlow":
            let spec = first as? [String: Any] ?? [:]
            guard let url = (spec["url"] as? String).flatMap(URL.init(string:)) else { throw Unsupported(what: "No authorization url") }
            return try await ExtensionAuth.run(url, extension: id, browser: browser).absoluteString
        case "identity.getProfileUserInfo":
            return ["email": "", "id": ""]
        case "identity.removeCachedAuthToken", "identity.clearAllCachedAuthTokens":
            return nil
        case "identity.getAuthToken":
            throw Unsupported(what: "getAuthToken needs a Google account signed into Chrome; this extension would need launchWebAuthFlow instead")

        default:
            throw Unsupported(what: "\(api) isn't available in Search")
        }
    }

    // MARK: - the side panel

    /// A function sent by an extension page inside a website's frame cannot
    /// survive the JSON message to its worker. Write it as a file for WebKit's
    /// scripting API, with its JSON arguments and final result intact.
    static func scriptingFile(_ function: String, arguments: [Any], in folder: URL) throws -> String {
        // A megabyte of source at most: a page gone wrong can't fill the
        // extension's folder with big files (Security).
        guard !function.isEmpty, function.utf8.count <= 1_000_000, JSONSerialization.isValidJSONObject(arguments),
              let data = try? JSONSerialization.data(withJSONObject: arguments),
              let args = String(data: data, encoding: .utf8)
        else { throw Unsupported(what: "Invalid script function or arguments") }
        let source = "(\(function))(...\(args))\n"
        let name = "script-" + SHA256.hash(data: Data(source.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined() + ".js"
        let dir = folder.appendingPathComponent("_search", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) { try source.write(to: url, atomically: true, encoding: .utf8) }
        for old in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where old.lastPathComponent.hasPrefix("script-") && old != url {
            let age = (try? old.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { -$0.timeIntervalSinceNow } ?? 0
            if age > 60 { try? FileManager.default.removeItem(at: old) }
        }
        return "_search/" + name
    }

    /// A user script as a file WebKit can inject: its code — inline, or read
    /// from the extension's own files — inside a block that leaves at once
    /// on a page its globs rule out and, for Chrome's USER_SCRIPT world,
    /// gives the code a `chrome` whose messages are marked as a user
    /// script's. Named by what is in it, so a changed script is a new file
    /// and never a stale one WebKit has already read.
    static func userScriptFile(_ script: [String: Any], in folder: URL) throws -> String {
        let json = { (value: Any) in
            (try? JSONSerialization.data(withJSONObject: value)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        }
        var code = ""
        for source in script["js"] as? [[String: Any]] ?? [] {
            if let inline = source["code"] as? String {
                code += inline + "\n;\n"
            } else if let file = source["file"] as? String,
                      // One of the extension's own files, and nothing outside
                      // its folder: a name is resolved before it is read.
                      let path = inside(file, of: folder),
                      let text = try? String(contentsOf: path, encoding: .utf8) {
                code += text + "\n;\n"
            }
        }
        let userWorld = (script["world"] as? String) != "MAIN"
        let prelude = #"""
          const chrome = (() => {
            const runtime = globalThis.chrome.runtime;
            return { runtime: {
              id: runtime.id, getURL: (path) => runtime.getURL(path), get lastError() { return runtime.lastError; },
              sendMessage: (message, ...rest) => runtime.sendMessage({ __searchUserScript: true, message }, ...rest.filter((r) => typeof r === "function" || (r && typeof r === "object"))),
              connect: (info) => runtime.connect({ ...(info || {}), name: "search-us:" + ((info && info.name) || "") }),
            } };
          })();
          const browser = chrome;
        """#
        let text = #"""
        /* Search: a user script (chrome.userScripts) */
        search_user_script: {
          const __searchHref = location.href;
          const __searchGlob = (g) => new RegExp("^" + g.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*").replace(/\?/g, ".") + "$");
          const __searchIn = \#(json(script["includeGlobs"] ?? [])), __searchOut = \#(json(script["excludeGlobs"] ?? []));
          if ((__searchIn.length && !__searchIn.some((g) => __searchGlob(g).test(__searchHref))) || __searchOut.some((g) => __searchGlob(g).test(__searchHref))) break search_user_script;
        \#(userWorld ? prelude : "")
        \#(code)
        }
        """#
        let name = "us-" + SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined() + ".js"
        let dir = folder.appendingPathComponent("_search", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) { try text.write(to: url, atomically: true, encoding: .utf8) }
        return "_search/" + name
    }

    /// Popups extensions set for their buttons: per tab, or "*" for all.
    static var popups: [String: [String: String]] = [:]
    /// Downloads an extension asked for, by address, until they land; then
    /// the files they became, which are the only ones it may open.
    static var askedDownloads: [URL: String] = [:]
    static var ownDownloads: [String: Set<String>] = [:]

    /// Keep-awake assertions, one per extension that asked.
    static var awake: [String: IOPMAssertionID] = [:]

    /// chrome.privacy and chrome.proxy: what each extension set, kept across
    /// launches as Chrome keeps it. Search acts on one of them — an
    /// extension turning the browser's own offer to save passwords off,
    /// which is how every password manager asks Chrome to step aside.
    private static func setting(_ api: String, _ details: [String: Any], extension id: String, owner: Extensions) -> Any? {
        let parts = api.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let name = parts[1]
        var mine = Extensions.settings(for: id)
        switch parts[0] {
        case "setting.set":
            mine[name] = details["value"]
        case "setting.clear":
            mine[name] = nil
        default:
            let value = mine[name] ?? defaultSetting(name, owner: owner)
            return ["value": value ?? NSNull(), "levelOfControl": mine[name] != nil ? "controlled_by_this_extension" : "controllable_by_this_extension"]
        }
        Extensions.setSettings(mine, for: id)
        owner.objectWillChange.send()
        return nil
    }

    private static func defaultSetting(_ name: String, owner: Extensions) -> Any? {
        switch name {
        case "privacy.services.passwordSavingEnabled": return owner.browser?.prefs.savesPasswords ?? true
        case "privacy.network.webRTCIPHandlingPolicy": return "default"
        case "privacy.websites.doNotTrackEnabled", "privacy.websites.adMeasurementEnabled",
             "privacy.websites.fledgeEnabled", "privacy.websites.topicsEnabled",
             "privacy.services.safeBrowsingExtendedReportingEnabled": return false
        case "proxy.settings": return ["mode": "system"]
        default: return true
        }
    }

    /// chrome.browsingData, from what WebKit and Search keep.
    private static func clear(_ what: [String: Bool], options: [String: Any], browser: Browser) async throws {
        let since = Date(timeIntervalSince1970: (options["since"] as? Double ?? 0) / 1000)
        let origins = (options["origins"] as? [String])?.compactMap { URL(string: $0)?.host() }
        var types = Set<String>()
        let map: [String: [String]] = [
            "cache": [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache],
            "cacheStorage": [WKWebsiteDataTypeFetchCache], "appcache": [WKWebsiteDataTypeOfflineWebApplicationCache],
            "cookies": [WKWebsiteDataTypeCookies], "localStorage": [WKWebsiteDataTypeLocalStorage, WKWebsiteDataTypeSessionStorage],
            "indexedDB": [WKWebsiteDataTypeIndexedDBDatabases], "serviceWorkers": [WKWebsiteDataTypeServiceWorkerRegistrations],
            "webSQL": [WKWebsiteDataTypeWebSQLDatabases], "fileSystems": [WKWebsiteDataTypeFileSystem],
        ]
        for (key, on) in what where on { types.formUnion(map[key] ?? []) }
        let store = Store.websites
        if !types.isEmpty {
            if let origins {
                let records = await store.dataRecords(ofTypes: types)
                let hit = records.filter { record in origins.contains { $0 == record.displayName || $0.hasSuffix("." + record.displayName) } }
                await store.removeData(ofTypes: types, for: hit)
            } else {
                await store.removeData(ofTypes: types, modifiedSince: since)
            }
        }
        if what["history"] == true, origins == nil {
            for trace in browser.history.everything() where trace.last >= since { browser.history.forget(trace.key) }
        }
    }

    static func defaultPanel(_ context: WKWebExtensionContext) -> String? {
        (context.webExtension.manifest["side_panel"] as? [String: Any])?["default_path"] as? String
    }

    /// One of the extension's own pages, from the path it gave: resolved
    /// rather than appended, since a path can carry a query (Claude's side
    /// panel names its tab, sidepanel.html?tabId=…), which appended would be
    /// escaped into the file's name. Never anywhere but inside the
    /// extension: a full address given as a "path" is refused.
    static func page(_ path: String, in context: WKWebExtensionContext) -> URL? {
        let base = context.baseURL
        guard let url = URL(string: path.trimmingCharacters(in: CharacterSet(charactersIn: "/")), relativeTo: base)?.absoluteURL,
              url.scheme == base.scheme, url.host == base.host
        else { return nil }
        return url
    }

    static func openPanel(_ context: WKWebExtensionContext, owner: Extensions) {
        guard let path = panelPath[context.uniqueIdentifier] ?? defaultPanel(context) else { return }
        // Resolved, not appended: a path can carry a query — Claude's names
        // the tab its panel is for, sidepanel.html?tabId=… — which appended
        // would be escaped into the file's name.
        guard let url = ExtensionShims.page(path, in: context) else { return }
        owner.browser?.open(url, foreground: true)
    }

    // MARK: - bookmarks, as Chrome shapes them

    private typealias Hit = (node: Bookmark, parent: String, index: Int)

    private static func flat(_ nodes: [Bookmark], parent: String = "1") -> [Hit] {
        nodes.enumerated().flatMap { index, n -> [Hit] in
            [(n, parent, index)] + flat(n.children ?? [], parent: n.id.uuidString)
        }
    }

    private static func find(_ key: String, in nodes: [Bookmark]) -> Hit? {
        flat(nodes).first { $0.node.id.uuidString == key }
    }

    private static func node(_ n: Bookmark, parent: String, index: Int, deep: Bool) -> [String: Any] {
        var out: [String: Any] = ["id": n.id.uuidString, "parentId": parent, "index": index, "title": n.title,
                                  "dateAdded": 0, "syncing": false]
        if let url = n.url { out["url"] = url }
        if n.isFolder {
            out["dateGroupModified"] = 0
            if deep {
                out["children"] = (n.children ?? []).enumerated().map { node($1, parent: n.id.uuidString, index: $0, deep: true) }
            }
        }
        return out
    }

    private static func bar(_ roots: [Bookmark], deep: Bool = true) -> [String: Any] {
        var out: [String: Any] = ["id": "1", "parentId": "0", "index": 0, "title": "Bookmarks", "dateAdded": 0,
                                  "folderType": "bookmarks-bar", "syncing": false]
        if deep { out["children"] = roots.enumerated().map { node($1, parent: "1", index: $0, deep: true) } }
        return out
    }

    private static func root(_ roots: [Bookmark]) -> [String: Any] {
        ["id": "0", "title": "", "dateAdded": 0, "syncing": false, "children": [bar(roots)]]
    }

    private static func visit(_ trace: History.Trace) -> [String: Any] {
        ["id": trace.key, "url": trace.url.absoluteString, "title": trace.title,
         "lastVisitTime": trace.last.timeIntervalSince1970 * 1000, "visitCount": trace.count, "typedCount": 0]
    }
}

/// chrome.identity.launchWebAuthFlow: a tab for the provider's sign-in, and
/// the moment it tries to go to https://<id>.chromiumapp.org/, that address
/// is the answer and the tab goes. Browser asks `intercept` about every
/// navigation; nothing is ever loaded from chromiumapp.org.
@MainActor
enum ExtensionAuth {
    private static var waiting: [String: (tab: Tab.ID, finish: (Result<URL, Error>) -> Void)] = [:]
    /// One per flow: whether its tab is still somewhere.
    private static var watches: [String: Timer] = [:]

    struct Declined: LocalizedError {
        var errorDescription: String? { "The user did not approve access." }
    }

    static func run(_ url: URL, extension id: String, browser: Browser) async throws -> URL {
        if #available(macOS 15.4, *) { try Extensions.mayOpen(url) }
        return try await withCheckedThrowingContinuation { continuation in
            waiting[id]?.finish(.failure(Declined()))
            let tab = browser.open(url, foreground: true)
            waiting[id] = (tab.id, { result in continuation.resume(with: result) })
            // Closing the tab is saying no. Moved to another window, or to
            // a space not on screen, it is still there.
            watches[id]?.invalidate()
            let started = Date()
            watches[id] = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated {
                    guard let entry = waiting[id], entry.tab == tab.id else {
                        watches.removeValue(forKey: id)?.invalidate()
                        return
                    }
                    // So is ten minutes with nobody finishing: its address is
                    // no longer watched for.
                    guard !exists(entry.tab) || Date().timeIntervalSince(started) > 600 else { return }
                    waiting[id] = nil
                    watches.removeValue(forKey: id)?.invalidate()
                    entry.finish(.failure(Declined()))
                }
            }
        }
    }

    private static func exists(_ id: Tab.ID) -> Bool {
        Browsers.all.contains { browser in
            browser.tabs.contains { $0.id == id } || browser.parked.values.contains { $0.tabs.contains { $0.id == id } }
        }
    }

    /// True when the address is an extension's OAuth redirect arriving in
    /// the tab that began the sign-in, which is then handed over and never
    /// loaded. Any page can go to an address shaped like one of these, and
    /// what it carries would be delivered as the flow's answer: only the
    /// tab the flow was started in may finish it, or a window that tab's
    /// page opened, since some providers finish the sign-in in a popup.
    static func intercept(_ url: URL, browser: Browser, from webView: WKWebView) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host()?.lowercased(), host.hasSuffix(".chromiumapp.org") else { return false }
        let id = String(host.dropLast(".chromiumapp.org".count))
        guard let entry = waiting[id], let from = browser.tab(for: webView),
              from.id == entry.tab || from.opener == entry.tab
        else { return false }
        waiting.removeValue(forKey: id)
        entry.finish(.success(url))
        // The popup, when the answer came in one, goes with the flow's tab:
        // left behind, it would hold a redirect that never loads.
        watches.removeValue(forKey: id)?.invalidate()
        if from.id != entry.tab { browser.close(from) }
        // The flow's tab, in whichever window it is now.
        for home in Browsers.all {
            if let tab = home.tabs.first(where: { $0.id == entry.tab }) { home.close(tab) }
        }
        return true
    }

    /// The same redirect with no launchWebAuthFlow waiting for it. Some
    /// extensions open the provider's page with tabs.create and watch that
    /// tab's address until it reaches their chromiumapp.org one, then close
    /// the tab (Figma's does). In Chrome the navigation fails onto an error
    /// page that still carries the address, and tabs.onUpdated reports it;
    /// in WebKit a failed load never commits, so nothing would. The tab takes
    /// the address without loading anything, for an installed extension
    /// that asked for identity. What each extension sees of it is WebKit's
    /// call, as for any address: tabs or host access, as in Chrome. Left
    /// open, the tab says what Chrome's would.
    static func handOver(_ url: URL, mainFrame: Bool, browser: Browser, from webView: WKWebView) -> Bool {
        guard mainFrame, url.scheme?.lowercased() == "https", let host = url.host()?.lowercased(),
              host.hasSuffix(".chromiumapp.org") else { return false }
        let id = String(host.dropLast(".chromiumapp.org".count))
        guard #available(macOS 15.4, *), let context = Extensions.shared.contexts[id],
              ExtensionShims.allowed(id, context: context).contains("identity"),
              let tab = browser.tab(for: webView)
        else { return false }
        tab.hold(url)
        Task { @MainActor [weak tab] in
            try? await Task.sleep(for: .seconds(4))
            guard let tab, tab.held == url else { return }
            tab.failure = "No site at that address."
        }
        return true
    }
}
