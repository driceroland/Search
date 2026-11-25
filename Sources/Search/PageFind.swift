import WebKit

/// The page-side part of ⌘F. A count and the range selected by Next always
/// come from the same list, built in Search's own world (`Web.world`), which
/// the page cannot see into: not the word looked for, not the list, and none
/// of the functions it is built with — a page that swaps `Range`,
/// `getSelection` or `RegExp` for its own swaps them in its world only.
@MainActor
final class PageFind {
    struct Result: Equatable {
        let count: Int?
        /// One-based, as shown in the find bar.
        let index: Int?
        /// More matches than `count` may follow: the list stops at
        /// `PageFind.limit` until Next goes past its end.
        let more: Bool
        let found: Bool
        let nativeFallback: Bool
        let wholeWordsAvailable: Bool
        let available: Bool
        let stale: Bool
    }

    /// Matches measured at a time. Each one is a range whose boxes are asked
    /// for, which is what costs on a long page; a letter typed into a book
    /// would otherwise measure every "e" in it before the count came back.
    /// Safari stops counting at the same number.
    static let limit = 1000

    private var newestGeneration: UInt64 = 0

    /// `steps` is how far to move: on a new search, from the first match
    /// (0 lands on it); otherwise from the current one, negative for back.
    func update(
        on web: WKWebView,
        query: String,
        matchCase: Bool,
        wholeWords: Bool,
        steps: Int,
        generation: UInt64
    ) async -> Result {
        guard generation >= newestGeneration else { return Self.staleResult }
        newestGeneration = max(newestGeneration, generation)
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return await clear(on: web, generation: generation)
        }

