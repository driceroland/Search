// The Application panel's early script, in the page's own world and ahead
// of its scripts while DevTools is open (DeveloperApplicationProbe.swift).
// It counts what can keep a page out of the back/forward cache (unload
// handlers, open sockets, WebRTC connections, capture tracks, broadcast
// channels, IndexedDB transactions) and keeps the reports a
// ReportingObserver sees. `early` says whether it ran before the page's
// scripts. It changes nothing a page does: each hook calls the original.
(early) => {
    const key = Symbol.for("perch.devtools.application");
    if (window[key]) return true;
    const nativeAdd = EventTarget.prototype.addEventListener;
    const nativeRemove = EventTarget.prototype.removeEventListener;
    const handlers = { unload: new Set(), beforeunload: new Set() };
    const sockets = new Set();
    const peers = new Set();
    const tracks = new Set();
    const channels = new Set();
    const closedChannels = new WeakSet();
    let transactions = 0;
    const reports = [];
    let dropped = 0;

    const weak = (value) => (typeof WeakRef === "function" ? new WeakRef(value) : { deref: () => value });
    const live = (set, alive) => {
        let count = 0;
        for (const ref of Array.from(set)) {
            const value = ref.deref();
            if (!value) { set.delete(ref); continue; }
            try { if (alive(value)) count++; else set.delete(ref); } catch { set.delete(ref); }
        }
        return count;
    };

    try {
        EventTarget.prototype.addEventListener = function (type, listener, options) {
            if (this === window && listener && (type === "unload" || type === "beforeunload")) handlers[type].add(listener);
            return nativeAdd.call(this, type, listener, options);
        };
        EventTarget.prototype.removeEventListener = function (type, listener, options) {
            if (this === window && (type === "unload" || type === "beforeunload")) handlers[type].delete(listener);
            return nativeRemove.call(this, type, listener, options);
        };
    } catch {}

    const watchConstructor = (name, track) => {
        const Native = window[name];
        if (typeof Native !== "function") return;
        try {
            window[name] = new Proxy(Native, {
                construct(target, args, newTarget) {
                    const made = Reflect.construct(target, args, newTarget);
                    try { track(made); } catch {}
                    return made;
                },
            });
        } catch {}
    };
    watchConstructor("WebSocket", (socket) => sockets.add(weak(socket)));
    watchConstructor("RTCPeerConnection", (peer) => peers.add(weak(peer)));
    watchConstructor("webkitRTCPeerConnection", (peer) => peers.add(weak(peer)));
    watchConstructor("BroadcastChannel", (channel) => channels.add(weak(channel)));
    try {
        const nativeClose = BroadcastChannel.prototype.close;
        BroadcastChannel.prototype.close = function () {
            closedChannels.add(this);
            return nativeClose.call(this);
        };
    } catch {}
    try {
        const devices = navigator.mediaDevices;
        for (const method of ["getUserMedia", "getDisplayMedia"]) {
            const native = devices && devices[method];
            if (typeof native !== "function") continue;
            devices[method] = function (...args) {
                return native.apply(this, args).then((stream) => {
                    try { for (const track of stream.getTracks()) tracks.add(weak(track)); } catch {}
                    return stream;
                });
            };
        }
    } catch {}
    try {
        const nativeTransaction = IDBDatabase.prototype.transaction;
        IDBDatabase.prototype.transaction = function (...args) {
            const transaction = nativeTransaction.apply(this, args);
            transactions++;
            let done = false;
            const finish = () => { if (!done) { done = true; transactions--; } };
            nativeAdd.call(transaction, "complete", finish);
            nativeAdd.call(transaction, "abort", finish);
            return transaction;
        };
    } catch {}

    const plain = (value, depth) => {
        if (value === null || value === undefined) return null;
        if (typeof value !== "object") return typeof value === "function" ? null : value;
        if (depth > 2) return String(value);
        const out = {};
        for (const name in value) {
            let item;
            try { item = value[name]; } catch { continue; }
            if (typeof item === "function") continue;
            out[name] = plain(item, depth + 1);
        }
        return out;
    };
    const add = (type, url, body, source) => {
        if (reports.length >= 500) { dropped++; return; }
        reports.push({ type: String(type), url: String(url || location.href), body: plain(body, 0), source, time: Date.now() });
    };
    if (typeof ReportingObserver === "function") {
        try {
            new ReportingObserver((list) => {
                for (const report of list) add(report.type, report.url, report.body, "ReportingObserver");
            }, { buffered: true }).observe();
        } catch {}
    }
    nativeAdd.call(document, "securitypolicyviolation", (event) => {
        if (!event.isTrusted) return;
        add("csp-violation", event.documentURI, {
            blockedURL: event.blockedURI, effectiveDirective: event.effectiveDirective, disposition: event.disposition,
            originalPolicy: event.originalPolicy, sourceFile: event.sourceFile, lineNumber: event.lineNumber,
            columnNumber: event.columnNumber, statusCode: event.statusCode, sample: event.sample,
        }, "securitypolicyviolation");
    }, true);

    const snapshot = () => ({
        early,
        unload: handlers.unload.size,
        beforeunload: handlers.beforeunload.size,
        sockets: live(sockets, (socket) => socket.readyState === 0 || socket.readyState === 1),
        peers: live(peers, (peer) => peer.signalingState !== "closed" && peer.connectionState !== "closed"),
        capture: live(tracks, (track) => track.readyState === "live"),
        channels: live(channels, (channel) => !closedChannels.has(channel)),
        transactions: Math.max(0, transactions),
        reports: reports.slice(),
        dropped,
    });
    const clearReports = () => { reports.length = 0; dropped = 0; return true; };
    try {
        Object.defineProperty(window, key, { value: Object.freeze({ snapshot, clearReports }), configurable: false, enumerable: false });
    } catch {}
    return true;
}
