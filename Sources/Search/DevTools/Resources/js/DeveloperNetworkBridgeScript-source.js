(() => {
    // The inspected page can report EventSource messages as WebKit dispatches
    // them. The inspector frontend continues to own the rest of Network.
    if (typeof perchEventSourceSession === "string")
        return captureEventSource(perchEventSourceSession);

    function captureEventSource(session) {
        const handler = globalThis.webkit?.messageHandlers?.perchNetworkEventSource;
        if (!handler)
            return false;
        // The capture's state stays off the page's enumerable globals. The
        // cleanup script finds it by this key and asks whether it's its own.
        const key = Symbol.for("perch.eventSourceCapture");
        const prior = globalThis[key];
        if (prior?.owns?.(session))
            return true;
        // An earlier session's capture goes first, so this one wraps the
        // engine's EventSource rather than that capture's.
        prior?.stop?.();
        const Native = globalThis.EventSource;
        if (typeof Native !== "function")
            return false;

        // Taken now, so a page that replaces these later can't skew or stop
        // the capture.
        const getter = (prototype, name) => Object.getOwnPropertyDescriptor(prototype ?? {}, name)?.get;
        const readData = getter(globalThis.MessageEvent?.prototype, "data");
        const readEventID = getter(globalThis.MessageEvent?.prototype, "lastEventId");
        const readType = getter(globalThis.Event?.prototype, "type");
        const readURL = getter(Native.prototype, "url");
        const now = Date.now;
        const schedule = globalThis.setTimeout;
        const unschedule = globalThis.clearTimeout;
        if (![readData, readEventID, readType, readURL, now, schedule, unschedule].every((value) => typeof value === "function"))
            return false;
        const read = (get, object) => Reflect.apply(get, object, []);

        const listeners = new AbortController;
        // Perch's own observers use the listener taken here. The page's calls
        // go to whichever addEventListener it has installed by then.
        const add = Native.prototype.addEventListener;
        const parent = Object.getPrototypeOf(Native.prototype);
        const ownAdd = Object.getOwnPropertyDescriptor(Native.prototype, "addEventListener");
        const ownConstructor = Object.getOwnPropertyDescriptor(Native.prototype, "constructor");
        const streams = new WeakMap;
        const clock = () => Reflect.apply(now, undefined, []);
        const wallTime = () => clock() / 1000;
        const frame = Math.random().toString(36).slice(2) + "-" + clock();
        let sequence = 0;
        let pending = [];
        let created = [];
        let dropped = null;
        let timer = 0;
        let active = true;

        function send(messages, opened = [], lost = null) {
            try { handler.postMessage({session, frame, messages, streams: opened, dropped: lost ?? {}}); } catch {}
        }

        function flush() {
            timer = 0;
            const batch = pending, opened = created, lost = dropped;
            pending = [];
            created = [];
            dropped = null;
            if (active && (batch.length || opened.length || lost))
                send(batch, opened, lost);
        }

        function later() {
            if (!timer)
                timer = Reflect.apply(schedule, globalThis, [flush, 16]);
        }

        function message(event) {
            const stream = streams.get(this);
            if (!active || !stream?.opened || !event.isTrusted)
                return;
            let data, eventID, type;
            try {
                data = read(readData, event);
                eventID = read(readEventID, event);
                type = read(readType, event);
            } catch {
                return;
            }
            if (typeof data !== "string" || typeof eventID !== "string" || typeof type !== "string")
                return;
            const connection = stream.id + "-" + stream.count;
            if (pending.length < 128) {
                pending.push({
                    connection,
                    stream: stream.id,
                    url: stream.url,
                    after: stream.after,
                    opened: stream.opened,
                    time: wallTime(),
                    type: type.slice(0, 256),
                    eventId: eventID.slice(0, 512),
                    data: data.slice(0, 8192),
                });
            } else {
                // Counted, so Messages can say how many it isn't showing.
                dropped ??= {};
                dropped[connection] = (dropped[connection] ?? 0) + 1;
            }
            later();
        }

        // There is no wildcard event listener. Observe the default event and
        // named events the page subscribes to on a source created here.
        function observe(source, stream, type) {
            if (stream.types.size >= 128 || stream.types.has(type))
                return;
            stream.types.add(type);
            Reflect.apply(add, source, [type, message, {capture: true, signal: listeners.signal}]);
        }

        // A proxy of the native method keeps its name, length and source
        // text. The call goes on to the addEventListener the page sees now,
        // such as zone.js's, rather than the one taken at injection.
        const addEventListener = new Proxy(add, {
            apply(target, self, args) {
                const stream = active ? streams.get(self) : undefined;
                if (stream && typeof args[0] === "string" && args[1] != null) {
                    try { observe(self, stream, args[0]); } catch {}
                }
                const next = ownAdd ? ownAdd.value : Reflect.get(parent, "addEventListener", self);
                return Reflect.apply(next, self, args);
            },
        });

        const wrapper = new Proxy(Native, {
            construct(target, args, newTarget) {
                const after = wallTime();
                const source = Reflect.construct(target, args, newTarget);
                if (!active)
                    return source;
                try {
                    const stream = {id: frame + "-" + ++sequence, url: read(readURL, source), after, opened: null, count: 0, types: new Set};
                    streams.set(source, stream);
                    // Registered at construction, so two sources on one URL
                    // keep their requests in the order they were created.
                    if (created.length < 128) {
                        created.push({stream: stream.id, url: stream.url, after});
                        later();
                    }
                    Reflect.apply(add, source, ["open", (event) => {
                        if (!event.isTrusted)
                            return;
                        stream.after = stream.opened ?? stream.after;
                        stream.opened = wallTime();
                        stream.count++;
                    }, {capture: true, signal: listeners.signal}]);
                    observe(source, stream, "message");
                } catch {}
                return source;
            },
        });

        globalThis.EventSource = wrapper;
        if (globalThis.EventSource !== wrapper)
            return false;
        try {
            Object.defineProperty(Native.prototype, "addEventListener", {value: addEventListener, configurable: true, writable: true});
        } catch {
            // The default events can still be observed if a page froze this prototype.
        }
        // EventSource.prototype.constructor is EventSource, as without Perch.
        try {
            if (ownConstructor?.value === Native)
                Object.defineProperty(Native.prototype, "constructor", {...ownConstructor, value: wrapper});
        } catch {}
        const state = Object.freeze({
            owns: (other) => other === session,
            stop() {
                active = false;
                Reflect.apply(unschedule, globalThis, [timer]);
                timer = 0;
                pending = [];
                created = [];
                dropped = null;
                listeners.abort();
                if (globalThis.EventSource === wrapper)
                    globalThis.EventSource = Native;
                if (Native.prototype.addEventListener === addEventListener) {
                    if (ownAdd)
                        Object.defineProperty(Native.prototype, "addEventListener", ownAdd);
                    else
                        delete Native.prototype.addEventListener;
                }
                try {
                    if (ownConstructor && Native.prototype.constructor === wrapper)
                        Object.defineProperty(Native.prototype, "constructor", ownConstructor);
                } catch {}
                if (globalThis[key] === state)
                    delete globalThis[key];
            },
        });
        try {
            Object.defineProperty(globalThis, key, {value: state, configurable: true, enumerable: false, writable: false});
        } catch {}
        // Register the frame for restoration even if it never opens a stream.
        send([]);
        return true;
    }

    if (globalThis.perchNetwork)
        return true;
    if (typeof WI === "undefined" || typeof InspectorBackend === "undefined" || !globalThis.perchInspector)
        return false;

    const rowLimit = 1000;
    const frameLimit = 2000;
    const rows = new Map;
    const sockets = new Map;
    const resources = new Map;
    const blocked = new Set;
    let version = 0;
    let page = {domContentLoaded: null, load: null};
    let patterns = [];
    let blockingEnabled = true;
    let matchers = [];
    // Request conditions that delay rather than block: [{test, latency}].
    let throttles = [];
    const throttled = new Map;
    let blockRule = null;
    let wallOffset = null;

    function trim(map, limit) {
        while (map.size > limit)
            map.delete(map.keys().next().value);
    }

    function lower(names) {
        return Object.keys(names ?? {}).slice(0, 200).map((name) => name.toLowerCase());
    }

    // Values by lowercased name, for the list's response header columns.
    function headerValues(headers) {
        const result = {};
        for (const name of Object.keys(headers ?? {}).slice(0, 200)) {
            const value = headers[name];
            if (typeof value === "string")
                result[name.toLowerCase()] = value.slice(0, 300);
        }
        return result;
    }

    function stackFrames(initiator) {
        const stack = initiator?.stackTrace?.callFrames ?? initiator?.stackTrace ?? [];
        if (!Array.isArray(stack))
            return [];
        return stack.slice(0, 20).map((frame) => ({
            functionName: frame.functionName ?? "", url: frame.url ?? "",
            lineNumber: frame.lineNumber ?? null, columnNumber: frame.columnNumber ?? null,
        }));
    }

    function headerValue(headers, name) {
        for (const key in headers ?? {}) {
            if (key.toLowerCase() === name && typeof headers[key] === "string")
                return headers[key];
        }
        return null;
    }

    function cookieNames(header) {
        if (!header)
            return [];
        return header.split(";").map((part) => part.split("=")[0].trim()).filter(Boolean).slice(0, 100);
    }

    // The Cookie header's name=value pairs, for the cookie-value: filter.
    function cookiePairs(header) {
        if (!header)
            return [];
        return header.split(";").slice(0, 100).map((part) => {
            const equals = part.indexOf("=");
            const name = (equals < 0 ? part : part.slice(0, equals)).trim();
            const value = equals < 0 ? "" : part.slice(equals + 1).trim().slice(0, 500);
            return {name, value};
        }).filter((cookie) => cookie.name);
    }

    // WebKit joins several Set-Cookie headers with new lines.
    function setCookies(header) {
        if (!header)
            return [];
        return header.split("\n").slice(0, 100).map((line) => {
            const [pair, ...attributes] = line.split(";");
            const trimmed = attributes.map((item) => item.trim());
            const domain = trimmed.find((item) => /^domain=/i.test(item));
            const path = trimmed.find((item) => /^path=/i.test(item));
            const equals = pair.indexOf("=");
            return {
                name: pair.split("=")[0].trim(), domain: domain ? domain.slice(7).trim() : "",
                path: path ? path.slice(5).trim() : "",
                value: equals < 0 ? "" : pair.slice(equals + 1).trim().slice(0, 500),
            };
        }).filter((cookie) => cookie.name);
    }

    function row(id) {
        let item = rows.get(id);
        if (!item) {
            item = {id};
            rows.set(id, item);
            trim(rows, rowLimit);
        }
        item.version = ++version;
        return item;
    }

    function observe(message, target) {
        const method = message?.method;
        const data = message?.params;
        if (typeof method !== "string" || !data)
            return;
        if (Number.isFinite(data.walltime) && Number.isFinite(data.timestamp))
            wallOffset = data.walltime - data.timestamp;
        switch (method) {
        case "Network.requestWillBeSent": {
            const item = row(data.requestId);
            const headers = data.request?.headers;
            item.requestHeaders = lower(headers);
            item.requestHeaderValues = headerValues(headers);
            item.cookies = cookieNames(headerValue(headers, "cookie"));
            item.requestCookies = cookiePairs(headerValue(headers, "cookie"));
            item.frameId = data.frameId ?? null;
            if (data.initiator) {
                item.initiatorLine = Number.isFinite(data.initiator.lineNumber) ? data.initiator.lineNumber : null;
                item.initiatorStack = stackFrames(data.initiator);
            }
            break;
        }
        case "Network.requestServedFromMemoryCache": {
            const item = row(data.requestId);
            item.responseHeaders = lower(data.resource?.response?.headers);
            item.responseHeaderValues = headerValues(data.resource?.response?.headers);
            item.decoded = data.resource?.bodySize ?? null;
            item.source = "memory-cache";
            break;
        }
        case "Network.responseReceived": {
            const item = row(data.requestId);
            const headers = data.response?.headers;
            item.responseHeaders = lower(headers);
            item.responseHeaderValues = headerValues(headers);
            item.setCookies = setCookies(headerValue(headers, "set-cookie"));
            item.source = data.response?.source ?? null;
            if (data.response?.timing) {
                item.timing = {};
                for (const [name, value] of Object.entries(data.response.timing))
                    if (Number.isFinite(value))
                        item.timing[name] = value;
            }
            break;
        }
        case "Network.loadingFinished": {
            const item = row(data.requestId);
            const metrics = data.metrics ?? {};
            for (const name of ["protocol", "priority", "remoteAddress", "connectionIdentifier"]) {
                if (typeof metrics[name] === "string")
                    item[name] = metrics[name].slice(0, 200);
            }
            if (Number.isFinite(metrics.responseBodyDecodedSize))
                item.decoded = metrics.responseBodyDecodedSize;
            if (metrics.requestHeaders) {
                item.requestHeaders = lower(metrics.requestHeaders);
                item.requestHeaderValues = headerValues(metrics.requestHeaders);
                item.cookies = cookieNames(headerValue(metrics.requestHeaders, "cookie"));
                item.requestCookies = cookiePairs(headerValue(metrics.requestHeaders, "cookie"));
            }
            break;
        }
        case "Network.loadingFailed":
            if (blocked.has(data.requestId))
                row(data.requestId).blocked = true;
            break;
        case "Network.webSocketFrameSent":
        case "Network.webSocketFrameReceived":
        case "Network.webSocketFrameError": {
            let frames = sockets.get(data.requestId);
            if (!frames) {
                frames = [];
                sockets.set(data.requestId, frames);
                trim(sockets, 64);
            }
            const frame = data.response ?? {};
            const text = method === "Network.webSocketFrameError"
                ? String(data.errorMessage ?? "") : String(frame.payloadData ?? "");
            frames.push({
                type: method === "Network.webSocketFrameSent" ? "sent"
                    : method === "Network.webSocketFrameError" ? "error" : "received",
                opcode: Number.isFinite(frame.opcode) ? frame.opcode : null,
                data: text.slice(0, 65536),
                length: Number.isFinite(frame.payloadLength) ? frame.payloadLength : text.length,
                time: Number.isFinite(data.timestamp) && wallOffset !== null ? data.timestamp + wallOffset : null,
            });
            if (frames.length > frameLimit)
                frames.splice(0, frames.length - frameLimit);
            row(data.requestId).frames = frames.length;
            break;
        }
        case "Page.domContentEventFired":
            page.domContentLoaded = data.timestamp ?? null;
            break;
        case "Page.loadEventFired":
            page.load = data.timestamp ?? null;
            break;
        case "Page.frameNavigated":
            if (!data.frame?.parentId)
                page = {domContentLoaded: null, load: null};
            break;
        case "Target.didCommitProvisionalTarget":
            setTimeout(() => {
                syncBlocking().catch(() => {});
                syncHeaders().catch(() => {});
            }, 0);
            break;
        }
    }

    // Patterns as Chrome's Request conditions take them: a URL Pattern,
    // or an older wildcard pattern matched anywhere in the URL.
    function matcher(pattern) {
        // Only a full URL pattern ("*://host/path") is one; anything else
        // is the wildcard form, so "*/a?b*" still matches on any port.
        if (typeof URLPattern === "function" && /^[^/]*:\/\//.test(pattern)) {
            try {
                const compiled = new URLPattern(pattern);
                if (!compiled.hasRegExpGroups)
                    return (url) => compiled.test(url);
            } catch {}
        }
        const source = pattern.split("*").map((part) => part.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join(".*");
        const expression = new RegExp(source);
        return (url) => expression.test(url);
    }

    function matches(url) {
        return typeof url === "string" && matchers.some((test) => {
            try { return test(url); } catch { return false; }
        });
    }

    const blockStage = "request";
    // Case-sensitive, so it never collides with the throttling rule.
    const blockInterception = {url: "^https?://", stage: blockStage, isRegex: true, caseSensitive: true};
    const blockCommands = ["addInterception", "removeInterception", "interceptContinue", "interceptRequestWithError"];

    function interceptionTarget() {
        return [WI.pageTarget, WI.mainTarget, WI.backendTarget].find((target) =>
            target && !target.isDestroyed && !target.isProvisional &&
            blockCommands.every((name) => target.hasCommand?.("Network." + name) &&
                typeof target.NetworkAgent?.[name]?.invoke === "function"));
    }

    let syncing = Promise.resolve();
    function syncBlocking() {
        const next = syncing.then(async () => {
            const wanted = (blockingEnabled && (matchers.length > 0 || throttles.length > 0)) || rewritesRequests();
            const target = wanted ? interceptionTarget() : null;
            if (blockRule && (blockRule !== target || !wanted)) {
                const previous = blockRule;
                blockRule = null;
                if (!previous.isDestroyed)
                    await previous.NetworkAgent.removeInterception.invoke(blockInterception).catch(() => {});
            }
            if (!wanted || !target || blockRule === target)
                return {active: !!blockRule};
            if (WI.networkManager && WI.networkManager.interceptionEnabled === false)
                WI.networkManager.interceptionEnabled = true;
            await target.NetworkAgent.addInterception.invoke(blockInterception).catch((error) => {
                if (!/already exists/i.test(String(error?.message ?? error)))
                    throw error;
            });
            blockRule = target;
            return {active: true};
        });
        syncing = next.catch(() => {});
        return next;
    }

    function setBlocking({enabled = true, patterns: list = [], throttled: delays = [], acceptEncoding: encoding = null,
                          disabledImageTypes: types = []} = {}) {
        blockingEnabled = !!enabled;
        acceptEncoding = typeof encoding === "string" && encoding.trim() ? encoding.trim() : null;
        disabledImageTypes = (Array.isArray(types) ? types : []).filter((type) => imageFormats.includes(type));
        patterns = (Array.isArray(list) ? list : []).filter((item) => typeof item === "string" && item.trim())
            .slice(0, 200);
        matchers = patterns.map((pattern) => {
            try { return matcher(pattern.trim()); } catch { return null; }
        }).filter(Boolean);
        throttles = (Array.isArray(delays) ? delays : []).slice(0, 200).map((item) => {
            const latency = Number(item?.latency);
            if (typeof item?.pattern !== "string" || !item.pattern.trim() || !Number.isFinite(latency) || latency <= 0)
                return null;
            try {
                return {test: matcher(item.pattern.trim()), latency: Math.min(5000, latency)};
            } catch {
                return null;
            }
        }).filter(Boolean);
        return Promise.all([syncBlocking(), syncImages()]).then(([request]) => request);
    }

    // Network conditions' Accepted Content-Encodings: the Accept-Encoding
    // each request goes out with, or null for the browser's own.
    let acceptEncoding = null;

    // Rendering's Disable AVIF / JPEG XL / WebP image format, as Chrome does
    // it: image requests stop offering the type, and a response in it is
    // answered with no bytes, so the image fails to decode.
    const imageFormats = ["image/avif", "image/jxl", "image/webp"];
    let disabledImageTypes = [];
    const imageStage = "response";
    // Case-insensitive, stage response: no other rule has this key.
    const imageInterception = {url: "^https?://", stage: imageStage, isRegex: true, caseSensitive: false};
    let imageRule = null;

    function rewritesRequests() {
        return acceptEncoding !== null || disabledImageTypes.length > 0;
    }

    // The Accept header without the disabled image types.
    function acceptWithout(value) {
        if (typeof value !== "string" || !disabledImageTypes.length)
            return value;
        return value.split(",").filter((part) =>
            !disabledImageTypes.includes(part.split(";")[0].trim().toLowerCase())).join(",");
    }

    let imageSyncing = Promise.resolve();
    function syncImages() {
        const next = imageSyncing.then(async () => {
            const wanted = disabledImageTypes.length > 0;
            const target = wanted ? headerTarget() : null;
            if (imageRule && (imageRule !== target || !wanted)) {
                const previous = imageRule;
                imageRule = null;
                if (!previous.isDestroyed)
                    await previous.NetworkAgent.removeInterception.invoke(imageInterception).catch(() => {});
            }
            if (!wanted || !target || imageRule === target)
                return {active: !!imageRule};
            if (WI.networkManager && WI.networkManager.interceptionEnabled === false)
                WI.networkManager.interceptionEnabled = true;
            await target.NetworkAgent.addInterception.invoke(imageInterception).catch((error) => {
                if (!/already exists/i.test(String(error?.message ?? error)))
                    throw error;
            });
            imageRule = target;
            return {active: true};
        });
        imageSyncing = next.catch(() => {});
        return next;
    }

    function imageIntercepted(message, target) {
        if (message?.method !== "Network.responseIntercepted" || !disabledImageTypes.length || !target?.NetworkAgent)
            return false;
        const {requestId, response} = message.params ?? {};
        if (typeof requestId !== "string" || !response)
            return false;
        let type = typeof response.mimeType === "string" ? response.mimeType : "";
        if (!type) {
            for (const [name, value] of Object.entries(response.headers ?? {})) {
                if (name.toLowerCase() === "content-type")
                    type = String(value);
            }
        }
        type = type.split(";")[0].trim().toLowerCase();
        if (!disabledImageTypes.includes(type))
            return false;
        const headers = {};
        for (const [name, value] of Object.entries(response.headers ?? {})) {
            if (!["content-encoding", "content-length"].includes(name.toLowerCase()))
                headers[name] = value;
        }
        headers["Cache-Control"] = "no-store";
        target.NetworkAgent.interceptWithResponse.invoke({
            requestId, content: "", base64Encoded: true, mimeType: type,
            status: Number.isFinite(response.status) ? response.status : 200,
            statusText: typeof response.statusText === "string" ? response.statusText : "OK", headers,
        }).catch(() => target.NetworkAgent.interceptContinue.invoke({requestId, stage: imageStage}).catch(() => {}));
        return true;
    }

    // Lets an intercepted request go, with the chosen Accept-Encoding and
    // without the disabled image types.
    function release(target, requestId, request) {
        if (rewritesRequests() && request && typeof request.headers === "object"
            && typeof target.NetworkAgent?.interceptWithRequest?.invoke === "function") {
            const headers = {};
            for (const [name, value] of Object.entries(request.headers ?? {})) {
                const lower = name.toLowerCase();
                if (lower === "accept-encoding" && acceptEncoding !== null)
                    continue;
                headers[name] = lower === "accept" ? acceptWithout(value) : value;
            }
            if (acceptEncoding !== null)
                headers["Accept-Encoding"] = acceptEncoding;
            return target.NetworkAgent.interceptWithRequest.invoke({requestId, headers})
                .catch(() => target.NetworkAgent.interceptContinue.invoke({requestId, stage: blockStage}));
        }
        return target.NetworkAgent.interceptContinue.invoke({requestId, stage: blockStage});
    }

    // A request neither blocked nor held, sent on with the chosen encodings.
    function encodeIntercepted(message, target) {
        if (message?.method !== "Network.requestIntercepted" || !rewritesRequests())
            return false;
        const {requestId, request} = message.params ?? {};
        if (typeof requestId !== "string" || !/^https?:/i.test(request?.url ?? ""))
            return false;
        // Let WebKit serve any explicit request-stage Local Override.
        const overrides = WI.networkManager?.localResourceOverridesForURL?.(request.url) ?? [];
        if (overrides.some((override) => !override.disabled && override.networkStage === blockStage))
            return false;
        // The page-wide condition owns the hold and also fails offline requests.
        if (globalThis.perchInspector?.isConditionedRequest?.(message, target, release))
            return true;
        release(target, requestId, request).catch(() => {});
        return true;
    }

    // The first throttling condition whose pattern matches, as Chrome
    // applies the first matching row.
    function throttleFor(url) {
        if (typeof url !== "string")
            return null;
        return throttles.find(({test}) => {
            try { return test(url); } catch { return false; }
        }) ?? null;
    }

    // Holds a matching request for its condition's latency, then lets it
    // go. Bandwidth can't be paced per request through interception.
    function throttleIntercepted(message, target) {
        if (message?.method !== "Network.requestIntercepted" || !blockingEnabled || !throttles.length
            || globalThis.perchInspector?.conditionFor?.(target)?.offline)
            return false;
        const {requestId, request} = message.params ?? {};
        if (typeof requestId !== "string" || throttled.has(requestId))
            return false;
        const rule = throttleFor(request?.url);
        if (!rule)
            return false;
        if (throttled.size >= 128) {
            // A busy page should not leave a large backlog of paused loads.
            return false;
        }
        row(requestId).throttled = rule.latency;
        throttled.set(requestId, setTimeout(() => {
            throttled.delete(requestId);
            if (!target.isDestroyed)
                release(target, requestId, request).catch(() => {});
        }, rule.latency));
        return true;
    }

    function blockIntercepted(message, target) {
        if (message?.method !== "Network.requestIntercepted" || !blockingEnabled || !matchers.length)
            return false;
        const {requestId, request} = message.params ?? {};
        if (typeof requestId !== "string" || !matches(request?.url))
            return false;
        blocked.add(requestId);
        while (blocked.size > rowLimit)
            blocked.delete(blocked.values().next().value);
        row(requestId).blocked = true;
        target.NetworkAgent.interceptRequestWithError.invoke({requestId, errorType: "General"})
            .catch(() => target.NetworkAgent.interceptContinue.invoke({requestId, stage: blockStage}))
            .catch(() => {});
        return true;
    }

    // Header overrides (the .headers files of DeveloperLocalOverrides, rules
    // compiled by DeveloperHeaderOverrides): a response whose address
    // matches is answered with its own status and body and the merged
    // headers. WebKit holds a response before its body arrives and
    // Network.interceptWithResponse takes a body with the headers, so the
    // body is loaded again: text with Network.loadResource (the inspector's
    // own load), anything else with fetch() in the page. A response that
    // can't be loaded again goes through unchanged. Content overrides carry
    // their headers themselves (WI.LocalResourceOverride), so they're left
    // to WebKit's frontend.
    const headerStage = "response";
    // Case-sensitive, stage response: no other rule has this key.
    const headerInterception = {url: "^https?://", stage: headerStage, isRegex: true, caseSensitive: true};
    const headerCommands = ["addInterception", "removeInterception", "interceptContinue", "interceptWithResponse"];
    const textTypes = /^(text\/|application\/([\w.-]+\+)?(json|xml|javascript|ecmascript|x-javascript|manifest\+json)|image\/svg\+xml)/i;
    let headerRules = [];
    let headerRule = null;
    // Addresses being loaded again, whose own responses go through.
    const refetching = new Map;
    // Each request's method and frame, from Network.requestWillBeSent.
    const requestInfo = new Map;

    function headerTarget() {
        return [WI.pageTarget, WI.mainTarget, WI.backendTarget].find((target) =>
            target && !target.isDestroyed && !target.isProvisional &&
            headerCommands.every((name) => target.hasCommand?.("Network." + name) &&
                typeof target.NetworkAgent?.[name]?.invoke === "function"));
    }

    let headerSyncing = Promise.resolve();
    function syncHeaders() {
        const next = headerSyncing.then(async () => {
            const wanted = headerRules.length > 0;
            const target = wanted ? headerTarget() : null;
            if (headerRule && (headerRule !== target || !wanted)) {
                const previous = headerRule;
                headerRule = null;
                if (!previous.isDestroyed)
                    await previous.NetworkAgent.removeInterception.invoke(headerInterception).catch(() => {});
            }
            if (!wanted)
                return {active: false};
            if (!target)
                return {active: false, reason: "WebKit response interception is unavailable for this page."};
            if (headerRule === target)
                return {active: true};
            if (WI.networkManager && WI.networkManager.interceptionEnabled === false)
                WI.networkManager.interceptionEnabled = true;
            await target.NetworkAgent.addInterception.invoke(headerInterception).catch((error) => {
                if (!/already exists/i.test(String(error?.message ?? error)))
                    throw error;
            });
            headerRule = target;
            return {active: true};
        });
        headerSyncing = next.catch(() => {});
        return next;
    }

    function setHeaderOverrides(list) {
        headerRules = (Array.isArray(list) ? list : []).slice(0, 2000).map((rule) => {
            const headers = (Array.isArray(rule?.headers) ? rule.headers : [])
                .filter((header) => typeof header?.name === "string" && typeof header?.value === "string")
                .map((header) => ({name: header.name, value: header.value}));
            try {
                return headers.length ? {pattern: new RegExp(String(rule.pattern)), headers} : null;
            } catch {
                return null;
            }
        }).filter(Boolean);
        return syncHeaders();
    }

    // What rules match, as DeveloperHeaderOverrides.target makes it.
    function headerTargetOf(url) {
        let address;
        try { address = new URL(url); } catch { return null; }
        if (!/^https?:$/.test(address.protocol) || !address.hostname)
            return null;
        let path = address.pathname || "/";
        try { path = decodeURIComponent(path); } catch {}
        if (path.endsWith("/"))
            path += "index.html";
        return {path: address.host.toLowerCase() + path, query: address.search ? address.search.slice(1) : null};
    }

    function cookieKey(value) {
        const match = /^([a-zA-Z0-9!#$%&'*+.^_`|~-]+=)/.exec(value);
        return match ? match[1] : value;
    }

    // DeveloperHeaderOverrides.merge: Chrome's.
    function mergeHeaders(base, overrides) {
        const isCookie = (header) => header.name.toLowerCase() === "set-cookie";
        const replacements = new Map;
        for (const header of overrides) {
            if (isCookie(header))
                continue;
            const key = header.name.toLowerCase();
            if (!replacements.has(key))
                replacements.set(key, []);
            replacements.get(key).push(header);
        }
        const result = [];
        const placed = new Set;
        for (const header of base) {
            if (isCookie(header))
                continue;
            const key = header.name.toLowerCase();
            if (!replacements.has(key))
                result.push(header);
            else if (!placed.has(key)) {
                placed.add(key);
                result.push(...replacements.get(key));
            }
        }
        for (const [key, list] of replacements) {
            if (!placed.has(key))
                result.push(...list);
        }
        const group = (list) => {
            const groups = new Map;
            for (const header of list) {
                const key = cookieKey(header.value);
                if (!groups.has(key))
                    groups.set(key, []);
                groups.get(key).push(header.value);
            }
            return groups;
        };
        const original = group(base.filter(isCookie));
        const added = group(overrides.filter(isCookie));
        for (const [key, values] of original) {
            for (const value of added.get(key) ?? values)
                result.push({name: "set-cookie", value});
        }
        for (const [key, values] of added) {
            if (!original.has(key))
                for (const value of values)
                    result.push({name: "set-cookie", value});
        }
        return result;
    }

    function headerOverridesFor(url) {
        const target = headerTargetOf(url);
        if (!target)
            return [];
        let result = [];
        for (const rule of headerRules) {
            if (rule.pattern.test(target.path) ||
                (target.query !== null && rule.pattern.test(target.path + "?" + target.query)))
                result = mergeHeaders(result, rule.headers);
        }
        return result;
    }

    // WebKit's header objects hold Set-Cookie values on separate lines.
    function headerList(object) {
        const list = [];
        for (const [name, value] of Object.entries(object ?? {})) {
            if (typeof value !== "string")
                continue;
            if (name.toLowerCase() === "set-cookie")
                value.split("\n").forEach((line) => list.push({name, value: line}));
            else
                list.push({name, value});
        }
        return list;
    }

    function headerObject(list) {
        const result = {};
        const names = new Map;
        for (const header of list) {
            const key = header.name.toLowerCase();
            const name = names.get(key) ?? header.name;
            names.set(key, name);
            result[name] = name in result ? result[name] + (key === "set-cookie" ? "\n" : ", ") + header.value : header.value;
        }
        return result;
    }

    function withDeadline(promise, milliseconds) {
        let timer;
        return Promise.race([
            promise,
            new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("timed out")), milliseconds); }),
        ]).finally(() => clearTimeout(timer));
    }

    async function reloadBody(target, url, mimeType, frameId) {
        if (textTypes.test(mimeType ?? "") && typeof target.NetworkAgent?.loadResource?.invoke === "function") {
            try {
                const result = await target.NetworkAgent.loadResource.invoke({
                    frameId: frameId ?? WI.networkManager?.mainFrame?.id ?? "", url,
                });
                if (typeof result?.content === "string")
                    return {content: result.content, base64Encoded: false};
            } catch {}
        }
        const runtime = target.RuntimeAgent;
        if (typeof runtime?.evaluate?.invoke !== "function" || typeof runtime?.awaitPromise?.invoke !== "function")
            return null;
        const objectGroup = "perch-header-overrides";
        const expression = `(async () => {
            const response = await fetch(${JSON.stringify(url)}, {credentials: "include"});
            const bytes = new Uint8Array(await response.arrayBuffer());
            let text = "";
            for (let index = 0; index < bytes.length; index += 32768)
                text += String.fromCharCode.apply(null, bytes.subarray(index, index + 32768));
            return btoa(text);
        })()`;
        try {
            const evaluated = await runtime.evaluate.invoke({
                expression, objectGroup, doNotPauseOnExceptionsAndMuteConsole: true, returnByValue: false,
            });
            const objectId = evaluated?.result?.objectId;
            if (evaluated?.wasThrown || !objectId)
                return null;
            const awaited = await runtime.awaitPromise.invoke({promiseObjectId: objectId, returnByValue: true});
            if (awaited?.wasThrown || typeof awaited?.result?.value !== "string")
                return null;
            return {content: awaited.result.value, base64Encoded: true};
        } finally {
            runtime.releaseObjectGroup?.invoke?.({objectGroup})?.catch?.(() => {});
        }
    }

    async function answerWithHeaders(target, requestId, response, overrides, info) {
        const url = response.url;
        const pass = () => target.NetworkAgent.interceptContinue.invoke({requestId, stage: headerStage}).catch(() => {});
        refetching.set(url, (refetching.get(url) ?? 0) + 1);
        let body = null;
        try {
            body = await withDeadline(reloadBody(target, url, response.mimeType, info?.frameId), 8000);
        } catch {
            body = null;
        } finally {
            const left = (refetching.get(url) ?? 1) - 1;
            if (left > 0)
                refetching.set(url, left);
            else
                refetching.delete(url);
        }
        if (!body)
            return pass();
        // The body is handed over decoded, whole.
        const base = headerList(response.headers).filter((header) =>
            !["content-encoding", "content-length"].includes(header.name.toLowerCase()));
        const params = {
            requestId, content: body.content, base64Encoded: body.base64Encoded,
            headers: headerObject(mergeHeaders(base, overrides)),
        };
        if (typeof response.mimeType === "string" && response.mimeType)
            params.mimeType = response.mimeType;
        if (Number.isFinite(response.status))
            params.status = response.status;
        if (typeof response.statusText === "string")
            params.statusText = response.statusText;
        try {
            await target.NetworkAgent.interceptWithResponse.invoke(params);
            const item = row(requestId);
            item.overridden = true;
            item.overriddenHeaders = [...new Set(overrides.map((header) => header.name.toLowerCase()))];
        } catch {
            await pass();
        }
    }

    function headerIntercepted(message, target) {
        const method = message?.method;
        if (method === "Network.requestWillBeSent") {
            const id = message.params?.requestId;
            if (typeof id === "string") {
                requestInfo.set(id, {method: message.params.request?.method ?? "GET", frameId: message.params.frameId ?? null});
                trim(requestInfo, rowLimit);
            }
            return false;
        }
        if (method !== "Network.responseIntercepted" || !headerRules.length || !target?.NetworkAgent)
            return false;
        const {requestId, response} = message.params ?? {};
        const url = response?.url;
        if (typeof requestId !== "string" || typeof url !== "string" || refetching.has(url))
            return false;
        // Only what can be loaded again the same way.
        const info = requestInfo.get(requestId);
        if (info && String(info.method).toUpperCase() !== "GET")
            return false;
        const overrides = headerOverridesFor(url);
        if (!overrides.length)
            return false;
        const local = WI.networkManager?.localResourceOverridesForURL?.(url) ?? [];
        if (local.some((item) => !item.disabled && item.networkStage === headerStage))
            return false;
        answerWithHeaders(target, requestId, response, overrides, info).catch(() => {});
        return true;
    }

    // WebKit's own resources, for WI.HARBuilder.
    function keep(resource) {
        const id = resource?.requestIdentifier;
        if (typeof id !== "string")
            return;
        resources.delete(id);
        resources.set(id, resource);
        trim(resources, rowLimit);
    }

    function collect(frame) {
        if (!frame)
            return;
        keep(frame.mainResource);
        for (const resource of frame.resourceCollection?.toArray?.() ?? [])
            keep(resource);
        for (const child of frame.childFrameCollection?.toArray?.() ?? [])
            collect(child);
    }

    try {
        collect(WI.networkManager?.mainFrame);
        for (const target of WI.targets ?? [])
            for (const resource of target.resourceCollection?.toArray?.() ?? [])
                keep(resource);
        WI.Frame?.addEventListener?.(WI.Frame.Event.ResourceWasAdded, (event) => keep(event.data?.resource));
        WI.Frame?.addEventListener?.(WI.Frame.Event.MainResourceDidChange, (event) => keep(event.target?.mainResource));
        WI.Target?.addEventListener?.(WI.Target.Event.ResourceAdded, (event) => keep(event.data?.resource));
    } catch {
        // HAR export falls back to the panel's own records.
    }

    async function har(ids) {
        const wanted = Array.isArray(ids) ? ids : [];
        const found = wanted.map((id) => resources.get(id)).filter(Boolean);
        const missing = wanted.filter((id) => !resources.has(id));
        if (typeof WI.HARBuilder?.buildArchive !== "function" || !found.length)
            return {archive: null, missing: wanted};
        let archive;
        try {
            archive = await WI.HARBuilder.buildArchive(found);
        } catch {
            // pages() needs a main resource; build the entries alone.
            const contents = await Promise.all(found.map((resource) =>
                resource.requestContent().then((content) => content, () => null)));
            archive = {log: {version: "1.2", creator: WI.HARBuilder.creator(), pages: [],
                entries: found.map((resource, index) => WI.HARBuilder.entry(resource, contents[index]))}};
        }
        archive.log.entries.forEach((entry, index) => {
            entry._requestId = found[index]?.requestIdentifier;
        });
        return {archive: JSON.stringify(archive), missing};
    }

    async function search(ids, query, {caseSensitive = false, regex = false} = {}) {
        if (typeof query !== "string" || !query)
            return [];
        let expression;
        try {
            expression = new RegExp(regex ? query : query.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), caseSensitive ? "" : "i");
        } catch {
            return [];
        }
        const results = [];
        for (const id of (Array.isArray(ids) ? ids : []).slice(0, 600)) {
            const item = await perchInspector.requestDetails(id).catch(() => null);
            if (!item)
                continue;
            const hits = [];
            const add = (where, text) => {
                if (typeof text !== "string" || !text || hits.length >= 50)
                    return;
                const lines = text.split(/\r?\n/);
                lines.forEach((line, index) => {
                    if (hits.length < 50 && expression.test(line))
                        hits.push({where, line: index + 1, text: line.slice(0, 300)});
                });
            };
            add("url", item.url);
            for (const [name, value] of item.requestHeaders ?? [])
                add("request header", name + ": " + value);
            for (const [name, value] of item.response?.headers ?? [])
                add("response header", name + ": " + value);
            if (item.postData)
                add("payload", item.postData);
            if (item.body && !item.base64Encoded)
                add("response", item.body.slice(0, 1048576));
            if (hits.length)
                results.push({id, hits});
        }
        return results;
    }

    function emulationTarget() {
        return [WI.pageTarget, WI.mainTarget, WI.backendTarget].find((target) =>
            target && !target.isDestroyed && target.hasCommand?.("Network.setEmulatedConditions") &&
            typeof target.NetworkAgent?.setEmulatedConditions?.invoke === "function");
    }

    function emulation() {
        const target = emulationTarget();
        const command = target?.NetworkAgent?.setEmulatedConditions;
        const parameters = (command?._instance?._command?._callSignature ?? []).map((item) => item.name);
        return {supported: !!target, parameters};
    }

    async function emulate({bandwidth = 0, latency = 0} = {}) {
        const target = emulationTarget();
        if (!target)
            throw new Error("This version of WebKit can’t limit bandwidth.");
        const bytes = Math.max(0, Math.round(Number(bandwidth) || 0));
        await target.NetworkAgent.setEmulatedConditions.invoke({
            bandwidth: bytes, latency: Math.max(0, Math.round(Number(latency) || 0)), bytesPerSecondLimit: bytes,
        });
        return true;
    }

    function state(since = 0) {
        if (((blockingEnabled && (matchers.length || throttles.length)) || rewritesRequests())
            && blockRule !== interceptionTarget())
            syncBlocking().catch(() => {});
        if (disabledImageTypes.length && imageRule !== headerTarget())
            syncImages().catch(() => {});
        if (headerRules.length && headerRule !== headerTarget())
            syncHeaders().catch(() => {});
        const changed = [];
        for (const item of rows.values()) {
            if (item.version > since)
                changed.push(item);
        }
        return {version, page, rows: changed.slice(-rowLimit), blockingActive: !!blockRule};
    }

    function frames(id, after = 0) {
        const list = sockets.get(id) ?? [];
        return {count: list.length, frames: list.slice(Math.max(0, after))};
    }

    function clear() {
        rows.clear();
        sockets.clear();
        blocked.clear();
        requestInfo.clear();
    }

    const connection = InspectorBackend.Connection?.prototype;
    const dispatchEvent = connection?._dispatchEvent;
    if (typeof dispatchEvent === "function") {
        connection._dispatchEvent = function(message) {
            try {
                if (imageIntercepted(message, this.target))
                    return;
            } catch {
                // WebKit's frontend releases the response.
            }
            try {
                if (headerIntercepted(message, this.target))
                    return;
            } catch {
                // WebKit's frontend releases the response.
            }
            try {
                if (blockIntercepted(message, this.target))
                    return;
            } catch {
                // The other handlers release the request.
            }
            try {
                if (throttleIntercepted(message, this.target))
                    return;
            } catch {
                // The page-wide throttling or WebKit's frontend releases it.
            }
            try {
                if (encodeIntercepted(message, this.target))
                    return;
            } catch {
                // WebKit's frontend releases it with the browser's encodings.
            }
            try {
                observe(message, this.target);
            } catch {}
            return dispatchEvent.apply(this, arguments);
        };
    }

    globalThis.perchNetwork = Object.freeze({
        state, frames, clear, setBlocking, setHeaderOverrides, har, search, emulation, emulate,
    });
    return true;
})()
