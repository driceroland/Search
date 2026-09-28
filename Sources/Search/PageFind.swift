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
            if status == "pdf" {
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

    func clear(on web: WKWebView, generation: UInt64) async -> Result {
        newestGeneration = max(newestGeneration, generation)
        do {
            _ = try await evaluate(
                on: web,
                arguments: [
                    "query": "",
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
        try await withCheckedThrowingContinuation { continuation in
            web.callAsyncJavaScript(Self.script, arguments: arguments, in: nil, in: Web.world) {
                (result: Swift.Result<Any, Error>) in
                continuation.resume(with: result)
            }
        }
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
    /// isolated content world, so the page's nodes and styles stay untouched.
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
            runs: null, current: null, savedSelections: [],
            observers: [], documents: [], controls: [], dirty: true
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
    function unmarkCurrent() {
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
        unmarkCurrent();
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
    // whether it breaks the text into a block of its own.
    function layout(element, doc) {
        if (hiddenTags.has(element.localName)) return null;
        if (element.hidden || element.hasAttribute("hidden")) return null;
        let style = null;
        try { style = doc.defaultView.getComputedStyle(element); } catch (_) {}
        if (!style) return { block: true };
        const display = style.display;
        if (display === "none" || style.visibility === "hidden"
            || style.visibility === "collapse" || style.contentVisibility === "hidden"
            || style.opacity === "0") return null;
        return {
            block: !(display.startsWith("inline") || display === "contents" || display === "ruby")
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
                    if (!frame || !layout(frame, frame.ownerDocument)) return;
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
        if (state.observers.some(item => item.doc === context.doc)) return;
        try {
            const observer = new context.win.MutationObserver(() => { state.dirty = true; });
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

    function addValue(run, node, value) {
        const space = /\s+/g;
        let last = 0;
        let found;
        while ((found = space.exec(value))) {
            if (found.index > last) addPiece(run, node, last, value.slice(last, found.index));
            const end = found.index + found[0].length;
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
            controlRun.nodes.push(element);
            addValue(controlRun, 0, value);
            run = controlRun;
            flush();
        }
        function walk(node) {
            if (node.nodeType === 3) {
                const value = node.nodeValue || "";
                if (!value) return;
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
            for (let child = element.firstChild; child; child = child.nextSibling) walk(child);
            if (box.block) flush();
        }
        walk(context.doc.body);
        flush();
    }

    function buildRuns(foundContexts) {
        state.controls = [];
        state.budget = 60000;
        state.cut = false;
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
        const spaced = needle.replace(/\s+/gu, " ").normalize("NFC");
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
                kind: "control", win: run.win, control,
                start: from.offset, end: to.offset,
                savedStart: control.selectionStart, savedEnd: control.selectionEnd,
                savedDirection: control.selectionDirection || "none"
            };
        }
        try {
            const range = run.doc.createRange();
            range.setStart(from.node, from.offset);
            range.setEnd(to.node, to.offset);
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
                match.control.setSelectionRange(match.start, match.end);
                match.control.scrollIntoView({ block: "center", inline: "nearest" });
            } catch (_) {}
        }
        state.current = match;
    }

    function scrollRange(range, win) {
        const target = range.startContainer;
        const element = target.nodeType === 1 ? target : target.parentElement;
        for (let ancestor = element; ancestor && ancestor !== win.document.documentElement; ancestor = ancestor.parentElement) {
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
        if (observer.takeRecords().length) state.dirty = true;
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
        state.savedSelections = [];
        state.index = -1;
        return answer("ok", 0, 0);
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
    return answer("ok", total, state.index + 1, !state.complete || !!state.cut);
    """#
}
