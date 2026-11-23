// The package's page and frontend scripts, as Swift string literals: a
// package is one binary, and Bundle.module would look for a resource bundle
// on the building Mac.

enum DevToolsScripts {
    // DeveloperApplicationScript-read.js
    static let applicationScriptRead = ##"""
const rowLimit = 100;
const table = (rows = [], note) => note ? { rows, note } : { rows };
const unavailable = (note) => table([], note);
const clipped = (value, length = 4096) => String(value).slice(0, length);
const limitNote = (count) => count > rowLimit ? "Showing the first 100 entries." : undefined;
const errorText = "The inspected page could not provide this information.";

function readLocal(storage) {
    const rows = [];
    const keys = [];
    const count = storage.length;
    for (let index = 0; index < Math.min(rowLimit, count); index++) {
        const key = storage.key(index);
        if (key === null) continue;
        rows.push([clipped(key), clipped(storage.getItem(key) ?? "")]);
        keys.push(fits(key, maxKey) ? key : null);
    }
    return { ...table(rows, limitNote(count)), keys };
}

function readCookies() {
    const cookies = document.cookie;
    if (!cookies) return table();
    const items = cookies.split(/;\s*/);
    return table(items.slice(0, rowLimit).map((pair) => {
        const equals = pair.indexOf("=");
        return equals < 0 ? [pair, ""] : [pair.slice(0, equals), clipped(pair.slice(equals + 1))];
    }), limitNote(items.length));
}

function link(value, base) {
    if (typeof value !== "string") return "";
    try {
        const address = new URL(value, base);
        if (!["http:", "https:"].includes(address.protocol) || address.username || address.password) return "";
        return clipped(address.href);
    } catch { return ""; }
}

// What the Manifest view checks (Errors and warnings, Installability):
// each member's type, the addresses resolved against the manifest, and
// each icon as the page loads it, with its real size and a small
// thumbnail where the page may read its pixels.
function kind(value) {
    if (value === undefined) return "missing";
    if (value === null) return "null";
    return Array.isArray(value) ? "array" : typeof value;
}

function iconDetails(src, largest = 64) {
    return new Promise((resolve) => {
        const image = new Image();
        const timer = setTimeout(() => resolve({ failed: true }), 2500);
        image.onload = () => {
            clearTimeout(timer);
            const width = image.naturalWidth;
            const height = image.naturalHeight;
            let thumbnail = null;
            try {
                const side = largest;
                const ratio = Math.min(1, side / Math.max(width || side, height || side));
                const canvas = document.createElement("canvas");
                canvas.width = Math.max(1, Math.round((width || side) * ratio));
                canvas.height = Math.max(1, Math.round((height || side) * ratio));
                canvas.getContext("2d").drawImage(image, 0, 0, canvas.width, canvas.height);
                thumbnail = canvas.toDataURL("image/png");
            } catch {}
            resolve({ width, height, thumbnail });
        };
        image.onerror = () => { clearTimeout(timer); resolve({ failed: true }); };
        image.src = src;
    });
}

async function manifestReport(manifest, base) {
    const types = {};
    for (const key of ["name", "short_name", "start_url", "scope", "display", "id", "icons", "display_override",
        "theme_color", "background_color", "orientation"])
        types[key] = kind(manifest[key]);
    const text = (value) => typeof value === "string" ? clipped(value, 512) : null;
    const icons = [];
    if (Array.isArray(manifest.icons)) {
        for (const icon of manifest.icons.slice(0, 15)) {
            const src = link(icon?.src, base);
            if (!src) continue;
            icons.push({ src, sizes: text(icon.sizes) ?? "", purpose: text(icon.purpose) ?? "", type: text(icon.type) ?? "",
                ...(await iconDetails(src)) });
        }
    }
    // Identity, Presentation, Protocol handlers, Shortcuts and Screenshots.
    // Colours come back as the canvas resolves them, so the view can draw a
    // swatch; one the canvas rejects comes back as null.
    const colour = (value) => {
        if (typeof value !== "string") return null;
        try {
            const context = document.createElement("canvas").getContext("2d");
            context.fillStyle = "#010203";
            context.fillStyle = value;
            const first = context.fillStyle;
            context.fillStyle = "#040506";
            context.fillStyle = value;
            return first === context.fillStyle ? clipped(first, 64) : null;
        } catch { return null; }
    };
    const handlers = [];
    if (Array.isArray(manifest.protocol_handlers)) {
        for (const handler of manifest.protocol_handlers.slice(0, 20)) {
            const url = link(handler?.url, base);
            if (typeof handler?.protocol !== "string" || !url) continue;
            handlers.push({ protocol: clipped(handler.protocol, 128), url });
        }
    }
    const shortcuts = [];
    if (Array.isArray(manifest.shortcuts)) {
        for (const shortcut of manifest.shortcuts.slice(0, 10)) {
            const url = link(shortcut?.url, base);
            if (!url) continue;
            const shortcutIcons = [];
            for (const icon of (Array.isArray(shortcut.icons) ? shortcut.icons : []).slice(0, 4)) {
                const src = link(icon?.src, base);
                if (!src) continue;
                shortcutIcons.push({ src, sizes: text(icon.sizes) ?? "", purpose: text(icon.purpose) ?? "",
                    type: text(icon.type) ?? "", ...(await iconDetails(src)) });
            }
            shortcuts.push({ name: text(shortcut.name) ?? "", short_name: text(shortcut.short_name) ?? "",
                description: text(shortcut.description) ?? "", url, icons: shortcutIcons });
        }
    }
    const screenshots = [];
    if (Array.isArray(manifest.screenshots)) {
        for (const shot of manifest.screenshots.slice(0, 8)) {
            const src = link(shot?.src, base);
            if (!src) continue;
            screenshots.push({ src, sizes: text(shot.sizes) ?? "", type: text(shot.type) ?? "",
                form_factor: text(shot.form_factor) ?? "", label: text(shot.label) ?? "",
                platform: text(shot.platform) ?? "", ...(await iconDetails(src, 240)) });
        }
    }
    let workers = 0;
    try { workers = (await navigator.serviceWorker?.getRegistrations?.())?.length ?? 0; } catch {}
    return {
        types, icons, protocol_handlers: handlers, shortcuts, screenshots,
        description: text(manifest.description), id: text(manifest.id), orientation: text(manifest.orientation),
        theme_color: text(manifest.theme_color), background_color: text(manifest.background_color),
        theme_colour: colour(manifest.theme_color), background_colour: colour(manifest.background_color),
        name: text(manifest.name), short_name: text(manifest.short_name), display: text(manifest.display),
        start_url: typeof manifest.start_url === "string" ? (link(manifest.start_url, base) || "invalid") : null,
        scope: typeof manifest.scope === "string" ? (link(manifest.scope, base) || "invalid") : null,
        display_override: Array.isArray(manifest.display_override)
            ? manifest.display_override.slice(0, 12).filter((mode) => typeof mode === "string").map((mode) => clipped(mode, 64))
            : [],
        manifestURL: clipped(base), documentURL: clipped(location.href),
        secure: isSecureContext, controlled: !!navigator.serviceWorker?.controller, workers,
    };
}

async function readManifest() {
    const declaration = document.querySelector('link[rel~="manifest" i][href]');
    const address = declaration && link(declaration.href, document.baseURI);
    if (!address) return unavailable("This page has no web app manifest.");
    const abort = new AbortController();
    const timeout = setTimeout(() => abort.abort(), 3500);
    const sameOrigin = new URL(address).origin === current;
    const credentials = sameOrigin ? "same-origin" : "omit";
    try {
        const response = await fetch(address, { credentials, referrerPolicy: "no-referrer", signal: abort.signal });
        if (!response.ok || !response.body) return unavailable("Could not load the web app manifest.");
        const reader = response.body.getReader();
        const decoder = new TextDecoder();
        let source = "";
        let size = 0;
        for (;;) {
            const part = await reader.read();
            if (part.done) break;
            size += part.value.byteLength;
            if (size > 256 * 1024) {
                await reader.cancel();
                return unavailable("The web app manifest exceeds the 256 KB inspection limit.");
            }
            source += decoder.decode(part.value, { stream: true });
        }
        const manifest = JSON.parse(source + decoder.decode());
        if (!manifest || typeof manifest !== "object" || Array.isArray(manifest))
            return unavailable("The web app manifest must be a JSON object.");
        const rows = [["Manifest URL", link(response.url, address) || address]];
        const properties = [
            ["Name", "name"], ["Short name", "short_name"], ["Description", "description"],
            ["Display", "display"], ["Orientation", "orientation"],
            ["Theme color", "theme_color"], ["Background color", "background_color"],
            ["Language", "lang"], ["Text direction", "dir"],
        ];
        for (const [label, key] of properties) {
            if (typeof manifest[key] === "string") rows.push([label, clipped(manifest[key])]);
        }
        for (const [label, key] of [["ID", "id"], ["Start URL", "start_url"], ["Scope", "scope"]]) {
            const address = link(manifest[key], response.url);
            if (address) rows.push([label, address]);
        }
        if (Array.isArray(manifest.display_override)) {
            const modes = manifest.display_override.slice(0, 12).filter((mode) => typeof mode === "string");
            if (modes.length) rows.push(["Display override", modes.map((mode) => clipped(mode, 128)).join(", ")]);
        }
        for (const [label, key, addressKey] of [
            ["Icon", "icons", "src"], ["Screenshot", "screenshots", "src"], ["Shortcut", "shortcuts", "url"],
        ]) {
            if (!Array.isArray(manifest[key])) continue;
            for (const asset of manifest[key].slice(0, 15)) {
                const url = link(asset?.[addressKey], response.url);
                if (!url) continue;
                const detail = [asset.name, asset.sizes, asset.purpose]
                    .filter((value) => typeof value === "string" && value !== "")
                    .map((value) => clipped(value, 100)).join(" · ");
                rows.push([detail ? label + " · " + detail : label, url]);
            }
        }
        return { ...table(rows), manifest: await manifestReport(manifest, response.url) };
    } catch (error) {
        return unavailable(error instanceof SyntaxError ? "The web app manifest is not valid JSON."
            : "Could not load the web app manifest.");
    } finally {
        clearTimeout(timeout);
    }
}

async function readWorkers() {
    if (!isSecureContext || !navigator.serviceWorker?.getRegistrations)
        return unavailable("Service workers require a secure context and support from WebKit.");
    const registrations = await navigator.serviceWorker.getRegistrations();
    const controller = navigator.serviceWorker.controller;
    const controllerScope = controller ? (await navigator.serviceWorker.getRegistration())?.scope : null;
    const rows = [];
    for (const registration of registrations.slice(0, rowLimit)) {
        const scope = link(registration.scope, location.href);
        if (!scope || new URL(scope).origin !== current) continue;
        for (const key of ["active", "waiting", "installing"]) {
            const worker = registration[key];
            if (!worker) continue;
            rows.push([scope, key + " · " + worker.state, link(worker.scriptURL, scope),
                key === "active" && controllerScope === registration.scope && controller?.scriptURL === worker.scriptURL ? "Yes" : "—"]);
        }
    }
    return table(rows.slice(0, rowLimit), limitNote(Math.max(rows.length, registrations.length)));
}

function preview(value, depth = 0) {
    if (typeof value === "string") return clipped(value, 1000);
    if (value === null || typeof value !== "object") return clipped(value, 120);
    if (value instanceof Date) return String(value);
    if (typeof Blob === "function" && value instanceof Blob) return "Blob (" + value.size + " B)";
    if (ArrayBuffer.isView(value) || value instanceof ArrayBuffer) return value.constructor.name + " (" + value.byteLength + " B)";
    if (depth >= 3) return Array.isArray(value) ? "[…]" : "{…}";
    if (Array.isArray(value)) {
        const items = value.slice(0, 10).map((item) => clipped(preview(item, depth + 1), 120));
        if (value.length > 10) items.push("…");
        return "[" + items.join(", ") + "]";
    }
    const items = [];
    for (const key in value) {
        if (!Object.hasOwn(value, key)) continue;
        if (items.length === 10) { items.push("…"); break; }
        items.push(clipped(key, 90) + ": " + clipped(preview(value[key], depth + 1), 120));
    }
    return "{" + items.join(", ") + "}";
}

function inspectDatabase(name, storeName) {
    return new Promise((resolve) => {
        let finished = false;
        let opened;
        let transaction;
        let timer;
        const finish = (result) => {
            if (finished) return;
            finished = true;
            clearTimeout(timer);
            try { transaction?.abort(); } catch {}
            opened?.close();
            resolve(result);
        };
        timer = setTimeout(() => finish(unavailable("The database did not respond in time.")), 3000);
        const request = indexedDB.open(name);
        // A database can be deleted by the page after enumeration. Never
        // create or upgrade it in response to an inspection.
        request.onupgradeneeded = () => {
            request.transaction.abort();
            finish(unavailable("The database changed. Return to the database list and refresh."));
        };
        request.onerror = () => finish(unavailable("Could not open this database."));
        request.onblocked = () => finish(unavailable("The database is busy."));
        request.onsuccess = () => {
            opened = request.result;
            if (finished) { opened.close(); return; }
            try {
                const names = Array.from(opened.objectStoreNames);
                if (names.length === 0) { finish(table()); return; }
                if (storeName === null) {
                    transaction = opened.transaction(names.slice(0, rowLimit), "readonly");
                    const indexes = [];
                    const rows = names.slice(0, rowLimit).map((item) => {
                        const objectStore = transaction.objectStore(item);
                        const keyPath = objectStore.keyPath;
                        const indexNames = Array.from(objectStore.indexNames).slice(0, 30);
                        indexes.push(indexNames.map((name) => clipped(name, 512)));
                        return [item, keyPath === null ? "—" : clipped(keyPath),
                            objectStore.autoIncrement ? "Yes" : "—", clipped(indexNames.join(", "))];
                    });
                    finish({ ...table(rows, limitNote(names.length)), indexes });
                    return;
                }
                if (!names.includes(storeName)) { finish(unavailable("This object store is no longer available.")); return; }
                transaction = opened.transaction(storeName, "readonly");
                const objectStore = transaction.objectStore(storeName);
                // An index lists its own key before the record's primary key.
                if (index !== null && !objectStore.indexNames.contains(index)) {
                    finish(unavailable("This index is no longer available."));
                    return;
                }
                const source = index === null ? objectStore : objectStore.index(index);
                // Chrome's "Start from key": the first entry at or after it.
                let range = null;
                if (startKey !== null && startKey.trim() !== "") {
                    try { range = IDBKeyRange.lowerBound(JSON.parse(startKey)); } catch {
                        finish(unavailable("The start key isn’t a valid key. Write it as JSON: 42, \"name\" or [1, \"a\"]."));
                        return;
                    }
                }
                const counting = source.count();
                const cursor = source.openCursor(range);
                const rows = [];
                const keys = [];
                let total = null;
                let advanced = skip === 0;
                counting.onsuccess = () => { total = counting.result; };
                cursor.onerror = () => finish(unavailable("Could not read this object store."));
                // Chrome's IndexedDB data view: 50 entries a page.
                const done = (more) => finish({ ...table(rows), keys, hasMore: more, total });
                cursor.onsuccess = () => {
                    if (finished) return;
                    if (!cursor.result) { done(false); return; }
                    if (!advanced) { advanced = true; cursor.result.advance(skip); return; }
                    if (rows.length === pageSize) { done(true); return; }
                    const entry = cursor.result;
                    rows.push(index === null
                        ? [String(skip + rows.length), clipped(preview(entry.primaryKey)), clipped(preview(entry.value))]
                        : [String(skip + rows.length), clipped(preview(entry.key)), clipped(preview(entry.primaryKey)),
                            clipped(preview(entry.value))]);
                    keys.push(JSON.stringify(encodeKey(entry.primaryKey)));
                    entry.continue();
                };
            } catch {
                finish(unavailable("Could not read this database."));
            }
        };
    });
}

async function readIndexedDB() {
    if (typeof indexedDB?.databases !== "function") return unavailable("WebKit cannot enumerate IndexedDB databases on this page.");
    if (database !== null) return inspectDatabase(database, store);
    const databases = await indexedDB.databases();
    return table(databases.slice(0, rowLimit).filter((db) => typeof db.name === "string")
        .map((db) => [db.name, String(db.version)]), limitNote(databases.length));
}

async function bodyPreview(response) {
    const type = response.headers.get("content-type") ?? "";
    if (!/^(text\/|application\/(json|javascript|xml|manifest\+json|[a-z.+-]*\+(json|xml)))|image\/svg/i.test(type))
        return type ? "No text preview for " + clipped(type, 120) + "." : "No text preview.";
    if (!response.body) return "";
    const reader = response.clone().body.getReader();
    const decoder = new TextDecoder();
    let text = "";
    while (text.length < 2048) {
        const part = await reader.read();
        if (part.done) break;
        text += decoder.decode(part.value, { stream: true });
    }
    await reader.cancel().catch(() => {});
    return text.length > 2048 ? text.slice(0, 2048) + "…" : text;
}

// Chrome's Cache Storage view: path, response type, content type and
// length, Vary, and the headers and body of the selected entry. The Cache
// API does not expose when an entry was stored, so the Date header stands in.
async function readCache(name) {
    if (!(await caches.has(name))) return unavailable("This cache is no longer available.");
    const opened = await caches.open(name);
    const requests = await opened.keys();
    const rows = [];
    const keys = [];
    const details = [];
    for (const [offset, request] of requests.slice(skip, skip + pageSize).entries()) {
        const response = await opened.match(request);
        if (!response) continue;
        const header = (name) => clipped(response.headers.get(name) ?? "", 512);
        rows.push([String(skip + offset), clipped(request.url), response.type, header("content-type"),
            header("content-length"), header("date"), header("vary")]);
        keys.push(request.url);
        const fields = [["Request", request.method + " " + clipped(request.url)],
            ["Status", response.status + " " + clipped(response.statusText, 200)]];
        for (const [key, value] of Array.from(response.headers).slice(0, 60))
            fields.push([clipped(key, 120), clipped(value, 1024)]);
        fields.push(["Preview", await bodyPreview(response).catch(() => "No preview available.")]);
        details.push(fields);
    }
    return { ...table(rows), keys, details, hasMore: requests.length > skip + pageSize, total: requests.length };
}

// About how many bytes a stored value takes: strings as UTF-16, as
// Chrome counts Web Storage, binary data at its length. An estimate.
function sizeOf(value, depth = 0) {
    if (value === null || value === undefined) return 0;
    switch (typeof value) {
    case "string": return value.length * 2;
    case "number": return 8;
    case "boolean": return 4;
    case "bigint": return 16;
    case "object": break;
    default: return 0;
    }
    if (typeof Blob === "function" && value instanceof Blob) return value.size;
    if (value instanceof ArrayBuffer) return value.byteLength;
    if (ArrayBuffer.isView(value)) return value.byteLength;
    if (value instanceof Date) return 8;
    if (depth > 6) return 0;
    let total = 0;
    if (Array.isArray(value)) { for (const item of value) total += sizeOf(item, depth + 1); return total; }
    if (value instanceof Map) { for (const [k, v] of value) total += sizeOf(k, depth + 1) + sizeOf(v, depth + 1); return total; }
    if (value instanceof Set) { for (const item of value) total += sizeOf(item, depth + 1); return total; }
    for (const key in value) {
        if (!Object.hasOwn(value, key)) continue;
        total += key.length * 2 + sizeOf(value[key], depth + 1);
    }
    return total;
}

function storageBytes(storage) {
    let total = 0;
    for (let index = 0; index < storage.length; index++) {
        const key = storage.key(index);
        if (key === null) continue;
        total += (key.length + (storage.getItem(key) ?? "").length) * 2;
    }
    return total;
}

// A database's records, measured up to `budget` of them. Never creates or upgrades it.
function databaseBytes(name, budget) {
    return new Promise((resolve) => {
        let finished = false;
        let opened;
        let bytes = 0;
        let counted = 0;
        let complete = true;
        let timer;
        const finish = () => {
            if (finished) return;
            finished = true;
            clearTimeout(timer);
            opened?.close();
            resolve({ bytes, counted, complete });
        };
        timer = setTimeout(() => { complete = false; finish(); }, 3000);
        const request = indexedDB.open(name);
        request.onupgradeneeded = () => { request.transaction.abort(); complete = false; finish(); };
        request.onerror = () => { complete = false; finish(); };
        request.onblocked = () => { complete = false; finish(); };
        request.onsuccess = () => {
            opened = request.result;
            if (finished) { opened.close(); return; }
            const names = Array.from(opened.objectStoreNames);
            if (!names.length) { finish(); return; }
            try {
                const transaction = opened.transaction(names, "readonly");
                let pending = names.length;
                for (const storeName of names) {
                    const cursor = transaction.objectStore(storeName).openCursor();
                    cursor.onerror = () => { complete = false; if (--pending === 0) finish(); };
                    cursor.onsuccess = () => {
                        const entry = cursor.result;
                        if (!entry || counted >= budget) {
                            if (entry) complete = false;
                            if (--pending === 0) finish();
                            return;
                        }
                        counted++;
                        bytes += sizeOf(entry.primaryKey) + sizeOf(entry.value);
                        entry.continue();
                    };
                }
            } catch { complete = false; finish(); }
        };
    });
}

async function cacheBytes(budget) {
    let bytes = 0;
    let complete = true;
    let counted = 0;
    for (const name of await caches.keys()) {
        const opened = await caches.open(name);
        for (const request of await opened.keys()) {
            if (counted++ >= budget) return { bytes, complete: false };
            const response = await opened.match(request);
            if (!response) continue;
            const length = Number(response.headers.get("content-length"));
            if (Number.isFinite(length) && length > 0) { bytes += length; continue; }
            try { bytes += (await response.clone().blob()).size; } catch { complete = false; }
        }
    }
    return { bytes, complete };
}

// The origin private file system's entries, depth first, each folder
// before what it holds, with its full path.
async function fileSystemEntries(limit = 2000) {
    const root = await navigator.storage.getDirectory();
    const entries = [];
    let complete = true;
    const walk = async (folder, path, depth) => {
        const children = [];
        for await (const [name, handle] of folder.entries()) children.push([name, handle]);
        children.sort((a, b) => a[0].localeCompare(b[0]));
        for (const [name, handle] of children) {
            if (entries.length >= limit) { complete = false; return; }
            const entry = { path: path + "/" + name, name, depth, kind: handle.kind, size: 0, modified: null, file: null };
            entries.push(entry);
            if (handle.kind === "file") {
                try {
                    const file = await handle.getFile();
                    entry.size = file.size;
                    entry.modified = file.lastModified;
                    entry.file = file;
                } catch {}
            } else if (depth < 16) {
                await walk(handle, entry.path, depth + 1);
            }
        }
    };
    await walk(root, "", 0);
    // A folder's size is what it holds.
    for (const entry of entries) {
        if (entry.kind !== "directory") continue;
        const prefix = entry.path + "/";
        entry.size = entries.reduce((sum, other) => other.kind === "file" && other.path.startsWith(prefix) ? sum + other.size : sum, 0);
    }
    return { entries, complete };
}

function hexDump(bytes) {
    const lines = [];
    for (let offset = 0; offset < bytes.length; offset += 16) {
        const row = bytes.subarray(offset, offset + 16);
        const hex = Array.from(row, (byte) => byte.toString(16).padStart(2, "0")).join(" ");
        const text = Array.from(row, (byte) => byte >= 0x20 && byte < 0x7f ? String.fromCharCode(byte) : ".").join("");
        lines.push(offset.toString(16).padStart(8, "0") + "  " + hex.padEnd(47, " ") + "  " + text);
    }
    return lines.join("\n");
}

// A file's start as text when it is UTF-8, otherwise as hex.
async function filePreview(file) {
    if (!file) return "No preview available.";
    if (file.size === 0) return "Empty file.";
    const bytes = new Uint8Array(await file.slice(0, 4096).arrayBuffer());
    try {
        const text = new TextDecoder("utf-8", { fatal: true }).decode(bytes, { stream: file.size > 4096 });
        if (!/[\u0000-\u0008\u000e-\u001f]/.test(text)) return file.size > 4096 ? text + "…" : text;
    } catch {}
    const shown = bytes.subarray(0, 1024);
    return hexDump(shown) + (file.size > shown.length ? "\n…" : "");
}

async function readFileSystem() {
    if (typeof navigator.storage?.getDirectory !== "function")
        return unavailable("WebKit does not offer the origin private file system on this page.");
    const { entries, complete } = await fileSystemEntries();
    const rows = [];
    const keys = [];
    const details = [];
    for (const entry of entries.slice(skip, skip + pageSize)) {
        rows.push(["    ".repeat(entry.depth) + clipped(entry.name, 1024), entry.kind === "directory" ? "Folder" : "File",
            String(entry.size), entry.modified === null ? "—" : new Date(entry.modified).toISOString()]);
        keys.push(entry.path);
        const fields = [["Path", clipped(entry.path)]];
        if (entry.kind === "file") {
            if (entry.file?.type) fields.push(["Type", clipped(entry.file.type, 200)]);
            fields.push(["Preview", await filePreview(entry.file).catch(() => "No preview available.")]);
        }
        details.push(fields);
    }
    const note = complete ? undefined : "Showing the first 2000 entries.";
    return { ...table(rows, note), keys, details, hasMore: entries.length > skip + pageSize, total: entries.length };
}

async function readOverview() {
    const estimate = await navigator.storage?.estimate?.().catch(() => null);
    const persisted = await navigator.storage?.persisted?.().catch(() => null);
    let databases = null;
    let databaseNames = [];
    try {
        databaseNames = (await indexedDB.databases()).map((db) => db.name).filter((name) => typeof name === "string");
        databases = databaseNames.length;
    } catch {}
    let cacheCount = null;
    try { if (isSecureContext && window.caches) cacheCount = (await caches.keys()).length; } catch {}
    let workers = null;
    try { if (navigator.serviceWorker?.getRegistrations) workers = (await navigator.serviceWorker.getRegistrations()).length; } catch {}
    // Each kind's size, measured here: WebKit's estimate has no breakdown.
    const sizes = { approximate: [] };
    try { sizes.local = storageBytes(localStorage); } catch {}
    try { sizes.session = storageBytes(sessionStorage); } catch {}
    if (databases !== null) {
        let bytes = 0;
        let budget = 20000;
        for (const name of databaseNames.slice(0, 50)) {
            const measured = await databaseBytes(name, budget);
            bytes += measured.bytes;
            budget -= measured.counted;
        }
        sizes.indexedDB = bytes;
        sizes.approximate.push("indexedDB");
    }
    if (cacheCount !== null) {
        try {
            const measured = await cacheBytes(2000);
            sizes.caches = measured.bytes;
            if (!measured.complete) sizes.approximate.push("caches");
        } catch {}
    }
    let files = null;
    if (typeof navigator.storage?.getDirectory === "function") {
        try {
            const { entries, complete } = await fileSystemEntries();
            files = entries.length;
            sizes.fileSystem = entries.reduce((sum, entry) => entry.kind === "file" ? sum + entry.size : sum, 0);
            if (!complete) sizes.approximate.push("fileSystem");
        } catch {}
    }
    return { rows: [], overview: {
        usage: estimate?.usage ?? null, quota: estimate?.quota ?? null, persisted,
        local: localStorage.length, session: sessionStorage.length, databases, caches: cacheCount, workers, files, sizes,
    } };
}

let result;
try {
    switch (section) {
    case "Manifest": result = await readManifest(); break;
    case "Service workers": result = await readWorkers(); break;
    case "Local storage": result = readLocal(localStorage); break;
    case "Session storage": result = readLocal(sessionStorage); break;
    case "IndexedDB": result = await readIndexedDB(); break;
    case "Cookies": result = readCookies(); break;
    case "Cache storage": {
        if (!isSecureContext || !window.caches?.keys) {
            result = unavailable("Cache storage requires a secure context and support from WebKit.");
            break;
        }
        if (cache !== null) { result = await readCache(cache); break; }
        const keys = await caches.keys();
        result = { ...table(keys.slice(0, rowLimit).map((key) => [clipped(key)]), limitNote(keys.length)),
            keys: keys.slice(0, rowLimit) };
        break;
    }
    case "Storage": result = await readOverview(); break;
    case "Origin private file system": result = await readFileSystem(); break;
    default: result = unavailable(errorText); break;
    }
} catch {
    result = unavailable(errorText);
}
return sameDocument() ? { ...result, documentID } : { changed: true };
"""##

    // DeveloperCSSOverview-collect.js
    static let cSSOverviewCollect = ##"""
// The CSS overview drawer's capture: run once in the page (Runtime.evaluate,
// main world) when Capture overview is clicked. It reads, and never
// changes, the document: every element's computed colours, fonts and the
// few properties the unused-declaration checks look at, and the
// same-origin style sheets' rules, selectors and media queries. What it
// finds goes back as plain data (strings interned in a table to keep the
// answer small); the elements stay behind in the returned holder so the
// drawer can ask for one by index to reveal or highlight it. All the
// counting, colour parsing and contrast is done in Swift
// (DeveloperCSSOverview.swift).
(() => {
    const elementLimit = 25000;
    const selectorLimit = 60000;
    const fields = [
        "color", "backgroundColor", "borderTopColor", "borderRightColor", "borderBottomColor", "borderLeftColor",
        "fill", "fontFamily", "fontSize", "fontWeight", "lineHeight", "display", "position",
        "top", "right", "bottom", "left", "width", "height", "verticalAlign",
        "marginTop", "marginRight", "marginBottom", "marginLeft",
    ];
    const strings = [];
    const stringIndex = new Map();
    const intern = (value) => {
        const text = typeof value === "string" ? value.slice(0, 300) : "";
        let index = stringIndex.get(text);
        if (index === undefined) {
            index = strings.length;
            strings.push(text);
            stringIndex.set(text, index);
        }
        return index;
    };
    intern("");

    const label = (element) => {
        let text = (element.localName || element.nodeName || "").toLowerCase();
        if (element.id) text += "#" + element.id;
        const classes = element.classList ? Array.from(element.classList).slice(0, 3) : [];
        if (classes.length) text += "." + classes.join(".");
        return text.slice(0, 160);
    };
    const hasOwnText = (element) => {
        for (const child of element.childNodes) {
            if (child.nodeType === 3 && child.data.trim()) return true;
        }
        return false;
    };
    const sides = ["Top", "Right", "Bottom", "Left"];
    const svgShapes = new Set(["path", "rect", "circle", "ellipse", "line", "polyline", "polygon", "text", "tspan", "textPath", "use"]);
    const svgNamespace = "http://www.w3.org/2000/svg";

    // Elements in tree order, into open shadow roots; each one's parent
    // as an index, for the effective background behind its text.
    const elements = [];
    const rows = [];
    let total = 0;
    const walk = (root) => {
        const stack = [[root, -1]];
        while (stack.length) {
            const [node, parent] = stack.pop();
            let index = parent;
            if (node.nodeType === 1) {
                total += 1;
                if (elements.length < elementLimit) {
                    const style = getComputedStyle(node);
                    index = elements.length;
                    elements.push(node);
                    // flags: 1 own text, 2 rendered, 4 background image, 8 SVG shape
                    let flags = 0;
                    if (hasOwnText(node)) flags |= 1;
                    if (style.display !== "none" && style.visibility !== "hidden" && node.getClientRects().length > 0) flags |= 2;
                    if (style.backgroundImage && style.backgroundImage !== "none") flags |= 4;
                    const shape = node.namespaceURI === svgNamespace && svgShapes.has(node.localName);
                    if (shape) flags |= 8;
                    const row = [parent, flags, intern(label(node))];
                    for (const field of fields) {
                        let value = style[field];
                        if (field === "fill" && !shape) value = "";
                        if (field.startsWith("border")) {
                            const side = sides.find((name) => field === "border" + name + "Color");
                            const width = parseFloat(style["border" + side + "Width"]) || 0;
                            const kind = style["border" + side + "Style"];
                            if (width <= 0 || kind === "none" || kind === "hidden") value = "";
                        }
                        row.push(intern(value));
                    }
                    rows.push(row);
                }
            }
            // Children pushed last first, so they come off in document
            // order; a shadow root's after the light children.
            const children = [];
            for (let child = node.firstElementChild; child; child = child.nextElementSibling) children.push(child);
            if (node.shadowRoot) {
                for (let child = node.shadowRoot.firstElementChild; child; child = child.nextElementSibling) children.push(child);
            }
            for (let i = children.length - 1; i >= 0; i--) stack.push([children[i], index]);
        }
    };
    walk(document);

    // The style sheets: external and inline, and the rules of those that
    // can be read (cross-origin ones can't).
    let externalSheets = 0;
    let inlineSheets = 0;
    let unreadableSheets = 0;
    let styleRules = 0;
    const selectors = [];
    const media = [];
    const seenSheets = new Set();
    const readRules = (rules, depth) => {
        if (!rules || depth > 20) return;
        for (const rule of rules) {
            if (rule instanceof CSSStyleRule) {
                styleRules += 1;
                if (selectors.length < selectorLimit) selectors.push(String(rule.selectorText || "").slice(0, 400));
                if (rule.cssRules && rule.cssRules.length) readRules(rule.cssRules, depth + 1);
            } else if (typeof CSSMediaRule !== "undefined" && rule instanceof CSSMediaRule) {
                media.push(String(rule.conditionText || rule.media?.mediaText || "").slice(0, 300));
                readRules(rule.cssRules, depth + 1);
            } else if (typeof CSSImportRule !== "undefined" && rule instanceof CSSImportRule) {
                readSheet(rule.styleSheet, depth + 1);
            } else if (rule.cssRules) {
                readRules(rule.cssRules, depth + 1);
            }
        }
    };
    const readSheet = (sheet, depth) => {
        if (!sheet || seenSheets.has(sheet)) return;
        seenSheets.add(sheet);
        let rules = null;
        try {
            rules = sheet.cssRules;
        } catch {
            unreadableSheets += 1;
            return;
        }
        readRules(rules, depth);
    };
    const sheets = [];
    const collectSheets = (root) => {
        for (const sheet of Array.from(root.styleSheets || [])) sheets.push(sheet);
        for (const sheet of Array.from(root.adoptedStyleSheets || [])) sheets.push(sheet);
    };
    collectSheets(document);
    for (const element of elements) {
        if (element.shadowRoot) collectSheets(element.shadowRoot);
    }
    for (const sheet of sheets) {
        if (seenSheets.has(sheet)) continue;
        if (sheet.href) externalSheets += 1;
        else inlineSheets += 1;
        readSheet(sheet, 0);
    }

    return {
        elements,
        data: {
            fields,
            strings,
            rows,
            total,
            truncated: total > elements.length,
            externalSheets,
            inlineSheets,
            unreadableSheets,
            styleRules,
            selectors,
            media,
        },
    };
})()
"""##

    // DeveloperConsoleScript-source.js
    static let consoleScriptSource = ##"""
(() => {
    if (globalThis.searchConsole)
        return true;
    if (typeof WI === "undefined" || !globalThis.searchInspector)
        return false;
    const command = (method, params, targetId) => searchInspector.command(method, params, targetId ?? null);

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

    // Called by searchInspector while it projects Console.messageAdded.
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
                // removed): Chrome falls back to top, and so does Search.
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

    async function evaluate(expression, nodes, userGesture, targetId, where) {
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
                    generatePreview: true, saveResult: true, emulateUserGesture: userGesture !== false,
                }, targetId, where);
        }
        return {value: remote(result.result), wasThrown: result.wasThrown === true, contextReset: result.contextReset === true};
    }

    // Live expressions run as typed, side effects allowed, like Chrome's
    // pinned expressions once they are committed.
    async function live(expression, targetId) {
        const group = "search-live";
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
    const safeWalk = `function searchSafeRead(root, rootValue, keys) {
        const native = (fn) => { try { return /\\{\\s*\\[native code\\]\\s*\\}\\s*$/.test(Function.prototype.toString.call(fn)); } catch { return false; } };
        let value;
        if (rootValue.found) value = rootValue.value;
        else {
            let owner = globalThis, descriptor;
            while (owner && !(descriptor = Object.getOwnPropertyDescriptor(owner, root))) owner = Object.getPrototypeOf(owner);
            if (!descriptor) throw new Error("search: unresolved");
            if ("value" in descriptor) value = descriptor.value;
            else if (descriptor.get && native(descriptor.get)) value = descriptor.get.call(globalThis);
            else throw new Error("search: side effect");
        }
        for (const key of keys) {
            if (value === null || value === undefined) throw new Error("search: unresolved");
            let owner = Object(value), descriptor;
            for (let depth = 0; owner && depth < 64 && !(descriptor = Object.getOwnPropertyDescriptor(owner, key)); depth++)
                owner = Object.getPrototypeOf(owner);
            if (!descriptor) { value = undefined; continue; }
            if ("value" in descriptor) value = descriptor.value;
            else if (descriptor.get && native(descriptor.get)) value = descriptor.get.call(value);
            else throw new Error("search: side effect");
        }
        return value;
    }`;

    // The root of a path may be a page `let` binding or a console helper
    // such as $0 or $_: reading a bare identifier runs no page code
    // unless it is a global accessor, which searchSafeRead checks.
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
        const group = "search-eager";
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
        const group = "search-completions";
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

    globalThis.searchConsole = Object.freeze({
        extra, properties, invokeGetter, nodeId, evaluate, eager, completions, parsePath, live, storeAsGlobal, copyText,
        contexts, errorStack, nodeTree, storePropertyAsGlobal,
    });
    return true;
})()
"""##

    // DeveloperElementsBridgeScript-source.js
    static let elementsBridgeScriptSource = ##"""