        do {
            let value = try await evaluate(
                on: web,
                arguments: [
                    "query": query,
                    "restoresFocus": true,
                    "matchCase": matchCase,
                    "wholeWords": wholeWords,
                    "steps": steps,
                    "limit": Self.limit,
                    "generation": NSNumber(value: generation),
                ]
            )
            guard generation >= newestGeneration else { return Self.staleResult }
            guard let result = value as? [String: Any], let status = result["status"] as? String else {
                return Self.unavailableResult
            }

            if status == "stale" { return Self.staleResult }
            // "cut" is a page too big to walk with nothing in the part read:
            // WebKit's own find looks past where the walk stopped.
            if status == "pdf" || status == "cut" {
                guard !wholeWords else {
                    return Result(
                        count: nil, index: nil, more: false, found: false, nativeFallback: true,
                        wholeWordsAvailable: false, available: true, stale: false
                    )
                }
                let found = await nativeFind(
                    query, on: web, matchCase: matchCase, forward: steps >= 0
                )
                guard generation >= newestGeneration else { return Self.staleResult }
                return Result(
                    count: nil, index: nil, more: false, found: found, nativeFallback: true,
                    wholeWordsAvailable: false, available: true, stale: false
                )
            }

            guard status == "ok",
                  let count = result["count"] as? Int,
                  let index = result["index"] as? Int else {
                return Self.unavailableResult
            }
            return Result(
                count: count,
                index: index == 0 ? nil : index,
                more: result["more"] as? Bool ?? false,
                found: count > 0,
                nativeFallback: false,
                wholeWordsAvailable: true,
                available: true,
                stale: false
            )
        } catch {
            guard generation >= newestGeneration else { return Self.staleResult }
            return Self.unavailableResult
        }
    }

    func clear(on web: WKWebView, generation: UInt64, restoresFocus: Bool = true) async -> Result {
        newestGeneration = max(newestGeneration, generation)
        do {
            _ = try await evaluate(
                on: web,
                arguments: [
                    "query": "",
                    "restoresFocus": restoresFocus,
                    "matchCase": false,
                    "wholeWords": false,
                    "steps": 0,
                    "limit": Self.limit,
                    "generation": NSNumber(value: generation),
                ]
            )
        } catch {
            // A page may have gone away between the clear and WebKit's reply.
        }
        return generation >= newestGeneration ? Self.emptyResult : Self.staleResult
    }

    private func evaluate(on web: WKWebView, arguments: [String: Any]) async throws -> Any {
        let window = web.window
        let editor = window?.firstResponder as? NSTextView
        let responder = editor?.isFieldEditor == true ? editor?.delegate as? NSView : window?.firstResponder as? NSView
        let selection = editor?.selectedRange()
        let value: Any = try await withCheckedThrowingContinuation { continuation in
            web.callAsyncJavaScript(Self.script, arguments: arguments, in: nil, in: Web.world) {
                (result: Swift.Result<Any, Error>) in
                continuation.resume(with: result)
            }
        }
        if let responder, responder.window === window,
           let current = window?.firstResponder as? NSView,
           current !== responder, current.isDescendant(of: web) {
            window?.makeFirstResponder(responder)
            if let selection, let field = responder as? NSTextField {
                field.currentEditor()?.selectedRange = selection
            }
            _ = try? await web.callAsyncJavaScript(
                """
                const state = globalThis.__searchPageFindState_v2;
                if (state?.generation === Number(generation) && state.current?.kind === "control"
                    && state.current.control.getRootNode().activeElement === state.current.control) {
                    state.current.control.setSelectionRange(state.current.start, state.current.end);
                }
                """,
                arguments: arguments, in: nil, contentWorld: Web.world
            )
        }
        return value
    }

    private func nativeFind(
        _ query: String,
        on web: WKWebView,
        matchCase: Bool,
        forward: Bool
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let configuration = WKFindConfiguration()
            configuration.backwards = !forward
            configuration.caseSensitive = matchCase
            configuration.wraps = true
            web.find(query, configuration: configuration) { result in
                continuation.resume(returning: result.matchFound)
            }
        }
    }

    private static let emptyResult = Result(
        count: 0, index: nil, more: false, found: false, nativeFallback: false,
        wholeWordsAvailable: true, available: true, stale: false
    )
    private static let unavailableResult = Result(
        count: nil, index: nil, more: false, found: false, nativeFallback: false,
        wholeWordsAvailable: true, available: false, stale: false
    )
    private static let staleResult = Result(
        count: nil, index: nil, more: false, found: false, nativeFallback: false,
        wholeWordsAvailable: true, available: false, stale: true
    )

    /// `callAsyncJavaScript` supplies these names as arguments; the query is
    /// never interpolated into source. State and ranges live only in Search's
    /// isolated content world, so the page's nodes stay untouched. The matches
    /// are painted with `CSS.highlights`; fields use mirrors in a closed
    /// shadow tree so their values and styles stay untouched. The page can
    /// read the highlight sheet back, but not the list the count comes from.
    ///
    /// The page's text is read once and kept, as runs of text with a map back
    /// to the nodes, until a mutation, a changed field or another frame says
    /// it is out of date: typing one more letter only runs the search again
    /// over the kept text, and measures the first `limit` matches.
    private static let script = #"""
    const needle = String(query ?? "");
    const epoch = Number(generation ?? 0);
    const moves = Math.trunc(Number(steps ?? 0)) || 0;
    const cap = Math.max(1, Math.trunc(Number(limit ?? 1000)) || 1000);
    const key = "__searchPageFindState_v2";
    let state = globalThis[key];
    if (!state) {
        state = {
            generation: -1, query: null, matchCase: false, wholeWords: false,
            index: -1, matches: [], complete: true, cursor: null, expression: null,
            runs: null, current: null, savedSelections: [], painted: [], highlights: new WeakMap(),
            observers: [], documents: [], controls: [], dirty: true,
            fieldPainters: new Map(), fieldHosts: new WeakSet()
        };
        Object.defineProperty(globalThis, key, { value: state, configurable: true });
    }

    const answer = (status, count = 0, index = 0, more = false) => ({ status, count, index, more });
    if (epoch < state.generation) return answer("stale");

    function sameRange(left, right) {
        try {
            return left.compareBoundaryPoints(0, right) === 0
                && left.compareBoundaryPoints(2, right) === 0;
        } catch (_) { return false; }
    }

    // Puts back whatever the page had selected before the find took over,
    // unless the page has since selected something else itself.
    function unmarkCurrent(restoresFocus = true) {
        if (!state.current) return;
        if (state.current.kind === "range") {
            try {
                const selection = state.current.win.getSelection();
                const saved = state.savedSelections.find(item => item.win === state.current.win);
                if (selection && saved && selection.rangeCount === 1
                    && sameRange(selection.getRangeAt(0), state.current.range)) {
                    selection.removeAllRanges();
                    for (const range of saved.ranges) selection.addRange(range);
                }
            } catch (_) {}
        } else if (state.current.kind === "control") {
            try {
                const control = state.current.control;
                if (control.selectionStart === state.current.start
                    && control.selectionEnd === state.current.end) {
                    control.setSelectionRange(state.current.savedStart, state.current.savedEnd, state.current.savedDirection);
                    if (control.getRootNode().activeElement === control && state.current.savedFocus !== control) {
                        control.blur();
                        if (restoresFocus) state.current.savedFocus?.focus({ preventScroll: true });
                        const selection = state.current.win.getSelection();
                        const saved = state.savedSelections.find(item => item.win === state.current.win);
                        if (selection && saved) {
                            selection.removeAllRanges();
                            for (const range of saved.ranges) selection.addRange(range);
                        }
                    }
                }
            } catch (_) {}
        }
        state.current = null;
    }

    function stopObservers() {
        for (const observer of state.observers) observer.disconnect();
        state.observers = [];
    }

    function clearState() {
        unmarkCurrent(restoresFocus);
        unpaint();
        state.savedSelections = [];
        state.matches = [];
        state.complete = true;
        state.cursor = null;
        state.expression = null;
        state.runs = null;
        state.index = -1;
        state.query = null;
        state.documents = [];
        state.controls = [];
        state.dirty = true;
        stopObservers();
    }

    if (!needle.trim()) {
        clearState();
        state.generation = Math.max(state.generation, epoch);
        state.matchCase = false;
        state.wholeWords = false;
        return answer("ok", 0, 0);
    }

    if (document.contentType === "application/pdf") {
        return answer("pdf");
    }

    const hiddenTags = new Set(["script", "style", "noscript", "template", "head", "title", "select", "option", "optgroup"]);

    // Null when the element and what is inside it are not drawn; otherwise
    // whether it breaks the text into a block of its own, and whether its
    // own text is drawn.
    // A hidden element's child may set `visibility: visible` again,
    // so only the text directly in it is left out (`shown`), not the child.
    function layout(element, doc) {
        if (hiddenTags.has(element.localName)) return null;
        if (element.hidden || element.hasAttribute("hidden")) return null;
        let style = null;
        try { style = doc.defaultView.getComputedStyle(element); } catch (_) {}
        if (!style) return { block: true, shown: true };
        const display = style.display;
        if (display === "none" || style.contentVisibility === "hidden"
            || style.opacity === "0") return null;
        return {
            block: !(display.startsWith("inline") || display === "contents" || display === "ruby"),
            shown: style.visibility === "visible"
        };
    }

    function contexts() {
        const found = [];
        const seen = new Set();
        function visit(win) {
            if (seen.has(win)) return;
            seen.add(win);
            try {
                const doc = win.document;
                if (win !== window) {
                    // Cross-origin frames cannot be read from this world.
                    const frame = win.frameElement;
                    const frameBox = frame && layout(frame, frame.ownerDocument);
                    if (!frameBox || !frameBox.shown) return;
                    const box = frame.getBoundingClientRect();
                    if (box.width === 0 || box.height === 0) return;
                }
                if (doc && doc.body) found.push({ win, doc });
                for (let i = 0; i < win.frames.length; i++) visit(win.frames[i]);
            } catch (_) {}
        }
        visit(window);
        return found;
    }

    function observe(context) {
        if (state.observers.some(item => !item.shadow && item.doc === context.doc)) return;
        try {
            const observer = new context.win.MutationObserver(pageMutations);
            observer.observe(context.doc.documentElement, {
                subtree: true, childList: true, characterData: true, attributes: true
            });
            observer.doc = context.doc;
            state.observers.push(observer);
        } catch (_) {}
    }

    // A run is one block's text with runs of white space made one space, and
    // a list of segments mapping it back: from text offset t0 on, either
    // straight into one node (kind 0: node offset so + (i - t0)), or all of
    // it onto one span of the page (kind 1: sn/so to en/eo), as a collapsed
    // space or a recomposed accent is.
    function makeRun(context, control) {
        return {
            win: context.win, doc: context.doc, control: control || null,
            parts: [], length: 0, nodes: [], text: "",
            t0: [], kind: [], sn: [], so: [], en: [], eo: [], pending: null
        };
    }

    function emitSpace(run) {
        const space = run.pending;
        if (!space) return;
        run.pending = null;
        run.t0.push(run.length); run.kind.push(1);
        run.sn.push(space.sn); run.so.push(space.so); run.en.push(space.en); run.eo.push(space.eo);
        run.parts.push(" ");
        run.length += 1;
    }

    function addPiece(run, node, offset, piece) {
        emitSpace(run);
        run.t0.push(run.length); run.kind.push(0);
        run.sn.push(node); run.so.push(offset); run.en.push(node); run.eo.push(offset);
        run.parts.push(piece);
        run.length += piece.length;
    }

    // Soft hyphens and zero-width characters are read past, as WebKit's
    // own find does, so "documentation" finds "docu&shy;mentation".
    const unseen = /[\u00AD\u200B\u2060\uFEFF]/g;
    function addValue(run, node, value) {
        const space = /[\u00AD\u200B\u2060\uFEFF]+|\s+/g;
        let last = 0;
        let found;
        while ((found = space.exec(value))) {
            if (found.index > last) addPiece(run, node, last, value.slice(last, found.index));
            const end = found.index + found[0].length;
            if (/^[\u00AD\u200B\u2060\uFEFF]/.test(found[0])) { last = end; continue; }
            if (!run.pending) run.pending = { sn: node, so: found.index, en: node, eo: end };
            else { run.pending.en = node; run.pending.eo = end; }
            last = end;
        }
        if (last < value.length) addPiece(run, node, last, value.slice(last));
    }

    function segmentAt(run, index) {
        const t0 = run.t0;
        let low = 0, high = t0.length - 1;
        while (low < high) {
            const middle = (low + high + 1) >> 1;
            if (t0[middle] <= index) low = middle; else high = middle - 1;
        }
        return low;
    }

    function startOf(run, index) {
        const k = segmentAt(run, index);
        if (run.kind[k] === 0) return { node: run.nodes[run.sn[k]], offset: run.so[k] + index - run.t0[k] };
        return { node: run.nodes[run.sn[k]], offset: run.so[k] };
    }

    function endOf(run, index) {
        const k = segmentAt(run, index);
        if (run.kind[k] === 0) return { node: run.nodes[run.sn[k]], offset: run.so[k] + index - run.t0[k] + 1 };
        return { node: run.nodes[run.en[k]], offset: run.eo[k] };
    }

    // Composed and decomposed accents read alike: each letter with the marks
    // after it is recomposed (NFC), and every unit of the result maps onto
    // the whole letter. Only runs that change under NFC take this path.
    function canonicalize(run) {
        if (run.text.normalize("NFC") !== run.text) remap(run, (letter) => letter.normalize("NFC"));
    }

    // Without Match case, a letter typed without its accent finds it with
    // one, as WebKit's own find does: "ete" finds "été", but "été" doesn't
    // find "ete". A run with accents gets a twin without them, each of its
    // letters mapped onto the whole letter it came from.
    const accent = /\p{M}/gu;
    const bare = (text) => text.normalize("NFD").replace(accent, "");
    function loosen(run) {
        if (bare(run.text) === run.text) return;
        const twin = Object.assign({}, run);
        remap(twin, bare);
        run.loose = twin;
    }

    // Rewrites a run letter by letter (a letter and the marks after it),
    // keeping every unit of the result mapped onto the letter it came from.
    function remap(run, change) {
        const original = run.text;
        const n = original.length;
        const sn = new Array(n), so = new Array(n), en = new Array(n), eo = new Array(n);
        for (let k = 0; k < run.t0.length; k++) {
            const from = run.t0[k];
            const to = k + 1 < run.t0.length ? run.t0[k + 1] : n;
            for (let i = from; i < to; i++) {
                if (run.kind[k] === 0) {
                    sn[i] = run.sn[k]; so[i] = run.so[k] + i - from;
                    en[i] = run.sn[k]; eo[i] = so[i] + 1;
                } else {
                    sn[i] = run.sn[k]; so[i] = run.so[k]; en[i] = run.en[k]; eo[i] = run.eo[k];
                }
            }
        }
        const mark = /^\p{M}$/u;
        const parts = [];
        let length = 0;
        run.t0 = []; run.kind = []; run.sn = []; run.so = []; run.en = []; run.eo = [];
        for (let offset = 0; offset < n;) {
            const first = offset;
            offset += original.codePointAt(offset) > 0xFFFF ? 2 : 1;
            while (offset < n) {
                const size = original.codePointAt(offset) > 0xFFFF ? 2 : 1;
                if (!mark.test(original.slice(offset, offset + size))) break;
                offset += size;
            }
            const value = change(original.slice(first, offset));
            for (let i = 0; i < value.length; i++) {
                run.t0.push(length + i); run.kind.push(1);
                run.sn.push(sn[first]); run.so.push(so[first]);
                run.en.push(en[offset - 1]); run.eo.push(eo[offset - 1]);
            }
            parts.push(value);
            length += value.length;
        }
        run.text = parts.join("");
        run.length = length;
    }

    function collectRuns(context, runs) {
        let run = makeRun(context);
        function flush() {
            run.pending = null;
            if (run.length) {
                run.text = run.parts.join("");
                run.parts = null;
                canonicalize(run);
                loosen(run);
                runs.push(run);
            }
            run = makeRun(context);
        }
        function addControl(element, value) {
            flush();
            state.controls.push({ element, value });
            const controlRun = makeRun(context, element);
            controlRun.value = value;
            controlRun.nodes.push(element);
            addValue(controlRun, 0, value);
            run = controlRun;
            flush();
        }
        // The page is walked as it's drawn, into open shadow trees
        // (Reddit, MSN), with each slot's assigned nodes where the slot is.
        // A run never spans two trees, since a range can't.
        let shadows = null;
        function walkChildren(parent, shown) {
            for (let child = parent.firstChild; child; child = child.nextSibling) walk(child, shown);
        }
        function walk(node, shown = true) {
            if (node.nodeType === 3) {
                const value = node.nodeValue || "";
                if (!value || !shown) return;
                addValue(run, run.nodes.push(node) - 1, value);
                return;
            }
            if (node.nodeType !== 1) return;
            // Each element's style is asked for, which is what costs: past
            // the budget the walk stops, and the count says there may be
            // more, rather than the page holding Find up (Security).
            if (--state.budget < 0) { state.cut = true; return; }
            const element = node;
            const box = layout(element, context.doc);
            if (!box) return;
            const tag = element.localName;
            if (tag === "input") {
                const type = (element.type || "text").toLowerCase();
                if (type !== "password" && element.selectionStart !== null
                    && element.getAttribute("aria-hidden") !== "true"
                    && element.getClientRects().length > 0) addControl(element, element.value || "");
                return;
            }
            if (tag === "textarea") {
                if (element.getAttribute("aria-hidden") !== "true"
                    && element.getClientRects().length > 0) addControl(element, element.value || "");
                return;
            }
            if (tag === "br") { flush(); return; }
            if (box.block) flush();
            const root = element.shadowRoot;
            if (root) {
                try {
                    if (!shadows) shadows = new context.win.MutationObserver(pageMutations);
                    shadows.observe(root, { subtree: true, childList: true, characterData: true, attributes: true });
                } catch (_) {}
                flush();
                walkChildren(root, box.shown);
                flush();
            } else if (tag === "slot") {
                const assigned = element.assignedNodes({ flatten: true });
                if (assigned.length) {
                    flush();
                    for (const child of assigned) walk(child, box.shown);
                    flush();
                } else {
                    walkChildren(element, box.shown);
                }
            } else {
                walkChildren(element, box.shown);
            }
            if (box.block) flush();
        }
        walk(context.doc.body);
        flush();
        if (shadows) {
            shadows.doc = context.doc;
            shadows.shadow = true;
            state.observers.push(shadows);
        }
    }

    function buildRuns(foundContexts) {
        state.controls = [];
        state.budget = 60000;
        state.cut = false;
        // The shadow trees are watched anew with each walk.
        for (const observer of state.observers) if (observer.shadow) observer.disconnect();
        state.observers = state.observers.filter(observer => !observer.shadow);
        const runs = [];
        for (const context of foundContexts) {
            observe(context);
            collectRuns(context, runs);
        }
        // Whatever the walk itself set off is already in the list.
        for (const observer of state.observers) observer.takeRecords();
        return runs;
    }

    function beforeCodePoint(text, index) {
        if (index <= 0) return "";
        const last = text.charCodeAt(index - 1);
        if (last >= 0xDC00 && last <= 0xDFFF && index > 1) {
            const first = text.charCodeAt(index - 2);
            if (first >= 0xD800 && first <= 0xDBFF) return text.slice(index - 2, index);
        }
        return text.slice(index - 1, index);
    }

    function afterCodePoint(text, index) {
        if (index >= text.length) return "";
        const first = text.charCodeAt(index);
        if (first >= 0xD800 && first <= 0xDBFF && index + 1 < text.length) {
            const last = text.charCodeAt(index + 1);
            if (last >= 0xDC00 && last <= 0xDFFF) return text.slice(index, index + 2);
        }
        return text.slice(index, index + 1);
    }

    const wordCharacter = /^[\p{L}\p{N}\p{M}_]$/u;
    function isWholeWord(text, start, end) {
        const before = beforeCodePoint(text, start);
        const after = afterCodePoint(text, end);
        return !(before && wordCharacter.test(before)) && !(after && wordCharacter.test(after));
    }

    function startMatching() {
        const spaced = needle.replace(unseen, "").replace(/\s+/gu, " ").normalize("NFC");
        state.loose = !state.matchCase && bare(spaced) === spaced;
        const normalizedNeedle = spaced;
        const escaped = normalizedNeedle.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
        state.matches = [];
        state.cursor = { run: 0, from: 0 };
        state.complete = false;
        try { state.expression = new RegExp(escaped, "gu" + (state.matchCase ? "" : "i")); }
        catch (_) { state.expression = null; state.complete = true; }
    }

    function makeMatch(run, start, end) {
        const from = startOf(run, start);
        const to = endOf(run, end - 1);
        if (run.control) {
            const control = run.control;
            return {
                kind: "control", win: run.win, control, value: run.value,
                start: from.offset, end: to.offset,
                savedStart: control.selectionStart, savedEnd: control.selectionEnd,
                savedDirection: control.selectionDirection || "none"
            };
        }
        try {
            const range = run.doc.createRange();
            range.setStart(from.node, from.offset);
            range.setEnd(to.node, to.offset);
            if (range.collapsed) return null;
            const rects = range.getClientRects();
            for (let i = 0; i < rects.length; i++) {
                if (rects[i].width > 0 || rects[i].height > 0) return { kind: "range", win: run.win, range };
            }
        } catch (_) {}
        return null;
    }

    // Goes on measuring matches until there are `until` of them or the text
    // has been read to its end.
    function collect(until) {
        const runs = state.runs, expression = state.expression, cursor = state.cursor;
        if (!expression || !cursor) { state.complete = true; return; }
        while (state.matches.length < until && cursor.run < runs.length) {
            const run = state.loose ? (runs[cursor.run].loose || runs[cursor.run]) : runs[cursor.run];
            expression.lastIndex = cursor.from;
            const found = expression.exec(run.text);
            if (!found) { cursor.run += 1; cursor.from = 0; continue; }
            const start = found.index;
            const end = start + found[0].length;
            cursor.from = end > start ? end : end + 1;
            if (end === start) continue;
            if (state.wholeWords && !isWholeWord(run.text, start, end)) continue;
            const match = makeMatch(run, start, end);
            if (match) state.matches.push(match);
        }
        state.complete = cursor.run >= runs.length;
    }

    function saveSelections(foundContexts) {
        state.savedSelections = [];
        for (const context of foundContexts) {
            try {
                const selection = context.win.getSelection();
                if (selection) {
                    state.savedSelections.push({
                        win: context.win,
                        ranges: Array.from({ length: selection.rangeCount }, (_, i) => selection.getRangeAt(i).cloneRange())
                    });
                }
            } catch (_) {}
        }
    }

    function mark(match) {
        unmarkCurrent();
        if (match.kind === "range") {
            try {
                const selection = match.win.getSelection();
                if (!selection) return;
                selection.removeAllRanges();
                selection.addRange(match.range);
                scrollRange(match.range, match.win);
            } catch (_) {}
        } else {
            try {
                match.savedFocus = match.control.getRootNode().activeElement;
                match.control.setSelectionRange(match.start, match.end);
                match.control.focus({ preventScroll: true });
                match.control.scrollIntoView({ block: "center", inline: "nearest" });
            } catch (_) {}
        }
        state.current = match;
    }

    // The selection alone is drawn pale grey while the find bar has the keys,
    // so every match is painted too: yellow, the current one orange.
    // Each window gets its two highlights once; after that they are only
    // cleared and added to. A highlight repaints the ranges it gains or
    // loses, whereas one set into or deleted from `CSS.highlights` could
    // stay on screen, or stay off it, until something else was drawn.
    function unpaint() {
        for (const painter of state.fieldPainters.values()) {
            try { painter.dispose(); } catch (_) {}
        }
        state.fieldPainters.clear();
        for (const highlights of state.painted) {
            try { highlights.all.clear(); highlights.current.clear(); } catch (_) {}
        }
        state.painted = [];
    }

    function highlightsIn(win) {
        const doc = win.document;
        let highlights = state.highlights.get(win);
        if (!highlights || highlights.doc !== doc) {
            const sheet = new win.CSSStyleSheet();
            sheet.replaceSync(
                "::highlight(search-find-match) { background-color: #ffff00; color: #000; }"
                + "::highlight(search-find-current) { background-color: #ff9632; color: #000; }"
            );
            const current = new win.Highlight();
            current.priority = 1;
            highlights = { doc, sheet, all: new win.Highlight(), current };
            state.highlights.set(win, highlights);
        }
        // A page may set its own sheets, or these names, again at any time.
        if (!doc.adoptedStyleSheets.includes(highlights.sheet)) {
            doc.adoptedStyleSheets = [...doc.adoptedStyleSheets, highlights.sheet];
        }
        if (win.CSS.highlights.get("search-find-match") !== highlights.all) {
            win.CSS.highlights.set("search-find-match", highlights.all);
        }
        if (win.CSS.highlights.get("search-find-current") !== highlights.current) {
            win.CSS.highlights.set("search-find-current", highlights.current);
        }
        return highlights;
    }

    function fieldPainter(win, highlights) {
        let painter = state.fieldPainters.get(win);
        if (painter) return painter;
        const doc = win.document;
        const host = doc.createElement("search-find-fields");
        host.setAttribute("aria-hidden", "true");
        host.style.cssText = "all:initial!important;display:block!important;position:fixed!important;inset:0!important;pointer-events:none!important;z-index:2147483647!important;contain:strict!important;overflow:hidden!important;user-select:none!important;-webkit-user-select:none!important";
        state.fieldHosts.add(host);
        const root = host.attachShadow({ mode: "closed" });
        root.adoptedStyleSheets = [highlights.sheet];
        doc.documentElement.append(host);
        const fields = new Map(), listeners = [], watched = new Set();
        const properties = [
            "font-family", "font-size", "font-style", "font-weight", "font-stretch", "font-variant",
            "font-feature-settings", "font-variation-settings", "font-kerning", "font-synthesis",
            "line-height", "letter-spacing", "word-spacing", "text-align", "text-indent",
            "text-transform", "text-rendering", "direction", "tab-size", "white-space",
            "overflow-wrap", "word-break", "padding-top", "padding-right", "padding-bottom",
            "padding-left", "-webkit-text-security"
        ];
        let timer = null, disposed = false;
        const resized = new win.ResizeObserver(schedule);
        function listen(target, type, capture = false) {
            target.addEventListener(type, schedule, capture);
            listeners.push({ target, type, capture });
        }
        function schedule() {
            if (disposed || timer !== null) return;
            timer = setTimeout(() => { timer = null; refresh(); }, 16);
        }
        function parent(element) {
            return element.assignedSlot || element.parentElement || element.getRootNode().host || null;
        }
        function live() {
            if (disposed) return false;
            try { if (win.document === doc) return true; } catch (_) {}
            painter.dispose();
            return false;
        }
        function refresh() {
            if (!live()) return;
            for (const [control, field] of fields) {
                const { box, mirror, value, ranges } = field;
                box.style.display = "none";
                field.retry = false;
                if (!control.isConnected || control.value !== value || control.type === "password") continue;
                const rect = control.getBoundingClientRect();
                field.rect = rect;
                field.scrollLeft = control.scrollLeft;
                field.scrollTop = control.scrollTop;
                if (!control.offsetWidth || !control.offsetHeight || rect.right <= 0 || rect.bottom <= 0
                    || rect.left >= win.innerWidth || rect.top >= win.innerHeight) continue;
                const style = win.getComputedStyle(control);
                if (!rect.width || !rect.height || style.visibility !== "visible"
                    || style.writingMode !== "horizontal-tb") continue;
                const sx = rect.width / control.offsetWidth, sy = rect.height / control.offsetHeight;
                const left = rect.left + control.clientLeft * sx, top = rect.top + control.clientTop * sy;
                let clip = { left: 0, top: 0, right: win.innerWidth, bottom: win.innerHeight };
                let opacity = Number(style.opacity), supported = true;
                for (let element = control; element; element = parent(element)) {
                    const css = element === control ? style : win.getComputedStyle(element);
                    if (element !== control && element !== doc.documentElement) opacity *= Number(css.opacity);
                    if (css.transform !== "none") {
                        const matrix = new win.DOMMatrix(css.transform);
                        if (!matrix.is2D || matrix.b !== 0 || matrix.c !== 0 || matrix.a <= 0 || matrix.d <= 0
                            || element === doc.documentElement) { supported = false; break; }
                    }
                    if (element === control || element === doc.documentElement) continue;
                    const bounds = element.getBoundingClientRect();
                    const scaleX = element.offsetWidth ? bounds.width / element.offsetWidth : 1;
                    const scaleY = element.offsetHeight ? bounds.height / element.offsetHeight : 1;
                    if (css.overflowX !== "visible") {
                        clip.left = Math.max(clip.left, bounds.left + element.clientLeft * scaleX);
                        clip.right = Math.min(clip.right, bounds.left + (element.clientLeft + element.clientWidth) * scaleX);
                    }
                    if (css.overflowY !== "visible") {
                        clip.top = Math.max(clip.top, bounds.top + element.clientTop * scaleY);
                        clip.bottom = Math.min(clip.bottom, bounds.top + (element.clientTop + element.clientHeight) * scaleY);
                    }
                }
                if (!supported || !opacity || clip.right <= left || clip.bottom <= top
                    || clip.left >= left + control.clientWidth * sx || clip.top >= top + control.clientHeight * sy) continue;
                const visibleLeft = Math.max(left, clip.left), visibleTop = Math.max(top, clip.top);
                const visibleRight = Math.min(left + control.clientWidth * sx, clip.right);
                const visibleBottom = Math.min(top + control.clientHeight * sy, clip.bottom);
                const insetX = Math.min(4, (visibleRight - visibleLeft) / 2);
                const insetY = Math.min(4, (visibleBottom - visibleTop) / 2);
                const xs = [visibleLeft + insetX, (visibleLeft + visibleRight) / 2, visibleRight - insetX];
                const ys = [visibleTop + insetY, (visibleTop + visibleBottom) / 2, visibleBottom - insetY];
                const uncovered = xs.every(x => ys.every(y => {
                    let hit = doc.elementFromPoint(x, y);
                    while (hit?.shadowRoot?.elementFromPoint) {
                        const nested = hit.shadowRoot.elementFromPoint(x, y);
                        if (!nested || nested === hit) break;
                        hit = nested;
                    }
                    return hit === control || control.contains(hit)
                        || (style.pointerEvents === "none" && hit?.contains(control));
                }));
                if (!uncovered) { field.retry = true; continue; }
                for (const property of properties) mirror.style.setProperty(property, style.getPropertyValue(property));
                mirror.style.width = control.clientWidth + "px";
                mirror.style.left = -control.scrollLeft + "px";
                mirror.style.top = -control.scrollTop + "px";
                box.style.cssText = "position:absolute;overflow:hidden;pointer-events:none;transform-origin:0 0";
                Object.assign(box.style, {
                    left: left + "px", top: top + "px", width: control.clientWidth + "px",
                    height: control.clientHeight + "px", transform: `scale(${sx}, ${sy})`,
                    opacity: String(opacity), borderRadius: style.borderRadius,
                    clipPath: `inset(${Math.max(0, (clip.top - top) / sy)}px ${Math.max(0, control.clientWidth - (clip.right - left) / sx)}px ${Math.max(0, control.clientHeight - (clip.bottom - top) / sy)}px ${Math.max(0, (clip.left - left) / sx)}px)`
                });
                if (control.localName === "input") {
                    mirror.style.whiteSpace = "pre";
                    mirror.style.overflowWrap = "normal";
                    mirror.style.top = (control.clientHeight - mirror.getBoundingClientRect().height / sy) / 2 + "px";
                }
                for (const range of ranges) {
                    const current = highlights.current.has(range);
                    highlights.all.delete(range);
                    highlights.all.add(range);
                    if (current) { highlights.current.delete(range); highlights.current.add(range); }
                }
            }
        }
        function reveal(match) {
            const field = fields.get(match.control);
            if (!field) return;
            const range = field.ranges.find(range => range.startOffset === match.start && range.endOffset === match.end);
            if (!range) return;
            for (let element = match.control; element; element = parent(element)) {
                const rect = range.getClientRects()[0];
                if (!rect) break;
                const viewport = element === doc.documentElement;
                const bounds = viewport ? { left: 0, top: 0, width: win.innerWidth, height: win.innerHeight }
                    : element.getBoundingClientRect();
                const sx = !viewport && element.offsetWidth ? bounds.width / element.offsetWidth : 1;
                const sy = !viewport && element.offsetHeight ? bounds.height / element.offsetHeight : 1;
                const left = bounds.left + (viewport ? 0 : element.clientLeft * sx);
                const top = bounds.top + (viewport ? 0 : element.clientTop * sy);
                const right = left + (viewport ? win.innerWidth : element.clientWidth * sx);
                const bottom = top + (viewport ? win.innerHeight : element.clientHeight * sy);
                const dx = rect.left < left ? rect.left - left : Math.max(0, Math.min(rect.right - right, rect.left - left));
                const dy = rect.top < top ? rect.top - top : Math.max(0, Math.min(rect.bottom - bottom, rect.top - top));
                if (dx) element.scrollLeft += dx / sx;
                if (dy) element.scrollTop += dy / sy;
                if (dx || dy) refresh();
            }
        }
        function rangeFor(match) {
            const control = match.control;
            if (control.value !== match.value) return null;
            let field = fields.get(control);
            if (!field) {
                const box = doc.createElement("div"), mirror = doc.createElement("div");
                const value = match.value;
                const text = doc.createTextNode(value);
                mirror.style.cssText = "all:initial;display:block;position:absolute;box-sizing:border-box;color:transparent;pointer-events:none";
                mirror.append(text);
                box.append(mirror);
                root.append(box);
                field = { box, mirror, text, value, ranges: [], rect: null, scrollLeft: 0, scrollTop: 0, retry: false };
                fields.set(control, field);
                for (let element = control; element; element = parent(element)) {
                    if (!watched.has(element)) {
                        watched.add(element);
                        resized.observe(element);
                        listen(element, "scroll");
                    }
                }
            }
            const range = doc.createRange();
            range.setStart(field.text, match.start);
            range.setEnd(field.text, match.end);
            field.ranges.push(range);
            return range;
        }
        listen(win, "scroll", true);
        listen(win, "resize");
        listen(doc, "input", true);
        if (doc.fonts) listen(doc.fonts, "loadingdone");
        const polling = setInterval(() => {
            if (!live()) return;
            for (const [control, field] of fields) {
                if (!control.isConnected || control.value !== field.value || control.type === "password") {
                    field.box.style.display = "none";
                    continue;
                }
                const rect = control.getBoundingClientRect(), previous = field.rect;
                if (field.retry || !previous || rect.x !== previous.x || rect.y !== previous.y
                    || rect.width !== previous.width || rect.height !== previous.height
                    || control.scrollLeft !== field.scrollLeft || control.scrollTop !== field.scrollTop) schedule();
            }
        }, 250);
        painter = {
            rangeFor, refresh, reveal, schedule,
            dispose() {
                if (disposed) return;
                disposed = true;
                if (timer !== null) clearTimeout(timer);
                clearInterval(polling);
                resized.disconnect();
                for (const { target, type, capture } of listeners) {
                    try { target.removeEventListener(type, schedule, capture); } catch (_) {}
                }
                host.remove();
                state.fieldPainters.delete(win);
            }
        };
        state.fieldPainters.set(win, painter);
        return painter;
    }

    function pageMutations(records) {
        const changed = records.some(record => !state.fieldHosts.has(record.target)
            && !(record.type === "childList"
                && [...record.addedNodes, ...record.removedNodes].every(node => state.fieldHosts.has(node))));
        if (changed) {
            state.dirty = true;
            for (const painter of state.fieldPainters.values()) painter.schedule();
        }
        return changed;
    }

    function paint() {
        unpaint();
        if (typeof Highlight !== "function") return;
        const painted = new Map(), fieldRanges = new Map();
        for (const match of state.matches) {
            try {
                let highlights = painted.get(match.win);
                if (!highlights) {
                    highlights = highlightsIn(match.win);
                    painted.set(match.win, highlights);
                    state.painted.push(highlights);
                }
                let range = match.range;
                if (match.kind === "control") {
                    range = fieldPainter(match.win, highlights).rangeFor(match);
                    if (!range) continue;
                    fieldRanges.set(match, range);
                } else {
                    const root = range.startContainer.getRootNode();
                    if (root.host && !root.adoptedStyleSheets.includes(highlights.sheet)) {
                        root.adoptedStyleSheets = [...root.adoptedStyleSheets, highlights.sheet];
                    }
                }
                highlights.all.add(range);
            } catch (_) {}
        }
        const current = state.matches[state.index];
        if (current) {
            try { painted.get(current.win)?.current.add(current.range || fieldRanges.get(current)); } catch (_) {}
        }
        for (const painter of state.fieldPainters.values()) painter.refresh();
        if (current?.kind === "control") state.fieldPainters.get(current.win)?.reveal(current);
    }

    function scrollRange(range, win) {
        const target = range.startContainer;
        const element = target.nodeType === 1 ? target : target.parentElement;
        // Up the drawn tree, so out of a shadow tree through its host.
        const up = (node) => node.assignedSlot || node.parentElement || node.getRootNode().host || null;
        for (let ancestor = element; ancestor && ancestor !== win.document.documentElement; ancestor = up(ancestor)) {
            try {
                const style = win.getComputedStyle(ancestor);
                const scrollsY = /(auto|scroll|overlay)/.test(style.overflowY)
                    && ancestor.scrollHeight > ancestor.clientHeight;
                const scrollsX = /(auto|scroll|overlay)/.test(style.overflowX)
                    && ancestor.scrollWidth > ancestor.clientWidth;
                if (scrollsY || scrollsX) {
                    const matchRect = range.getBoundingClientRect();
                    const box = ancestor.getBoundingClientRect();
                    if (scrollsY) {
                        if (matchRect.top < box.top) ancestor.scrollTop -= box.top - matchRect.top;
                        else if (matchRect.bottom > box.bottom) ancestor.scrollTop += matchRect.bottom - box.bottom;
                    }
                    if (scrollsX) {
                        if (matchRect.left < box.left) ancestor.scrollLeft -= box.left - matchRect.left;
                        else if (matchRect.right > box.right) ancestor.scrollLeft += matchRect.right - box.right;
                    }
                }
            } catch (_) {}
        }
        try {
            const rect = range.getBoundingClientRect();
            const margin = 24;
            const scroller = win.document.scrollingElement;
            if (scroller && rect.top < margin) scroller.scrollTop += rect.top - margin;
            else if (scroller && rect.bottom > win.innerHeight - margin) {
                scroller.scrollTop += rect.bottom - win.innerHeight + margin;
            }
            if (scroller && rect.left < margin) scroller.scrollLeft += rect.left - margin;
            else if (scroller && rect.right > win.innerWidth - margin) {
                scroller.scrollLeft += rect.right - win.innerWidth + margin;
            }
        } catch (_) {}
        let child = win;
        while (child !== child.parent) {
            try { child.frameElement?.scrollIntoView({ block: "nearest", inline: "nearest" }); }
            catch (_) {}
            child = child.parent;
        }
    }

    function sameSpec() {
        return state.generation === epoch && state.query === needle
            && state.matchCase === Boolean(matchCase) && state.wholeWords === Boolean(wholeWords);
    }

    const changed = !sameSpec();
    const currentContexts = contexts();
    const documents = currentContexts.map(context => context.doc);
    if (documents.length !== state.documents.length
        || documents.some((doc, index) => doc !== state.documents[index])) {
        state.dirty = true;
        for (const observer of state.observers) {
            if (!documents.includes(observer.doc)) observer.disconnect();
        }
        state.observers = state.observers.filter(observer => documents.includes(observer.doc));
        state.documents = documents;
    }
    for (const observer of state.observers) {
        pageMutations(observer.takeRecords());
    }
    if (state.controls.some(item => {
        try { return item.element.value !== item.value; }
        catch (_) { return true; }
    })) state.dirty = true;

    if (changed) {
        unmarkCurrent();
        state.savedSelections = [];
        state.generation = epoch;
        state.query = needle;
        state.matchCase = Boolean(matchCase);
        state.wholeWords = Boolean(wholeWords);
        state.index = -1;
    }

    const rebuilt = state.dirty || !state.runs;
    if (rebuilt) {
        state.runs = buildRuns(currentContexts);
        state.dirty = false;
    }
    if (changed || rebuilt) {
        const oldIndex = changed ? -1 : state.index;
        const oldCurrent = oldIndex >= 0 ? state.matches[oldIndex] : null;
        startMatching();
        collect(Math.max(cap, oldIndex + 1));
        state.index = -1;
        if (oldCurrent) {
            state.index = state.matches.findIndex(candidate => {
                if (candidate.win !== oldCurrent.win || candidate.kind !== oldCurrent.kind) return false;
                if (candidate.kind === "range") return sameRange(candidate.range, oldCurrent.range);
                return candidate.control === oldCurrent.control
                    && candidate.start === oldCurrent.start && candidate.end === oldCurrent.end;
            });
        }
    }

    if (state.matches.length === 0) {
        unmarkCurrent();
        unpaint();
        state.savedSelections = [];
        state.index = -1;
        // A page too big to read through within the budget may hold
        // it past where the walk stopped; WebKit's own find looks there.
        return answer(state.cut ? "cut" : "ok", 0, 0);
    }

    let target;
    if (changed) {
        saveSelections(currentContexts);
        target = moves;
    } else if (state.index < 0) {
        // The match that was current has gone from the page: start again
        // from the first, with the page's own selection put back first.
        unmarkCurrent();
        saveSelections(currentContexts);
        target = 0;
    } else {
        target = state.index + moves;
    }
    if (target >= state.matches.length && !state.complete) collect(target + cap);
    if (target < 0 && !state.complete) collect(Infinity);
    const total = state.matches.length;
    state.index = ((target % total) + total) % total;
    mark(state.matches[state.index]);
    paint();
    return answer("ok", total, state.index + 1, !state.complete || !!state.cut);
    """#
}
