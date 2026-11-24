(() => {
    if (globalThis.perchConsole)
        return true;
    if (typeof WI === "undefined" || !globalThis.perchInspector)
        return false;
    const command = (method, params, targetId) => perchInspector.command(method, params, targetId ?? null);

    function text(value, limit) {
        return typeof value === "string" ? value.slice(0, limit) : undefined;
    }

    function address(value) {
        if (typeof value !== "string" || !value)
            return "";
        const opaque = /^(data|javascript|blob):/i.exec(value);
        if (opaque)
            return opaque[0];
        const path = value.split(/[?#]/, 1)[0];
        try {
            const url = new URL(path);
            url.username = "";
            url.password = "";
            return url.href.slice(0, 768);
        } catch {
            return path.slice(0, 768);
        }
    }

    function primitive(value) {
        if (value === null || value === undefined)
            return value;
        if (typeof value === "string")
            return value.slice(0, 10000);
        if (typeof value === "number" || typeof value === "boolean")
            return value;
        try {
            return JSON.stringify(value).slice(0, 10000);
        } catch {
            return String(value).slice(0, 10000);
        }
    }

    // WebKit's frontend swaps a payload's previews for WI.ObjectPreview
    // objects, whose fields carry a leading underscore.
    function field(data, name) {
        const value = data?.[name];
        return value !== undefined && value !== null ? value : data?.["_" + name];
    }

    function preview(data, depth = 0) {
        if (!data || typeof data !== "object")
            return undefined;
        const properties = field(data, "properties"), entries = field(data, "entries"), size = field(data, "size");
        const output = {
            type: text(field(data, "type"), 40), subtype: text(field(data, "subtype"), 40),
            description: text(field(data, "description"), 400),
            lossless: field(data, "lossless") === true, overflow: field(data, "overflow") === true,
            size: Number.isFinite(size) ? size : undefined,
        };
        if (Array.isArray(properties))
            output.properties = properties.slice(0, 100).map((item) => ({
                name: text(String(field(item, "name") ?? ""), 200), type: text(field(item, "type"), 40),
                subtype: text(field(item, "subtype"), 40), value: text(field(item, "value"), 400),
                internal: field(item, "internal") === true || undefined,
                valuePreview: depth < 1 ? preview(field(item, "valuePreview"), depth + 1) : undefined,
            }));
        if (Array.isArray(entries))
            output.entries = entries.slice(0, 50).map((entry) => ({
                key: field(entry, "key") ? preview(field(entry, "key"), depth + 1) : undefined,
                value: preview(field(entry, "value"), depth + 1),
            }));
        return output;
    }

    function remote(data) {
        if (!data || typeof data !== "object")
            return {type: "undefined"};
        return clean({
            type: text(data.type, 40) ?? "object", subtype: text(data.subtype, 40),
            className: text(data.className, 200), description: text(data.description, 10000),
            value: "value" in data ? primitive(data.value) : undefined,
            objectId: text(data.objectId, 300),
            size: Number.isFinite(data.size) ? data.size : undefined,
            preview: preview(data.preview),
        });
    }

    // Swift cannot bridge an object that holds `undefined`.
    function clean(value) {
        return JSON.parse(JSON.stringify(value));
    }

    function frames(trace) {
        const output = [];
        for (let current = trace, depth = 0; current && depth < 4 && output.length < 60; current = current.parentStackTrace, depth++) {
            const list = Array.isArray(current) ? current : current.callFrames;
            if (!Array.isArray(list))
                break;
            if (depth > 0 && list.length)
                output.push({functionName: "", url: "", lineNumber: 0, columnNumber: 0, asyncBoundary: true});
            for (const frame of list.slice(0, 40))
                output.push({
                    functionName: text(frame.functionName, 200) ?? "", url: address(frame.url),
                    lineNumber: Number.isFinite(frame.lineNumber) ? frame.lineNumber : 0,
                    columnNumber: Number.isFinite(frame.columnNumber) ? frame.columnNumber : 0,
                    ...(typeof frame.scriptId === "string" ? {scriptId: frame.scriptId.slice(0, 32)} : {}),
                });
            if (Array.isArray(current))
                break;
        }
        return output;
    }

    // Called by perchInspector while it projects Console.messageAdded.
    function extra(message) {
        const output = {};
        if (Array.isArray(message?.parameters))
            output.parameters = message.parameters.slice(0, 100).map(remote);
        if (message?.stackTrace)
            output.stackTrace = frames(message.stackTrace);
        return clean(output);
    }

    // The object tree DevTools shows when an object is expanded: own
    // properties, native getters, internal slots and, for Map and Set,
    // the entries.
    async function properties(objectId, subtype, targetId) {
        const collection = ["map", "set", "weakmap", "weakset", "iterator"].includes(subtype);
        const [displayable, entries] = await Promise.all([
            command("Runtime.getDisplayableProperties", {objectId, generatePreview: true, fetchStart: 0, fetchCount: 200}, targetId)
                .catch(() => command("Runtime.getProperties", {objectId, ownProperties: true, generatePreview: true}, targetId)),
            collection
                ? command("Runtime.getCollectionEntries", {objectId, fetchStart: 0, fetchCount: 100}, targetId).catch(() => null)
                : null,
        ]);
        const list = [];
        if (entries?.entries)
            list.push({name: "[[Entries]]", entries: entries.entries.slice(0, 100).map((entry) => ({
                key: entry.key ? remote(entry.key) : undefined, value: remote(entry.value),
            }))});
        for (const item of (displayable.properties ?? []).slice(0, 300)) {
            const name = String(item.name ?? "");
            const property = {
                name: name === "__proto__" ? "[[Prototype]]" : name.slice(0, 300),
                enumerable: item.enumerable === true, isOwn: item.isOwn !== false,
                wasThrown: item.wasThrown === true || undefined,
            };
            if (item.value)
                property.value = remote(item.value);
            else if (item.get)
                property.getter = true;
            list.push(property);
        }
        for (const item of (displayable.internalProperties ?? []).slice(0, 40))
            if (item.value)
                list.push({name: "[[" + String(item.name).slice(0, 100) + "]]", value: remote(item.value), internal: true});
        return clean({properties: list, more: (displayable.properties?.length ?? 0) >= 200});
    }

    async function invokeGetter(objectId, name, targetId) {
        const result = await command("Runtime.callFunctionOn", {
            objectId, functionDeclaration: "function(name) { return this[name]; }",
            arguments: [{value: name}], generatePreview: true, doNotPauseOnExceptionsAndMuteConsole: true,
        }, targetId);
        return {value: remote(result.result), wasThrown: result.wasThrown === true};
    }

    async function nodeId(objectId, targetId) {
        const result = await command("DOM.requestNode", {objectId}, targetId);
        return Number.isFinite(result.nodeId) ? result.nodeId : null;
    }

    // A statement such as `{a: 1}` reads as an object literal, as in
    // Chrome. Building the function only checks the syntax; it is never
    // called, and this runs in the inspector, not in the page.
    function wrapObjectLiteral(source) {
        const trimmed = source.trim();
        if (!/^\{[\s\S]*\}$/.test(trimmed))
            return source;
        try {
            new Function("return (" + trimmed + "\n)");
            return "(" + trimmed + "\n)";
        } catch {
            return source;
        }
    }

    // Where the prompt runs, as in Chrome DevTools: the selected call
    // frame while the debugger is paused (Debugger.evaluateOnCallFrame,
    // which sees the frame's locals and closures), else the JavaScript
    // context chosen in the Console's context selector, else the page.
    function place(where) {
        return where && typeof where === "object" ? where : {};
    }

    // WebKit's frontend refuses an argument that is present but
    // undefined, so only the ones that are set go through.
    function defined(params) {
        const output = {};
        for (const [key, value] of Object.entries(params))
            if (value !== undefined && value !== null)
                output[key] = value;
        return output;
    }

    async function run(params, targetId, where) {
        const at = place(where);
        const target = at.targetId ?? targetId;
        if (typeof at.callFrameId === "string" && at.callFrameId) {
            return command("Debugger.evaluateOnCallFrame", defined({
                callFrameId: at.callFrameId, expression: params.expression, objectGroup: params.objectGroup,
                includeCommandLineAPI: params.includeCommandLineAPI,
                doNotPauseOnExceptionsAndMuteConsole: params.doNotPauseOnExceptionsAndMuteConsole,
                returnByValue: params.returnByValue, generatePreview: params.generatePreview,
                saveResult: params.saveResult, emulateUserGesture: params.emulateUserGesture,
            }), target);
        }
        if (Number.isFinite(at.contextId) && at.contextId >= 0) {
            try {
                return await command("Runtime.evaluate", defined({...params, contextId: at.contextId}), target);
            } catch {
                // The context went away (its frame navigated or was
                // removed): Chrome falls back to top, and so does Perch.
                const result = await command("Runtime.evaluate", defined(params), targetId);
                return {...result, contextReset: true};
            }
        }
        return command("Runtime.evaluate", defined(params), target);
    }

    // Chrome's $1-$4 are the nodes picked before $0; WebKit's are saved
    // results. When the prompt names them, the expression runs in a
    // function that binds them to the Elements history. It runs on the
    // context's global object, so a paused frame's locals are not seen.
    async function withNodeHistory(source, nodes, targetId, where) {
        const resolved = [];
        for (const nodeId of nodes.slice(0, 5)) {
            const result = await command("DOM.resolveNode", {nodeId, objectGroup: "console"}, null).catch(() => null);
            resolved.push(result?.object?.objectId ? {objectId: result.object.objectId} : {value: undefined});
        }
        while (resolved.length < 5)
            resolved.push({value: undefined});
        const at = place(where);
        const global = await run({expression: "globalThis", objectGroup: "console"}, targetId,
            {contextId: at.contextId, targetId: at.targetId});
        return command("Runtime.callFunctionOn", {
            objectId: global.result.objectId,
            functionDeclaration: "function($0, $1, $2, $3, $4) { return eval(" + JSON.stringify(source) + "); }",
            arguments: resolved, generatePreview: true,
        }, at.targetId ?? targetId);
    }

    // The function an argument such as `greet` or `obj.method` names, and
    // where WebKit says it starts (Debugger.getFunctionDetails), for
    // monitor() and debug(); or the evaluation's result when it threw.
    async function functionStart(argument, helper, targetId, where) {
        const found = await run({
            expression: argument, objectGroup: "console", includeCommandLineAPI: true,
        }, targetId, where);
        if (found.wasThrown)
            return {thrown: found};
        if (found.result?.type !== "function" || !found.result.objectId)
            throw new Error(helper + "() needs a function.");
        const details = (await command("Debugger.getFunctionDetails", {functionId: found.result.objectId}, targetId)).details;
        const location = details?.location;
        if (!location)
            throw new Error("WebKit can't find where this function starts.");
        const key = location.scriptId + ":" + location.lineNumber + ":" + (location.columnNumber ?? 0);
        return {details, location, key};
    }

    // debug(fn) / undebug(fn): WebKit has neither, so, as Chrome does it,
    // a breakpoint where the function starts pauses its next call in
    // Sources; undebug() takes it away.
    const debugged = new Map;
    async function debug(argument, on, targetId, where) {
        const start = await functionStart(argument, on ? "debug" : "undebug", targetId, where);
        if (start.thrown)
            return start.thrown;
        const {location, key} = start;
        if (!on) {
            const breakpointId = debugged.get(key);
            debugged.delete(key);
            if (breakpointId)
                await command("Debugger.removeBreakpoint", {breakpointId}, targetId);
        } else if (!debugged.has(key)) {
            const result = await command("Debugger.setBreakpoint", {location, options: {autoContinue: false}}, targetId);
            debugged.set(key, result.breakpointId);
        }
        return {result: {type: "undefined"}};
    }

    // monitor(fn) / unmonitor(fn): WebKit has neither, so a breakpoint
    // that logs and continues stands in, with Chrome's wording.
    const monitored = new Map;
    async function monitor(argument, on, targetId, where) {
        const start = await functionStart(argument, on ? "monitor" : "unmonitor", targetId, where);
        if (start.thrown)
            return start.thrown;
        const {details, location, key} = start;
        if (!on) {
            const breakpointId = monitored.get(key);
            monitored.delete(key);
            if (breakpointId)
                await command("Debugger.removeBreakpoint", {breakpointId}, targetId);
        } else if (!monitored.has(key)) {
            const name = String(details.displayName || details.name || "(anonymous)").replace(/[^\w$.]/g, "");
            const data = "console.log(\"function " + name + " called\" + (typeof arguments !== \"undefined\" && arguments.length > 0 ? " +
                "\" with arguments: \" + Array.prototype.map.call(arguments, (value) => { try { return String(value); } catch { return typeof value; } }).join(\", \") : \"\"))";
            const result = await command("Debugger.setBreakpoint", {
                location, options: {autoContinue: true, actions: [{type: "evaluate", data}]},
            }, targetId);
            monitored.set(key, result.breakpointId);
        }
        return {result: {type: "undefined"}};
    }

    // `awaited`: the prompt was made an async function (top-level await,
    // DeveloperConsoleSyntax), so its promise is awaited for the result.
    async function evaluate(expression, nodes, userGesture, targetId, where, awaited = false) {
        const history = Array.isArray(nodes) ? nodes.filter(Number.isFinite) : [];
        if (history.length)
            await command("DOM.setInspectedNode", {nodeId: history[0]}, null).catch(() => {});
        let source = wrapObjectLiteral(String(expression));
        const monitorCall = /^\s*(un)?monitor\s*\(([\s\S]+)\)\s*;?\s*$/.exec(source);
        const debugCall = /^\s*(un)?debug\s*\(([\s\S]+)\)\s*;?\s*$/.exec(source);
        let result;
        if (monitorCall)
            result = await monitor(monitorCall[2], !monitorCall[1], targetId, where);
        else if (debugCall)
            result = await debug(debugCall[2], !debugCall[1], targetId, where);
        else {
            // Chrome's queryObjects(Constructor) is WebKit's queryInstances.
            source = source.replace(/\bqueryObjects\s*\(/g, "queryInstances(");
            result = /\$[1-4]\b/.test(source)
                ? await withNodeHistory(source, history.length ? history : [], targetId, where)
                : await run({
                    expression: source, objectGroup: "console", includeCommandLineAPI: true,
                    generatePreview: true, saveResult: !awaited, emulateUserGesture: userGesture !== false,
                }, targetId, where);
            if (awaited && !result.wasThrown && result.result?.objectId) {
                const settled = await command("Runtime.awaitPromise", {
                    promiseObjectId: result.result.objectId, generatePreview: true, saveResult: true,
                }, place(where).targetId ?? targetId).catch(() => null);
                if (settled)
                    result = {...settled, contextReset: result.contextReset};
            }
        }
        return {value: remote(result.result), wasThrown: result.wasThrown === true, contextReset: result.contextReset === true};
    }

    // Live expressions run as typed, side effects allowed, like Chrome's
    // pinned expressions once they are committed.
    async function live(expression, targetId) {
        const group = "perch-live";
        try {
            const result = await command("Runtime.evaluate", {
                expression: String(expression), objectGroup: group, includeCommandLineAPI: true,
                generatePreview: true, doNotPauseOnExceptionsAndMuteConsole: true,
            }, targetId);
            return {value: remote(result.result), wasThrown: result.wasThrown === true};
        } finally {
            command("Runtime.releaseObjectGroup", {objectGroup: group}, targetId).catch(() => {});
        }
    }

    async function storeAsGlobal(objectId, targetId) {
        const result = await command("Runtime.callFunctionOn", {
            objectId, returnByValue: true,
            functionDeclaration: "function() { let i = 1; while (Object.prototype.hasOwnProperty.call(globalThis, 'temp' + i)) i++; " +
                "globalThis['temp' + i] = this; return 'temp' + i; }",
        }, targetId);
        return typeof result.result?.value === "string" ? result.result.value : null;
    }

    async function copyText(objectId, targetId) {
        const result = await command("Runtime.callFunctionOn", {
            objectId, returnByValue: true, doNotPauseOnExceptionsAndMuteConsole: true,
            functionDeclaration: "function() { if (typeof Node !== 'undefined' && this instanceof Node) return this.outerHTML ?? this.textContent; " +
                "if (typeof this === 'function') return String(this); " +
                "try { const text = JSON.stringify(this, null, 2); return text === undefined ? String(this) : text; } catch { return String(this); } }",
        }, targetId);
        return typeof result.result?.value === "string" ? result.result.value.slice(0, 10000000) : null;
    }

    // Only reads that cannot run page code: a chain of plain data
    // properties or native getters (`document.body.children.length`),
    // or arithmetic on number literals. WebKit has no
    // throwOnSideEffect, so anything else gets no eager preview.
    const identifier = "[A-Za-z_$][\\w$]*";
    const pathPattern = new RegExp("^\\s*(" + identifier + ")((?:\\s*\\.\\s*" + identifier +
        "|\\s*\\[\\s*(?:\\d+|\"(?:[^\"\\\\]|\\\\.)*\"|'(?:[^'\\\\]|\\\\.)*')\\s*\\])*)\\s*$");
    const keywords = new Set(["await", "break", "case", "catch", "class", "const", "continue", "debugger",
        "default", "delete", "do", "else", "export", "extends", "finally", "for", "function", "if", "import",
        "in", "instanceof", "let", "new", "return", "super", "switch", "throw", "try", "typeof", "var",
        "void", "while", "with", "yield"]);

    function parsePath(source) {
        const match = pathPattern.exec(source);
        if (!match || keywords.has(match[1]))
            return null;
        const keys = [];
        const step = new RegExp("\\.\\s*(" + identifier + ")|\\[\\s*(\\d+|\"(?:[^\"\\\\]|\\\\.)*\"|'(?:[^'\\\\]|\\\\.)*')\\s*\\]", "g");
        for (const part of match[2].matchAll(step)) {
            if (part[1] !== undefined)
                keys.push(part[1]);
            else if (/^\d/.test(part[2]))
                keys.push(Number(part[2]));
            else
                keys.push(part[2].startsWith("'")
                    ? JSON.parse('"' + part[2].slice(1, -1).replace(/\\'/g, "'").replace(/"/g, '\\"') + '"')
                    : JSON.parse(part[2]));
        }
        return {root: match[1], keys};
    }

    // Runs in the page: walk the path, refusing user getters, proxies
    // and anything else that would call page code.
    const safeWalk = `function perchSafeRead(root, rootValue, keys) {
        const native = (fn) => { try { return /\\{\\s*\\[native code\\]\\s*\\}\\s*$/.test(Function.prototype.toString.call(fn)); } catch { return false; } };
        let value;
        if (rootValue.found) value = rootValue.value;
        else {
            let owner = globalThis, descriptor;
            while (owner && !(descriptor = Object.getOwnPropertyDescriptor(owner, root))) owner = Object.getPrototypeOf(owner);
            if (!descriptor) throw new Error("perch: unresolved");
            if ("value" in descriptor) value = descriptor.value;
            else if (descriptor.get && native(descriptor.get)) value = descriptor.get.call(globalThis);
            else throw new Error("perch: side effect");
        }
        for (const key of keys) {
            if (value === null || value === undefined) throw new Error("perch: unresolved");
            let owner = Object(value), descriptor;
            for (let depth = 0; owner && depth < 64 && !(descriptor = Object.getOwnPropertyDescriptor(owner, key)); depth++)
                owner = Object.getPrototypeOf(owner);
            if (!descriptor) { value = undefined; continue; }
            if ("value" in descriptor) value = descriptor.value;
            else if (descriptor.get && native(descriptor.get)) value = descriptor.get.call(value);
            else throw new Error("perch: side effect");
        }
        return value;
    }`;

    // The root of a path may be a page `let` binding or a console helper
    // such as $0 or $_: reading a bare identifier runs no page code
    // unless it is a global accessor, which perchSafeRead checks.
    function readExpression(path) {
        const root = JSON.stringify(path.root);
        return `(${safeWalk})(${root}, (() => { if (${root} in globalThis) return {found: false}; ` +
            `try { return {found: true, value: ${path.root}}; } catch { return {found: false}; } })(), ${JSON.stringify(path.keys)})`;
    }

    async function eager(source, inspectedNode, targetId, where) {
        if (/\$[1-4]\b/.test(source))
            return null;
        const trimmed = String(source).trim();
        if (!trimmed || trimmed.length > 500)
            return null;
        let expression = null;
        if (/^[\d\s+\-*/%().eE_]+$/.test(trimmed) && /\d/.test(trimmed) && !/\+\+|--/.test(trimmed))
            expression = trimmed;
        else {
            const path = parsePath(trimmed);
            if (!path)
                return null;
            expression = readExpression(path);
        }
        if (Number.isFinite(inspectedNode))
            await command("DOM.setInspectedNode", {nodeId: inspectedNode}, null).catch(() => {});
        const group = "perch-eager";
        try {
            const result = await run({
                expression, objectGroup: group, includeCommandLineAPI: true, generatePreview: true,
                doNotPauseOnExceptionsAndMuteConsole: true,
            }, targetId, where);
            if (result.wasThrown)
                return null;
            return {value: remote(result.result)};
        } finally {
            command("Runtime.releaseObjectGroup", {objectGroup: group}, targetId).catch(() => {});
        }
    }

    const commandLineAPI = ["$", "$$", "$0", "$1", "$2", "$3", "$4", "$_", "$x", "clear", "copy", "debug", "dir",
        "dirxml", "getEventListeners", "inspect", "keys", "monitor", "monitorEvents", "queryInstances", "queryHolders",
        "table", "undebug", "unmonitor", "unmonitorEvents", "values", "screenshot"];

    // Property names for `object.prefix`, or global names for a bare
    // word, as Chrome's prompt suggests them.
    // The variable names of a paused frame's scopes (locals, closures,
    // blocks), which a bare word completes from as in Chrome.
    async function scopeNames(scopes, targetId) {
        if (!Array.isArray(scopes))
            return [];
        const names = [];
        for (const objectId of scopes.slice(0, 12)) {
            if (typeof objectId !== "string")
                continue;
            const result = await command("Runtime.getProperties", {objectId, ownProperties: true}, targetId).catch(() => null);
            for (const item of (result?.properties ?? []).slice(0, 2000))
                if (typeof item.name === "string" && /^[A-Za-z_$][\w$]*$/.test(item.name))
                    names.push(item.name);
        }
        return names;
    }

    async function completions(source, targetId, where) {
        const input = String(source).slice(-500);
        const member = /([A-Za-z_$][\w$]*(?:\s*\.\s*[A-Za-z_$][\w$]*|\s*\[\s*\d+\s*\])*)\s*\.\s*([\w$]*)$/.exec(input);
        // ⌃Space asks for completions with nothing typed yet, as in
        // Chrome: every global (and, paused, every variable in scope).
        const bare = /(?:^|[^\w$.])([A-Za-z_$][\w$]*)$/.exec(input) ??
            (place(where).force && /(?:^|[^\w$.\]\)'"`])$/.test(input) ? [input, ""] : null);
        let expression, prefix, extraNames = [];
        if (member) {
            const path = parsePath(member[1]);
            if (!path)
                return {prefix: member[2], names: []};
            prefix = member[2];
            expression = readExpression(path);
        } else if (bare) {
            prefix = bare[1];
            expression = "globalThis";
            extraNames = [...commandLineAPI, ...keywords, "true", "false", "null", "undefined", "NaN", "Infinity"];
        } else
            return {prefix: "", names: []};
        const group = "perch-completions";
        try {
            if (!member)
                extraNames = [...await scopeNames(place(where).scopes, place(where).targetId ?? targetId), ...extraNames];
            const result = await run({
                expression: `(() => { const value = ${expression}; const names = new Set; ` +
                    `for (let o = (value === null || value === undefined) ? null : Object(value), d = 0; o && d < 32 && names.size < 4000; o = Object.getPrototypeOf(o), d++) ` +
                    `for (const name of Object.getOwnPropertyNames(o)) names.add(name); ` +
                    `return [...names].filter((name) => /^[A-Za-z_$][\\w$]*$/.test(name)); })()`,
                objectGroup: group, includeCommandLineAPI: true, returnByValue: true,
                doNotPauseOnExceptionsAndMuteConsole: true,
            }, targetId, where);
            const found = result.wasThrown || !Array.isArray(result.result?.value) ? [] : result.result.value;
            const lower = prefix.toLowerCase();
            const names = [...new Set([...found, ...extraNames])]
                .filter((name) => name !== prefix && name.toLowerCase().startsWith(lower))
                .sort((a, b) => (a.startsWith(prefix) === b.startsWith(prefix) ? 0 : a.startsWith(prefix) ? -1 : 1) ||
                    (a.startsWith("_") - b.startsWith("_")) || a.localeCompare(b))
                .slice(0, 60);
            return {prefix, names};
        } catch {
            return {prefix, names: []};
        } finally {
            command("Runtime.releaseObjectGroup", {objectGroup: group}, targetId).catch(() => {});
        }
    }

    // Chrome's JavaScript context selector: top, each frame's page
    // context, extensions' content scripts (WebKit's "user" worlds) and
    // workers. WebKit's frontend already keeps these from
    // Runtime.executionContextCreated / Destroyed, per frame.
    function contexts() {
        const output = [];
        const mainFrame = WI.networkManager?.mainFrame ?? null;
        const children = (frame) => {
            const collection = frame?.childFrameCollection;
            if (collection?.items)
                return [...collection.items];
            if (typeof collection?.toArray === "function")
                return collection.toArray();
            return Array.isArray(frame?.childFrames) ? frame.childFrames : [];
        };
        const frameTitle = (frame) => {
            const name = typeof frame?.name === "string" ? frame.name : "";
            if (name)
                return name.slice(0, 120);
            const url = typeof frame?.url === "string" ? frame.url : "";
            try {
                const parsed = new URL(url);
                const file = parsed.pathname.split("/").filter(Boolean).pop();
                return (file ? file + " (" + parsed.host + ")" : parsed.host || url).slice(0, 120);
            } catch {
                return url.slice(0, 120);
            }
        };
        const walk = (frame, depth) => {
            if (!frame || output.length >= 200 || depth > 12)
                return;
            const list = frame.executionContextList;
            const all = Array.isArray(list?.contexts) ? list.contexts : [];
            const page = list?.pageExecutionContext ?? all.find((context) => context.isPageContext || context.type === "normal");
            const isTop = frame === mainFrame;
            const ordered = page ? [page, ...all.filter((context) => context !== page)] : all;
            for (const context of ordered) {
                if (!Number.isFinite(context?.id))
                    continue;
                const type = typeof context.type === "string" ? context.type : (context.isPageContext ? "normal" : "user");
                if (type === "internal")
                    continue;
                const target = context.target ?? frame.target ?? null;
                output.push({
                    id: context.id, targetId: typeof target?.identifier === "string" ? target.identifier : null,
                    name: typeof context.name === "string" ? context.name.slice(0, 120) : "",
                    frame: frameTitle(frame), top: isTop && context === page, contentScript: context !== page && type !== "normal",
                    depth,
                });
            }
            for (const child of children(frame))
                walk(child, depth + 1);
        };
        walk(mainFrame, 0);
        for (const target of (WI.targets ? [...WI.targets] : [])) {
            if (output.length >= 220 || target?.type !== (WI.TargetType?.Worker ?? "worker"))
                continue;
            if (target.isDestroyed)
                continue;
            // Chrome's label: the worker's name, else its script's file.
            const custom = typeof target.customName === "string" ? target.customName : "";
            const address = typeof target.name === "string" ? target.name : "";
            let file = address;
            try {
                file = new URL(address).pathname.split("/").filter(Boolean).pop() || address;
            } catch {
                // A name rather than an address.
            }
            output.push({
                id: -1, targetId: typeof target.identifier === "string" ? target.identifier : null,
                name: String(custom || file || "worker").slice(0, 120),
                frame: String(custom || file || "worker").slice(0, 120),
                url: /^(data|blob|javascript):/i.test(address) ? address.split(":", 1)[0] + ":" : address.slice(0, 2048),
                top: false, contentScript: false, depth: 0, worker: true,
            });
        }
        return clean(output);
    }

    // An Error's `stack`, which WebKit leaves out of its description.
    async function errorStack(objectId, targetId) {
        const result = await command("Runtime.callFunctionOn", {
            objectId, returnByValue: true, doNotPauseOnExceptionsAndMuteConsole: true,
            functionDeclaration: "function() { try { const stack = this && this.stack; " +
                "return typeof stack === 'string' ? stack.slice(0, 20000) : null; } catch { return null; } }",
        }, targetId);
        return typeof result.result?.value === "string" ? result.result.value : null;
    }

    // A logged node as Chrome's console draws it: an element tree, each
    // child an object of its own so it can be opened, hovered and revealed.
    const describeNodes = "function() { const list = Array.isArray(this) ? this : [this]; return list.map((node) => { " +
        "if (!node || typeof node.nodeType !== 'number') return null; " +
        "const out = {type: node.nodeType, name: String(node.nodeName || '').slice(0, 200), children: 0}; " +
        "const shown = (child) => child.nodeType === 1 || child.nodeType === 8 || child.nodeType === 10 || (child.nodeType === 3 && /\\S/.test(child.data)); " +
        "if (node.nodeType === 1) { out.name = String(node.localName || out.name.toLowerCase()).slice(0, 200); " +
        "out.attributes = Array.from(node.attributes || []).slice(0, 60).map((a) => [String(a.name).slice(0, 200), String(a.value).slice(0, 500)]); " +
        "const kids = Array.from(node.childNodes || []).filter(shown); out.children = kids.length + (node.shadowRoot ? 1 : 0); " +
        "if (!node.shadowRoot && kids.length === 1 && kids[0].nodeType === 3 && kids[0].data.length <= 80) { out.text = kids[0].data.trim(); out.children = 0; } } " +
        "else if (node.nodeType === 3 || node.nodeType === 8) out.text = String(node.data).slice(0, 500); " +
        "else if (node.nodeType === 10) out.name = String(node.name).slice(0, 200); " +
        "else if (node.nodeType === 11 && node.host) { out.name = '#shadow-root (' + node.mode + ')'; out.children = Array.from(node.childNodes).filter(shown).length; } " +
        "else if (node.nodeType === 9 || node.nodeType === 11) out.children = Array.from(node.childNodes).filter(shown).length; " +
        "return out; }); }";
    const childList = "function() { const shown = (child) => child.nodeType === 1 || child.nodeType === 8 || child.nodeType === 10 || (child.nodeType === 3 && /\\S/.test(child.data)); " +
        "const kids = Array.from(this.childNodes || []).filter(shown); if (this.shadowRoot) kids.unshift(this.shadowRoot); return kids.slice(0, 300); }";

    async function nodeTree(objectId, targetId) {
        const own = await command("Runtime.callFunctionOn", {
            objectId, functionDeclaration: describeNodes, returnByValue: true, doNotPauseOnExceptionsAndMuteConsole: true,
        }, targetId);
        const summary = Array.isArray(own.result?.value) ? own.result.value[0] : null;
        if (!summary || !(summary.children > 0))
            return clean({summary, children: []});
        const array = await command("Runtime.callFunctionOn", {
            objectId, functionDeclaration: childList, objectGroup: "console", doNotPauseOnExceptionsAndMuteConsole: true,
        }, targetId);
        const arrayId = array.result?.objectId;
        if (!arrayId)
            return clean({summary, children: []});
        const [summaries, listed] = await Promise.all([
            command("Runtime.callFunctionOn", {
                objectId: arrayId, functionDeclaration: describeNodes, returnByValue: true, doNotPauseOnExceptionsAndMuteConsole: true,
            }, targetId),
            command("Runtime.getProperties", {objectId: arrayId, ownProperties: true}, targetId),
        ]);
        const objects = new Map;
        for (const item of listed.properties ?? [])
            if (/^\d+$/.test(String(item.name)) && item.value)
                objects.set(Number(item.name), item.value);
        const children = (Array.isArray(summaries.result?.value) ? summaries.result.value : [])
            .map((child, index) => ({summary: child, object: objects.has(index) ? remote(objects.get(index)) : undefined}))
            .filter((child) => child.summary);
        return clean({summary, children});
    }

    // "Store as global variable" on a property whose value has no object
    // id (a string, a number): the parent's property is stored instead.
    async function storePropertyAsGlobal(objectId, name, targetId) {
        const result = await command("Runtime.callFunctionOn", {
            objectId, returnByValue: true, arguments: [{value: name}],
            functionDeclaration: "function(name) { let i = 1; while (Object.prototype.hasOwnProperty.call(globalThis, 'temp' + i)) i++; " +
                "globalThis['temp' + i] = this[name]; return 'temp' + i; }",
        }, targetId);
        return typeof result.result?.value === "string" ? result.result.value : null;
    }

    globalThis.perchConsole = Object.freeze({
        extra, properties, invokeGetter, nodeId, evaluate, eager, completions, parsePath, live, storeAsGlobal, copyText,
        contexts, errorStack, nodeTree, storePropertyAsGlobal,
    });
    return true;
})()