if (!globalThis.searchElements && globalThis.searchInspector) {
    const {command} = searchInspector;

    // The DOM as the backend has described it to this connection, kept
    // here because WebKit's own frontend only models the document while
    // its Elements tab is open: attributes, text, children and layout.
    const mirrors = new Map;
    function targetKey(targetId) {
        return String(targetId ?? searchInspector.capabilities().domTargetId);
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
    // too; Search's own overlay layer is left out.
    function inPageBadges() {
        const output = [];
        const own = document[Symbol.for("search.elementsOverlay")]?.host ?? null;
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
        const objectGroup = "search-anchor";
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
        const objectGroup = "search-badges";
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
        const resolved = await command("DOM.resolveNode", {nodeId, objectGroup: "search-elements"}, targetId);
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
        const styleId = source?.styleId && typeof source.styleId.styleSheetId === "string"
            ? {styleSheetId: source.styleId.styleSheetId, ordinal: source.styleId.ordinal ?? 0} : null;
        return {
            selector: String(selector).slice(0, 350), origin: String(origin ?? "").slice(0, 60),
            styleId: origin === "user-agent" || origin === "user" ? null : styleId,
            properties: (source?.cssProperties ?? []).filter((item) =>
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

    // Elements › Properties: the node object's properties, own first and
    // then each prototype's, as DevTools lists them.
    const propertyGroup = "search-properties";
    async function properties(nodeId, objectId, targetId) {
        if (!objectId) {
            await command("Runtime.releaseObjectGroup", {objectGroup: propertyGroup}, targetId).catch(() => {});
            const resolved = await command("DOM.resolveNode", {nodeId, objectGroup: propertyGroup}, targetId);
            objectId = resolved.object?.objectId;
        }
        if (!objectId)
            return [];
        const method = searchInspector.supports("Runtime.getDisplayableProperties", targetId)
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
        const objectGroup = "search-accessibility-" + ++accessibilityRead;
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
        const objectGroup = "search-listeners";
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

    globalThis.searchElements = Object.freeze({
        details, flags, documentRoot, subtree, children, search, styles, addRule, fonts, cssCatalog, layoutNodes, setOverlay, properties, accessibility,
        anchorOf, accessibilityTreeRoot, accessibilityTreeChildren, listener,
        contrast: (nodeId, targetId) => callOn(nodeId, targetId, inPageContrast),
        paths: (nodeId, targetId) => callOn(nodeId, targetId, inPagePaths),
        toggleHidden: (nodeId, targetId, hidden) => callOn(nodeId, targetId, inPageToggleHidden, [!!hidden]),
        storeAsGlobal: (nodeId, targetId) => callOn(nodeId, targetId, inPageStore),
        scrollIntoView: (nodeId, targetId) => callOn(nodeId, targetId, inPageScroll),
        setUserAgentShadowDOM: (on) => { userAgentShadowDOM = !!on; return userAgentShadowDOM; },
    });
}
"""##

    // DeveloperIssues-collect.js
    static let issuesCollect = ##"""
// The Issues drawer's scan of the page's forms and ARIA attributes, and
// whether it is cross-origin isolated: run in the page
// (Runtime.evaluate, main world) after it loads and again when its form
// fields change. It reads, and never changes, the document's fields,
// labels and ids, and whether it is in Quirks Mode. The first run also
// leaves a MutationObserver that counts changes to them (debounced), so
// DevTools can ask cheaply whether to scan again: it reads the count off
// the returned state object (Runtime.getProperties) without running any
// script. Nothing is left on the page's globals: the state is the returned
// holder's, and DevTools disconnects its observer when it scans again or
// closes. The judging is done in Swift (DeveloperIssueRules.forms);
// the elements stay behind in the returned holder so the drawer can
// reveal one by its index.
(() => {
    const state = {version: 0, timer: 0, observer: null};
    {
        // Only changes that can change an issue: form fields and labels
        // added or taken away, and the attributes the rules read.
        const fieldSelector = "input, select, textarea, label, form";
        const touchesFields = (node) => node.nodeType === 1
            && (node.matches(fieldSelector) || !!node.querySelector(fieldSelector));
        const bump = (records) => {
            const relevant = records.some((record) => record.type === "attributes"
                || Array.prototype.some.call(record.addedNodes, touchesFields)
                || Array.prototype.some.call(record.removedNodes, touchesFields));
            if (!relevant)
                return;
            clearTimeout(state.timer);
            state.timer = setTimeout(() => { state.version += 1; }, 500);
        };
        try {
            state.observer = new MutationObserver(bump);
            state.observer.observe(document, {
                subtree: true, childList: true, attributes: true,
                attributeFilter: ["id", "name", "for", "type", "form", "autocomplete", "aria-label", "aria-labelledby", "title",
                    "role", "aria-hidden", "aria-describedby", "aria-controls", "tabindex"],
            });
        } catch {}
    }

    const limit = 2000;
    const idLimit = 10000;
    const elements = [];
    const label = (element) => {
        let text = (element.localName || element.nodeName || "").toLowerCase();
        if (element.id) text += "#" + element.id;
        const type = element.localName === "input" ? element.getAttribute("type") : null;
        if (type) text += "[type=" + type + "]";
        const name = element.getAttribute("name");
        if (name) text += "[name=" + name + "]";
        return text.slice(0, 160);
    };
    const attribute = (element, name) => (element.getAttribute(name) || "").slice(0, 300);

    const forms = new Map;
    const fields = [];
    let truncated = false;
    for (const element of document.querySelectorAll("input, select, textarea")) {
        if (fields.length >= limit) { truncated = true; break; }
        const type = element.localName === "input" ? (element.getAttribute("type") || "text").toLowerCase() : "";
        if (type === "hidden")
            continue;
        let form = -1;
        if (element.form) {
            if (!forms.has(element.form)) forms.set(element.form, forms.size);
            form = forms.get(element.form);
        }
        elements.push(element);
        fields.push({
            i: elements.length - 1, tag: element.localName, type,
            id: (element.id || "").slice(0, 300), name: attribute(element, "name"),
            autocomplete: element.hasAttribute("autocomplete") ? attribute(element, "autocomplete") : null,
            labels: element.labels ? element.labels.length : 0,
            ariaLabel: attribute(element, "aria-label"), ariaLabelledBy: attribute(element, "aria-labelledby"),
            title: attribute(element, "title"), form, label: label(element),
        });
    }

    const labels = [];
    for (const element of document.querySelectorAll("label")) {
        if (labels.length >= limit) { truncated = true; break; }
        elements.push(element);
        labels.push({
            i: elements.length - 1,
            for: element.hasAttribute("for") ? attribute(element, "for") : null,
            hasField: !!element.querySelector("input:not([type=hidden]), select, textarea, button, meter, output, progress"),
            label: label(element),
        });
    }

    // Elements with a role or an aria-* attribute, for the ARIA rules:
    // the attributes as written, and whether the element or something in
    // it can take keyboard focus (for aria-hidden).
    const focusableSelector = "a[href], area[href], button:not([disabled]), input:not([disabled]):not([type=hidden]), "
        + "select:not([disabled]), textarea:not([disabled]), iframe, summary, [contenteditable]:not([contenteditable=false]), "
        + "[tabindex]";
    const tabbable = (element) => element.matches(focusableSelector) && element.getAttribute("tabindex") !== "-1";
    const aria = [];
    const walker = document.createTreeWalker(document.documentElement || document, NodeFilter.SHOW_ELEMENT);
    let visited = 0;
    for (let element = walker.currentNode; element; element = walker.nextNode()) {
        if (++visited > 50000 || aria.length >= limit) { truncated = true; break; }
        if (element.nodeType !== 1)
            continue;
        const attributes = [];
        for (const attribute of element.attributes) {
            if (attribute.name.startsWith("aria-") && attributes.length < 40)
                attributes.push([attribute.name, attribute.value.slice(0, 300)]);
        }
        const role = element.hasAttribute("role") ? element.getAttribute("role").slice(0, 200) : null;
        if (!attributes.length && role === null)
            continue;
        const hidden = (element.getAttribute("aria-hidden") || "").trim().toLowerCase() === "true";
        let inner = false;
        if (hidden && !element.inert) {
            for (const child of element.querySelectorAll(focusableSelector)) {
                if (tabbable(child) && !child.inert) { inner = true; break; }
            }
        }
        elements.push(element);
        aria.push({
            i: elements.length - 1, label: label(element), role, attributes,
            focusable: !element.inert && tabbable(element),
            containsFocusable: inner, field: element.matches("input, select, textarea"),
        });
    }

    const ids = [];
    for (const element of document.querySelectorAll("[id]")) {
        if (ids.length >= idLimit) { truncated = true; break; }
        ids.push(element.id.slice(0, 300));
    }

    return {
        elements,
        state,
        data: {
            version: state.version, fields, labels, ids, aria, quirks: document.compatMode === "BackCompat", truncated,
            isolated: typeof crossOriginIsolated === "boolean" ? crossOriginIsolated : null,
        },
    };
})()
"""##

    // DeveloperIssues-frontend.js
    static let issuesFrontend = ##"""
// The Issues drawer's ear on the Network domain, for cookie and
// cross-origin isolation issues. Runs in the hidden inspector frontend,
// beside searchInspector: it listens on the same connection and keeps each
// response's Set-Cookie headers (which the Network list's model leaves
// out) and its COOP, COEP, CORP and Access-Control-Allow-Origin headers,
// handing them over in batches.
// Returns whether it was set up just now.
let fresh = false;
if (!globalThis.searchIssues) {
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
    globalThis.searchIssues = Object.freeze({
        drain() {
            const out = pending;
            pending = [];
            return out;
        },
    });
    fresh = true;
}
"""##

    // DeveloperNetworkBridgeScript-source.js
    static let networkBridgeScriptSource = ##"""
(() => {

    if (globalThis.searchNetwork)
        return true;
    if (typeof WI === "undefined" || typeof InspectorBackend === "undefined" || !globalThis.searchInspector)
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
            const wanted = blockingEnabled && (matchers.length > 0 || throttles.length > 0);
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

    function setBlocking({enabled = true, patterns: list = [], throttled: delays = []} = {}) {
        blockingEnabled = !!enabled;
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
        return syncBlocking();
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
        if (message?.method !== "Network.requestIntercepted" || !blockingEnabled || !throttles.length)
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
                target.NetworkAgent.interceptContinue.invoke({requestId, stage: blockStage}).catch(() => {});
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
        const objectGroup = "search-header-overrides";
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
            const item = await searchInspector.requestDetails(id).catch(() => null);
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
        if (blockingEnabled && (matchers.length || throttles.length) && blockRule !== interceptionTarget())
            syncBlocking().catch(() => {});
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
                observe(message, this.target);
            } catch {}
            return dispatchEvent.apply(this, arguments);
        };
    }

    globalThis.searchNetwork = Object.freeze({
        state, frames, clear, setBlocking, setHeaderOverrides, har, search, emulation, emulate,
    });
    return true;
})()
"""##

    // DeveloperServiceWorkers-script.js
    static let serviceWorkersScript = ##"""
if (location.origin !== origin) return { changed: true };
if (!isSecureContext || !navigator.serviceWorker?.getRegistrations)
    return { note: "Service workers require a secure context and support from WebKit." };
const own = (registration) => {
    try { return new URL(registration.scope).origin === location.origin; } catch { return false; }
};
const registrations = (await navigator.serviceWorker.getRegistrations()).filter(own);
// "Update on reload": every registration checks for a new script, and a
// new worker is asked to take over at once, with the message Workbox and
// most generated workers answer with skipWaiting().
if (action === "updateAll") {
    for (const registration of registrations.slice(0, 50)) {
        try { await registration.update(); } catch {}
        const fresh = registration.waiting ?? registration.installing;
        if (fresh) fresh.postMessage({ type: "SKIP_WAITING" });
    }
    return { done: true };
}
if (action !== null) {
    const registration = registrations.find((item) => item.scope === scope);
    if (!registration) return { issue: "This registration is gone. Refresh the list." };
    switch (action) {
    case "update":
        await registration.update();
        return { done: true };
    case "unregister":
        return { done: await registration.unregister() };
    case "skipWaiting": {
        const waiting = registration.waiting;
        if (!waiting) return { issue: "No worker is waiting to activate." };
        // Only a worker can call skipWaiting(). This is the message
        // Workbox and most generated workers answer with it.
        waiting.postMessage({ type: "SKIP_WAITING" });
        for (let tries = 0; tries < 20 && registration.waiting === waiting; tries++)
            await new Promise((resolve) => setTimeout(resolve, 100));
        return registration.waiting === waiting
            ? { issue: "The waiting worker didn’t call skipWaiting(). WebKit only lets the worker itself activate early: have it answer a {type: \"SKIP_WAITING\"} message, or close the other tabs it controls." }
            : { done: true };
    }
    case "sync":
        if (!registration.sync?.register)
            return { issue: "WebKit doesn’t support Background Sync, so a sync event can’t be sent." };
        await registration.sync.register(tag || "test-tag-from-devtools");
        return { done: true };
    }
    return { issue: "Unknown action." };
}
const controller = navigator.serviceWorker.controller;
const rows = [];
for (const registration of registrations.slice(0, 50)) {
    const workers = [];
    for (const role of ["active", "waiting", "installing"]) {
        const worker = registration[role];
        if (worker) workers.push({ role, state: worker.state, scriptURL: String(worker.scriptURL).slice(0, 4096) });
    }
    let subscribed = false;
    try { subscribed = !!(await registration.pushManager?.getSubscription()); } catch {}
    rows.push({
        scope: registration.scope, workers, subscribed,
        controlsPage: !!controller && !!registration.active && controller.scriptURL === registration.active.scriptURL
            && location.href.startsWith(registration.scope),
        updateViaCache: registration.updateViaCache ?? "imports",
        sync: !!registration.sync?.register,
    });
}
return { rows };
"""##

    // DeveloperToolsBridgeScript-source.js
    static let toolsBridgeScriptSource = ##"""
(() => {
    if (globalThis.searchInspector)
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
    // dropped and the next drain says so (a "Search.eventsDropped" event
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
            result.push({method: "Search.eventsDropped", params: {}});
        }
        return result;
    }

    // Where a console evaluation's reply came, among the events: what the
    // expression logged comes before its result, what happened after it
    // comes after, as in Chrome.
    function mark(token) {
        pending.push({method: "Search.evaluated", params: {token: String(token).slice(0, 64)}});
    }

    function setDomains(names) {
        const requested = new Set(Array.isArray(names) ? names.filter((name) => domains.has(name)) : []);
        if (requested.size === enabled.size && [...requested].every((name) => enabled.has(name)))
            return;
        enabled = requested;
        // The overflow flag stays for the next drain.
        pending = pending.filter(({method}) => method.startsWith("Search.") || enabled.has(method.split(".")[0]));
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
        const objectGroup = "search-framework-listeners-" + ++listenerRead;
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
                data.message, "url"), ...(globalThis.searchConsole?.extra?.(data.message) ?? {})}};
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
        if (typeof agent.setBreakpointsActive?.invoke === "function" && (!workerBreakpointsActive || target.searchBreakpointsInactive)) {
            target.searchBreakpointsInactive = !workerBreakpointsActive;
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
        if (typeof resumeIfPaused === "function" && !resumeIfPaused.searchWorkers) {
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
            wrapped.searchWorkers = true;
            targetPrototype._resumeIfPaused = wrapped;
        }
        // The Console's inspect(node): WebKit's frontend would select the
        // node in its own hidden Elements and release the object; the app
        // is given the object instead, to select the node in its Elements
        // (and release it there).
        const domManager = WI.DOMManager?.prototype;
        const inspectNodeObject = domManager?.inspectNodeObject;
        if (typeof inspectNodeObject === "function" && !inspectNodeObject.searchInspect) {
            const wrappedInspect = function(remoteObject) {
                const objectId = remoteObject?.objectId;
                if (typeof objectId !== "string" || !enabled.has("DOM"))
                    return inspectNodeObject.apply(this, arguments);
                if (pending.length < limit)
                    pending.push({method: "Search.inspectNode", params: {objectId: objectId.slice(0, 500)}});
                else
                    overflowed = true;
            };
            wrappedInspect.searchInspect = true;
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
        if (typeof didPause === "function" && typeof pauseIfNeeded === "function" && !didPause.searchThreads) {
            let inDidPause = false;
            const wrappedDidPause = function() {
                inDidPause = true;
                try {
                    return didPause.apply(this, arguments);
                } finally {
                    inDidPause = false;
                }
            };
            wrappedDidPause.searchThreads = true;
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

    globalThis.searchInspector = Object.freeze({
        command, supports, drain, setDomains, capabilities, networkConditions, nodePath,
        requestDetails, clearRequestDetails: () => details.clear(), setStyleText, eventListeners,
        scriptLocation, pauseOnExceptions, workers, setWorkerBreakpoints, mark,
    });
    return true;
})()
"""##

}
