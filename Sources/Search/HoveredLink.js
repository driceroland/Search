// Tells the window which link the pointer is over, for the bubble that shows where a click would
// go. That bubble is a safety feature as much as a convenience: it lets a person check a
// destination before following it. So what is reported is the address the link resolves to, never
// its text, and a page has no way to put words of its own there.
//
// One passive listener looks up from whatever the pointer entered to the nearest link, and a
// message is sent only when the answer changes, so moving over a page costs a walk up a few
// ancestors per element entered. It runs in every frame, since links in embedded pages are links
// too, and in the isolated client world, out of the page's reach.
(() => {
    let shown = '';

    function report(address) {
        if (address === shown) return;
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
