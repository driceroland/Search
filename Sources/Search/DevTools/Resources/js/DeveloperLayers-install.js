// The Layers drawer's ear on WebKit's LayerTree domain. Runs in the hidden
// inspector frontend, beside perchInspector: it counts layerTreeDidChange
// as it goes by on the same connection, so the drawer asks for the layers
// again only when they changed. Returns whether it was set up just now,
// so the drawer enables the domain again after the frontend reloaded, and
// the count so far.
let fresh = false;
if (!globalThis.perchLayers) {
    const connection = InspectorBackend.Connection?.prototype;
    const dispatch = connection?._dispatchEvent;
    if (typeof dispatch !== "function")
        throw new Error("This version of WebKit can’t report layer changes.");
    let changes = 0;
    connection._dispatchEvent = function(message) {
        const result = dispatch.apply(this, arguments);
        try {
            if (message?.method === "LayerTree.layerTreeDidChange")
                changes += 1;
        } catch {
            // The drawer's count must never interrupt WebKit's own.
        }
        return result;
    };
    globalThis.perchLayers = Object.freeze({
        changes() { return changes; },
    });
    fresh = true;
}
