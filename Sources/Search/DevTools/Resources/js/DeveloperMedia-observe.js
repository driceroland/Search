// Perch DevTools › Media: finds the document's <video> and <audio>
// elements (those added later too), logs their media events with the time
// each fired, and sends a description of every player to Perch about twice
// a second while the Media tool is open (its message handler is there).
// Runs in Perch's own content world, at document start, in every frame:
// page scripts can't see or undo it. Elements made outside the document
// (new Audio().play()) are announced by DeveloperMedia-hooks.js, which runs
// in the page's world, through a MouseEvent whose relatedTarget is the
// element (DOM nodes are shared by every world; JS objects aren't).
(() => {
    const KEY = Symbol.for("perch.media");
    const existing = window[KEY];
    if (existing) {
        existing.resync();
        return true;
    }
    const HANDLER = "perchMedia";
    const EVENTS = [
        "loadstart", "durationchange", "loadedmetadata", "loadeddata", "progress", "canplay", "canplaythrough",
        "play", "playing", "pause", "seeking", "seeked", "waiting", "stalled", "suspend", "ended", "error",
        "abort", "emptied", "ratechange", "volumechange", "resize", "encrypted", "waitingforkey",
    ];
    const EVENT_LIMIT = 300;
    const PLAYER_LIMIT = 60;
    const top = window === window.top;
    const doc = Math.random().toString(36).slice(2) + Date.now().toString(36);
    const players = [];
    const byElement = new WeakMap();
    // MediaSource details from the page world's hooks, by blob URL.
    const mse = new Map();
    let counter = 0;
    let lastHandler = false;
    let marked = null;

    const handler = () => {
        try { return window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[HANDLER]; }
        catch (e) { return null; }
    };
    const post = (message) => {
        const h = handler();
        if (!h) return false;
        try { h.postMessage(message); return true; } catch (e) { return false; }
    };
    const now = () => (performance.timeOrigin || 0) + performance.now();
    const finite = (n) => (typeof n === "number" && isFinite(n) ? n : null);
    const ranges = (list) => {
        const out = [];
        try {
            for (let i = 0; list && i < list.length && i < 100; i++) out.push([list.start(i), list.end(i)]);
        } catch (e) {}
        return out;
    };
    const tracks = (list, selectedKey) => {
        const out = [];
        try {
            for (let i = 0; list && i < list.length && i < 40; i++) {
                const t = list[i];
                const on = selectedKey === "mode" ? t.mode === "showing" : !!t[selectedKey];
                out.push({kind: String(t.kind || ""), label: String(t.label || ""), language: String(t.language || ""), on});
            }
        } catch (e) {}
        return out;
    };
    const label = (el) => {
        let text = el.localName;
        if (el.id) text += "#" + el.id;
        const classes = el.classList ? Array.from(el.classList).slice(0, 2) : [];
        if (classes.length) text += "." + classes.join(".");
        return text.slice(0, 120);
    };

    const record = (player, name, detail) => {
        player.seq += 1;
        let mediaTime = null;
        try { mediaTime = finite(player.el.currentTime); } catch (e) {}
        player.events.push({seq: player.seq, name, time: now(), mediaTime, detail: detail || ""});
        if (player.events.length > EVENT_LIMIT) player.events.splice(0, player.events.length - EVENT_LIMIT);
        player.dirty = true;
    };

    const detailFor = (el, event) => {
        try {
            switch (event.type) {
            case "encrypted": return "initDataType: " + (event.initDataType || "");
            case "resize": return el.videoWidth + "×" + el.videoHeight;
            case "ratechange": return "playbackRate: " + el.playbackRate;
            case "volumechange": return "volume: " + el.volume + (el.muted ? ", muted" : "");
            case "durationchange": return "duration: " + el.duration;
            case "error": return el.error ? "code " + el.error.code + (el.error.message ? ": " + el.error.message : "") : "";
            case "seeking": case "seeked": return "currentTime: " + el.currentTime;
            }
        } catch (e) {}
        return "";
    };

    const adopt = (el) => {
        if (!el || byElement.has(el)) return byElement.get(el);
        const name = el.localName;
        if (name !== "video" && name !== "audio") return null;
        counter += 1;
        const player = {id: doc + ":" + counter, el, seq: 0, events: [], dirty: true, last: "", initDataTypes: [],
                        keySystem: "", errorAt: 0};
        byElement.set(el, player);
        players.push(player);
        if (players.length > PLAYER_LIMIT) {
            // The oldest that has left the document goes first.
            const gone = players.findIndex((p) => !p.el.isConnected);
            const removed = players.splice(gone >= 0 ? gone : 0, 1)[0];
            if (removed) removed.removed = true;
        }
        for (const type of EVENTS) {
            el.addEventListener(type, (event) => {
                if (type === "encrypted" && event.initDataType && !player.initDataTypes.includes(event.initDataType))
                    player.initDataTypes.push(event.initDataType);
                record(player, type, detailFor(el, event));
            }, {capture: true, passive: true});
        }
        el.addEventListener("perch-media-info", (event) => {
            try {
                const info = JSON.parse(String(event.detail));
                if (info.keySystem) player.keySystem = info.keySystem;
                player.dirty = true;
            } catch (e) {}
        });
        // Created already playing: say so in the log, as Chrome's first entries do.
        record(player, "player created", el.currentSrc ? "src: " + el.currentSrc.slice(0, 200) : "");
        return player;
    };

    const scan = (node) => {
        if (!node || node.nodeType !== 1) return;
        if (node.localName === "video" || node.localName === "audio") adopt(node);
        if (node.querySelectorAll) for (const el of node.querySelectorAll("video, audio")) adopt(el);
        if (node.shadowRoot) for (const el of node.shadowRoot.querySelectorAll("video, audio")) adopt(el);
    };

    const start = () => {
        if (document.documentElement) scan(document.documentElement);
        new MutationObserver((records) => {
            for (const r of records) for (const node of r.addedNodes) scan(node);
        }).observe(document, {childList: true, subtree: true});
    };

    // The page world's hooks: an element played outside the document, and
    // MediaSource details by blob URL.
    window.addEventListener("perch-media-element", (event) => {
        if (event.relatedTarget) adopt(event.relatedTarget);
    }, true);
    window.addEventListener("perch-media-mse", (event) => {
        try {
            const info = JSON.parse(String(event.detail));
            if (info && info.url) mse.set(info.url, info);
            for (const p of players) p.dirty = true;
        } catch (e) {}
    }, true);

    const sourceKind = (el) => {
        try { if (el.srcObject) return (el.srcObject.constructor && el.srcObject.constructor.name) === "MediaStream" ? "MediaStream" : "srcObject"; }
        catch (e) {}
        const src = el.currentSrc || el.src || "";
        if (!src) return "none";
        if (src.startsWith("blob:")) return mse.has(src) ? "MSE" : "blob";
        if (src.startsWith("data:")) return "data";
        return "File";
    };

    const describe = (player) => {
        const el = player.el;
        const out = {id: player.id, tag: el.localName, frameURL: String(location.href).slice(0, 500), top,
                     connected: el.isConnected, label: label(el)};
        try {
            const src = el.currentSrc || el.src || "";
            out.currentSrc = src.length > 2000 ? src.slice(0, 2000) : src;
            out.sourceKind = sourceKind(el);
            out.duration = finite(el.duration);
            if (out.duration === null) out.durationText = String(el.duration);
            out.currentTime = finite(el.currentTime);
            out.readyState = el.readyState;
            out.networkState = el.networkState;
            out.paused = el.paused;
            out.ended = el.ended;
            out.seeking = el.seeking;
            out.loop = el.loop;
            out.autoplay = el.autoplay;
            out.controls = el.controls;
            out.preload = el.preload;
            out.playbackRate = finite(el.playbackRate);
            out.volume = finite(el.volume);
            out.muted = el.muted;
            if (el.localName === "video") {
                out.videoWidth = el.videoWidth;
                out.videoHeight = el.videoHeight;
                if (typeof el.getVideoPlaybackQuality === "function") {
                    const q = el.getVideoPlaybackQuality();
                    out.quality = {total: q.totalVideoFrames, dropped: q.droppedVideoFrames, corrupted: q.corruptedVideoFrames};
                }
            }
            out.buffered = ranges(el.buffered);
            out.played = ranges(el.played);
            out.seekable = ranges(el.seekable);
            if (el.audioTracks) out.audioTracks = tracks(el.audioTracks, "enabled");
            if (el.videoTracks) out.videoTracks = tracks(el.videoTracks, "selected");
            if (el.textTracks) out.textTracks = tracks(el.textTracks, "mode");
            const info = mse.get(src);
            if (info) out.mse = {mimeTypes: info.mimeTypes || [], readyState: info.readyState || "", managed: !!info.managed};
            out.mediaKeys = !!el.mediaKeys;
            out.keySystem = player.keySystem;
            out.initDataTypes = player.initDataTypes;
            if (el.error) out.error = {code: el.error.code, message: String(el.error.message || "")};
        } catch (e) {}
        return out;
    };

    const send = (force) => {
        const changed = [];
        for (const player of players) {
            const description = describe(player);
            const text = JSON.stringify(description);
            if (!force && !player.dirty && text === player.last) continue;
            const events = force ? player.events.slice() : player.events.filter((e) => e.seq > (player.sent || 0));
            changed.push(Object.assign(description, {events}));
            player.pending = {text, seq: player.seq};
        }
        if (!changed.length && !force) return;
        if (post({kind: "players", doc, top, url: String(location.href).slice(0, 500), players: changed})) {
            for (const player of players) {
                if (!player.pending) continue;
                player.last = player.pending.text;
                player.sent = player.pending.seq;
                player.dirty = false;
                player.pending = null;
            }
        } else {
            for (const player of players) player.pending = null;
        }
    };

    const tick = () => {
        const present = !!handler();
        if (present && !lastHandler) {
            post({kind: "hello", doc, top, url: String(location.href).slice(0, 500)});
            send(true);
        } else if (present) {
            send(false);
        }
        lastHandler = present;
    };

    const find = (id) => players.find((p) => p.id === id);
    const api = {
        resync() { lastHandler = false; tick(); },
        // Marks a player's element so Perch can find it through the
        // inspector (which works in the page's world): one at a time.
        mark(id) {
            api.unmark();
            const player = find(id);
            if (!player || !player.el.isConnected) return false;
            const token = "m" + Math.random().toString(36).slice(2);
            player.el.setAttribute("data-perch-media", token);
            marked = player.el;
            return token;
        },
        unmark() {
            if (marked) marked.removeAttribute("data-perch-media");
            marked = null;
            return true;
        },
        clear() {
            for (const player of players) { player.events = []; player.dirty = true; }
            return true;
        },
    };
    Object.defineProperty(window, KEY, {value: api, configurable: false, enumerable: false});

    start();
    addEventListener("pagehide", () => { post({kind: "gone", doc, top}); lastHandler = false; }, true);
    setInterval(tick, 500);
    tick();
    return true;
})();
