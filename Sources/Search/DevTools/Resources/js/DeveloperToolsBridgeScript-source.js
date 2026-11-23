(() => {
    if (globalThis.perchInspector)
        return true;
    if (typeof WI === "undefined" || typeof InspectorBackend === "undefined" ||
        typeof InspectorFrontendHost === "undefined")
        return false;

    // Keep WebKit's native window hidden when its frontend handles a
    // breakpoint or an element pick. Closing our dock destroys this
    // frontend before a standalone Web Inspector can open.
    try {
        Object.defineProperty(InspectorFrontendHost, "bringToFront", {
            configurable: true,
            value() {},
        });
    } catch {
        // Older frontends may expose an immutable host object.
    }

    const domains = new Set([
        "Console", "Runtime", "DOM", "CSS", "DOMDebugger", "Page", "Target",
        "Debugger", "Network", "Timeline", "Animation", "Canvas", "LayerTree",
        "DOMStorage", "Storage", "IndexedDB", "Heap", "Memory", "CPUProfiler",
        "ScriptProfiler", "Audit", "ServiceWorker",
    ]);
    // Events wait here between drains. Losing one in the middle (a
    // Network.requestWillBeSent, a DOM.childNodeInserted) leaves a panel
    // wrong for good, so none is overwritten: past the cap new ones are
    // dropped and the next drain says so (a "Perch.eventsDropped" event
    // at its end), and the app reads the document again.
    const limit = 20000;
    let enabled = new Set;
    let pending = [];
    let overflowed = false;

    // The worker targets seen at the last drain. A change is noted here as
    // well as by TargetManager's events, which a bridge installed before
    // WebKit's frontend made its target manager never hears.
    let workerSignature = "";

    function noteWorkerChanges() {
        if (!enabled.has("Target"))
            return;
        let ids = [];
        try {
            ids = Array.from(WI.targetManager?.targets ?? []).filter(isWorker).map((target) => target.identifier);
        } catch {
            return;
        }
        const signature = ids.join("\n");
        if (signature === workerSignature)
            return;
        workerSignature = signature;
        if (pending.length < limit)
            pending.push({method: "Target.workersChanged", params: {}});
        else
            overflowed = true;
    }

    function drain() {
        noteWorkerChanges();
        const result = pending;
        pending = [];
        if (overflowed) {
            overflowed = false;
            result.push({method: "Perch.eventsDropped", params: {}});
        }
        return result;
    }

    // Where a console evaluation's reply came, among the events: what the
    // expression logged comes before its result, what happened after it
    // comes after, as in Chrome.
    function mark(token) {
        pending.push({method: "Perch.evaluated", params: {token: String(token).slice(0, 64)}});
    }

    function setDomains(names) {
        const requested = new Set(Array.isArray(names) ? names.filter((name) => domains.has(name)) : []);
        if (requested.size === enabled.size && [...requested].every((name) => enabled.has(name)))
            return;
        enabled = requested;
        // The overflow flag stays for the next drain.
        pending = pending.filter(({method}) => method.startsWith("Perch.") || enabled.has(method.split(".")[0]));
    }

    function targetDescription(target) {
        if (!target || target.isDestroyed || target.isProvisional || typeof target.identifier !== "string")
            return null;
        return {id: target.identifier, type: typeof target.type === "string" ? target.type : "unknown"};
    }

    function targetById(id) {
        if (id == null)
            return null;
        return WI.targetManager?.targetForIdentifier?.(id) ??
            [WI.mainTarget, WI.pageTarget, WI.backendTarget].find((target) => target?.identifier === id);
    }

    function protocolCommand(method, targetId) {
        if (typeof method !== "string")
            return null;
        const name = /^([A-Z][A-Za-z0-9]*)\.([a-z][A-Za-z0-9]*)$/.exec(method);
        if (!name || !domains.has(name[1]))
            return null;
        const targets = targetId == null
            ? [WI.mainTarget, WI.pageTarget, WI.backendTarget]
            : [targetById(targetId)];
        for (const target of targets) {
            if (!targetDescription(target) || !target.hasCommand?.(method))
                continue;
            const command = target[name[1] + "Agent"]?.[name[2]];
            if (typeof command?.invoke === "function")
                return {command, target};
        }
        return null;
    }

    async function command(method, params = {}, targetId = null) {
        const call = protocolCommand(method, targetId);
        if (!call)
            throw new Error("WebKit does not support " + method + " on this target.");
        return (await call.command.invoke(params ?? {})) ?? {};
    }

    function supports(method, targetId = null) {
        return !!protocolCommand(method, targetId);
    }

    function frontendNode(id, targetId) {
        const target = targetById(targetId);
        if (target?.type === "frame")
            return WI.domManager?.nodeForIdInFrameTarget?.(id, target);
        return WI.domManager?.nodeForId?.(id);
    }

    function describeNode(current) {
        const output = {
            nodeId: current.backendNodeId ?? current.id,
            nodeType: current.nodeType(),
            nodeName: current.nodeName(),
            childNodeCount: current.childNodeCount || 0,
        };
        // ::before and #shadow-root rows, ordered as Chrome orders them.
        const pseudoType = typeof current.pseudoType === "function" ? current.pseudoType() : null;
        const shadowRootType = typeof current.shadowRootType === "function" ? current.shadowRootType() : null;
        if (pseudoType)
            output.pseudoType = pseudoType;
        if (shadowRootType)
            output.shadowRootType = shadowRootType;
        return output;
    }

    function nodePath(id, targetId) {
        const path = [];
        for (let current = frontendNode(id, targetId); current && path.length < 100; current = current.parentNode)
            path.unshift(describeNode(current));
        return path;
    }

    // A rule's declarations replaced as Web Inspector writes them: the
    // ones switched off stay in the text as comments.
    function setStyleText(styleId, text, targetId) {
        if (!styleId || typeof styleId.styleSheetId !== "string" || typeof text !== "string")
            throw new Error("This rule can't be edited.");
        return command("CSS.setStyleText", {styleId, text}, targetId);
    }

    function listenerSource(location, target) {
        let url = "";
        try {
            const script = WI.debuggerManager?.scriptForIdentifier?.(location?.scriptId, target);
            url = script?.url ?? script?.sourceURL ?? "";
        } catch {}
        return {scriptId: location?.scriptId ?? null, line: location?.lineNumber ?? null,
            column: location?.columnNumber ?? null, url: String(url).slice(0, 1024)};
    }

    // Runs on the selected node in the inspected page. The functions are
    // returned as remote objects so the debugger can find their locations.
    function inPageFrameworkListeners(includeAncestors) {
        const metadata = [], handlers = [], dispatchers = [], nodes = [];
        const ancestors = new Set;
        const page = this.ownerDocument?.defaultView;
        const jquery = page?.jQuery;
        const jqueryData = jquery?._data ?? jquery?.data;
        let node = this;
        while (node && ancestors.size < 100 && !ancestors.has(node) && metadata.length < 100) {
            ancestors.add(node);
            // Its index lets the frontend match this node to the native list.
            const owner = nodes.push(node) - 1;
            const name = node.nodeName?.toLowerCase() ?? "";
            const id = node.getAttribute?.("id");
            const classes = node.getAttribute?.("class")?.trim();
            const target = node === page ? "window" : name === "#document" ? "document" : name
                + (id ? "#" + id : "")
                + (classes ? "." + classes.split(/\s+/).slice(0, 3).join(".") : "");

            function add(type, framework, handler, useCapture = false, dispatcher = null, nativeType = type) {
                if (metadata.length >= 100 || typeof handler !== "function")
                    return;
                metadata.push({type: String(type).slice(0, 100), nativeType: String(nativeType).slice(0, 100),
                    framework, target: target.slice(0, 200), name: String(handler.name ?? "").slice(0, 200), useCapture,
                    owner: node === page ? "window" : owner});
                handlers.push(handler);
                dispatchers.push(typeof dispatcher === "function" ? dispatcher : null);
            }
            if (typeof jqueryData === "function") {
                try {
                    const events = jqueryData.call(jquery, node, "events") ?? {};
                    const dispatcher = jqueryData.call(jquery, node, "handle");
                    for (const type of Object.keys(events).slice(0, 100)) {
                        const entries = events[type];
                        if (!Array.isArray(entries))
                            continue;
                        for (const entry of entries.slice(0, 100))
                            add(entry?.origType ?? type, "jQuery", entry?.handler ?? entry, false, dispatcher, type);
                    }
                } catch {}
            }

            // Chrome's hook for any framework: window.devtoolsFrameworkEventListeners,
            // functions that take a node and return {eventListeners, internalHandlers}.
            // The internal handlers are the framework's own DOM listeners, which
            // the native list then leaves out.
            const fetchers = page?.devtoolsFrameworkEventListeners;
            if (Array.isArray(fetchers)) {
                for (const fetcher of fetchers.slice(0, 20)) {
                    if (typeof fetcher !== "function")
                        continue;
                    try {
                        const found = fetcher(node) ?? {};
                        const internal = Array.isArray(found.internalHandlers)
                            ? found.internalHandlers.filter((handler) => typeof handler === "function") : [];
                        const entries = Array.isArray(found.eventListeners) ? found.eventListeners : [];
                        for (const entry of entries.slice(0, 100)) {
                            if (typeof entry?.type !== "string")
                                continue;
                            add(entry.type, "Framework", entry.handler, !!entry.useCapture, internal[0] ?? null);
                        }
                    } catch {}
                }
            }

            // React exposes its host event props here in React DOM builds
            // that attach them to the node. Delegated DOM dispatchers stay
            // in the native list for the events React handles at the root.
            const propsKey = Object.getOwnPropertyNames(node).find((key) =>
                key.startsWith("__reactProps$") || key.startsWith("__reactEventHandlers$"));
            const props = propsKey ? Object.getOwnPropertyDescriptor(node, propsKey)?.value : null;
            if (props) {
                for (const key of Object.keys(props).slice(0, 300)) {
                    if (!/^on[A-Z][A-Za-z0-9]*$/.test(key))
                        continue;
                    const capture = key.endsWith("Capture");
                    const type = key.slice(2, capture ? -7 : undefined).toLowerCase();
                    // The DOM events React listens to for these props.
                    const types = {doubleclick: ["dblclick"], change: ["input", "change"],
                        focus: ["focusin"], blur: ["focusout"]}[type] ?? [type];
                    for (const domType of types)
                        add(domType, "React", Object.getOwnPropertyDescriptor(props, key)?.value, capture);
                }
            }
            if (!includeAncestors)
                break;
            node = node.assignedSlot ?? node.parentNode ?? node.host ?? node.defaultView;
        }
        return {metadata, handlers, dispatchers, nodes};
    }

    let listenerRead = 0;
    async function frameworkListeners(nodeId, targetId, includeAncestors, target) {
        const objectGroup = "perch-framework-listeners-" + ++listenerRead;
        try {
            const resolved = await command("DOM.resolveNode", {nodeId, objectGroup}, targetId);
            const objectId = resolved.object?.objectId;
            if (!objectId)
                return [];
            const result = await command("Runtime.callFunctionOn", {objectId,
                functionDeclaration: String(inPageFrameworkListeners),
                arguments: [{value: !!includeAncestors}], doNotPauseOnExceptionsAndMuteConsole: true,
            }, targetId);
            const resultId = result.result?.objectId;
            if (!resultId || result.wasThrown)
                return [];
            async function ownProperties(objectId) {
                const reply = await command("Runtime.getProperties", {objectId, ownProperties: true}, targetId);
                return new Map((reply.properties ?? []).map((item) => [item.name, item.value]));
            }
            const parts = await ownProperties(resultId);
            const [metadata, handlers, dispatchers, nodes] = await Promise.all([
                command("Runtime.callFunctionOn", {objectId: resultId,
                    functionDeclaration: "function () { return this.metadata; }", returnByValue: true}, targetId),
                ownProperties(parts.get("handlers")?.objectId), ownProperties(parts.get("dispatchers")?.objectId),
                ownProperties(parts.get("nodes")?.objectId),
            ]);
            // The node each jQuery dispatcher is on, as the native list
            // names it, so the dispatcher row is matched by node.
            const nodeReads = new Map;
            function ownerNode(owner) {
                if (owner === "window")
                    return Promise.resolve("window");
                const objectId = nodes.get(String(owner))?.objectId;
                if (!objectId)
                    return Promise.resolve(null);
                if (!nodeReads.has(objectId))
                    nodeReads.set(objectId, command("DOM.requestNode", {objectId}, targetId)
                        .then((reply) => reply.nodeId ?? null).catch(() => null));
                return nodeReads.get(objectId);
            }
            const functionReads = new Map;
            function details(functionId) {
                if (!functionId)
                    return Promise.resolve(null);
                if (!functionReads.has(functionId))
                    functionReads.set(functionId, command("Debugger.getFunctionDetails", {functionId}, targetId)
                        .then((reply) => reply.details).catch(() => null));
                return functionReads.get(functionId);
            }
            return await Promise.all((metadata.result?.value ?? []).map(async (item, index) => {
                const [handler, dispatcher] = await Promise.all([
                    details(handlers.get(String(index))?.objectId), details(dispatchers.get(String(index))?.objectId),
                ]);
                const owner = dispatcher?.location ? await ownerNode(item.owner) : null;
                return {
                    id: -index - 1, type: item.type, target: item.target, useCapture: item.useCapture,
                    framework: item.framework, handler: String(handler?.displayName || handler?.name || item.name).slice(0, 200),
                    ...listenerSource(handler?.location, target),
                    nativeType: item.nativeType, dispatcher: dispatcher?.location, owner,
                };
            }));
        } catch {
            return [];
        } finally {
            await command("Runtime.releaseObjectGroup", {objectGroup}, targetId).catch(() => {});
        }
    }

    async function eventListeners(nodeId, targetId, includeAncestors, includeFramework) {
        const result = await command("DOM.getEventListenersForNode", {nodeId, includeAncestors: !!includeAncestors}, targetId);
        const target = targetById(targetId) ?? WI.mainTarget;
        const native = (result.listeners ?? []).slice(0, 500).map((listener) => {
            const node = listener.nodeId != null ? frontendNode(listener.nodeId, targetId) : null;
            let label = listener.onWindow ? "window" : "";
            try {
                if (!label && node) {
                    const name = node.nodeName?.().toLowerCase() ?? "";
                    const id = node.getAttribute?.("id");
                    const classes = node.getAttribute?.("class")?.trim();
                    label = name === "#document" ? "document" : name +
                        (id ? "#" + id : "") + (classes ? "." + classes.split(/\s+/).slice(0, 3).join(".") : "");
                }
            } catch {}
            return {
                id: listener.eventListenerId, type: String(listener.type ?? "").slice(0, 100),
                useCapture: !!listener.useCapture, isAttribute: !!listener.isAttribute,
                nodeId: listener.nodeId ?? null, target: label.slice(0, 200),
                handler: String(listener.handlerName ?? "").slice(0, 200),
                passive: !!listener.passive, once: !!listener.once, disabled: !!listener.disabled,
                ...listenerSource(listener.location, target),
            };
        });
        if (!includeFramework)
            return native;
        const resolved = await frameworkListeners(nodeId, targetId, includeAncestors, target);
        // Replace a verified jQuery dispatcher with its application
        // handlers. A native callback with similar names is still shown.
        // Matched by node rather than label, which the two lists build from
        // different reads of id and class.
        const dispatchers = new Set(resolved.flatMap(({dispatcher, nativeType, owner}) => dispatcher?.scriptId && owner != null
            ? [JSON.stringify([owner, nativeType, dispatcher.scriptId, dispatcher.lineNumber, dispatcher.columnNumber])]
            : []));
        return native.filter((item) => !dispatchers.has(JSON.stringify([
            item.target === "window" ? "window" : item.nodeId, item.type, item.scriptId, item.line, item.column])))
            .concat(resolved.map(({dispatcher, nativeType, owner, ...item}) => item));
    }

    const requestStage = "request";
    const conditionRule = {url: "^https?://", stage: requestStage, isRegex: true, caseSensitive: false};
    const conditionCommands = [
        "setInterceptionEnabled", "addInterception", "removeInterception",
        "interceptContinue", "interceptRequestWithError",
    ];
    let condition = null;
    let updatingCondition = Promise.resolve();

    function networkTarget(commands) {
        return [WI.pageTarget, WI.mainTarget, WI.backendTarget].find((target) =>
            targetDescription(target) && commands.every((name) =>
                target.hasCommand?.("Network." + name) &&
                typeof target.NetworkAgent?.[name]?.invoke === "function"));
    }

    function interceptionTarget() {
        const target = networkTarget(conditionCommands);
        return target?.hasEvent?.("Network.requestIntercepted") === false ? null : target;
    }

    async function networkCall(target, name, params) {
        const call = target.NetworkAgent?.[name];
        if (typeof call?.invoke !== "function")
            throw new Error("WebKit does not support Network." + name + ".");
        let deadline;
        try {
            return await Promise.race([
                call.invoke(params),
                new Promise((_, reject) => {
                    deadline = setTimeout(() => reject(new Error("WebKit did not finish Network." + name + ".")), 2000);
                }),
            ]);
        } finally {
            clearTimeout(deadline);
        }
    }

    function continueRequest(target, requestId) {
        return networkCall(target, "interceptContinue", {requestId, stage: requestStage});
    }

    function isConditionedRequest(message, target) {
        if (!condition || condition.target !== target ||
            message?.method !== "Network.requestIntercepted")
            return false;
        const {requestId, request} = message.params ?? {};
        if (typeof requestId !== "string" || !/^https?:\/\//i.test(request?.url ?? ""))
            return false;
        const overrides = WI.networkManager?.localResourceOverridesForURL?.(request.url) ?? [];
        if (overrides.some((override) => !override.disabled && override.networkStage === requestStage))
            return false;

        const mode = condition;
        if (mode.offline) {
            networkCall(target, "interceptRequestWithError", {requestId, errorType: "General"})
                .catch(() => continueRequest(target, requestId)).catch(() => {});
        } else if (mode.held.size >= 128) {
            // A busy page should not leave a large backlog of paused loads.
            continueRequest(target, requestId).catch(() => {});
        } else if (!mode.held.has(requestId)) {
            mode.held.set(requestId, setTimeout(() => {
                mode.held.delete(requestId);
                continueRequest(target, requestId).catch(() => {});
            }, mode.latency));
        }
        return true;
    }

    async function clearConditions() {
        const mode = condition;
        condition = null;
        if (!mode)
            return;
        const requests = [];
        for (const [requestId, timer] of mode.held) {
            clearTimeout(timer);
            if (!mode.target.isDestroyed)
                requests.push(continueRequest(mode.target, requestId));
        }
        mode.held.clear();
        if (mode.target.isDestroyed)
            return;
        await Promise.allSettled(requests);
        try {
            if (mode.addedRule)
                await networkCall(mode.target, "removeInterception", conditionRule);
        } finally {
            if (mode.enabledInterception)
                await networkCall(mode.target, "setInterceptionEnabled", {enabled: false});
        }
    }

    function networkConditions({latency = 0, offline = false} = {}) {
        const changed = updatingCondition.then(async () => {
            if (!Number.isFinite(latency) || latency < 0 || latency > 5000 || typeof offline !== "boolean")
                throw new Error("Choose a request delay from 0 to 5000 ms.");
            const target = latency || offline ? interceptionTarget() : null;
            if ((latency || offline) && (!eventCapture || !target))
                throw new Error("WebKit request interception is unavailable for this page.");

            await clearConditions();
            if (!target)
                return {latency: 0, offline: false, targetId: null};
            if (target.isDestroyed)
                throw new Error("The page’s inspector target changed.");
            const mode = {target, latency, offline, held: new Map, addedRule: false, enabledInterception: false};
            condition = mode;
            try {
                if (WI.networkManager?.interceptionEnabled === false) {
                    await networkCall(target, "setInterceptionEnabled", {enabled: true});
                    mode.enabledInterception = true;
                }
                await networkCall(target, "addInterception", conditionRule);
                mode.addedRule = true;
            } catch (error) {
                await clearConditions().catch(() => {});
                throw error;
            }
            return {latency, offline, targetId: target.identifier};
        });
        updatingCondition = changed.catch(() => {});
        return changed;
    }

    function fields(source, names) {
        const output = {};
        for (const name of names.split(" ")) {
            const value = source?.[name];
            if (typeof value === "string")
                output[name] = value.slice(0, name === "text" ? 1800 : 512);
            else if (typeof value === "boolean" || Number.isFinite(value))
                output[name] = value;
        }
        return output;
    }

    // At most `limit` items, spread evenly over the whole list rather than
    // cut from one end, so a long recording keeps samples from start to end.
    function thinned(items, limit) {
        if (!Array.isArray(items) || items.length <= limit)
            return items;
        const output = [];
        for (let index = 0; index < limit; index++)
            output.push(items[Math.floor(index * items.length / limit)]);
        return output;
    }

    // keepQuery: the whole address, query and fragment too, as the Network
    // panel lists, filters and copies it (Chrome's "data?from-script").
    function urlFields(target, source, names, keepQuery = false) {
        for (const name of names.split(" ")) {
            const value = source?.[name];
            if (!value || typeof value !== "string")
                continue;
            const opaque = /^(data|javascript|blob):/i.exec(value);
            if (opaque) {
                target[name] = opaque[0];
                continue;
            }
            if (value.length > (keepQuery ? 16384 : 4096))
                continue;
            const path = keepQuery ? value : value.split(/[?#]/, 1)[0];
            // URL parsing also strips credential-bearing authority from URLs.
            try {
                const url = new URL(path);
                url.username = "";
                url.password = "";
                target[name] = url.href.slice(0, keepQuery ? 16384 : 768);
            } catch {
                target[name] = path.replace(/^\/\/[^/]*@/, "//").slice(0, keepQuery ? 16384 : 768);
            }
        }
        return target;
    }

    const diagnosticHeaders = new Set([
        "accept", "accept-encoding", "accept-language", "age", "cache-control",
        "content-encoding", "content-length", "content-type", "etag", "expires",
        "last-modified", "server-timing", "vary",
    ]);

    function headers(source) {
        const output = {};
        for (const key in source) {
            if (diagnosticHeaders.has(key.toLowerCase()) && typeof source[key] === "string")
                output[key.toLowerCase()] = source[key].slice(0, 512);
        }
        return output;
    }

    function response(data) {
        return {
            ...urlFields(fields(data, "status statusText mimeType source fromDiskCache"), data, "url"),
            headers: headers(data?.headers),
            timing: fields(data?.timing, "startTime redirectStart redirectEnd fetchStart domainLookupStart domainLookupEnd connectStart connectEnd secureConnectionStart requestStart responseStart responseEnd"),
            security: securityDetails(data?.security),
        };
    }

    // The Security panel's Connection and Certificate for the response's origin.
    function securityDetails(security) {
        if (!security || typeof security !== "object")
            return null;
        const names = (list) => Array.isArray(list)
            ? list.filter((name) => typeof name === "string").slice(0, 100).map((name) => name.slice(0, 512)) : [];
        const certificate = security.certificate;
        return {
            ...fields(security.connection, "protocol cipher"),
            certificate: certificate && typeof certificate === "object" ? {
                ...fields(certificate, "subject validFrom validUntil"),
                dnsNames: names(certificate.dnsNames),
                ipAddresses: names(certificate.ipAddresses),
            } : null,
        };
    }

    function location(data) {
        return fields(data, "scriptId lineNumber columnNumber");
    }

    // DOM nodes in events: identity, text, and the one text child WebKit
    // sends inline with an element (Chrome's <li>text</li> row).
    // Beside the children, as Chrome DevTools' tree shows them: the
    // node's pseudo-elements, shadow roots, template content and frame
    // document, each by identity alone.
    function node(data, nested = false) {
        const output = fields(data, "nodeId nodeType nodeName localName nodeValue childNodeCount shadowRootType pseudoType");
        if (Array.isArray(data?.layoutFlags))
            output.layoutFlags = data.layoutFlags.slice(0, 12).filter((flag) => typeof flag === "string");
        const only = Array.isArray(data?.children) && data.children.length === 1 ? data.children[0] : null;
        if (only?.nodeType === 3)
            output.children = [fields(only, "nodeId nodeType nodeName nodeValue childNodeCount")];
        if (nested)
            return output;
        if (Array.isArray(data?.pseudoElements) && data.pseudoElements.length)
            output.pseudoElements = data.pseudoElements.slice(0, 8).map((item) => node(item, true));
        if (Array.isArray(data?.shadowRoots) && data.shadowRoots.length)
            output.shadowRoots = data.shadowRoots.slice(0, 8).map((item) => node(item, true));
        if (data?.templateContent)
            output.templateContent = node(data.templateContent, true);
        if (data?.contentDocument)
            output.contentDocument = node(data.contentDocument, true);
        return output;
    }

    // The Performance panel's flame chart: each record's kind and times,
    // the details its tooltip and Summary show, a few frames of the call
    // stack that caused it, and its nested records.
    function timelineFrames(stack) {
        const frames = Array.isArray(stack) ? stack : stack?.callFrames;
        if (!Array.isArray(frames))
            return undefined;
        return frames.slice(0, 5).map((frame) =>
            urlFields(fields(frame, "functionName lineNumber columnNumber"), frame, "url"));
    }

    function timeline(data, depth = 0) {
        const record = fields(data, "type startTime endTime");
        if (data?.data && typeof data.data === "object") {
            record.data = urlFields(fields(data.data,
                "type scriptLine lineNumber columnNumber timerId timeout singleShot id title message x y width height"),
                data.data, "url scriptName");
            // Performance's screenshots: the Screenshot instrument's frames.
            if (data.type === "Screenshot" && typeof data.data.imageData === "string" && data.data.imageData.length < 4000000)
                record.data.imageData = data.data.imageData;
        }
        const frames = timelineFrames(data?.stackTrace);
        if (frames?.length)
            record.stackTrace = frames;
        if (depth < 24 && Array.isArray(data?.children))
            record.children = data.children.slice(0, 200).map((child) => timeline(child, depth + 1));
        return record;
    }

    // Model updates use identifiers and timing. Sensitive and potentially
    // large fields are deliberately absent from the background stream.
    const simpleEvents = {
        "Console.messageRepeatCountUpdated": "count timestamp",
        "Console.messagesCleared": "reason",
        "DOM.documentUpdated": "",
        // Application's Local and Session storage read again on a change;
        // keys and values stay out of the stream.
        "DOMStorage.domStorageItemAdded": "",
        "DOMStorage.domStorageItemRemoved": "",
        "DOMStorage.domStorageItemUpdated": "",
        "DOMStorage.domStorageItemsCleared": "",
        "DOM.attributeModified": "nodeId name",
        "DOM.attributeRemoved": "nodeId name",
        "DOM.characterDataModified": "nodeId",
        "DOM.childNodeCountUpdated": "nodeId childNodeCount",
        "DOM.childNodeRemoved": "parentNodeId nodeId",
        "DOM.willDestroyDOMNode": "nodeId",
        "Page.frameDetached": "frameId",
        "Page.domContentEventFired": "timestamp",
        "Page.loadEventFired": "timestamp",
        "Network.loadingFailed": "requestId timestamp errorText canceled",
        "Network.webSocketWillSendHandshakeRequest": "requestId timestamp",
        "Network.webSocketClosed": "requestId timestamp",
        "Debugger.globalObjectCleared": "",
        "Debugger.resumed": "",
        "Runtime.executionContextDestroyed": "executionContextId",
        "Runtime.executionContextsCleared": "",
        "Target.targetDestroyed": "targetId",
        "Target.didCommitProvisionalTarget": "oldTargetId newTargetId",
        "Timeline.recordingStarted": "startTime",
        "Timeline.recordingStopped": "endTime",
        "Timeline.autoCaptureStarted": "",
        "Memory.memoryPressure": "timestamp severity",
        "Memory.trackingStart": "timestamp",
        "Memory.trackingComplete": "timestamp",
        "CPUProfiler.trackingStart": "timestamp",
        "CPUProfiler.trackingComplete": "timestamp",
    };

    function remoteObject(data) {
        return fields(data, "type subtype className description objectId value");
    }

    function scriptURL(scriptId, target) {
        try {
            const script = WI.debuggerManager?.scriptForIdentifier?.(scriptId, target ?? WI.mainTarget);
            return script?.url ?? script?.sourceURL ?? "";
        } catch {
            return "";
        }
    }

    function asyncStackTrace(trace, target, depth = 0) {
        if (!Array.isArray(trace?.callFrames) || depth >= 32)
            return null;
        return {
            ...fields(trace, "topCallFrameIsBoundary"),
            callFrames: trace.callFrames.slice(0, 32).map((frame) => urlFields(
                fields(frame, "functionName scriptId lineNumber columnNumber"),
                {url: frame.url || scriptURL(frame.scriptId, target)}, "url")),
            parentStackTrace: asyncStackTrace(trace.parentStackTrace, target, depth + 1),
        };
    }

    // Why the debugger paused, as the sidebar's banner explains it.
    function pauseData(reason, data) {
        if (!data || typeof data !== "object")
            return {};
        if (reason === "exception" || reason === "assert")
            return remoteObject(data);
        return urlFields(fields(data, "breakpointId type nodeId targetNodeId insertion eventName eventListenerId directive message"),
            data, "url breakpointURL");
    }

    function project(method, data, target) {
        if (Object.hasOwn(simpleEvents, method))
            return fields(data, simpleEvents[method]);
        switch (method) {
        case "Console.messageAdded":
            return {message: {...urlFields(
                fields(data.message, "source level type text line column repeatCount networkRequestId timestamp"),
                data.message, "url"), ...(globalThis.perchConsole?.extra?.(data.message) ?? {})}};
        case "DOM.setChildNodes":
            return {...fields(data, "parentId"), nodes: data.nodes?.slice(0, 800).map((item) => node(item)) ?? []};
        case "DOM.childNodeInserted":
            return {...fields(data, "parentNodeId previousNodeId"), node: node(data.node)};
        case "DOM.shadowRootPushed":
            return {...fields(data, "hostId"), root: node(data.root)};
        case "DOM.shadowRootPopped":
            return fields(data, "hostId rootId");
        case "DOM.pseudoElementAdded":
            return {...fields(data, "parentId"), pseudoElement: node(data.pseudoElement)};
        case "DOM.pseudoElementRemoved":
            return fields(data, "parentId pseudoElementId");
        case "Page.frameNavigated":
            return {frame: urlFields(fields(data.frame, "id parentId loaderId name mimeType"), data.frame, "url", true)};
        case "Network.requestWillBeSent": {
            const event = urlFields(fields(data, "requestId frameId loaderId timestamp walltime type targetId"), data, "documentURL");
            event.request = {...urlFields(fields(data.request, "method"), data.request, "url", true), headers: headers(data.request?.headers)};
            if (data.initiator)
                event.initiator = urlFields(fields(data.initiator, "type lineNumber nodeId"), data.initiator, "url", true);
            if (data.redirectResponse)
                event.redirectResponse = response(data.redirectResponse);
            return event;
        }
        case "Network.responseReceived":
            return {...fields(data, "requestId frameId loaderId timestamp type"), response: response(data.response)};
        case "Network.requestServedFromMemoryCache":
            return {
                ...urlFields(fields(data, "requestId frameId loaderId timestamp"), data, "documentURL"),
                initiator: urlFields(fields(data.initiator, "type"), data.initiator, "url", true),
                resource: {
                    ...urlFields(fields(data.resource, "type bodySize"), data.resource, "url", true),
                    response: response(data.resource?.response),
                },
            };
        case "Network.loadingFinished":
            return {
                ...fields(data, "requestId timestamp"),
                metrics: {
                    ...fields(data.metrics, "protocol priority requestHeaderBytesSent requestBodyBytesSent responseHeaderBytesReceived responseBodyBytesReceived responseBodyDecodedSize"),
                    // WebKit reports the TLS protocol and cipher here, not on the response.
                    securityConnection: fields(data.metrics?.securityConnection, "protocol cipher"),
                },
            };
        case "Network.webSocketCreated":
            return urlFields(fields(data, "requestId"), data, "url");
        case "Network.webSocketHandshakeResponseReceived":
            return {...fields(data, "requestId timestamp"), response: fields(data.response, "status statusText")};
        case "Debugger.scriptParsed":
            return urlFields(fields(data, "scriptId startLine startColumn endLine endColumn isContentScript module"), data, "url sourceURL sourceMapURL");
        case "Debugger.scriptFailedToParse":
            return urlFields(fields(data, "startLine errorLine errorMessage"), data, "url");
        case "Debugger.breakpointResolved":
            return {...fields(data, "breakpointId"), location: location(data.location)};
        case "Debugger.paused":
            return {
                ...fields(data, "reason"),
                data: pauseData(data.reason, data.data),
                asyncStackTrace: asyncStackTrace(data.asyncStackTrace, target),
                callFrames: data.callFrames?.slice(0, 32).map((frame) => ({
                    ...fields(frame, "callFrameId functionName isTailDeleted"),
                    location: location(frame.location),
                    // The debugger sidebar's Scope pane and frame links.
                    ...urlFields({}, {url: scriptURL(frame.location?.scriptId, target)}, "url"),
                    this: remoteObject(frame.this),
                    scopeChain: frame.scopeChain?.slice(0, 24).map((scope) => ({
                        ...fields(scope, "type name empty"),
                        object: remoteObject(scope.object),
                        ...(scope.location ? {location: location(scope.location)} : {}),
                    })) ?? [],
                })) ?? [],
            };
        case "Runtime.executionContextCreated":
            return {context: fields(data.context, "id type name frameId isPageContext")};
        case "Target.targetCreated":
            return {targetInfo: fields(data.targetInfo, "targetId type isProvisional isPaused")};
        case "Timeline.eventRecorded":
            return {record: timeline(data.record)};
        case "ScriptProfiler.trackingComplete":
            // Frames come innermost first: the outermost 24 keep each
            // sample's place under the script record it ran in.
            return {samples: {stackTraces: thinned(data.samples?.stackTraces, 6000)?.map((trace) => ({
                ...fields(trace, "timestamp"),
                stackFrames: trace.stackFrames?.slice(-24).map((frame) =>
                    urlFields(fields(frame, "name line column"), frame, "url")) ?? [],
            })) ?? []}};
        case "Memory.trackingUpdate":
            return {event: {
                ...fields(data.event, "timestamp"),
                categories: data.event?.categories?.slice(0, 12).map((item) => fields(item, "type size")) ?? [],
            }};
        case "CPUProfiler.trackingUpdate":
            return {event: {
                ...fields(data.event, "timestamp usage"),
                threads: data.event?.threads?.slice(0, 24).map((thread) => fields(thread, "name usage type targetId")) ?? [],
            }};
        case "Heap.garbageCollected":
            return {collection: fields(data.collection, "type startTime endTime")};
        case "Heap.trackingStart":
        case "Heap.trackingComplete":
            // Snapshot strings are parsed off the main thread in the Memory panel.
            return {...fields(data, "timestamp"), snapshotData: data.snapshotData};
        default:
            return null;
        }
    }

    // Full request and response details, kept only for the requests the
    // Network panel lists and handed over one at a time when a request is
    // selected (requestDetails), the way DevTools shows them.
    const detailLimit = 600;
    const details = new Map;

    function headerList(source) {
        if (!source || typeof source !== "object")
            return [];
        return Object.keys(source).slice(0, 200).filter((key) => typeof source[key] === "string")
            .map((key) => [key.slice(0, 256), source[key].slice(0, 8192)]);
    }

    function remember(method, data, target) {
        const id = data?.requestId;
        if (typeof id !== "string")
            return;
        let item = details.get(id);
        if (method === "Network.requestWillBeSent" || method === "Network.requestServedFromMemoryCache") {
            const request = data.request ?? data.resource ?? {};
            item = {
                targetId: typeof target?.identifier === "string" ? target.identifier : null,
                url: typeof request.url === "string" ? request.url.slice(0, 16384) : "",
                method: typeof request.method === "string" ? request.method : "GET",
                requestHeaders: headerList(request.headers),
                postData: typeof request.postData === "string" ? request.postData.slice(0, 262144) : null,
                initiator: data.initiator ? {
                    type: data.initiator.type ?? null, url: data.initiator.url ?? null,
                    lineNumber: data.initiator.lineNumber ?? null,
                    stack: (data.initiator.stackTrace?.callFrames ?? data.initiator.stackTrace ?? [])
                        .slice?.(0, 20).map((frame) => ({
                            functionName: frame.functionName ?? "", url: frame.url ?? "",
                            lineNumber: frame.lineNumber ?? null, columnNumber: frame.columnNumber ?? null,
                        })) ?? [],
                } : null,
                response: null,
                metrics: null,
            };
            details.delete(id);
            details.set(id, item);
            while (details.size > detailLimit)
                details.delete(details.keys().next().value);
            if (method === "Network.requestServedFromMemoryCache" && request.response)
                item.response = responseDetails(request.response);
            return;
        }
        if (!item)
            return;
        if (method === "Network.responseReceived")
            item.response = responseDetails(data.response);
        else if (method === "Network.loadingFinished")
            item.metrics = fields(data.metrics, "protocol priority remoteAddress connectionIdentifier requestHeaderBytesSent requestBodyBytesSent responseHeaderBytesReceived responseBodyBytesReceived responseBodyDecodedSize");
        else if (method === "Network.loadingFailed")
            item.failure = typeof data.errorText === "string" ? data.errorText : "Failed";
        if (method === "Network.loadingFinished" && data.metrics?.requestHeaders)
            item.requestHeaders = headerList(data.metrics.requestHeaders);
    }

    function responseDetails(data) {
        if (!data)
            return null;
        return {
            ...fields(data, "status statusText mimeType source fromDiskCache"),
            url: typeof data.url === "string" ? data.url.slice(0, 16384) : null,
            headers: headerList(data.headers),
            requestHeaders: headerList(data.requestHeaders),
            security: data.security?.connection ? fields(data.security.connection, "protocol cipher") : null,
        };
    }

    async function requestDetails(requestId) {
        const item = details.get(requestId);
        if (!item)
            return null;
        let body = null, base64Encoded = false, bodyError = null;
        const targets = [item.targetId, null];
        for (const targetId of targets) {
            try {
                const result = await command("Network.getResponseBody", {requestId}, targetId);
                if (typeof result.body === "string") {
                    body = result.body.slice(0, 4194304);
                    base64Encoded = result.base64Encoded === true;
                }
                bodyError = null;
                break;
            } catch (error) {
                bodyError = String(error?.message ?? error);
            }
        }
        return {...item, body, base64Encoded, bodyError};
    }

    function capture(message, target) {
        const method = message?.method;
        if (typeof method === "string" && method.startsWith("Network.") && enabled.has("Network")) {
            try {
                remember(method, message.params ?? {}, target);
            } catch {
                // Details are a convenience; the list still updates.
            }
        }
        if (typeof method !== "string" || !enabled.has(method.split(".")[0]))
            return;
        const params = project(method, message.params ?? {}, target);
        if (!params)
            return;
        const event = {method, params};
        if (typeof target?.identifier === "string")
            event.targetId = target.identifier;
        if (pending.length < limit)
            pending.push(event);
        else
            overflowed = true;
    }

    const connection = InspectorBackend.Connection?.prototype;
    const dispatchEvent = connection?._dispatchEvent;
    let eventCapture = false;
    if (typeof dispatchEvent === "function") {
        try {
            connection._dispatchEvent = function(message) {
                try {
                    if (isConditionedRequest(message, this.target))
                        return;
                } catch {
                    // WebKit's own handler can release the request.
                }
                const result = dispatchEvent.apply(this, arguments);
                try {
                    capture(message, this.target);
                } catch {
                    // The extra diagnostic stream must not interrupt WebKit.
                }
                return result;
            };
            eventCapture = true;
        } catch {
            // Command routing can still work if the event hook changed.
        }
    }

    // A line in a loaded script, for Continue to here.
    function scriptLocation(url, lineNumber, targetId) {
        const target = targetById(targetId) ?? WI.mainTarget;
        const scripts = WI.debuggerManager?.scriptsForURL?.(url, target) ?? [];
        const script = scripts.find((item) => !item.range ||
            (item.range.startLine <= lineNumber && lineNumber <= item.range.endLine)) ?? scripts[0];
        return script?.id != null ? {scriptId: String(script.id), lineNumber, columnNumber: 0} : null;
    }

    // Pause on exceptions through WebKit's own exception breakpoints, so the
    // frontend's state agrees and it re-sends it to new targets. Null
    // arguments leave a side as it is.
    function pauseOnExceptions(uncaught, caught) {
        const all = WI.debuggerManager?.allExceptionsBreakpoint;
        const uncaughtBreakpoint = WI.debuggerManager?.uncaughtExceptionsBreakpoint;
        if (!all || !uncaughtBreakpoint)
            return null;
        if (uncaught != null)
            uncaughtBreakpoint.disabled = !uncaught;
        if (caught != null)
            all.disabled = !caught;
        return {uncaught: !uncaughtBreakpoint.disabled, caught: !all.disabled};
    }

    function capabilities() {
        const main = targetDescription(WI.mainTarget ?? WI.pageTarget);
        const network = eventCapture ? targetDescription(interceptionTarget()) : null;
        const targets = Array.from(WI.targetManager?.targets ?? []).slice(0, 128)
            .map(targetDescription).filter(Boolean);
        return {
            ready: !!main,
            eventCapture,
            mainTargetId: main?.id ?? null,
            domTargetId: protocolCommand("DOM.getDocument", null)?.target.identifier ?? null,
            runtimeTargetId: protocolCommand("Runtime.evaluate", null)?.target.identifier ?? null,
            requestInterception: !!network,
            networkTargetId: network?.id ?? null,
            networkConditionsTargetId: targetDescription(condition?.target)?.id ?? null,
            targets,
        };
    }

    // Dedicated workers. WebKit's frontend makes a WI.WorkerTarget for each
    // (Worker.workerCreated on the page, or Target.targetCreated) and its
    // events come through the same connection hook, marked with the
    // worker's identifier. The app is told when the list changes.
    function isWorker(target) {
        return target?.type === (WI.TargetType?.Worker ?? "worker") && !target.isDestroyed &&
            typeof target.identifier === "string";
    }

    function workers() {
        return Array.from(WI.targetManager?.targets ?? []).filter(isWorker).slice(0, 64).map((target) => {
            const address = typeof target.mainResource?.url === "string" && target.mainResource.url
                ? target.mainResource.url : (typeof target.name === "string" ? target.name : "");
            // The scripts the worker loaded (its own and importScripts()),
            // as WebKit's frontend keeps them from Debugger.scriptParsed.
            let data = null;
            try {
                data = WI.debuggerManager?.dataForTarget?.(target) ?? null;
            } catch {
                data = null;
            }
            const scripts = Array.from(data?.scripts ?? []).filter((script) => script &&
                (typeof script.url === "string" && script.url || typeof script.sourceURL === "string" && script.sourceURL))
                .slice(0, 400).map((script) => urlFields({id: String(script.id)},
                    {url: script.url || script.sourceURL}, "url", true))
                .filter((script) => typeof script.url === "string");
            return urlFields({
                id: target.identifier,
                name: typeof target.customName === "string" ? target.customName.slice(0, 200) : "",
                parentId: typeof target.parentTarget?.identifier === "string" ? target.parentTarget.identifier : null,
                paused: data?.paused === true,
                scripts,
            }, {url: address}, "url", true);
        });
    }

    function workersChanged(target) {
        if (!isWorker(target) && target?.type !== (WI.TargetType?.Worker ?? "worker"))
            return;
        if (!enabled.has("Target"))
            return;
        if (pending.length < limit)
            pending.push({method: "Target.workersChanged", params: {}, targetId: target.identifier});
        else
            overflowed = true;
    }

    // Line breakpoints by URL, set in every worker as Chrome sets them:
    // the app's list, applied to the workers there now and, before a new
    // one runs its first line, to each worker WebKit starts.
    let workerBreakpoints = [];
    let workerBreakpointsActive = true;
    const workerBreakpointIds = new WeakMap;

    function applyWorkerBreakpoints(target) {
        const agent = target?.DebuggerAgent;
        if (!isWorker(target) || typeof agent?.setBreakpointByUrl?.invoke !== "function")
            return;
        let ids = workerBreakpointIds.get(target);
        if (!ids) {
            ids = new Map;
            workerBreakpointIds.set(target, ids);
        }
        const wanted = new Set(workerBreakpoints.map((item) => item.key));
        for (const [key, id] of [...ids]) {
            if (wanted.has(key))
                continue;
            ids.delete(key);
            // An id still on its way is removed when it arrives (below).
            if (id)
                agent.removeBreakpoint?.invoke?.({breakpointId: id})?.catch?.(() => {});
        }
        for (const item of workerBreakpoints) {
            if (ids.has(item.key))
                continue;
            ids.set(item.key, null);
            Promise.resolve(agent.setBreakpointByUrl.invoke(item.params)).then((result) => {
                const id = result?.breakpointId ?? null;
                if (ids.has(item.key))
                    ids.set(item.key, id);
                else if (id)
                    agent.removeBreakpoint?.invoke?.({breakpointId: id})?.catch?.(() => {});
            }).catch(() => {
                if (ids.get(item.key) === null)
                    ids.delete(item.key);
            });
        }
        if (typeof agent.setBreakpointsActive?.invoke === "function" && (!workerBreakpointsActive || target.perchBreakpointsInactive)) {
            target.perchBreakpointsInactive = !workerBreakpointsActive;
            Promise.resolve(agent.setBreakpointsActive.invoke({active: workerBreakpointsActive})).catch(() => {});
        }
    }

    function setWorkerBreakpoints(list, active) {
        workerBreakpoints = (Array.isArray(list) ? list : []).slice(0, 2000)
            .filter((params) => params && typeof params === "object" && typeof params.url === "string")
            .map((params) => ({key: JSON.stringify(params), params}));
        workerBreakpointsActive = active !== false;
        for (const target of Array.from(WI.targetManager?.targets ?? []).filter(isWorker))
            applyWorkerBreakpoints(target);
        return true;
    }

    try {
        const targetPrototype = WI.Target?.prototype;
        const resumeIfPaused = targetPrototype?._resumeIfPaused;
        if (typeof resumeIfPaused === "function" && !resumeIfPaused.perchWorkers) {
            // Runs at the end of a target's initialize(), after its
            // Debugger.enable and before the worker is let go.
            const wrapped = function() {
                try {
                    if (isWorker(this))
                        applyWorkerBreakpoints(this);
                } catch {
                    // The worker runs without them.
                }
                return resumeIfPaused.apply(this, arguments);
            };
            wrapped.perchWorkers = true;
            targetPrototype._resumeIfPaused = wrapped;
        }
        // The Console's inspect(node): WebKit's frontend would select the
        // node in its own hidden Elements and release the object; the app
        // is given the object instead, to select the node in its Elements
        // (and release it there).
        const domManager = WI.DOMManager?.prototype;
        const inspectNodeObject = domManager?.inspectNodeObject;
        if (typeof inspectNodeObject === "function" && !inspectNodeObject.perchInspect) {
            const wrappedInspect = function(remoteObject) {
                const objectId = remoteObject?.objectId;
                if (typeof objectId !== "string" || !enabled.has("DOM"))
                    return inspectNodeObject.apply(this, arguments);
                if (pending.length < limit)
                    pending.push({method: "Perch.inspectNode", params: {objectId: objectId.slice(0, 500)}});
                else
                    overflowed = true;
            };
            wrappedInspect.perchInspect = true;
            domManager.inspectNodeObject = wrappedInspect;
        }
        // Threads pause on their own, as in Chrome: WebKit's frontend pauses
        // every other target when one pauses (debuggerDidPause calls each
        // one's pauseIfNeeded), so a worker's breakpoint would stop the page
        // too and resuming the worker would leave the page stopped. The
        // app's Pause sends Debugger.pause to one target itself.
        const debuggerManager = WI.DebuggerManager?.prototype;
        const debuggerData = WI.DebuggerData?.prototype;
        const didPause = debuggerManager?.debuggerDidPause;
        const pauseIfNeeded = debuggerData?.pauseIfNeeded;
        if (typeof didPause === "function" && typeof pauseIfNeeded === "function" && !didPause.perchThreads) {
            let inDidPause = false;
            const wrappedDidPause = function() {
                inDidPause = true;
                try {
                    return didPause.apply(this, arguments);
                } finally {
                    inDidPause = false;
                }
            };
            wrappedDidPause.perchThreads = true;
            debuggerManager.debuggerDidPause = wrappedDidPause;
            debuggerData.pauseIfNeeded = function() {
                return inDidPause ? Promise.resolve() : pauseIfNeeded.apply(this, arguments);
            };
        }
        const manager = WI.targetManager;
        const events = WI.TargetManager?.Event;
        if (manager && events?.TargetAdded) {
            manager.addEventListener(events.TargetAdded, (event) => workersChanged(event?.data?.target), globalThis);
            manager.addEventListener(events.TargetRemoved, (event) => workersChanged(event?.data?.target), globalThis);
        }
    } catch {
        // Workers stay out of the lists if WebKit's frontend changed.
    }

    globalThis.perchInspector = Object.freeze({
        command, supports, drain, setDomains, capabilities, networkConditions, nodePath,
        requestDetails, clearRequestDetails: () => details.clear(), setStyleText, eventListeners,
        scriptLocation, pauseOnExceptions, workers, setWorkerBreakpoints, mark,
    });
    return true;
})()
