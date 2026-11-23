if (!globalThis.perchRendering) {
    let state = null;
    const preferenceNames = ["PrefersColorScheme", "PrefersReducedMotion", "PrefersContrast"];
    const isDefault = (s) => !s || (!s.paintFlashing && !s.layerBorders && !s.mediaType && !s.colorScheme &&
        !s.reducedMotion && !s.contrast && !s.javaScriptDisabled && !s.imagesDisabled);
    async function applyTo(target, s) {
        if (!target || typeof target.hasCommand !== "function") return;
        const calls = [];
        const run = (method, params) => {
            if (!target.hasCommand(method)) return;
            const [domain, name] = method.split(".");
            const command = target[domain + "Agent"]?.[name];
            if (typeof command?.invoke === "function")
                calls.push(Promise.resolve(command.invoke(params)).catch(() => null));
        };
        run("Page.setShowPaintRects", {result: !!s.paintFlashing});
        const settings = [["ShowDebugBorders", s.layerBorders ? true : null],
            ["ScriptEnabled", s.javaScriptDisabled ? false : null],
            ["ImagesEnabled", s.imagesDisabled ? false : null]];
        for (const [setting, value] of settings)
            run("Page.overrideSetting", value === null ? {setting} : {setting, value});
        run("Page.setEmulatedMedia", {media: s.mediaType || ""});
        const names = InspectorBackend.Enum?.Page?.UserPreferenceName ?? {};
        for (const [name, value] of [["PrefersColorScheme", s.colorScheme],
            ["PrefersReducedMotion", s.reducedMotion], ["PrefersContrast", s.contrast]]) {
            if (names[name]) run("Page.overrideUserPreference", value ? {name, value} : {name});
        }
        await Promise.all(calls);
    }
    const reapply = (event) => {
        const target = event?.data?.target ?? event?.data;
        if (!isDefault(state)) applyTo(target, state);
    };
    try {
        WI.targetManager.addEventListener(WI.TargetManager.Event.TargetAdded, reapply);
        WI.targetManager.addEventListener(WI.TargetManager.Event.DidCommitProvisionalTarget, reapply);
    } catch {}
    globalThis.perchRendering = Object.freeze({
        async apply(next) {
            state = next;
            await Promise.all(Array.from(WI.targets ?? []).map((target) => applyTo(target, next)));
            return true;
        },
    });
}
const names = InspectorBackend.Enum?.Page?.UserPreferenceName ?? {};
return {
    paintRects: perchInspector.supports("Page.setShowPaintRects"),
    settings: perchInspector.supports("Page.overrideSetting"),
    media: perchInspector.supports("Page.setEmulatedMedia"),
    preferences: perchInspector.supports("Page.overrideUserPreference")
        ? ["PrefersColorScheme", "PrefersReducedMotion", "PrefersContrast"].filter((name) => names[name]) : [],
};