// The Lighthouse panel's permission watcher (DeveloperLighthouseModel.swift):
// a user script in the page's own world at document start, put in only for
// a Navigation run's reload. Chrome's Lighthouse reads the "violation" logs
// Chrome writes when a page asks for geolocation or notifications without a
// user gesture; WebKit writes none, so the calls are noted here as the page
// makes them: the API, whether a gesture was under way, and the first frame
// of the page's own code on the stack. DeveloperLighthouse-collect.js reads
// the log for geolocation-on-start and notification-on-start. The page's
// calls go through to the real methods unchanged.
(() => {
    const key = Symbol.for("perch.lighthouse.permissions");
    if (window[key]) return;
    const calls = [];
    try {
        Object.defineProperty(window, key, { value: calls, enumerable: false, configurable: true });
    } catch (error) {
        return;
    }
    // JavaScriptCore's frames read "name@url:line:column"; this script's
    // own are user-script: addresses and are skipped.
    const where = () => {
        const lines = String(new Error().stack || "").split("\n");
        for (const line of lines) {
            const match = line.match(/((?:https?|file):\/\/.*?):(\d+):(\d+)$/);
            if (match) return { url: match[1], line: Number(match[2]), column: Number(match[3]) };
        }
        return { url: "", line: 0, column: 0 };
    };
    const wrap = (owner, name, api) => {
        if (!owner) return;
        const original = owner[name];
        if (typeof original !== "function") return;
        const wrapped = {
            [name](...args) {
                if (calls.length < 50) {
                    const gesture = !!(navigator.userActivation && navigator.userActivation.isActive);
                    calls.push(Object.assign({ api, gesture }, where()));
                }
                return original.apply(this, args);
            },
        }[name];
        try {
            Object.defineProperty(owner, name, { value: wrapped, writable: true, configurable: true, enumerable: false });
        } catch (error) {}
    };
    try {
        if (typeof Geolocation === "function") {
            wrap(Geolocation.prototype, "getCurrentPosition", "geolocation");
            wrap(Geolocation.prototype, "watchPosition", "geolocation");
        }
        if (typeof Notification === "function") wrap(Notification, "requestPermission", "notification");
    } catch (error) {}
})();
