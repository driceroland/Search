import WebKit

// The window moved by the top of the page, as in Arc and Dia: a drag that
// starts on an empty part of a site's top bar, or of the page's top edge,
// takes the window with it, the way its title bar would. With the tabs down
// the side the page runs right up to the window's top, and without this the
// only part of that edge that moved the window was the column's.
//
// Off unless turned on in Settings › General. Off, not a line of it reaches
// a page: the listener is only put into pages while the switch is on.
//
// Whether a press there is the page's or the window's has to be known the
// moment it lands, and the page lives in another process. So the page says
// ahead of time, as the pointer moves: the listener tells the view whenever
// what is under the pointer changes between grabbable and not, and the view
// decides on the press from what it was last told (see PageView.mouseDown).

/// Tells the page's view whether a press where the pointer is would move
/// the window. WebKit retains this relay; the view is reached through the
/// message, so closing the tab releases the page.
final class GrabRelay: NSObject, WKScriptMessageHandler {
    static let name = "officeGrab"
    /// Whether pages get the listener, and presses are taken. Set from
    /// Settings.
    @MainActor static var on = false

    /// For a page already up when it is turned off: its listener says no
    /// once more, and then nothing.
    static let off = "if (window.__searchGrab) window.__searchGrab.on = false;"

    // In Search's own world, the main frame only: a frame is never the top
    // bar, and a pointer over one is over the frame, which is the page's.
    //
    // What counts as the top bar: the page's top edge, as tall as the tab
    // strip, where a title bar would be; and below it, anything at least half
    // the page wide whose top is the page's top and that is no taller than a
    // bar — a site's header, pinned or at the top of an unscrolled page.
    // Scrolled, only one that is fixed or sticky still counts, so the middle
    // of an article is never taken for a header on its way past.
    //
    // What stays the page's: links, buttons, fields, media and anything else
    // a hand would use; anything the page gave a pointer of its own, which is
    // how most clickable things built out of plain boxes say so; and words
    // that can be selected. Words that can't be are as good as the ground.
    static let script = """
    (() => {
        if (window.__searchGrab) { window.__searchGrab.on = true; return; }
        const EDGE = \(Int(Metrics.strip)), BAR = 120;
        const TAGS = new Set(['a', 'area', 'button', 'input', 'textarea', 'select', 'option', 'label',
            'summary', 'video', 'audio', 'canvas', 'iframe', 'frame', 'embed', 'object', 'img']);
        const ROLES = new Set(['button', 'link', 'menuitem', 'menuitemcheckbox', 'menuitemradio', 'option',
            'tab', 'checkbox', 'radio', 'switch', 'textbox', 'searchbox', 'combobox', 'slider',
            'spinbutton', 'scrollbar', 'treeitem']);
        const state = { on: true, at };
        window.__searchGrab = state;
        // Nothing said yet: a new page's first answer always goes, so the
        // view never keeps the last page's.
        let said = null;

        function say(grab) {
            if (grab === said) return;
            said = grab;
            webkit.messageHandlers.officeGrab.postMessage(grab);
        }

        function used(el) {
            if (TAGS.has(el.localName)) return true;
            const role = el.getAttribute('role');
            if (role && ROLES.has(role)) return true;
            if (el.isContentEditable || el.getAttribute('draggable') === 'true') return true;
            if (el.hasAttribute('onclick') || el.hasAttribute('onmousedown')) return true;
            const index = el.getAttribute('tabindex');
            return index !== null && index !== '' && Number(index) >= 0;
        }

        function inBar(path, y) {
            if (y <= EDGE) return true;
            if (y > BAR) return false;
            const scrolled = scrollY > 0;
            let pinned = false;
            // From the outside in, so a pinned header counts for what is in it.
            for (let i = path.length - 1; i >= 0; i--) {
                const el = path[i];
                const style = getComputedStyle(el);
                if (style.position === 'fixed' || style.position === 'sticky') pinned = true;
                // The document itself is the page, never a bar across it.
                if (scrolled && !pinned || el === document.documentElement || el === document.body) continue;
                const box = el.getBoundingClientRect();
                if (box.top <= 1 && box.bottom >= y && box.height <= BAR && box.width >= innerWidth / 2) return true;
            }
            return false;
        }

        function onWords(el, style, x, y) {
            if (style.webkitUserSelect === 'none' || style.userSelect === 'none') return false;
            for (const node of el.childNodes) {
                if (node.nodeType !== 3 || !node.data.trim()) continue;
                const range = document.createRange();
                range.selectNodeContents(node);
                for (const box of range.getClientRects()) {
                    if (x >= box.left - 2 && x <= box.right + 2 && y >= box.top - 2 && y <= box.bottom + 2) return true;
                }
            }
            return false;
        }

        // Whether a press at this point of the page would be the window's.
        function at(x, y) {
            // Below any bar the answer is known without asking the page
            // anything, which is where the pointer spends most of its time.
            if (x < 0 || y < 0 || x > innerWidth || y > BAR) return false;
            let el = document.elementFromPoint(x, y);
            // Into open shadow trees, where the point may be on a button.
            while (el && el.shadowRoot) {
                const inner = el.shadowRoot.elementFromPoint(x, y);
                if (!inner || inner === el) break;
                el = inner;
            }
            if (!el) return false;
            const path = [];
            for (let node = el; node; node = node.parentNode || node.host) {
                if (node.nodeType === 1) path.push(node);
            }
            if (!inBar(path, y)) return false;
            if (path.some(used)) return false;
            const style = getComputedStyle(el);
            if (style.cursor !== 'auto' && style.cursor !== 'default') return false;
            return !onWords(el, style, x, y);
        }

        // Worked out once a frame at most, from where the pointer was last.
        let x = 0, y = 0, asked = false;
        addEventListener('mousemove', event => {
            x = event.clientX; y = event.clientY;
            if (asked) return;
            asked = true;
            requestAnimationFrame(() => { asked = false; say(state.on && at(x, y)); });
        }, { passive: true, capture: true });
        // Leaving the page altogether: there is no next element to enter.
        addEventListener('mouseout', event => { if (!event.relatedTarget) say(false); }, { passive: true, capture: true });
        addEventListener('pagehide', () => say(false));
    })();
    """

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let grab = message.body as? Bool else { return }
        MainActor.assumeIsolated {
            guard message.frameInfo.isMainFrame, let page = message.webView as? PageView else { return }
            page.grabbable = grab
        }
    }
}
