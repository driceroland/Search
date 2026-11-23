// Perch DevTools › Media, in the page's own world: what only the page's
// prototypes can see. HTMLMediaElement.prototype.play, so an element that
// was never put in the document (new Audio().play()) is still found;
// URL.createObjectURL and MediaSource.prototype.addSourceBuffer, so a
// player fed by Media Source Extensions shows its SourceBuffers' MIME
// types; and requestMediaKeySystemAccess with setMediaKeys, so encrypted
// media shows its key system. Each finding goes to DeveloperMedia-observe.js
// (in Perch's world) as a DOM event carrying a node or a JSON string, the
// two things that cross between worlds. Installed once per document; the
// originals are called exactly as before.
(() => {
    const KEY = Symbol.for("perch.media.hooks");
    if (window[KEY]) return true;
    Object.defineProperty(window, KEY, {value: true, configurable: false, enumerable: false});

    const announce = (el) => {
        try { window.dispatchEvent(new MouseEvent("perch-media-element", {relatedTarget: el})); } catch (e) {}
    };
    const tell = (target, type, info) => {
        try { target.dispatchEvent(new CustomEvent(type, {detail: JSON.stringify(info)})); } catch (e) {}
    };

    const Media = window.HTMLMediaElement;
    if (Media && Media.prototype.play) {
        const play = Media.prototype.play;
        Media.prototype.play = function () {
            if (!this.isConnected) announce(this);
            return play.apply(this, arguments);
        };
    }

    // MediaSource by its blob URL, and what is known of each.
    const sources = new WeakMap();
    const update = (source) => {
        const info = sources.get(source);
        if (!info) return;
        try {
            info.readyState = source.readyState;
            info.mimeTypes = info.buffers.map((b) => b.type);
        } catch (e) {}
        for (const url of info.urls) tell(window, "perch-media-mse", {url, mimeTypes: info.mimeTypes,
                                                                     readyState: info.readyState, managed: info.managed});
    };
    const track = (source) => {
        if (sources.has(source)) return sources.get(source);
        const managed = typeof window.ManagedMediaSource === "function" && source instanceof window.ManagedMediaSource;
        const info = {urls: [], buffers: [], mimeTypes: [], readyState: "", managed};
        sources.set(source, info);
        for (const type of ["sourceopen", "sourceended", "sourceclose"])
            source.addEventListener(type, () => update(source));
        return info;
    };

    const MS = window.MediaSource || window.ManagedMediaSource;
    if (MS && URL.createObjectURL) {
        const create = URL.createObjectURL;
        URL.createObjectURL = function (object) {
            const url = create.apply(this, arguments);
            try {
                if ((window.MediaSource && object instanceof window.MediaSource)
                    || (window.ManagedMediaSource && object instanceof window.ManagedMediaSource)) {
                    track(object).urls.push(url);
                    update(object);
                }
            } catch (e) {}
            return url;
        };
        for (const Source of [window.MediaSource, window.ManagedMediaSource]) {
            if (!Source || !Source.prototype.addSourceBuffer || Source.prototype.addSourceBuffer[KEY]) continue;
            const add = Source.prototype.addSourceBuffer;
            const hooked = function (type) {
                const buffer = add.apply(this, arguments);
                try {
                    track(this).buffers.push({type: String(type)});
                    update(this);
                } catch (e) {}
                return buffer;
            };
            hooked[KEY] = true;
            Source.prototype.addSourceBuffer = hooked;
        }
    }

    // Encrypted media: which key system each MediaKeys came from.
    const keySystems = new WeakMap();
    const nav = window.navigator;
    if (nav && typeof nav.requestMediaKeySystemAccess === "function" && window.MediaKeySystemAccess) {
        const createKeys = window.MediaKeySystemAccess.prototype.createMediaKeys;
        window.MediaKeySystemAccess.prototype.createMediaKeys = function () {
            const system = this.keySystem;
            return createKeys.apply(this, arguments).then((keys) => {
                try { keySystems.set(keys, system); } catch (e) {}
                return keys;
            });
        };
    }
    if (Media && Media.prototype.setMediaKeys) {
        const setKeys = Media.prototype.setMediaKeys;
        Media.prototype.setMediaKeys = function (keys) {
            const el = this;
            announce(el);
            const result = setKeys.apply(this, arguments);
            try { tell(el, "perch-media-info", {keySystem: keys ? keySystems.get(keys) || "unknown" : ""}); } catch (e) {}
            return result;
        };
    }
    return true;
})();
