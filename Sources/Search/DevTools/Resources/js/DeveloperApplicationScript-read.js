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