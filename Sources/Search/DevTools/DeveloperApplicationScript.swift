enum DeveloperApplicationScript {
    // A token stays in the inspected main frame's isolated world. Retire it
    // when a document goes away, including when WebKit keeps it for Back.
    private static let document = #"""
    const current = new URL(origin).origin;
    const addressHref = new URL(address).href;
    const atAddress = () => location.origin === current && location.href === addressHref;
    if (!atAddress()) return { changed: true };
    const token = '__perchDeveloperApplicationDocument';
    if (!globalThis[token]) {
        globalThis[token] = Array.from(crypto.getRandomValues(new Uint32Array(4))).join('-');
        const retire = (event) => {
            if (!event.isTrusted) return;
            delete globalThis[token];
            removeEventListener('pagehide', retire, true);
        };
        addEventListener('pagehide', retire, true);
    }
    const documentID = globalThis[token];
    if (expectedDocument !== null && documentID !== expectedDocument) return { changed: true };
    const sameDocument = () => atAddress() && globalThis[token] === documentID;
    const fits = (string, limit) => string.length <= limit && new TextEncoder().encode(string).length <= limit;
    """# + "\n"

    static let identity = document + "return { documentID };"

    // Runs only on demand, in the inspected main frame's isolated world.
    static let read = document + keyCoding + DevToolsResources.script("DeveloperApplicationScript-read.js")

    // No yield between the comparison and the write. A table preview is
    // never used as a value or key, and a missing entry is never recreated.
    static let storageValue = document + #"""
    if (!sameDocument() || !fits(key, maxKey)) return { changed: true };
    try {
        const storage = persistent ? localStorage : sessionStorage;
        const value = storage.getItem(key);
        if (value === null || (replacement !== null && value !== expectedValue)) return { issue: 'stale' };
        if (replacement === null) return fits(value, maxValue) ? { value } : { issue: 'tooLarge' };
        if (!fits(replacement, maxValue)) return { issue: 'tooLarge' };
        storage.setItem(key, replacement);
        return { saved: true };
    } catch {
        return { issue: 'unavailable' };
    }
    """#

    // IndexedDB keys cross into Swift as JSON and come back for deletion.
    // Numbers travel as strings so Infinity survives.
    static let keyCoding = #"""
    function encodeKey(key) {
        if (typeof key === "number") return { n: String(key) };
        if (typeof key === "string") return { s: key };
        if (key instanceof Date) return { d: key.getTime() };
        if (Array.isArray(key)) return { a: key.map(encodeKey) };
        if (key instanceof ArrayBuffer) return { b: Array.from(new Uint8Array(key)) };
        if (ArrayBuffer.isView(key)) return { b: Array.from(new Uint8Array(key.buffer, key.byteOffset, key.byteLength)) };
        return null;
    }
    function decodeKey(value) {
        if (!value || typeof value !== "object") throw new TypeError("key");
        if ("n" in value) return Number(value.n);
        if ("s" in value) return String(value.s);
        if ("d" in value) return new Date(value.d);
        if ("a" in value) return value.a.map(decodeKey);
        if ("b" in value) return new Uint8Array(value.b).buffer;
        throw new TypeError("key");
    }
    """# + "\n"

    // Adds, renames, removes or clears Web Storage entries of this document.
    static let storageWrite = document + #"""
    if (!sameDocument()) return { changed: true };
    try {
        const storage = persistent ? localStorage : sessionStorage;
        switch (operation) {
        case 'set': {
            if (!fits(key, maxKey) || (value !== null && !fits(value, maxValue))) return { issue: 'tooLarge' };
            if (previousKey !== null && previousKey !== key) {
                const old = storage.getItem(previousKey);
                if (old === null) return { issue: 'stale' };
                storage.setItem(key, value ?? old);
                storage.removeItem(previousKey);
            } else {
                if (value === null) return { issue: 'unavailable' };
                storage.setItem(key, value);
            }
            return { saved: true };
        }
        case 'remove':
            for (const name of keys) storage.removeItem(name);
            return { saved: true };
        case 'clear':
            storage.clear();
            return { saved: true };
        }
        return { issue: 'unavailable' };
    } catch (error) {
        return { issue: error?.name === 'QuotaExceededError' ? 'tooLarge' : 'unavailable' };
    }
    """#

    // Deletes records, clears an object store or deletes a database. It never
    // creates or upgrades a database.
    static let indexedDBWrite = document + keyCoding + #"""
    if (!sameDocument()) return { changed: true };
    if (operation === 'deleteDatabase') {
        return await new Promise((resolve) => {
            const request = indexedDB.deleteDatabase(database);
            const timer = setTimeout(() => resolve({ blocked: true }), 3000);
            request.onsuccess = () => { clearTimeout(timer); resolve({ saved: true }); };
            request.onerror = () => { clearTimeout(timer); resolve({ issue: 'unavailable' }); };
            request.onblocked = () => { clearTimeout(timer); resolve({ blocked: true }); };
        });
    }
    return await new Promise((resolve) => {
        let opened;
        let settled = false;
        const finish = (result) => {
            if (settled) return;
            settled = true;
            clearTimeout(timer);
            opened?.close();
            resolve(result);
        };
        const timer = setTimeout(() => finish({ issue: 'unavailable' }), 3000);
        const request = indexedDB.open(database);
        request.onupgradeneeded = () => { request.transaction.abort(); finish({ issue: 'stale' }); };
        request.onerror = () => finish({ issue: 'unavailable' });
        request.onblocked = () => finish({ issue: 'unavailable' });
        request.onsuccess = () => {
            opened = request.result;
            if (settled) { opened.close(); return; }
            try {
                if (!Array.from(opened.objectStoreNames).includes(store)) { finish({ issue: 'stale' }); return; }
                const transaction = opened.transaction(store, 'readwrite');
                const objectStore = transaction.objectStore(store);
                if (operation === 'clearStore') objectStore.clear();
                else for (const key of keys) objectStore.delete(decodeKey(JSON.parse(key)));
                transaction.oncomplete = () => finish({ saved: true });
                transaction.onerror = () => finish({ issue: 'unavailable' });
                transaction.onabort = () => finish({ issue: 'unavailable' });
            } catch {
                finish({ issue: 'unavailable' });
            }
        };
    });
    """#

    // Deletes Cache Storage entries or whole caches. It never creates a cache.
    static let cacheWrite = document + #"""
    if (!sameDocument()) return { changed: true };
    try {
        if (!isSecureContext || !window.caches) return { issue: 'unavailable' };
        if (operation === 'deleteCache') {
            for (const name of keys) await caches.delete(name);
            return { saved: true };
        }
        if (!(await caches.has(cache))) return { issue: 'stale' };
        const opened = await caches.open(cache);
        const wanted = new Set(keys);
        for (const request of await opened.keys()) {
            if (wanted.has(request.url)) await opened.delete(request);
        }
        return { saved: true };
    } catch {
        return { issue: 'unavailable' };
    }
    """#

    // Deletes a file or folder (with what it holds) of the origin private
    // file system, by its path from the root. It never creates one.
    static let fileSystemWrite = document + #"""
    if (!sameDocument()) return { changed: true };
    try {
        if (typeof navigator.storage?.getDirectory !== 'function') return { issue: 'unavailable' };
        const parts = String(path).split('/').filter((part) => part.length);
        if (!parts.length) return { issue: 'unavailable' };
        let folder = await navigator.storage.getDirectory();
        for (const part of parts.slice(0, -1)) folder = await folder.getDirectoryHandle(part, { create: false });
        await folder.removeEntry(parts[parts.length - 1], { recursive: true });
        return { saved: true };
    } catch (error) {
        return { issue: error?.name === 'NotFoundError' ? 'stale' : 'unavailable' };
    }
    """#

    // Chrome's "Clear site data" for this origin. Cookies are cleared from
    // Swift, which also reaches HttpOnly cookies.
    static let clearSite = document + #"""
    if (!sameDocument()) return { changed: true };
    const failed = [];
    const attempt = async (name, work) => { try { await work(); } catch { failed.push(name); } };
    if (types.includes('storage')) {
        await attempt('Local and session storage', () => { localStorage.clear(); sessionStorage.clear(); });
    }
    if (types.includes('indexedDB')) {
        await attempt('IndexedDB', async () => {
            for (const { name } of await indexedDB.databases()) {
                if (typeof name !== 'string') continue;
                await new Promise((resolve) => {
                    const request = indexedDB.deleteDatabase(name);
                    request.onsuccess = request.onerror = request.onblocked = () => resolve();
                });
            }
        });
    }
    if (types.includes('caches') && isSecureContext && window.caches) {
        await attempt('Cache storage', async () => { for (const name of await caches.keys()) await caches.delete(name); });
    }
    if (types.includes('workers') && navigator.serviceWorker?.getRegistrations) {
        await attempt('Service workers', async () => {
            for (const registration of await navigator.serviceWorker.getRegistrations()) await registration.unregister();
        });
    }
    return sameDocument() ? { saved: true, failed } : { changed: true };
    """#
}
