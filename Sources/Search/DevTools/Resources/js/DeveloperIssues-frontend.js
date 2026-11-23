// The Issues drawer's ear on the Network domain, for cookie and
// cross-origin isolation issues. Runs in the hidden inspector frontend,
// beside perchInspector: it listens on the same connection and keeps each
// response's Set-Cookie headers (which the Network list's model leaves
// out) and its COOP, COEP, CORP and Access-Control-Allow-Origin headers,
// handing them over in batches.
// Returns whether it was set up just now.
let fresh = false;
if (!globalThis.perchIssues) {
    const connection = InspectorBackend.Connection?.prototype;
    const dispatch = connection?._dispatchEvent;
    if (typeof dispatch !== "function")
        throw new Error("This version of WebKit can’t report cookie issues.");
    const limit = 500;
    let pending = [];
    connection._dispatchEvent = function(message) {
        const result = dispatch.apply(this, arguments);
        try {
            if (message?.method === "Network.responseReceived" && pending.length < limit) {
                const params = message.params ?? {};
                const response = params.response ?? {};
                const headers = response.headers ?? {};
                let value = null;
                // The headers cross-origin isolation turns on, kept for
                // every response so a require-corp page's resources
                // without Cross-Origin-Resource-Policy can be named.
                const isolation = {};
                const wanted = {
                    "cross-origin-opener-policy": "coop", "cross-origin-embedder-policy": "coep",
                    "cross-origin-resource-policy": "corp", "access-control-allow-origin": "allowOrigin",
                };
                for (const name of Object.keys(headers)) {
                    const lower = name.toLowerCase();
                    if (typeof headers[name] !== "string")
                        continue;
                    if (lower === "set-cookie")
                        value = headers[name];
                    else if (wanted[lower])
                        isolation[wanted[lower]] = headers[name].slice(0, 300);
                }
                const entry = {
                    requestId: String(params.requestId ?? ""),
                    url: typeof response.url === "string" ? response.url.slice(0, 16384) : "",
                    type: typeof params.type === "string" ? params.type : "",
                    isolation,
                };
                if (value)
                    entry.setCookie = value.slice(0, 65536);
                pending.push(entry);
            }
        } catch {
            // Issues are a convenience; WebKit's own handling goes on.
        }
        return result;
    };
    globalThis.perchIssues = Object.freeze({
        drain() {
            const out = pending;
            pending = [];
            return out;
        },
    });
    fresh = true;
}
