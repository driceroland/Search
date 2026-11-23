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