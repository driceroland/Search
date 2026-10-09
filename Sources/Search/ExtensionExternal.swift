import Foundation

// A website talking to an extension that lists it (#496).
//
// An extension's manifest can name websites under `externally_connectable`,
// and those pages may send it messages: claude.ai hands Claude in Chrome its
// sign-in that way, with chrome.runtime.sendMessage(extensionId, …). WebKit
// already does the work: it puts a `browser.runtime` in the page's own world,
// and what a listed page sends reaches the extension's
// runtime.onMessageExternal with the page's origin and address as the sender
// (a page that isn't listed is answered with nothing). What it doesn't do is
// name it `chrome`, the name every page written for Chrome calls.
//
// WebKit gives every page that `browser` once any extension is loaded, so the
// name can't simply follow it: a `chrome` on every site would tell them all
// this is Chrome. Only a page some loaded extension lists, by the same rules
// as Chrome's match patterns, gets `chrome.runtime` — the same two calls,
// with Chrome's callbacks as well as promises — and only if it has no
// `chrome` of its own. The list is read again for every page that loads.

enum ExtensionExternal {
    /// The `externally_connectable` patterns of every extension loaded now,
    /// those Chrome would take and no others.
    @MainActor static var patterns: [String] {
        guard #available(macOS 15.4, *) else { return [] }
        return Extensions.shared.contexts.values.flatMap { context -> [String] in
            let listed = context.webExtension.manifest["externally_connectable"] as? [String: Any]
            return ((listed?["matches"] as? [String]) ?? []).filter(allowed)
        }
    }

    /// Chrome refuses a pattern for every site (`*://*/*`) and a wildcard
    /// over a whole top-level domain (`*.com`): a wildcard needs a domain
    /// with a dot in it, which fails closed where Chrome reads the public
    /// suffix list. Google's sites are left out too: a page there with a
    /// partial `chrome` and a Safari name is what its sign-in and reCAPTCHA
    /// look for to turn a browser away, the reason Search keeps its own
    /// names out of pages (and nothing that needs this lives there).
    nonisolated static func allowed(_ pattern: String) -> Bool {
        guard let start = pattern.range(of: "://") else { return false }
        let scheme = pattern[..<start.lowerBound]
        guard ["*", "http", "https"].contains(scheme) else { return false }
        let rest = pattern[start.upperBound...]
        var host = String(rest.prefix { $0 != "/" }).lowercased()
        guard rest.dropFirst(host.count).hasPrefix("/") else { return false }
        if let colon = host.lastIndex(of: ":"), !host.hasSuffix("]") { host = String(host[..<colon]) }
        guard host != "*", !host.isEmpty else { return false }
        if host.hasPrefix("*.") {
            let base = host.dropFirst(2)
            guard base.contains("."), !base.contains("*") else { return false }
        } else if host.contains("*") {
            return false
        }
        let labels = host.split(separator: ".")
        return !labels.dropLast().contains("google")
    }

    /// For the page about to load, in its own world before any of its
    /// scripts; nil with nothing listed anywhere.
    @MainActor static var script: String? {
        let patterns = Array(Set(patterns)).sorted()
        guard !patterns.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: patterns),
              let list = String(data: data, encoding: .utf8)
        else { return nil }
        return """
        (function (patterns) {
          var made = window.browser, runtime = made && made.runtime;
          if (typeof window.chrome !== 'undefined' || !runtime || typeof runtime.sendMessage !== 'function') return;
          // Chrome's match patterns: scheme, host, then path. A host with a
          // port matches that port only; one without, any.
          var glob = function (text) {
            return new RegExp('^' + text.replace(/[.+?^${}()|[\\]\\\\]/g, '\\\\$&').replace(/\\*/g, '.*') + '$');
          };
          var listed = function (pattern) {
            var parts = /^(\\*|https?):\\/\\/([^\\/]+)(\\/.*)$/.exec(pattern);
            if (!parts) return false;
            var scheme = location.protocol.slice(0, -1);
            if (parts[1] === '*' ? scheme !== 'http' && scheme !== 'https' : parts[1] !== scheme) return false;
            var host = parts[2], port = '';
            var colon = host.lastIndexOf(':');
            if (colon > 0 && host.indexOf(']') < colon) { port = host.slice(colon + 1); host = host.slice(0, colon); }
            if (port && port !== '*' && port !== location.port) return false;
            var here = location.hostname;
            if (host.indexOf('*.') === 0) {
              var base = host.slice(2);
              if (base.indexOf('.') < 0) return false;
              if (here !== base && here.slice(-base.length - 1) !== '.' + base) return false;
            } else if (host !== here) return false;
            return glob(parts[3]).test(location.pathname + location.search);
          };
          if (!patterns.some(listed)) return;
          var chromeRuntime = {
            sendMessage: function (id, message, options, callback) {
              if (typeof options === 'function') { callback = options; options = undefined; }
              var sent = options === undefined ? runtime.sendMessage(id, message) : runtime.sendMessage(id, message, options);
              if (typeof callback !== 'function') return sent;
              Promise.resolve(sent).then(function (reply) { callback(reply); }, function (error) {
                chromeRuntime.lastError = { message: String(error && error.message || error) };
                try { callback(); } finally { delete chromeRuntime.lastError; }
              });
            }
          };
          if (typeof runtime.connect === 'function') {
            chromeRuntime.connect = function () { return runtime.connect.apply(runtime, arguments); };
          }
          try {
            Object.defineProperty(window, 'chrome', {
              value: { runtime: chromeRuntime }, configurable: true, writable: true, enumerable: false
            });
          } catch (e) {}
        })(\(list));
        """
    }
}
