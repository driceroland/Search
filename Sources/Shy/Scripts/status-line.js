(() => {
    // Turned back on over a page that already has it: the same listener
    // speaks again rather than a second one beside it.
    if (Object.prototype.hasOwnProperty.call(window, '__shyLinks')) { window.__shyLinks.on = true; return; }
    const state = { on: true };
    window.__shyLinks = state;
    let shown = '';

    function report(address) {
        if (!state.on || address === shown) return;
        shown = address;
        webkit.messageHandlers.link.postMessage(address);
    }

    // The composed path reaches links inside open shadow trees, where `target` stops at the host.
    function linkIn(path) {
        for (const node of path) {
            if (node.nodeType !== 1 || (node.localName !== 'a' && node.localName !== 'area')) continue;
            // An SVG link's href is an object, and its address may be relative.
            const href = typeof node.href === 'string' ? node.href : node.href && node.href.baseVal;
            if (!href) continue;
            try {
                const address = new URL(href, node.baseURI).href;
                // A script link goes nowhere worth showing.
                return address.startsWith('javascript:') ? '' : address.slice(0, 600);
            } catch {
                return '';
            }
        }
        return '';
    }

    addEventListener('mouseover', event => report(linkIn(event.composedPath())), { passive: true, capture: true });
    // Leaving the frame altogether: there is no next element to enter.
    addEventListener('mouseout', event => { if (!event.relatedTarget) report(''); }, { passive: true, capture: true });
    addEventListener('pagehide', () => report(''));
})();
