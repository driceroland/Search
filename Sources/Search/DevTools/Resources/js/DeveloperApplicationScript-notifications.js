// Application › Background services › Notifications, in the page's own
// world (DeveloperNotificationRecorder in DeveloperApplicationProbe.swift).
// While recording, hooks on the Notification constructor,
// Notification.requestPermission and
// ServiceWorkerRegistration.prototype.showNotification log each event; each
// hook calls the page's own. Stopping puts the page's globals back as they
// were. The log sits under a non-enumerable Symbol.for key.
// `action` is "start", "read", "clear" or "stop".
(action, symbolName) => {
    const key = Symbol.for(symbolName);
    const current = window[key];
    const reply = (log) => ({
        recording: !!(log && log.recording),
        supported: typeof window.Notification === "function" || typeof window.ServiceWorkerRegistration === "function",
        events: log ? log.events.slice() : [],
        dropped: log ? log.dropped : 0,
    });
    if (action === "read") return reply(current);
    if (action === "clear") {
        if (current) { current.events.length = 0; current.dropped = 0; }
        return reply(current);
    }
    if (action === "stop") {
        if (!current) return reply(null);
        current.recording = false;
        current.restore();
        try { delete window[key]; } catch {}
        return reply(current);
    }
    if (action !== "start" || current) return reply(current);

    const log = { recording: true, events: [], dropped: 0, restore: null };
    const undo = [];
    log.restore = () => {
        for (const step of undo.splice(0).reverse()) {
            try { step(); } catch {}
        }
    };
    const text = (value) => {
        if (value === undefined || value === null) return "";
        if (typeof value === "string") return value.slice(0, 2048);
        try {
            const json = JSON.stringify(value);
            return (json === undefined ? String(value) : json).slice(0, 2048);
        } catch {
            return String(value).slice(0, 2048);
        }
    };
    // NotificationOptions as label and value pairs, in Chrome's order.
    const fields = ["body", "tag", "icon", "image", "badge", "lang", "dir", "data", "actions", "vibrate",
        "timestamp", "requireInteraction", "renotify", "silent"];
    const described = (options) => {
        const pairs = [];
        if (!options || typeof options !== "object") return pairs;
        for (const field of fields) {
            let value;
            try { value = options[field]; } catch { continue; }
            if (value === undefined) continue;
            pairs.push([field, text(value)]);
        }
        return pairs;
    };
    const record = (event, title, details) => {
        if (!log.recording) return;
        if (log.events.length >= 1000) { log.dropped++; return; }
        log.events.push({ time: Date.now(), event, origin: location.origin, title: text(title), details });
    };
    // Replaces `owner[property]`, keeping its attributes; undone by putting the old descriptor back.
    const swap = (owner, property, replacement) => {
        const saved = Object.getOwnPropertyDescriptor(owner, property);
        if (!saved || !saved.configurable) return false;
        Object.defineProperty(owner, property, {
            configurable: true, enumerable: saved.enumerable, writable: true, value: replacement,
        });
        undo.push(() => Object.defineProperty(owner, property, saved));
        return true;
    };
    const nativeAdd = typeof EventTarget === "function" ? EventTarget.prototype.addEventListener : null;

    const Native = window.Notification;
    if (typeof Native === "function") {
        try {
            const nativeRequest = Native.requestPermission;
            if (typeof nativeRequest === "function") {
                const requestPermission = function (...args) {
                    let before = "";
                    try { before = String(Native.permission); } catch {}
                    record("Permission requested", "", [["permission", before]]);
                    const result = nativeRequest.apply(this === hooked ? Native : this, args);
                    if (result && typeof result.then === "function") {
                        result.then((permission) => record("Permission decided", "", [["permission", String(permission)]]),
                            () => {});
                    }
                    return result;
                };
                swap(Native, "requestPermission", requestPermission);
            }
        } catch {}
        const hooked = new Proxy(Native, {
            construct(target, args, newTarget) {
                const made = Reflect.construct(target, args, newTarget === hooked ? target : newTarget);
                try {
                    const title = args[0];
                    record("Notification displayed", title, [["source", "new Notification()"]].concat(described(args[1])));
                    if (!nativeAdd || !(made instanceof EventTarget)) return made;
                    nativeAdd.call(made, "show", () => record("Notification shown", title, []));
                    nativeAdd.call(made, "click", () => record("Notification clicked", title, []));
                    nativeAdd.call(made, "close", () => record("Notification closed", title, []));
                    nativeAdd.call(made, "error", () => record("Notification failed", title, []));
                } catch {}
                return made;
            },
        });
        try { swap(window, "Notification", hooked); } catch {}
    }

    const Registration = window.ServiceWorkerRegistration;
    const prototype = Registration && Registration.prototype;
    const nativeShow = prototype && prototype.showNotification;
    if (typeof nativeShow === "function") {
        try {
            swap(prototype, "showNotification", function (...args) {
                let scope = "";
                try { scope = String(this.scope); } catch {}
                record("Notification displayed", args[0],
                    [["source", "ServiceWorkerRegistration.showNotification()"], ["scope", scope]].concat(described(args[1])));
                return nativeShow.apply(this, args);
            });
        } catch {}
    }

    Object.defineProperty(window, key, { value: log, configurable: true, enumerable: false, writable: false });
    return reply(log);
}
