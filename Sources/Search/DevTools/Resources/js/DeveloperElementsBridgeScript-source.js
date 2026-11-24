if (!globalThis.perchElements && globalThis.perchInspector) {
    const {command} = perchInspector;

    // The DOM as the backend has described it to this connection, kept
    // here because WebKit's own frontend only models the document while
    // its Elements tab is open: attributes, text, children and layout.
    const mirrors = new Map;
    function targetKey(targetId) {
        return String(targetId ?? perchInspector.capabilities().domTargetId);
    }
    function mirrorFor(targetId) {
        const key = targetKey(targetId);
        let map = mirrors.get(key);
        if (!map) {
            map = new Map;
            mirrors.set(key, map);
        }
        return map;
    }
    function remember(map, node, parentId) {
        if (!node || typeof node.nodeId !== "number" || map.size > 60000)
            return;
        const old = map.get(node.nodeId);
        const item = {
            nodeId: node.nodeId, parentId: parentId ?? old?.parentId ?? null,
            nodeType: node.nodeType ?? old?.nodeType, nodeName: node.nodeName ?? old?.nodeName ?? "",
            nodeValue: typeof node.nodeValue === "string" ? node.nodeValue.slice(0, 300) : old?.nodeValue ?? "",
            attributes: Array.isArray(node.attributes) ? node.attributes.slice(0, 120).map((value) => String(value).slice(0, 300)) : old?.attributes ?? [],
            childNodeCount: node.childNodeCount ?? old?.childNodeCount ?? 0,
            layoutFlags: Array.isArray(node.layoutFlags) ? node.layoutFlags : old?.layoutFlags ?? [],
            children: old?.children ?? null,
            pseudoType: typeof node.pseudoType === "string" ? node.pseudoType : old?.pseudoType ?? null,
            shadowRootType: typeof node.shadowRootType === "string" ? node.shadowRootType : old?.shadowRootType ?? null,
            pseudo: old?.pseudo ?? null, shadowRoots: old?.shadowRoots ?? null,
            template: old?.template ?? null, contentDocument: old?.contentDocument ?? null,
        };
        map.set(node.nodeId, item);
        if (Array.isArray(node.children)) {
            item.children = node.children.map((child) => child.nodeId);
            for (const child of node.children)
                remember(map, child, node.nodeId);
        }
        // What WebKit sends beside the children: pseudo-elements, shadow
        // roots, a template's content and a frame's document.
        if (Array.isArray(node.pseudoElements)) {
            item.pseudo = node.pseudoElements.map((child) => child.nodeId);
            for (const child of node.pseudoElements)
                remember(map, child, node.nodeId);
        }
        if (Array.isArray(node.shadowRoots)) {
            item.shadowRoots = node.shadowRoots.map((child) => child.nodeId);
            for (const child of node.shadowRoots)
                remember(map, child, node.nodeId);
        }
        if (node.templateContent && typeof node.templateContent.nodeId === "number") {
            item.template = node.templateContent.nodeId;
            remember(map, node.templateContent, node.nodeId);
        }
        if (node.contentDocument && typeof node.contentDocument.nodeId === "number") {
            item.contentDocument = node.contentDocument.nodeId;
            remember(map, node.contentDocument, node.nodeId);
        }
    }

    // As in Chrome DevTools: a node's rows in the tree are ::marker,
    // ::before, its shadow roots (not the browser's own, which Chrome
    // shows only with "Show user agent shadow DOM" on), a template's
    // content, a frame's document, the children, then ::after.
    const pseudoRank = {marker: 0, before: 1};
    // Settings › Preferences › Elements › "Show user agent shadow DOM".
    let userAgentShadowDOM = false;
    function treeChildren(map, item) {
        if (!item)
            return [];
        const leading = [], trailing = [];
        for (const id of item.pseudo ?? []) {
            const type = map.get(id)?.pseudoType;
            if (type in pseudoRank)
                leading.push(id);
            else
                trailing.push(id);
        }
        leading.sort((a, b) => pseudoRank[map.get(a)?.pseudoType] - pseudoRank[map.get(b)?.pseudoType]);
        trailing.sort((a, b) => (map.get(a)?.pseudoType === "after" ? 0 : 1) - (map.get(b)?.pseudoType === "after" ? 0 : 1));
        for (const id of item.shadowRoots ?? []) {
            if (userAgentShadowDOM || map.get(id)?.shadowRootType !== "user-agent")
                leading.push(id);
        }
        if (item.template != null)
            leading.push(item.template);
        if (item.contentDocument != null)
            leading.push(item.contentDocument);
        const seen = new Set;
        return [...leading, ...(item.children ?? []), ...trailing].filter((id) => !seen.has(id) && seen.add(id));
    }
    // The rows beside the children (a frame's document is already one of
    // WebKit's children: its count includes it).
    function extraCount(map, item) {
        const light = new Set(item?.children ?? []);
        return treeChildren(map, item).filter((id) => !light.has(id) && id !== item.contentDocument).length;
    }
    function treeCount(map, item) {
        return (item?.childNodeCount ?? 0) + extraCount(map, item);
    }
    function attributeIndex(node, name) {
        return node ? node.attributes.findIndex((value, at) => at % 2 === 0 && value === name) : -1;
    }
    function observe(method, params, target) {
        if (typeof method !== "string" || (!method.startsWith("DOM.") && method !== "CSS.nodeLayoutFlagsChanged"))
            return;
        const map = mirrorFor(target?.identifier);
        switch (method) {
        case "DOM.documentUpdated":
            map.clear();
            pageFlagReads.delete(targetKey(target?.identifier));
            if (overlayPings.has(targetKey(target?.identifier)))
                clearPageOverlays(target?.identifier);
            break;
        case "DOM.setChildNodes": {
            const ids = (params.nodes ?? []).map((node) => node.nodeId);
            for (const node of params.nodes ?? [])
                remember(map, node, params.parentId);
            const parent = map.get(params.parentId);
            if (parent)
                parent.children = ids;
            else
                map.set(params.parentId, {nodeId: params.parentId, parentId: null, attributes: [], nodeValue: "",
                    layoutFlags: [], children: ids, partial: true});
            break;
        }
        case "DOM.childNodeInserted": {
            remember(map, params.node, params.parentNodeId);
            const parent = map.get(params.parentNodeId);
            if (parent?.children && params.node) {
                const at = params.previousNodeId ? parent.children.indexOf(params.previousNodeId) + 1 : 0;
                parent.children.splice(at, 0, params.node.nodeId);
            }
            break;
        }
        case "DOM.childNodeRemoved": {
            const parent = map.get(params.parentNodeId);
            if (parent?.children)
                parent.children = parent.children.filter((id) => id !== params.nodeId);
            map.delete(params.nodeId);
            break;
        }
        case "DOM.attributeModified": {
            const node = map.get(params.nodeId);
            if (!node)
                break;
            const index = attributeIndex(node, params.name);
            const value = String(params.value ?? "").slice(0, 300);
            if (index >= 0)
                node.attributes[index + 1] = value;
            else
                node.attributes.push(String(params.name).slice(0, 300), value);
            break;
        }
        case "DOM.attributeRemoved": {
            const node = map.get(params.nodeId);
            const index = attributeIndex(node, params.name);
            if (index >= 0)
                node.attributes.splice(index, 2);
            break;
        }
        case "DOM.characterDataModified": {
            const node = map.get(params.nodeId);
            if (node)
                node.nodeValue = String(params.characterData ?? "").slice(0, 300);
            break;
        }
        case "DOM.childNodeCountUpdated": {
            const node = map.get(params.nodeId);
            if (node)
                node.childNodeCount = params.childNodeCount;
            break;
        }
        case "DOM.shadowRootPushed": {
            const host = map.get(params.hostId);
            if (!host || typeof params.root?.nodeId !== "number")
                break;
            remember(map, params.root, params.hostId);
            host.shadowRoots = [...(host.shadowRoots ?? []).filter((id) => id !== params.root.nodeId), params.root.nodeId];
            break;
        }
        case "DOM.shadowRootPopped": {
            const host = map.get(params.hostId);
            if (host?.shadowRoots)
                host.shadowRoots = host.shadowRoots.filter((id) => id !== params.rootId);
            map.delete(params.rootId);
            break;
        }
        case "DOM.pseudoElementAdded": {
            const parent = map.get(params.parentId);
            if (!parent || typeof params.pseudoElement?.nodeId !== "number")
                break;
            remember(map, params.pseudoElement, params.parentId);
            parent.pseudo = [...(parent.pseudo ?? []).filter((id) => id !== params.pseudoElement.nodeId), params.pseudoElement.nodeId];
            break;
        }
        case "DOM.pseudoElementRemoved": {
            const parent = map.get(params.parentId);
            if (parent?.pseudo)
                parent.pseudo = parent.pseudo.filter((id) => id !== params.pseudoElementId);
            map.delete(params.pseudoElementId);
            break;
        }
        case "CSS.nodeLayoutFlagsChanged": {
            const node = map.get(params.nodeId);
            if (node)
                node.layoutFlags = params.layoutFlags ?? [];
            else
                map.set(params.nodeId, {nodeId: params.nodeId, parentId: null, attributes: [], nodeValue: "",
                    layoutFlags: params.layoutFlags ?? [], children: null, partial: true});
            break;
        }
        }
    }
    const connection = InspectorBackend.Connection?.prototype;
    const dispatchEvent = connection?._dispatchEvent;
    if (typeof dispatchEvent === "function") {
        connection._dispatchEvent = function(message) {
            const result = dispatchEvent.apply(this, arguments);
            try {
                observe(message?.method, message?.params ?? {}, this.target);
            } catch {}
            return result;
        };
    }

    function layoutKind(node) {
        const flags = node?.layoutFlags ?? [];
        if (flags.includes("grid") || flags.includes("subgrid") || flags.includes("grid-lanes"))
            return "grid";
        return flags.includes("flex") ? "flex" : null;
    }

    // What the tree shows for nodes it learned of by id alone.
    // A node's name and text, falling back on its type and on the
    // frontend's own model when the mirror entry left them out, so a
    // text node never reaches the tree without "#text" or its value.
    const typeNames = {3: "#text", 4: "#cdata-section", 8: "#comment", 9: "#document", 11: "#document-fragment"};
    function nameOf(node) {
        return node.nodeName || typeNames[node.nodeType] || "";
    }
    function valueOf(node, targetId) {
        if (node.nodeValue || (node.nodeType !== 3 && node.nodeType !== 4 && node.nodeType !== 8))
            return node.nodeValue ?? "";
        const known = isPageTarget(targetId) ? WI.domManager?.nodeForId?.(node.nodeId) : null;
        const value = known?.nodeValue?.();
        return typeof value === "string" ? value.slice(0, 300) : node.nodeValue ?? "";
    }
    // Chrome's inline text: an element whose only child is a text node
    // comes with that child, so the row can show <li>text</li>.
    function inlineChild(map, node, targetId) {
        if (node.nodeType !== 1 || !Array.isArray(node.children))
            return null;
        const rows = treeChildren(map, node);
        if (rows.length !== 1)
            return null;
        const child = map.get(rows[0]);
        if (!child || child.nodeType !== 3)
            return null;
        return {nodeId: child.nodeId, nodeType: 3, nodeName: "#text", nodeValue: valueOf(child, targetId),
            childNodeCount: 0, attributes: []};
    }
    // A node's own kind beside its type: ::before, #shadow-root (open).
    function kinds(item, node) {
        if (node.pseudoType)
            item.pseudoType = node.pseudoType;
        if (node.shadowRootType)
            item.shadowRootType = node.shadowRootType;
        if (node.layoutFlags?.length)
            item.layoutFlags = node.layoutFlags;
        return item;
    }

    // The tree's badges: WebKit's layout flags (scrollable, event, grid,
    // flex, subgrid) and the ones WebKit has no flag for, read from the
    // page (container, scroll-snap, top-layer, slot, subgrid, anchor and
    // "anchored:<name>" for an anchor-positioned element), for the nodes
    // asked about that have any.
    async function flags(ids, targetId) {
        const map = mirrorFor(targetId);
        const list = (Array.isArray(ids) ? ids : []).slice(0, 4000);
        const extra = list.length ? await pageFlags(targetId) : new Map;
        const output = {};
        for (const id of list) {
            const node = map.get(id);
            const merged = [...(node?.layoutFlags ?? []).slice(0, 12), ...(extra.get(id) ?? [])];
            if (merged.length)
                output[id] = [...new Set(merged)].slice(0, 16);
        }
        return output;
    }

    // Run in the page: the elements with a badge WebKit doesn't flag, as
    // [element, "flag flag", element, …]. Open shadow trees are walked
    // too; Perch's own overlay layer is left out.
    function inPageBadges() {
        const output = [];
        const own = document[Symbol.for("perch.elementsOverlay")]?.host ?? null;
        const fullscreen = document.fullscreenElement ?? document.webkitFullscreenElement ?? null;
        const isTopLayer = (element) => {
            if (element === fullscreen)
                return true;
            for (const selector of [":modal", ":popover-open"]) {
                try {
                    if (element.matches(selector))
                        return true;
                } catch {}
            }
            return false;
        };
        // CSS anchor positioning, where the engine has it.
        const anchoring = "anchorName" in document.documentElement.style;
        const anchored = (value) => value && value !== "auto" && value !== "none" && value !== "normal";
        let visited = 0;
        const roots = [document];
        while (roots.length && visited < 15000 && output.length < 400) {
            const root = roots.pop();
            for (const element of root.querySelectorAll("*")) {
                if (++visited > 15000 || output.length >= 400)
                    break;
                if (element === own)
                    continue;
                if (element.shadowRoot)
                    roots.push(element.shadowRoot);
                const style = getComputedStyle(element);
                const found = [];
                if (style.containerType && style.containerType !== "normal")
                    found.push("container");
                if (style.scrollSnapType && style.scrollSnapType !== "none")
                    found.push("scroll-snap");
                if (isTopLayer(element))
                    found.push("top-layer");
                if (element.assignedSlot)
                    found.push("slot");
                if (/^subgrid/.test(style.gridTemplateColumns) || /^subgrid/.test(style.gridTemplateRows))
                    found.push("subgrid");
                if (anchoring) {
                    if (style.anchorName && style.anchorName !== "none")
                        found.push("anchor");
                    if (anchored(style.positionAnchor))
                        found.push("anchored:" + String(style.positionAnchor).replace(/\s+/g, "").slice(0, 80));
                }
                if (found.length)
                    output.push(element, found.join(" "));
            }
        }
        return output;
    }

    // Run in the page on an anchor-positioned element: the element its
    // position-anchor names (the last in tree order with that
    // anchor-name, as the spec picks), its own tree searched before the
    // document's, the scan capped. Null without anchor positioning.
    function inPageAnchor() {
        if (!("anchorName" in document.documentElement.style))
            return null;
        const name = String(getComputedStyle(this).positionAnchor ?? "").trim();
        if (!name || name === "auto" || name === "none" || name === "normal")
            return null;
        const roots = [...new Set([this.getRootNode(), document])];
        for (const root of roots) {
            let found = null;
            let visited = 0;
            for (const element of root.querySelectorAll?.("*") ?? []) {
                if (++visited > 15000)
                    break;
                if (element === this)
                    continue;
                const names = String(getComputedStyle(element).anchorName ?? "");
                if (names !== "none" && names.split(",").some((item) => item.trim() === name))
                    found = element;
            }
            if (found)
                return found;
        }
        return null;
    }

    // The anchor of an anchor-positioned node, pushed to the inspector:
    // its node id, or 0 when there is none.
    async function anchorOf(nodeId, targetId) {
        const objectGroup = "perch-anchor";
        try {
            const resolved = await command("DOM.resolveNode", {nodeId, objectGroup}, targetId);
            const objectId = resolved.object?.objectId;
            if (!objectId)
                return 0;
            const reply = await command("Runtime.callFunctionOn", {
                objectId, functionDeclaration: String(inPageAnchor), returnByValue: false,
            }, targetId);
            const found = reply.wasThrown ? null : reply.result?.objectId;
            if (!found)
                return 0;
            const node = await command("DOM.requestNode", {objectId: found}, targetId).catch(() => null);
            return node?.nodeId ?? 0;
        } finally {
            command("Runtime.releaseObjectGroup", {objectGroup}, targetId).catch(() => {});
        }
    }

    // The page's badges by node id, read at most every second and a half
    // (the tree asks again on each expand) and shared by calls meanwhile.
    const pageFlagReads = new Map;
    function pageFlags(targetId) {
        const key = targetKey(targetId);
        const cached = pageFlagReads.get(key);
        if (cached && Date.now() - cached.at < 1500)
            return cached.promise;
        const promise = readPageFlags(targetId).catch(() => new Map);
        pageFlagReads.set(key, {at: Date.now(), promise});
        return promise;
    }
    async function readPageFlags(targetId) {
        const objectGroup = "perch-badges";
        const output = new Map;
        try {
            const reply = await command("Runtime.evaluate", {
                expression: "(" + String(inPageBadges) + ")()", objectGroup, returnByValue: false,
            }, targetId);
            const listId = reply.result?.objectId;
            if (!listId || reply.wasThrown)
                return output;
            const entries = await command("Runtime.getProperties", {objectId: listId, ownProperties: true}, targetId);
            const items = [];
            for (const item of entries.properties ?? []) {
                if (/^\d+$/.test(item.name))
                    items[Number(item.name)] = item.value;
            }
            const pairs = [];
            for (let at = 0; at + 1 < items.length; at += 2) {
                if (items[at]?.objectId && typeof items[at + 1]?.value === "string")
                    pairs.push([items[at].objectId, items[at + 1].value.split(" ")]);
            }
            await Promise.all(pairs.map(async ([objectId, found]) => {
                const node = await command("DOM.requestNode", {objectId}, targetId).catch(() => null);
                if (node?.nodeId)
                    output.set(node.nodeId, found);
            }));
            return output;
        } finally {
            command("Runtime.releaseObjectGroup", {objectGroup}, targetId).catch(() => {});
        }
    }
    // childNodeCount is WebKit's; extraChildCount the rows beside it.
    function payload(map, node, targetId) {
        const item = kinds({nodeId: node.nodeId, nodeType: node.nodeType, nodeName: nameOf(node),
            nodeValue: valueOf(node, targetId), childNodeCount: node.childNodeCount ?? 0,
            extraChildCount: extraCount(map, node), attributes: node.attributes}, node);
        const inline = inlineChild(map, node, targetId);
        if (inline)
            item.children = [inline];
        return item;
    }

    function details(ids, targetId) {
        const map = mirrorFor(targetId);
        const output = {};
        for (const id of (Array.isArray(ids) ? ids : []).slice(0, 4000)) {
            const node = map.get(id);
            if (!node || node.partial)
                continue;
            output[id] = {attributes: node.attributes, nodeValue: valueOf(node, targetId), layout: layoutKind(node),
                childNodeCount: treeCount(map, node)};
        }
        return output;
    }

    function describe(map, id, budget) {
        const node = map.get(id);
        if (!node || budget.left-- <= 0)
            return null;
        const item = kinds({nodeId: id, nodeType: node.nodeType, nodeName: nameOf(node), nodeValue: node.nodeValue ?? "",
            childNodeCount: node.childNodeCount ?? 0, extraChildCount: extraCount(map, node), attributes: node.attributes}, node);
        const rows = treeChildren(map, node);
        if (Array.isArray(node.children) || rows.length)
            item.children = rows.slice(0, 800).map((child) => describe(map, child, budget)).filter(Boolean);
        return item;
    }

    // A node of WebKit's own frontend model, as the backend described it.
    function frontendPayload(node, depth) {
        const item = {
            nodeId: node.backendNodeId ?? node.id, nodeType: node.nodeType(), nodeName: node.nodeName(),
            nodeValue: node.nodeValue() ?? "", childNodeCount: node.childNodeCount || 0,
            attributes: (node.attributes?.() ?? []).flatMap((attribute) => [attribute.name, attribute.value]),
        };
        const pseudoType = typeof node.pseudoType === "function" ? node.pseudoType() : null;
        const shadowRootType = typeof node.shadowRootType === "function" ? node.shadowRootType() : null;
        if (pseudoType)
            item.pseudoType = pseudoType;
        if (shadowRootType)
            item.shadowRootType = shadowRootType;
        if (depth > 0 && Array.isArray(node.children))
            item.children = node.children.slice(0, 800).map((child) => frontendPayload(child, depth - 1));
        // WebKit's own model keeps these apart from the children.
        if (depth > 0) {
            const shadows = typeof node.shadowRoots === "function" ? node.shadowRoots() : null;
            if (Array.isArray(shadows) && shadows.length)
                item.shadowRoots = shadows.slice(0, 8).map((child) => frontendPayload(child, depth - 1));
            const pseudos = typeof node.pseudoElements === "function" ? node.pseudoElements() : null;
            if (pseudos instanceof Map && pseudos.size)
                item.pseudoElements = [...pseudos.values()].slice(0, 8).map((child) => frontendPayload(child, 0));
            const template = typeof node.templateContent === "function" ? node.templateContent() : null;
            if (template)
                item.templateContent = frontendPayload(template, depth - 1);
        }
        return item;
    }

    function isPageTarget(targetId) {
        const page = WI.pageTarget ?? WI.mainTarget;
        return targetId == null || page?.identifier === targetId;
    }

    // The document root, from the one DOM.getDocument the frontend makes.
    // WebKit renumbers every node on each getDocument, and WebKit's own
    // DOMManager asks again after each navigation, so a second request
    // of ours would leave one of the two holding dead node ids. Going
    // through DOMManager.requestDocument shares its request and model.
    async function documentRoot(targetId) {
        const manager = WI.domManager;
        const map = mirrorFor(targetId);
        let root = null;
        if (isPageTarget(targetId) && typeof manager?.requestDocument === "function") {
            const document = await new Promise((resolve) => manager.requestDocument(resolve));
            if (document)
                root = frontendPayload(document, 64);
        } else {
            root = (await command("DOM.getDocument", {}, targetId)).root ?? null;
        }
        if (!root)
            return null;
        map.clear();
        remember(map, root, null);
        map.rootId = root.nodeId;
        return describe(map, root.nodeId, {left: 3000});
    }

    // Expand recursively. WebKit's requestChildNodes has no pierce: its
    // depth stops at shadow roots, template contents and frames'
    // documents, so each of those still closed is asked for in turn, as
    // Chrome's pierce reaches them.
    async function subtree(nodeId, targetId) {
        const map = mirrorFor(targetId);
        await command("DOM.requestChildNodes", {nodeId, depth: -1}, targetId);
        const asked = new Set([nodeId]);
        for (let round = 0; round < 6; round++) {
            const pending = [];
            const stack = [nodeId];
            const seen = new Set;
            while (stack.length && seen.size < 6000 && pending.length < 60) {
                const id = stack.pop();
                if (seen.has(id))
                    continue;
                seen.add(id);
                const item = map.get(id);
                if (!item)
                    continue;
                if (!Array.isArray(item.children) && (item.childNodeCount ?? 0) > 0 && !asked.has(id))
                    pending.push(id);
                stack.push(...treeChildren(map, item));
            }
            if (!pending.length)
                break;
            await Promise.all(pending.map((id) => {
                asked.add(id);
                return command("DOM.requestChildNodes", {nodeId: id, depth: -1}, targetId).catch(() => {});
            }));
        }
        return describe(map, nodeId, {left: 3000});
    }

    // A node's children one level down, read from the mirror once the
    // backend has sent them (the frontend's own model doesn't hold them).
    async function children(nodeId, targetId) {
        const map = mirrorFor(targetId);
        await command("DOM.requestChildNodes", {nodeId, depth: 1}, targetId);
        for (let tries = 0; tries < 20 && !Array.isArray(map.get(nodeId)?.children); tries++) {
            // Children the backend sent before this mirror listened are
            // in the frontend's model.
            const known = isPageTarget(targetId) ? WI.domManager?.nodeForId?.(nodeId) : null;
            if (Array.isArray(known?.children)) {
                remember(map, frontendPayload(known, 1), map.get(nodeId)?.parentId ?? known.parentNode?.backendNodeId ?? known.parentNode?.id);
                break;
            }
            await new Promise((resolve) => setTimeout(resolve, 25));
        }
        return treeChildren(map, map.get(nodeId)).map((child) => {
            const node = map.get(child);
            return node && !node.partial && payload(map, node, targetId);
        }).filter(Boolean);
    }

    // A node and its ancestors as the mirror knows them, nearest first.
    function chain(map, id) {
        const output = [];
        for (let node = map.get(id); node && !node.partial && output.length < 200; node = map.get(node.parentId)) {
            output.push(kinds({nodeId: node.nodeId, parentId: node.parentId, nodeType: node.nodeType,
                nodeName: nameOf(node), nodeValue: node.nodeValue ?? "", attributes: node.attributes,
                childNodeCount: node.childNodeCount ?? 0, extraChildCount: extraCount(map, node)}, node));
            if (node.parentId == null)
                break;
        }
        return output;
    }

    async function callOn(nodeId, targetId, declaration, args = []) {
        const resolved = await command("DOM.resolveNode", {nodeId, objectGroup: "perch-elements"}, targetId);
        const objectId = resolved.object?.objectId;
        if (!objectId)
            throw new Error("This node is no longer in the page.");
        try {
            const reply = await command("Runtime.callFunctionOn", {
                objectId, functionDeclaration: String(declaration),
                arguments: args.map((value) => ({value})), returnByValue: true,
            }, targetId);
            if (reply.wasThrown)
                throw new Error(reply.result?.description ?? "The page threw an error.");
            return reply.result?.value;
        } finally {
            command("Runtime.releaseObject", {objectId}, targetId).catch(() => {});
        }
    }

    // Chromium's DOMPath (panels/elements/DOMPath.ts), run on the page's
    // own nodes: Copy selector, Copy JS path, Copy XPath, Copy full XPath.
    function inPagePaths() {
        const ELEMENT = 1, DOCUMENT = 9, TEXT = 3, CDATA = 4;
        const nameOf = (node) => node.localName || node.nodeName.toLowerCase();
        function cssStep(node, optimized, isTarget) {
            if (node.nodeType !== ELEMENT)
                return null;
            const id = node.getAttribute("id");
            if (optimized) {
                if (id)
                    return {value: "#" + CSS.escape(id), optimized: true};
                const lower = node.nodeName.toLowerCase();
                if (lower === "body" || lower === "head" || lower === "html")
                    return {value: nameOf(node), optimized: true};
            }
            const name = nameOf(node);
            if (id)
                return {value: name + "#" + CSS.escape(id), optimized: true};
            const parent = node.parentNode;
            if (!parent || parent.nodeType === DOCUMENT)
                return {value: name, optimized: true};
            const classes = (element) => (element.getAttribute("class") ?? "").split(/\s+/g).filter(Boolean);
            const own = classes(node);
            let needsClassNames = false, needsNthChild = false, ownIndex = -1, elementIndex = -1;
            const siblings = parent.children;
            for (let i = 0; siblings && (ownIndex === -1 || !needsNthChild) && i < siblings.length; ++i) {
                const sibling = siblings[i];
                elementIndex += 1;
                if (sibling === node) {
                    ownIndex = elementIndex;
                    continue;
                }
                if (needsNthChild || nameOf(sibling) !== name)
                    continue;
                needsClassNames = true;
                const remaining = new Set(own);
                if (!remaining.size) {
                    needsNthChild = true;
                    continue;
                }
                for (const name of classes(sibling)) {
                    if (!remaining.has(name))
                        continue;
                    remaining.delete(name);
                    if (!remaining.size) {
                        needsNthChild = true;
                        break;
                    }
                }
            }
            let result = name;
            if (isTarget && name === "input" && node.getAttribute("type") && !id && !node.getAttribute("class"))
                result += "[type=" + CSS.escape(node.getAttribute("type")) + "]";
            if (needsNthChild)
                result += ":nth-child(" + (ownIndex + 1) + ")";
            else if (needsClassNames)
                for (const name of own)
                    result += "." + CSS.escape(name);
            return {value: result, optimized: false};
        }
        function cssPath(node, optimized) {
            if (node.nodeType !== ELEMENT)
                return "";
            const steps = [];
            for (let context = node; context;) {
                const step = cssStep(context, optimized, context === node);
                if (!step)
                    break;
                steps.push(step);
                if (step.optimized)
                    break;
                context = context.parentNode;
            }
            return steps.reverse().map((step) => step.value).join(" > ");
        }
        function jsPath(node) {
            const path = [];
            for (let context = node; context;) {
                path.push(cssPath(context, true));
                const root = context.getRootNode?.();
                context = root instanceof ShadowRoot ? root.host : null;
            }
            return path.reverse().map((step, index) =>
                (index ? ".shadowRoot.querySelector(" : "document.querySelector(") + JSON.stringify(step) + ")").join("");
        }
        function similar(left, right) {
            if (left === right)
                return true;
            if (left.nodeType === ELEMENT && right.nodeType === ELEMENT)
                return left.localName === right.localName;
            const type = (node) => node.nodeType === CDATA ? TEXT : node.nodeType;
            return type(left) === type(right);
        }
        function xIndex(node) {
            const siblings = node.parentNode ? node.parentNode.childNodes : null;
            if (!siblings)
                return 0;
            let same = false;
            for (const sibling of siblings)
                if (sibling !== node && similar(node, sibling)) {
                    same = true;
                    break;
                }
            if (!same)
                return 0;
            let index = 1;
            for (const sibling of siblings) {
                if (similar(node, sibling)) {
                    if (sibling === node)
                        return index;
                    ++index;
                }
            }
            return -1;
        }
        function xStep(node, optimized) {
            const index = xIndex(node);
            if (index === -1)
                return null;
            let value;
            switch (node.nodeType) {
            case ELEMENT:
                if (optimized && node.getAttribute("id"))
                    return {value: "//*[@id=\"" + node.getAttribute("id") + "\"]", optimized: true};
                value = node.localName;
                break;
            case 2: value = "@" + node.nodeName; break;
            case TEXT: case CDATA: value = "text()"; break;
            case 7: value = "processing-instruction()"; break;
            case 8: value = "comment()"; break;
            default: value = "";
            }
            if (index > 0)
                value += "[" + index + "]";
            return {value, optimized: node.nodeType === DOCUMENT};
        }
        function xPath(node, optimized) {
            if (node.nodeType === DOCUMENT)
                return "/";
            const steps = [];
            for (let context = node; context; context = context.parentNode) {
                const step = xStep(context, optimized);
                if (!step)
                    break;
                steps.push(step);
                if (step.optimized)
                    break;
            }
            steps.reverse();
            return (steps.length && steps[0].optimized ? "" : "/") + steps.map((step) => step.value).join("/");
        }
        return {
            selector: this.nodeType === ELEMENT ? cssPath(this, true) : nameOf(this),
            jsPath: this.nodeType === ELEMENT ? jsPath(this) : "",
            xpath: xPath(this, true),
            fullXPath: xPath(this, false),
        };
    }

    // Chromium's toggleClassAndInjectStyleRule (core/sdk/PageFunctions.ts).
    function inPageToggleHidden(hidden) {
        const className = "__web-inspector-hide-shortcut__";
        const styleTagId = "__web-inspector-hide-shortcut-style__";
        this.classList.toggle(className, hidden);
        let root = this;
        while (root.parentNode)
            root = root.parentNode;
        if (root.nodeType === 9)
            root = document.head ?? document.documentElement;
        if (!root.querySelector("style#" + styleTagId)) {
            const style = document.createElement("style");
            style.id = styleTagId;
            style.textContent = "\n.__web-inspector-hide-shortcut__, .__web-inspector-hide-shortcut__ *\n{\n    visibility: hidden !important;\n}\n";
            root.appendChild(style);
        }
        return this.classList.contains(className);
    }

    function inPageStore() {
        let index = 1;
        while (("temp" + index) in globalThis)
            index++;
        globalThis["temp" + index] = this;
        return "temp" + index;
    }

    // A document's or shadow root's adoptedStyleSheets, each as its rules'
    // text (null where they can't be read); given text, sheet `index` is
    // replaced through replaceSync first.
    function inPageAdoptedSheets(index, text) {
        const sheets = Array.from(this.adoptedStyleSheets ?? []).slice(0, 1000);
        if (text != null && sheets[index])
            sheets[index].replaceSync(text);
        return sheets.map((sheet) => {
            try {
                return Array.from(sheet.cssRules).map((rule) => rule.cssText);
            } catch {
                return null;
            }
        });
    }

    function inPageScroll() {
        if (typeof this.scrollIntoViewIfNeeded === "function")
            this.scrollIntoViewIfNeeded(true);
        else
            this.scrollIntoView({block: "center", inline: "center"});
        return true;
    }

    async function search(query, targetId) {
        const found = await command("DOM.performSearch", {query, caseSensitive: false}, targetId);
        try {
            const count = Math.min(found.resultCount ?? 0, 500);
            if (!count)
                return [];
            const results = await command("DOM.getSearchResults", {searchId: found.searchId, fromIndex: 0, toIndex: count}, targetId);
            const map = mirrorFor(targetId);
            return (results.nodeIds ?? []).map((id) => ({nodeId: id, chain: chain(map, id)}));
        } finally {
            command("DOM.discardSearchResults", {searchId: found.searchId}, targetId).catch(() => {});
        }
    }

    function inheritable(name) {
        try {
            return WI.CSSProperty.isInheritedPropertyName(name);
        } catch {
            return true;
        }
    }

    const scratch = document.createElement("div").style;
    function longhands(name, value) {
        let names = null;
        try {
            names = WI.CSSKeywordCompletions?.LonghandNamesForShorthandProperty?.get?.(name) ?? null;
        } catch {}
        if (!Array.isArray(names) || !names.length || /var\(/i.test(value))
            return [];
        scratch.cssText = "";
        scratch.setProperty(name, value);
        const output = names.slice(0, 40).map((longhand) => ({name: longhand, value: scratch.getPropertyValue(longhand)}));
        scratch.cssText = "";
        return output.every((item) => item.value) ? output : [];
    }

    // The at-rules and, for a nested rule, the style rules it sits in
    // (WebKit's "style-rule" grouping, its text the parent's selector),
    // outermost first, as Chrome heads a nested rule with `.card` above
    // `&:hover`.
    function groupings(rule) {
        const prefixes = {
            "media-rule": "@media", "media-import-rule": "@media", "media-link-node": "@media",
            "media-style-node": "@media", "supports-rule": "@supports", "layer-rule": "@layer",
            "layer-import-rule": "@layer", "container-rule": "@container", "scope-rule": "@scope",
            "starting-style-rule": "@starting-style",
        };
        return (rule?.groupings ?? []).filter((item) => prefixes[item.type] || (item.type === "style-rule" && item.text))
            .map((item) => (item.type === "style-rule" ? String(item.text)
                : prefixes[item.type] + (item.text ? " " + item.text : "")).slice(0, 300)).reverse();
    }

    function label(node) {
        if (!node)
            return "";
        const attribute = (name) => {
            const index = attributeIndex(node, name);
            return index >= 0 ? node.attributes[index + 1] : null;
        };
        const id = attribute("id");
        const classes = (attribute("class") ?? "").trim().split(/\s+/).filter(Boolean);
        return (String(node.nodeName ?? "").toLowerCase() + (id ? "#" + id : "") + classes.map((item) => "." + item).join("")).slice(0, 200);
    }

    function style(selector, origin, source, extra) {
        // A user agent or user sheet's rules aren't editable, and WebKit
        // sends their properties without source text: they are kept by
        // name and value, as Chrome lists them under "user agent stylesheet".
        const editable = origin !== "user-agent" && origin !== "user";
        const styleId = editable && source?.styleId && typeof source.styleId.styleSheetId === "string"
            ? {styleSheetId: source.styleId.styleSheetId, ordinal: source.styleId.ordinal ?? 0} : null;
        return {
            selector: String(selector).slice(0, 350), origin: String(origin ?? "").slice(0, 60),
            styleId,
            properties: agentProperties(editable, source).filter((item) =>
                typeof item.name === "string" && typeof item.value === "string" &&
                item.implicit !== true && (typeof item.text === "string" || item.status === "disabled" || !styleId)
            ).slice(0, 120).map((item) => ({
                name: item.name.slice(0, 100), value: item.value.slice(0, 300),
                enabled: !(item.disabled === true || item.status === "disabled"),
                important: item.priority === "important",
                parsed: item.parsedOk !== false,
                inactive: item.status === "inactive",
                inheritable: inheritable(item.name),
                longhands: longhands(item.name, item.value),
            })),
            ...extra,
        };
    }

    // A user agent rule's properties as written: WebKit sends `margin: 8px`
    // as its longhands with the shorthand in shorthandEntries, and Chrome
    // shows the shorthand.
    function agentProperties(editable, source) {
        const properties = source?.cssProperties ?? [];
        const shorthands = editable ? [] : (source?.shorthandEntries ?? [])
            .filter((entry) => typeof entry.name === "string" && typeof entry.value === "string" && entry.value);
        if (!shorthands.length)
            return properties;
        const covered = new Set(shorthands.flatMap((entry) => longhands(entry.name, entry.value).map((item) => item.name)));
        if (!covered.size)
            return properties;
        const shown = shorthands.filter((entry) => longhands(entry.name, entry.value).length)
            .map((entry) => ({name: entry.name, value: entry.value, priority: entry.priority ?? ""}));
        return [...shown, ...properties.filter((item) => !covered.has(item.name))];
    }

    function fromRule(rule, extra) {
        const ruleId = rule?.ruleId && typeof rule.ruleId.styleSheetId === "string" && rule.origin !== "user-agent"
            ? {styleSheetId: rule.ruleId.styleSheetId, ordinal: rule.ruleId.ordinal ?? 0} : null;
        return style(rule?.selectorList?.text ?? "Rule", rule?.origin, rule?.style, {
            ruleId, groupings: groupings(rule),
            sourceURL: typeof rule?.sourceURL === "string" ? rule.sourceURL.slice(0, 2048) : null,
            sourceLine: Number.isFinite(rule?.sourceLine) ? rule.sourceLine : null,
            // The selector's column, for a CSS source map of a minified sheet;
            // only when its range is on the rule's line (an external sheet).
            sourceColumn: Number.isFinite(rule?.selectorList?.range?.startColumn)
                && rule.selectorList.range.startLine === rule?.sourceLine ? rule.selectorList.range.startColumn : null,
            ...extra,
        });
    }

    // Read in the page: the at-rules the element's styles use, as Chrome
    // shows them below its rules: @keyframes for its animation names,
    // @position-try for its fallbacks, every @property (filtered to the
    // ones used by the caller) and @font-face for its font families.
    // Cross-origin sheets, whose rules can't be read, are skipped.
    function inPageAtRules() {
        if (this.nodeType !== 1)
            return null;
        const computed = getComputedStyle(this);
        const listOf = (text) => String(text ?? "").split(",")
            .map((part) => part.trim().replace(/^["']|["']$/g, "")).filter((part) => part && part !== "none");
        const animationNames = new Set(listOf(computed.animationName));
        const familyNames = new Set(listOf(computed.fontFamily).map((part) => part.toLowerCase()));
        const tryText = computed.getPropertyValue("position-try-fallbacks") || computed.getPropertyValue("position-try-options") || "";
        const tryNames = new Set(listOf(tryText).flatMap((part) => part.split(/\s+/)).filter((part) => part.startsWith("--")));
        const declarationsOf = (block) => {
            const text = String(block?.cssText ?? "");
            const parts = [];
            let depth = 0, quote = null, start = 0;
            for (let at = 0; at < text.length; at++) {
                const character = text[at];
                if (quote) {
                    if (character === "\\")
                        at++;
                    else if (character === quote)
                        quote = null;
                    continue;
                }
                if (character === "\"" || character === "'")
                    quote = character;
                else if (character === "(")
                    depth++;
                else if (character === ")")
                    depth = Math.max(0, depth - 1);
                else if (character === ";" && !depth) {
                    parts.push(text.slice(start, at));
                    start = at + 1;
                }
            }
            parts.push(text.slice(start));
            const declarations = [];
            for (const part of parts) {
                const colon = part.indexOf(":");
                if (colon <= 0)
                    continue;
                let value = part.slice(colon + 1).trim();
                const important = /!\s*important$/i.test(value);
                if (important)
                    value = value.replace(/\s*!\s*important$/i, "");
                declarations.push({name: part.slice(0, colon).trim(), value, important});
                if (declarations.length >= 60)
                    break;
            }
            return declarations;
        };
        const keyframes = new Map, positionTries = new Map, registered = new Map, faces = [];
        let visited = 0;
        const walk = (list, href) => {
            for (const rule of Array.from(list ?? [])) {
                if (++visited > 20000)
                    return;
                const kind = rule?.constructor?.name ?? "";
                if (kind === "CSSKeyframesRule" || rule.type === 7) {
                    // The last @keyframes of a name is the one in effect.
                    if (animationNames.has(rule.name))
                        keyframes.set(rule.name, {name: rule.name, href, frames: Array.from(rule.cssRules ?? []).slice(0, 40)
                            .map((frame) => ({key: frame.keyText, declarations: declarationsOf(frame.style)}))});
                } else if (kind === "CSSPropertyRule") {
                    const declarations = [];
                    if (rule.syntax != null)
                        declarations.push({name: "syntax", value: JSON.stringify(String(rule.syntax))});
                    if (rule.inherits != null)
                        declarations.push({name: "inherits", value: String(rule.inherits)});
                    if (rule.initialValue != null)
                        declarations.push({name: "initial-value", value: String(rule.initialValue)});
                    if (registered.size < 200)
                        registered.set(rule.name, {name: rule.name, href, declarations});
                } else if (kind === "CSSFontFaceRule" || rule.type === 5) {
                    const family = String(rule.style?.getPropertyValue("font-family") ?? "").trim()
                        .replace(/^["']|["']$/g, "").toLowerCase();
                    if (familyNames.has(family) && faces.length < 20)
                        faces.push({name: family, href, declarations: declarationsOf(rule.style)});
                } else if (kind === "CSSPositionTryRule") {
                    if (tryNames.has(rule.name))
                        positionTries.set(rule.name, {name: rule.name, href, declarations: declarationsOf(rule.style)});
                } else if (kind === "CSSImportRule" || rule.type === 3) {
                    try {
                        if (rule.styleSheet)
                            walk(rule.styleSheet.cssRules, rule.styleSheet.href ?? href);
                    } catch {}
                } else if (rule.cssRules) {
                    // @media, @supports, @layer and the other grouping rules.
                    walk(rule.cssRules, href);
                }
            }
        };
        const holders = [document];
        const root = this.getRootNode();
        if (root && root !== document)
            holders.push(root);
        for (const holder of holders) {
            for (const sheet of [...Array.from(holder.styleSheets ?? []), ...Array.from(holder.adoptedStyleSheets ?? [])]) {
                let list = null;
                try {
                    list = sheet.cssRules;
                } catch {
                    continue;
                }
                walk(list, sheet.href ?? location.href);
            }
        }
        return {keyframes: [...keyframes.values()], positionTries: [...positionTries.values()],
            properties: [...registered.values()], fontFaces: faces};
    }

    // The custom properties the element's rules set or read with var().
    function usedVariables(rules) {
        const names = new Set;
        for (const rule of rules) {
            for (const item of rule.properties ?? []) {
                if (item.name.startsWith("--"))
                    names.add(item.name);
                for (const match of String(item.value).matchAll(/var\(\s*(--[^\s,)]+)/g))
                    names.add(match[1]);
            }
        }
        return names;
    }

    // The at-rule sections, read-only: WebKit's protocol gives these rules
    // no style ids to edit them by. Their section starts with "@", which
    // keeps them out of the cascade.
    function atRuleStyles(found, rules) {
        if (!found || typeof found !== "object")
            return [];
        const section = (selector, title, declarations, href) => ({
            selector: String(selector ?? "").slice(0, 350), origin: "regular", styleId: null, ruleId: null, groupings: [],
            properties: (Array.isArray(declarations) ? declarations : []).slice(0, 60).map((item) => ({
                name: String(item.name).slice(0, 100), value: String(item.value ?? "").slice(0, 300),
                enabled: true, important: item.important === true, parsed: true, inactive: false,
                inheritable: true, longhands: [],
            })),
            section: String(title).slice(0, 300),
            sourceURL: typeof href === "string" ? href.slice(0, 2048) : null, sourceLine: null,
        });
        const output = [];
        for (const item of (found.keyframes ?? []).slice(0, 10)) {
            for (const frame of (item.frames ?? []).slice(0, 40))
                output.push(section(frame.key, "@keyframes " + item.name, frame.declarations, item.href));
        }
        for (const item of (found.positionTries ?? []).slice(0, 10))
            output.push(section("@position-try " + item.name, "@position-try " + item.name, item.declarations, item.href));
        const used = usedVariables(rules);
        for (const item of (found.properties ?? []).filter((entry) => used.has(entry.name)).slice(0, 20))
            output.push(section(item.name, "@property", item.declarations, item.href));
        for (const item of (found.fontFaces ?? []).slice(0, 10))
            output.push(section("@font-face", "@font-face", item.declarations, item.href));
        return output.slice(0, 60);
    }

    // The Styles pane as DevTools lays it out: element.style and the
    // element's rules, then "Inherited from …" per ancestor, then each
    // pseudo-element's rules (::before first).
    // ancestors: the element's ancestor elements, nearest first, as
    // {nodeId, label} from the tree the panel shows.
    async function styles(nodeId, targetId, ancestors = []) {
        const [matched, inline] = await Promise.all([
            command("CSS.getMatchedStylesForNode", {nodeId, includePseudo: true, includeInherited: true}, targetId),
            command("CSS.getInlineStylesForNode", {nodeId}, targetId).catch(() => null),
        ]);
        const output = [style("element.style", "inline", inline?.inlineStyle, {})];
        for (const {rule} of (matched.matchedCSSRules ?? []).slice(-60).reverse())
            output.push(fromRule(rule, {}));
        const lineage = Array.isArray(ancestors) && ancestors.length ? ancestors
            : chain(mirrorFor(targetId), nodeId).slice(1).filter((node) => node.nodeType === 1)
                .map((node) => ({nodeId: node.nodeId, label: label(node)}));
        (matched.inherited ?? []).slice(0, 30).forEach((entry, index) => {
            const ancestor = lineage[index];
            const extra = {section: "Inherited from " + (ancestor?.label ?? "ancestor"), inherited: true,
                sectionNode: ancestor?.nodeId ?? null};
            if (entry.inlineStyle?.cssProperties?.length)
                output.push(style("style attribute", "inline", entry.inlineStyle, extra));
            for (const {rule} of (entry.matchedCSSRules ?? []).slice(-40).reverse())
                output.push(fromRule(rule, extra));
        });
        const pseudos = (matched.pseudoElements ?? []).slice().sort((a, b) =>
            (a.pseudoId === "before" ? 0 : 1) - (b.pseudoId === "before" ? 0 : 1));
        for (const pseudo of pseudos.slice(0, 20)) {
            const extra = {section: "Pseudo ::" + pseudo.pseudoId + " element", pseudo: String(pseudo.pseudoId)};
            for (const {rule} of (pseudo.matches ?? []).slice(-20).reverse())
                output.push(fromRule(rule, extra));
        }
        const atRules = atRuleStyles(await callOn(nodeId, targetId, inPageAtRules).catch(() => null), output);
        return [...output.slice(0, 200 - atRules.length), ...atRules];
    }

    const inspectorSheets = new Map;
    async function mainFrameId(targetId) {
        const tree = await command("Page.getResourceTree", {}, targetId).catch(() => command("Page.getResourceTree", {}, null));
        return tree.frameTree?.frame?.id;
    }

    async function addRule(selector, targetId) {
        const frameId = await mainFrameId(targetId);
        const key = String(targetId) + "\n" + frameId;
        for (let attempt = 0; attempt < 2; attempt++) {
            let sheet = inspectorSheets.get(key);
            if (!sheet) {
                sheet = (await command("CSS.createStyleSheet", {frameId}, targetId)).styleSheetId;
                inspectorSheets.set(key, sheet);
            }
            try {
                return (await command("CSS.addRule", {styleSheetId: sheet, selector}, targetId)).rule?.ruleId ?? null;
            } catch (error) {
                inspectorSheets.delete(key);
                if (attempt)
                    throw error;
            }
        }
    }

    async function fonts(nodeId, targetId) {
        const data = await command("CSS.getFontDataForNode", {nodeId}, targetId);
        const list = data.renderedFonts?.length ? data.renderedFonts : (data.primaryFont ? [data.primaryFont] : []);
        return list.slice(0, 40).map((font) => ({
            name: String(font.displayName ?? "").slice(0, 200),
            url: typeof font.url === "string" ? font.url.slice(0, 2048) : null,
            glyphs: (font.characterRanges ?? []).reduce((sum, range) => sum + Math.max(0, (range.end ?? 0) - (range.start ?? 0) + 1), 0),
            synthesized: !!(font.synthesizedBold || font.synthesizedOblique),
        }));
    }

    let catalog = null;
    async function cssCatalog() {
        if (catalog)
            return catalog;
        const reply = await command("CSS.getSupportedCSSProperties", {}, null);
        catalog = (reply.cssProperties ?? []).slice(0, 2000).map((item) => {
            let values = Array.isArray(item.values) ? item.values : [];
            if (!values.length) {
                try {
                    values = WI.CSSKeywordCompletions.forProperty(item.name).values ?? [];
                } catch {}
            }
            return {name: item.name, values: values.slice(0, 200)};
        });
        return catalog;
    }

    let layoutObserved = false;
    async function layoutNodes(targetId) {
        if (!layoutObserved) {
            // Every grid and flex container is then described to us.
            await command("CSS.setLayoutContextTypeChangedMode", {mode: "all"}, targetId).catch(() => {});
            layoutObserved = true;
        }
        const map = mirrorFor(targetId);
        const output = [];
        for (const node of map.values()) {
            if (output.length >= 300)
                break;
            const kind = layoutKind(node);
            if (kind)
                output.push({nodeId: node.nodeId, kind, label: label(node), chain: chain(map, node.nodeId)});
        }
        return output;
    }

    // A grid or flex overlay, with DevTools' Overlay display settings.
    async function setOverlay(nodeId, targetId, on, kind, color, options) {
        options = options ?? {};
        const hex = /^#?([0-9a-f]{6})$/i.exec(color ?? "")?.[1] ?? (kind === "grid" ? "9c27b0" : "7b1fa2");
        const rgba = {r: parseInt(hex.slice(0, 2), 16), g: parseInt(hex.slice(2, 4), 16), b: parseInt(hex.slice(4, 6), 16), a: 1};
        if (kind === "grid") {
            if (!on)
                return command("DOM.hideGridOverlay", {nodeId}, targetId);
            return command("DOM.showGridOverlay", {nodeId, gridOverlayConfig: {
                gridColor: rgba, showLineNames: !!options.lineNames, showLineNumbers: !!options.lineNumbers,
                showExtendedGridLines: !!options.extendedLines, showTrackSizes: !!options.trackSizes,
                showAreaNames: !!options.areaNames,
            }}, targetId);
        }
        if (!on)
            return command("DOM.hideFlexOverlay", {nodeId}, targetId);
        return command("DOM.showFlexOverlay", {nodeId, flexOverlayConfig: {flexColor: rgba}}, targetId);
    }

    // Run in the page on the element: the container and scroll-snap
    // overlays, which WebKit has no overlay for. Drawn in a fixed layer
    // in a closed shadow root, in the grid and flex overlays' purples;
    // the layer removes itself once nothing is shown or DevTools stops
    // checking in (closed, or the connection lost). Returns how many
    // overlays are shown.
    function inPageOverlay(kind, on) {
        const key = Symbol.for("perch.elementsOverlay");
        let state = document[key];
        if (!state && !on)
            return 0;
        if (!state) {
            const host = document.createElement("perch-overlay");
            host.style.cssText = "all: initial; position: fixed; inset: 0; pointer-events: none; z-index: 2147483647; display: block;";
            const shadow = host.attachShadow({mode: "closed"});
            state = {host, shadow, entries: new Map, pinged: Date.now(), frame: 0, refreshed: 0};
            state.count = () => [...state.entries.values()].reduce((sum, kinds) => sum + kinds.size, 0);
            state.ping = () => {
                state.pinged = Date.now();
                return state.count();
            };
            state.remove = () => {
                cancelAnimationFrame(state.frame);
                state.host.remove();
                delete document[key];
            };
            const place = (layer, rect, inset) => {
                layer.style.left = (rect.left + inset) + "px";
                layer.style.top = (rect.top + inset) + "px";
                layer.style.width = Math.max(0, rect.width - inset * 2) + "px";
                layer.style.height = Math.max(0, rect.height - inset * 2) + "px";
            };
            const snapAreas = (element) => {
                const areas = [];
                for (const child of element.querySelectorAll("*")) {
                    if (areas.length >= 200)
                        break;
                    const align = getComputedStyle(child).scrollSnapAlign;
                    if (align && align !== "none")
                        areas.push(child);
                }
                return areas;
            };
            const tick = () => {
                if (Date.now() - state.pinged > 4000 || !state.count()) {
                    state.remove();
                    return;
                }
                const refresh = Date.now() - state.refreshed > 500;
                if (refresh)
                    state.refreshed = Date.now();
                for (const [element, kinds] of state.entries) {
                    if (!element.isConnected) {
                        for (const layer of kinds.values())
                            layer.root.remove();
                        state.entries.delete(element);
                        continue;
                    }
                    const rect = element.getBoundingClientRect();
                    for (const [name, layer] of kinds) {
                        place(layer.box, rect, 0);
                        if (name !== "scroll-snap")
                            continue;
                        if (refresh)
                            layer.areas = snapAreas(element);
                        while (layer.marks.length < layer.areas.length) {
                            const mark = document.createElement("div");
                            mark.className = "area";
                            layer.root.append(mark);
                            layer.marks.push(mark);
                        }
                        layer.marks.forEach((mark, index) => {
                            const area = layer.areas[index];
                            mark.style.display = area ? "block" : "none";
                            if (area)
                                place(mark, area.getBoundingClientRect(), 0);
                        });
                    }
                }
                state.frame = requestAnimationFrame(tick);
            };
            const sheet = document.createElement("style");
            sheet.textContent = [
                "div { position: fixed; box-sizing: border-box; pointer-events: none; }",
                ".container { border: 2px dashed #9c27b0; background: rgba(156, 39, 176, 0.08); }",
                ".scroll-snap { border: 2px dashed #7b1fa2; }",
                ".area { border: 1px dotted #7b1fa2; background: rgba(123, 31, 162, 0.1); }",
                ".label { position: absolute; left: -2px; top: -18px; padding: 1px 4px; font: 500 10px system-ui, sans-serif;",
                "  color: white; background: #9c27b0; border-radius: 2px; white-space: nowrap; }",
                ".scroll-snap .label { background: #7b1fa2; }",
            ].join("\n");
            shadow.append(sheet);
            state.add = (element, name) => {
                const kinds = state.entries.get(element) ?? new Map;
                if (kinds.has(name))
                    return;
                const root = document.createElement("div");
                root.style.position = "static";
                const box = document.createElement("div");
                box.className = name;
                const tag = document.createElement("div");
                tag.className = "label";
                const named = getComputedStyle(element).containerName;
                tag.textContent = name === "container" && named && named !== "none" ? "container " + named : name;
                box.append(tag);
                root.append(box);
                shadow.append(root);
                kinds.set(name, {root, box, areas: [], marks: []});
                state.entries.set(element, kinds);
            };
            state.drop = (element, name) => {
                const kinds = state.entries.get(element);
                const layer = kinds?.get(name);
                if (!layer)
                    return;
                layer.root.remove();
                kinds.delete(name);
                if (!kinds.size)
                    state.entries.delete(element);
            };
            Object.defineProperty(document, key, {value: state, configurable: true});
            (document.documentElement ?? document.body).appendChild(host);
            state.frame = requestAnimationFrame(tick);
        }
        if (on)
            state.add(this, kind);
        else
            state.drop(this, kind);
        state.pinged = Date.now();
        return state.count();
    }

    // DevTools checks in with a page layer (the overlays, the source order
    // badges: `document[Symbol.for(symbol)]`) every second while it shows
    // anything; once it stops, the layer takes itself down.
    function keepPinging(pings, symbol, targetId) {
        const key = targetKey(targetId);
        if (pings.has(key))
            return;
        pings.set(key, setInterval(() => {
            command("Runtime.evaluate", {
                expression: `document[Symbol.for('${symbol}')]?.ping?.() ?? 0`, returnByValue: true,
            }, targetId).then((reply) => {
                if (!reply?.result?.value)
                    stopPinging(pings, key);
            }).catch(() => stopPinging(pings, key));
        }, 1000));
    }
    function stopPinging(pings, key) {
        clearInterval(pings.get(key));
        pings.delete(key);
    }
    // The layer taken down now.
    function removeLayer(pings, symbol, targetId) {
        stopPinging(pings, targetKey(targetId));
        return command("Runtime.evaluate", {
            expression: `document[Symbol.for('${symbol}')]?.remove?.()`, returnByValue: true,
        }, targetId).catch(() => {});
    }

    const overlayPings = new Map;
    async function setPageOverlay(nodeId, targetId, kind, on) {
        if (kind !== "container" && kind !== "scroll-snap")
            return 0;
        const shown = await callOn(nodeId, targetId, inPageOverlay, [kind, !!on]);
        if (shown)
            keepPinging(overlayPings, "perch.elementsOverlay", targetId);
        return shown;
    }

    // Every page-drawn overlay taken down (the document was read again).
    function clearPageOverlays(targetId) {
        removeLayer(overlayPings, "perch.elementsOverlay", targetId);
    }

    // Elements › Properties: the node object's properties, own first and
    // then each prototype's, as DevTools lists them.
    const propertyGroup = "perch-properties";
    async function properties(nodeId, objectId, targetId) {
        if (!objectId) {
            await command("Runtime.releaseObjectGroup", {objectGroup: propertyGroup}, targetId).catch(() => {});
            const resolved = await command("DOM.resolveNode", {nodeId, objectGroup: propertyGroup}, targetId);
            objectId = resolved.object?.objectId;
        }
        if (!objectId)
            return [];
        const method = perchInspector.supports("Runtime.getDisplayableProperties", targetId)
            ? "Runtime.getDisplayableProperties" : "Runtime.getProperties";
        const reply = await command(method, {objectId, fetchStart: 0, fetchCount: 400, generatePreview: false}, targetId);
        return (reply.properties ?? []).slice(0, 400).map((item) => {
            const value = item.value ?? item.get ?? null;
            return {
                name: String(item.name).slice(0, 200),
                value: value ? String(value.description ?? (value.type === "string" ? JSON.stringify(value.value) : String(value.value))).slice(0, 300) : (item.get ? "(...)" : "undefined"),
                type: value?.type ?? "undefined", subtype: value?.subtype ?? null,
                objectId: value?.type === "object" && value.subtype !== "null" ? value.objectId ?? null : null,
                own: !!item.isOwn, enumerable: item.enumerable !== false,
            };
        });
    }

    let accessibilityRead = 0;
    async function accessibilityLabels(nodeId, targetId) {
        const objectGroup = "perch-accessibility-" + ++accessibilityRead;
        try {
            const resolved = await command("DOM.resolveNode", {nodeId, objectGroup}, targetId);
            const objectId = resolved.object?.objectId;
            if (!objectId)
                return [];
            const labels = await command("Runtime.callFunctionOn", {objectId, functionDeclaration: String(function () {
                const references = this.getAttribute?.("aria-labelledby")?.trim();
                if (this.ariaLabelledByElements?.length)
                    return Array.from(this.ariaLabelledByElements);
                if (!references)
                    return Array.from(this.labels ?? []);
                const root = this.getRootNode();
                return references.split(/\s+/).map((id) => root.getElementById?.(id)).filter(Boolean);
            })}, targetId);
            const list = labels.result?.objectId;
            if (!list || labels.wasThrown)
                return [];
            const reply = await command("Runtime.getProperties", {objectId: list, ownProperties: true}, targetId);
            const objects = (reply.properties ?? []).filter((item) => /^\d+$/.test(item.name)).map((item) => item.value?.objectId);
            return (await Promise.all(objects.filter(Boolean).map(async (objectId) => {
                const node = await command("DOM.requestNode", {objectId}, targetId).catch(() => null);
                return node?.nodeId;
            }))).filter(Boolean);
        } catch {
            return [];
        } finally {
            await command("Runtime.releaseObjectGroup", {objectGroup}, targetId).catch(() => {});
        }
    }

    async function accessibility(nodeId, targetId) {
        const reads = new Map;
        function read(id) {
            if (!reads.has(id))
                reads.set(id, command("DOM.getAccessibilityPropertiesForNode", {nodeId: id}, targetId)
                    .then((reply) => reply.properties ?? {}).catch(() => ({})));
            return reads.get(id);
        }
        const properties = await read(nodeId);
        if (!properties.exists)
            return {properties};

        // The accessibility parents are mostly the element's DOM ancestors:
        // ask for those together, so the walk up rarely waits on a round
        // trip per level. The tree shows the nearest 30.
        const depth = 30;
        const map = mirrorFor(targetId);
        for (let id = map.get(nodeId)?.parentId, count = 0; id && count < depth; id = map.get(id)?.parentId, count++)
            read(id);
        const parents = [];
        const seen = new Set([nodeId]);
        for (let id = properties.parentNodeId; id && !seen.has(id) && parents.length < depth; ) {
            seen.add(id);
            parents.push(id);
            id = (await read(id)).parentNodeId;
        }

        function links(ids) {
            return Promise.all([...new Set(ids.filter((id) => Number.isInteger(id) && id > 0))]
                .map(async (id, index) => {
                    // Each AX query also computes that node's immediate children.
                    // Keep large sets of siblings clickable without fetching them all.
                    const entry = index < 40 || reads.has(id) ? await read(id) : {};
                    const item = map.get(id);
                    const name = (item?.nodeName ?? "").toLowerCase();
                    const at = attributeIndex(item, "id");
                    return {id, role: String(entry.role || name).slice(0, 120),
                        label: String(entry.label || (at < 0 ? "" : "#" + item.attributes[at + 1])).slice(0, 300)};
                }));
        }

        // Shipping versions of WebKit have a computed label but may not
        // return its source nodes. Resolve the element's references then.
        const labels = properties.labelledByNodeIds ?? properties.labeledByNodeIds
            ?? await accessibilityLabels(nodeId, targetId);
        const [ancestors, selected, children, labelledBy, controls, owns, activeDescendant] = await Promise.all([
            links(parents.reverse()), links([nodeId]), links(properties.childNodeIds ?? []), links(labels),
            links(properties.controlledNodeIds ?? []), links(properties.ownedNodeIds ?? []),
            links([properties.activeDescendantNodeId]),
        ]);
        return {properties, ancestors, selected: selected[0], children, labelledBy, controls, owns, activeDescendant};
    }

    // Elements' full-page accessibility tree, read a level at a time as
    // rows open: each row's role, name and how many children it has.
    // Ignored nodes are skipped, their children shown in their place.
    function readAccessibility(nodeId, targetId) {
        return command("DOM.getAccessibilityPropertiesForNode", {nodeId}, targetId)
            .then((reply) => reply.properties ?? {}).catch(() => ({}));
    }
    function accessibilityRow(nodeId, properties) {
        return {nodeId, role: String(properties.role || "").slice(0, 120), name: String(properties.label || "").slice(0, 300),
            childCount: Array.isArray(properties.childNodeIds) ? properties.childNodeIds.length : 0};
    }
    async function shownAccessibilityChildren(ids, targetId, depth, budget) {
        const list = (Array.isArray(ids) ? ids : []).filter((id) => Number.isInteger(id) && id > 0);
        const rows = [];
        for (let at = 0; at < list.length && budget.left > 0; at += 40) {
            const batch = list.slice(at, at + 40);
            const reads = await Promise.all(batch.map((id) => readAccessibility(id, targetId)));
            for (let index = 0; index < batch.length && budget.left > 0; index++) {
                const properties = reads[index];
                if (!properties.exists)
                    continue;
                if (properties.ignored) {
                    if (depth < 6)
                        rows.push(...await shownAccessibilityChildren(properties.childNodeIds, targetId, depth + 1, budget));
                    continue;
                }
                rows.push(accessibilityRow(batch[index], properties));
                budget.left--;
            }
        }
        return rows;
    }
    // candidates: the document, then <html> and <body>; the first the
    // accessibility tree has is the root row.
    async function accessibilityTreeRoot(candidates, targetId) {
        for (const id of (Array.isArray(candidates) ? candidates : []).slice(0, 4)) {
            if (!Number.isInteger(id))
                continue;
            const properties = await readAccessibility(id, targetId);
            if (properties.exists && !properties.ignored)
                return [accessibilityRow(id, properties)];
            if (properties.exists)
                return shownAccessibilityChildren(properties.childNodeIds, targetId, 0, {left: 200});
        }
        return [];
    }
    async function accessibilityTreeChildren(nodeId, targetId) {
        const properties = await readAccessibility(nodeId, targetId);
        if (!properties.exists)
            return [];
        return shownAccessibilityChildren(properties.childNodeIds, targetId, 0, {left: 200});
    }

    function inPageContrast() {
        if (this.nodeType !== Node.ELEMENT_NODE)
            return null;
        const style = getComputedStyle(this);
        const backgrounds = [];
        for (let node = this; node && backgrounds.length < 400; node = node.assignedSlot ?? node.parentElement ?? node.getRootNode().host) {
            const layer = getComputedStyle(node);
            backgrounds.push({color: layer.backgroundColor, image: layer.backgroundImage !== "none"});
        }
        return {backgrounds, fontSize: style.fontSize, fontWeight: style.fontWeight};
    }

    // Run in the page on the selected element, for the Styles hover on
    // calc(), min(), max() and clamp(): each step set in turn on a hidden
    // copy of the element placed beside it (so %, em and the rest resolve
    // as for it) and the copy's computed `property` read; null where the
    // step isn't valid for the property. Elements that would load or run
    // something when copied are stood in for by a div.
    function inPageMathSteps(property, steps) {
        if (this.nodeType !== Node.ELEMENT_NODE)
            return null;
        const loads = /^(iframe|frame|img|video|audio|object|embed|script|link|style|source|picture|portal|html|body|head)$/i;
        const probe = loads.test(this.localName) ? document.createElement("div") : this.cloneNode(false);
        probe.removeAttribute("id");
        probe.style.setProperty("visibility", "hidden", "important");
        probe.style.setProperty("pointer-events", "none", "important");
        if (this.parentElement)
            this.after(probe);
        else
            this.appendChild(probe);
        try {
            return steps.map((step) => {
                probe.style.removeProperty(property);
                probe.style.setProperty(property, `calc(${step})`, "important");
                return probe.style.getPropertyValue(property) ? getComputedStyle(probe).getPropertyValue(property) : null;
            });
        } finally {
            probe.remove();
        }
    }

    // Run in the page on the listener's node (or window), with the console's
    // getEventListeners: the listener WebKit lists as the `index`th of its
    // type and phase there, removed or its handler's source read.
    function inPageListener(getListeners, type, capture, index, isAttribute, action) {
        const all = typeof getListeners === "function" ? getListeners(this) : null;
        const found = (all?.[type] ?? []).filter((item) => !!item.useCapture === !!capture)[index];
        if (!found)
            throw new Error("This listener is no longer in the page.");
        const handler = found.listener;
        if (action === "source") {
            const callable = typeof handler === "function" ? handler : handler?.handleEvent;
            return (typeof callable === "function" ? Function.prototype.toString.call(callable) : String(handler)).slice(0, 4000);
        }
        if (isAttribute) {
            try { this["on" + type] = null; } catch {}
            if (typeof this.removeAttribute === "function")
                this.removeAttribute("on" + type);
        }
        this.removeEventListener(type, handler, {capture: !!capture});
        return true;
    }

    // Event Listeners › Remove and the handler's source. WebKit's DOM
    // domain has no removeEventListener: when the backend lacks it, the
    // page removes the handler itself.
    async function listener(eventListenerId, nodeId, targetId, action) {
        const backends = [...(globalThis.WI?.targets ?? [])];
        if (action === "remove" && backends.some((target) => target.hasCommand?.("DOM.removeEventListener"))) {
            try {
                await command("DOM.removeEventListener", {eventListenerId}, targetId);
                return true;
            } catch {}
        }
        const reply = await command("DOM.getEventListenersForNode", {nodeId, includeAncestors: true}, targetId);
        const list = reply.listeners ?? [];
        const item = list.find((candidate) => candidate.eventListenerId === eventListenerId);
        if (!item)
            throw new Error("This listener is no longer in the page.");
        const sameOwner = (candidate) => item.onWindow ? !!candidate.onWindow : !candidate.onWindow && candidate.nodeId === item.nodeId;
        const index = list.filter((candidate) => sameOwner(candidate) && candidate.type === item.type &&
            !!candidate.useCapture === !!item.useCapture).indexOf(item);
        const objectGroup = "perch-listeners";
        try {
            const owner = item.onWindow
                ? (await command("Runtime.evaluate", {expression: "window", objectGroup,
                    doNotPauseOnExceptionsAndMuteConsole: true}, targetId)).result
                : (await command("DOM.resolveNode", {nodeId: item.nodeId ?? nodeId, objectGroup}, targetId)).object;
            const getter = (await command("Runtime.evaluate", {
                expression: "getEventListeners", objectGroup, includeCommandLineAPI: true,
                doNotPauseOnExceptionsAndMuteConsole: true,
            }, targetId)).result;
            if (!owner?.objectId || !getter?.objectId)
                throw new Error("This listener is no longer in the page.");
            const called = await command("Runtime.callFunctionOn", {
                objectId: owner.objectId, functionDeclaration: String(inPageListener),
                arguments: [{objectId: getter.objectId}, {value: item.type}, {value: !!item.useCapture}, {value: index},
                    {value: !!item.isAttribute}, {value: action}],
                returnByValue: true, doNotPauseOnExceptionsAndMuteConsole: true,
            }, targetId);
            if (called.wasThrown)
                throw new Error(called.result?.description ?? "The page threw an error.");
            return called.result?.value;
        } finally {
            command("Runtime.releaseObjectGroup", {objectGroup}, targetId).catch(() => {});
        }
    }

    // Run in the page on the element: Accessibility › Source order viewer.
    // Its element descendants with a box, numbered in DOM order (at most
    // `cap`), in a fixed layer in a closed shadow root that takes itself
    // down once DevTools stops checking in. Returns how many are numbered
    // and whether the cap cut the list short.
    function inPageSourceOrder(on, cap) {
        const key = Symbol.for("perch.sourceOrder");
        document[key]?.remove?.();
        if (!on)
            return {shown: 0, capped: false};
        const element = this;
        const host = document.createElement("perch-overlay");
        host.style.cssText = "all: initial; position: fixed; inset: 0; pointer-events: none; z-index: 2147483647; display: block;";
        const shadow = host.attachShadow({mode: "closed"});
        const sheet = document.createElement("style");
        sheet.textContent = [
            "div { position: fixed; box-sizing: border-box; pointer-events: none; }",
            ".parent { border: 2px solid rgb(178, 0, 158); }",
            ".child { border: 1px dashed rgb(0, 120, 212); }",
            ".badge { position: absolute; left: -1px; top: -1px; min-width: 14px; padding: 0 3px; font: 600 10px/14px system-ui, sans-serif;",
            "  text-align: center; color: white; background: rgb(0, 120, 212); border-radius: 0 0 2px 0; }",
        ].join("\n");
        shadow.append(sheet);
        const outline = document.createElement("div");
        outline.className = "parent";
        shadow.append(outline);
        const items = [];
        let capped = false;
        const walker = document.createTreeWalker(element, NodeFilter.SHOW_ELEMENT);
        for (let node = walker.nextNode(); node; node = walker.nextNode()) {
            if (!node.getClientRects().length)
                continue;
            if (items.length >= cap) {
                capped = true;
                break;
            }
            const box = document.createElement("div");
            box.className = "child";
            const badge = document.createElement("div");
            badge.className = "badge";
            badge.textContent = String(items.length + 1);
            box.append(badge);
            shadow.append(box);
            items.push({node, box});
        }
        const place = (layer, rect) => {
            layer.style.left = rect.left + "px";
            layer.style.top = rect.top + "px";
            layer.style.width = Math.max(0, rect.width) + "px";
            layer.style.height = Math.max(0, rect.height) + "px";
        };
        const state = {pinged: Date.now(), frame: 0};
        state.remove = () => {
            cancelAnimationFrame(state.frame);
            host.remove();
            if (document[key] === state)
                delete document[key];
        };
        state.ping = () => {
            state.pinged = Date.now();
            return items.length + 1;
        };
        const tick = () => {
            if (Date.now() - state.pinged > 4000 || !element.isConnected) {
                state.remove();
                return;
            }
            place(outline, element.getBoundingClientRect());
            for (const item of items)
                place(item.box, item.node.getBoundingClientRect());
            state.frame = requestAnimationFrame(tick);
        };
        Object.defineProperty(document, key, {value: state, configurable: true});
        (document.documentElement ?? document.body).appendChild(host);
        tick();
        return {shown: items.length, capped};
    }

    const sourceOrderPings = new Map;
    async function setSourceOrder(nodeId, targetId, on, cap) {
        if (!on || nodeId == null) {
            await removeLayer(sourceOrderPings, "perch.sourceOrder", targetId);
            return {shown: 0, capped: false};
        }
        const shown = await callOn(nodeId, targetId, inPageSourceOrder, [true, cap]);
        keepPinging(sourceOrderPings, "perch.sourceOrder", targetId);
        return shown;
    }

    globalThis.perchElements = Object.freeze({
        details, flags, documentRoot, subtree, children, search, styles, addRule, fonts, cssCatalog, layoutNodes, setOverlay, properties, accessibility,
        setPageOverlay, clearPageOverlays, anchorOf, accessibilityTreeRoot, accessibilityTreeChildren, listener, setSourceOrder,
        contrast: (nodeId, targetId) => callOn(nodeId, targetId, inPageContrast),
        mathSteps: (nodeId, targetId, property, steps) => callOn(nodeId, targetId, inPageMathSteps, [String(property), steps]),
        paths: (nodeId, targetId) => callOn(nodeId, targetId, inPagePaths),
        toggleHidden: (nodeId, targetId, hidden) => callOn(nodeId, targetId, inPageToggleHidden, [!!hidden]),
        storeAsGlobal: (nodeId, targetId) => callOn(nodeId, targetId, inPageStore),
        scrollIntoView: (nodeId, targetId) => callOn(nodeId, targetId, inPageScroll),
        adoptedSheets: (nodeId, targetId, index, text) => callOn(nodeId, targetId, inPageAdoptedSheets, [index, text]),
        setUserAgentShadowDOM: (on) => { userAgentShadowDOM = !!on; return userAgentShadowDOM; },
    });
}
