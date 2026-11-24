// Layout shifts where WebKit has no layout-shift entries: the Layout
// Instability algorithm run in the page instead. A function expression,
// handed to the scripts that use it (DeveloperLighthouse-observe.js and
// DeveloperPerformance-metrics.js, see DeveloperLayoutShiftEstimator).
// Each sample takes the layout boxes of up to 1500 elements in document
// coordinates (so scrolling isn't a shift), from the offset chain, which
// leaves transforms out as Chrome does (a spinning or sliding element
// isn't a shift); an element whose top-left moved since the last sample
// is unstable. A sample's score is the impact
// fraction (the union of the unstable elements' old and new boxes, in the
// viewport, over its area, on a 100 × 100 grid) times the distance fraction
// (the largest move over the viewport's larger side); shifts within 500 ms
// of input are left out. Sampled on a 50 ms timer rather than animation
// frames, which an occluded tab doesn't get, for as long as
// `options.active()` says; then `options.ended()`, if given. Each shift
// goes to `options.onShift({value, time, elements})`, `elements` being up
// to five of the moved elements whose parent didn't move with them. What
// it calls on the page is taken when it starts, so the page's own
// replacements of them aren't used.
(options) => {
    const active = options.active;
    const onShift = options.onShift;
    const ended = options.ended || (() => {});
    const now = performance.now.bind(performance);
    const later = setTimeout.bind(window);
    const rectOf = Element.prototype.getBoundingClientRect;
    const byTag = Element.prototype.getElementsByTagName;
    const HTML = window.HTMLElement;
    const offset = (name) => Object.getOwnPropertyDescriptor(HTML.prototype, name).get;
    const [offsetLeft, offsetTop, offsetWidth, offsetHeight, offsetParent] =
        ["offsetLeft", "offsetTop", "offsetWidth", "offsetHeight", "offsetParent"].map(offset);
    // An element's layout box, transforms left out: document coordinates,
    // or the viewport's for a fixed element (whose chain ends short of the
    // body), as that's where it stays put. Other elements (SVG) by their
    // bounding box.
    const boxOf = (element, sx, sy) => {
        if (!(element instanceof HTML)) {
            const rect = rectOf.call(element);
            return {x: rect.left + sx, y: rect.top + sy, w: rect.width, h: rect.height, vx: rect.left, vy: rect.top};
        }
        let x = 0, y = 0, node = element, last = element;
        while (node) { x += offsetLeft.call(node); y += offsetTop.call(node); last = node; node = offsetParent.call(node); }
        // A chain ends at the body, unless it ends at a fixed element.
        const fixed = last !== document.body && last !== document.documentElement;
        return fixed
            ? {x, y, w: offsetWidth.call(element), h: offsetHeight.call(element), vx: x, vy: y}
            : {x, y, w: offsetWidth.call(element), h: offsetHeight.call(element), vx: x - sx, vy: y - sy};
    };
    const listen = EventTarget.prototype.addEventListener;
    const unlisten = EventTarget.prototype.removeEventListener;
    const previous = new WeakMap();
    let lastInput = -Infinity;
    const input = (event) => { if (event.isTrusted) lastInput = now(); };
    const inputs = ["pointerdown", "keydown", "mousedown"];
    for (const type of inputs) listen.call(window, type, input, true);
    const grid = 100;
    const frame = () => {
        if (!active()) {
            for (const type of inputs) unlisten.call(window, type, input, true);
            ended();
            return;
        }
        const width = innerWidth, height = innerHeight;
        const root = document.body || document.documentElement;
        if (root && width > 0 && height > 0) {
            const sx = scrollX, sy = scrollY;
            const moved = [];
            const elements = new Set();
            let distance = 0;
            const all = byTag.call(root, "*");
            for (let i = 0; i < all.length && i < 1500; i++) {
                const element = all[i];
                const current = boxOf(element, sx, sy);
                if (current.w === 0 && current.h === 0) { previous.delete(element); continue; }
                const before = previous.get(element);
                previous.set(element, current);
                if (!before) continue;
                const dx = current.x - before.x, dy = current.y - before.y;
                if (Math.abs(dx) < 1 && Math.abs(dy) < 1) continue;
                // The old box where it would be in today's viewport.
                moved.push([before.x - (current.x - current.vx), before.y - (current.y - current.vy), before.w, before.h],
                           [current.vx, current.vy, current.w, current.h]);
                elements.add(element);
                distance = Math.max(distance, Math.abs(dx), Math.abs(dy));
                if (moved.length >= 200) break;
            }
            if (moved.length && now() - lastInput > 500) {
                const cells = new Uint8Array(grid * grid);
                let covered = 0;
                for (const [x, y, w, h] of moved) {
                    const x0 = Math.max(0, Math.floor(x / width * grid)), x1 = Math.min(grid, Math.ceil((x + w) / width * grid));
                    const y0 = Math.max(0, Math.floor(y / height * grid)), y1 = Math.min(grid, Math.ceil((y + h) / height * grid));
                    for (let gy = y0; gy < y1; gy++) for (let gx = x0; gx < x1; gx++) {
                        if (!cells[gy * grid + gx]) { cells[gy * grid + gx] = 1; covered++; }
                    }
                }
                const value = (covered / (grid * grid)) * Math.min(1, distance / Math.max(width, height));
                if (value > 0) {
                    const sources = [];
                    for (const element of elements) {
                        if (elements.has(element.parentElement)) continue;
                        sources.push(element);
                        if (sources.length >= 5) break;
                    }
                    onShift({value, time: now(), elements: sources});
                }
            }
        }
        later(frame, 50);
    };
    later(frame, 0);
}
