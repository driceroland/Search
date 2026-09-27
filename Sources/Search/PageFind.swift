import WebKit

/// The page-side part of ⌘F. A count and the range selected by Next always
/// come from the same list, built in a world the page cannot inspect.
@MainActor
final class PageFind {
    struct Result: Equatable {
        let count: Int?
        /// One-based, as shown in the find bar.
        let index: Int?
        let found: Bool
        let nativeFallback: Bool
        let wholeWordsAvailable: Bool
        let available: Bool
        let stale: Bool
    }

    private let world = WKContentWorld.world(name: "Search")
    private var newestGeneration: UInt64 = 0

    func update(
        on web: WKWebView,
        query: String,
        matchCase: Bool,
        wholeWords: Bool,
        forward: Bool,
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
                    "forward": forward,
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
                        count: nil, index: nil, found: false, nativeFallback: true,
                        wholeWordsAvailable: false, available: true, stale: false
                    )
                }
                let found = await nativeFind(
                    query, on: web, matchCase: matchCase, forward: forward
                )
                guard generation >= newestGeneration else { return Self.staleResult }
                return Result(
                    count: nil, index: nil, found: found, nativeFallback: true,
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
                    "forward": true,
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
            web.callAsyncJavaScript(Self.script, arguments: arguments, in: nil, in: world) {
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
        count: 0, index: nil, found: false, nativeFallback: false,
        wholeWordsAvailable: true, available: true, stale: false
    )
    private static let unavailableResult = Result(
        count: nil, index: nil, found: false, nativeFallback: false,
        wholeWordsAvailable: true, available: false, stale: false
    )
    private static let staleResult = Result(
        count: nil, index: nil, found: false, nativeFallback: false,
        wholeWordsAvailable: true, available: false, stale: true
    )

    /// `callAsyncJavaScript` supplies these names as arguments; the query is
    /// never interpolated into source. State and ranges live only in Search's
    /// isolated content world, so the page's nodes and styles stay untouched.
    private static let script = #"""
    const needle = String(query ?? "");
    const epoch = Number(generation ?? 0);
    const key = "__searchPageFindState_v1";
    let state = globalThis[key];
    if (!state) {
        state = {
            generation: -1, query: null, matchCase: false, wholeWords: false,
            index: -1, matches: [], current: null, savedSelections: [],
            observers: [], documents: [], controls: [], dirty: true
        };
        Object.defineProperty(globalThis, key, { value: state, configurable: true });
    }

    const answer = (status, count = 0, index = 0) => ({ status, count, index });
    if (epoch < state.generation) return answer("stale");

    function sameRange(left, right) {
        try {
            return left.compareBoundaryPoints(0, right) === 0
                && left.compareBoundaryPoints(2, right) === 0;
        } catch (_) { return false; }
    }

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
        }
        if (state.current && state.current.kind === "control") {
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

    function restoreSavedSelections() { unmarkCurrent(); }

    function stopObservers() {
        for (const observer of state.observers) observer.disconnect();
        state.observers = [];
    }

    function clearState() {
        restoreSavedSelections();
        state.savedSelections = [];
        state.matches = [];
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
                    if (!frame || !visible(frame, frame.ownerDocument)
                        || frame.getBoundingClientRect().width === 0
                        || frame.getBoundingClientRect().height === 0) return;
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
            state.observers.push(observer);
            observer.doc = context.doc;
        } catch (_) {}
    }

    function visible(element, doc) {
        const tag = element.localName;
        if (["script", "style", "noscript", "template", "head", "title", "select", "option", "optgroup"].includes(tag)) return false;
        if (element.hidden || element.hasAttribute("hidden")) return false;
        try {
            const style = doc.defaultView.getComputedStyle(element);
            if (style.display === "none" || style.visibility === "hidden"
                || style.visibility === "collapse" || style.contentVisibility === "hidden"
                || style.opacity === "0") return false;
        } catch (_) {}
        return true;
    }

    function isBlock(element, doc) {
        try {
            const display = doc.defaultView.getComputedStyle(element).display;
            return !(display.startsWith("inline") || display === "contents"
                || display === "ruby" || display === "none");
        } catch (_) { return true; }
    }

    function addText(run, node, value) {
        for (let offset = 0; offset < value.length;) {
            const code = value.codePointAt(offset);
            const size = code > 0xFFFF ? 2 : 1;
            const piece = value.slice(offset, offset + size);
            const start = { node, offset };
            const end = { node, offset: offset + size };
            if (/^\s+$/u.test(piece)) {
                if (!run.pending) run.pending = { start, end };
                else run.pending.end = end;
            } else {
                if (run.pending) {
                    appendMapped(run, " ", run.pending.start, run.pending.end);
                    run.pending = null;
                }
                appendMapped(run, piece, start, end);
            }
            offset += size;
        }
    }

    function appendMapped(run, value, start, end) {
        run.text += value;
        for (let i = 0; i < value.length; i++) {
            run.starts.push(start);
            run.ends.push(end);
        }
    }

    function makeRun(context) {
        return { win: context.win, doc: context.doc, text: "", starts: [], ends: [], pending: null };
    }

    function collectRuns(context) {
        const runs = [];
        let run = makeRun(context);
        function flush() {
            run.pending = null;
            if (run.text) runs.push(run);
            run = makeRun(context);
        }
        function addControl(element, value) {
            flush();
            state.controls.push({ element, value });
            const controlRun = makeRun(context);
            for (let offset = 0; offset < value.length;) {
                const code = value.codePointAt(offset);
                const size = code > 0xFFFF ? 2 : 1;
                const piece = value.slice(offset, offset + size);
                const start = { control: element, offset };
                const end = { control: element, offset: offset + size };
                if (/^\s+$/u.test(piece)) {
                    if (!controlRun.pending) controlRun.pending = { start, end };
                    else controlRun.pending.end = end;
                } else {
                    if (controlRun.pending) {
                        appendMapped(controlRun, " ", controlRun.pending.start, controlRun.pending.end);
                        controlRun.pending = null;
                    }
                    appendMapped(controlRun, piece, start, end);
                }
                offset += size;
            }
            controlRun.pending = null;
            if (controlRun.text) runs.push(controlRun);
            run = makeRun(context);
        }
        function walk(node) {
            if (node.nodeType === 3) {
                addText(run, node, node.nodeValue || "");
                return;
            }
            if (node.nodeType !== 1) return;
            const element = node;
            if (!visible(element, context.doc)) return;
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
            const block = isBlock(element, context.doc);
            if (block) flush();
            for (const child of element.childNodes) walk(child);
            if (block) flush();
        }
        walk(context.doc.body);
        flush();
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

    function canonicalize(run) {
        const original = run.text;
        let text = "";
        const starts = [];
        const ends = [];
        for (let offset = 0; offset < original.length;) {
            const first = offset;
            const firstCode = original.codePointAt(offset);
            offset += firstCode > 0xFFFF ? 2 : 1;
            while (offset < original.length) {
                const code = original.codePointAt(offset);
                const size = code > 0xFFFF ? 2 : 1;
                if (!/^\p{M}$/u.test(original.slice(offset, offset + size))) break;
                offset += size;
            }
            const value = original.slice(first, offset).normalize("NFC");
            const start = run.starts[first];
            const end = run.ends[offset - 1];
            text += value;
            for (let i = 0; i < value.length; i++) {
                starts.push(start);
                ends.push(end);
            }
        }
        run.text = text;
        run.starts = starts;
        run.ends = ends;
        return run;
    }

    function buildMatches(foundContexts) {
        for (const observer of state.observers) {
            if (observer.takeRecords().length) state.dirty = true;
        }
        state.controls = [];
        const all = [];
        for (const context of foundContexts) {
            observe(context);
            for (const run of collectRuns(context)) all.push(canonicalize(run));
        }
        const normalizedNeedle = needle.replace(/\s+/gu, " ").normalize("NFC");
        const flags = "gu" + (matchCase ? "" : "i");
        const escaped = normalizedNeedle.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
        let expression;
        try { expression = new RegExp(escaped, flags); }
        catch (_) { return []; }
        const matches = [];
        for (const run of all) {
            expression.lastIndex = 0;
            let found;
            while ((found = expression.exec(run.text))) {
                const end = found.index + found[0].length;
                if ((!wholeWords || isWholeWord(run.text, found.index, end)) && end > found.index) {
                    const startPoint = run.starts[found.index];
                    const endPoint = run.ends[end - 1];
                    if (!startPoint || !endPoint) continue;
                    if (startPoint.node && endPoint.node) {
                        try {
                            const range = run.doc.createRange();
                            range.setStart(startPoint.node, startPoint.offset);
                            range.setEnd(endPoint.node, endPoint.offset);
                            const rects = Array.from(range.getClientRects());
                            if (!rects.some(rect => rect.width > 0 || rect.height > 0)) continue;
                            matches.push({ kind: "range", win: run.win, range });
                        } catch (_) {}
                    } else if (startPoint.control && startPoint.control === endPoint.control) {
                        const control = startPoint.control;
                        matches.push({
                            kind: "control", win: run.win, control,
                            start: startPoint.offset, end: endPoint.offset,
                            savedStart: control.selectionStart, savedEnd: control.selectionEnd,
                            savedDirection: control.selectionDirection || "none"
                        });
                    }
                }
                if (found[0].length === 0) expression.lastIndex++;
            }
        }
        return matches;
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

    let changed = !sameSpec();
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
    if (state.controls.some(item => {
        try { return item.element.value !== item.value; }
        catch (_) { return true; }
    })) state.dirty = true;
    if (changed) {
        restoreSavedSelections();
        state.savedSelections = [];
        state.current = null;
        state.generation = epoch;
        state.query = needle;
        state.matchCase = Boolean(matchCase);
        state.wholeWords = Boolean(wholeWords);
        state.dirty = true;
        state.index = -1;
    }
    if (state.dirty || changed) {
        const oldMatches = state.matches;
        const oldCurrent = oldMatches[state.index];
        const fresh = buildMatches(currentContexts);
        state.matches = fresh;
        state.dirty = false;
        if (!changed && oldCurrent) {
            const exact = fresh.findIndex(candidate => {
                if (candidate.win !== oldCurrent.win || candidate.kind !== oldCurrent.kind) return false;
                if (candidate.kind === "range") return sameRange(candidate.range, oldCurrent.range);
                return candidate.control === oldCurrent.control
                    && candidate.start === oldCurrent.start && candidate.end === oldCurrent.end;
            });
            if (exact >= 0) state.index = exact;
            else state.index = -1;
        } else if (changed) {
            state.index = -1;
        }
    }

    if (state.matches.length === 0) {
        restoreSavedSelections();
        state.savedSelections = [];
        state.index = -1;
        return answer("ok", 0, 0);
    }

    if (changed || state.index < 0) {
        const foundContexts = contexts();
        saveSelections(foundContexts);
        state.index = 0;
    } else {
        const step = forward ? 1 : -1;
        state.index = (state.index + step + state.matches.length) % state.matches.length;
    }
    mark(state.matches[state.index]);
    return answer("ok", state.matches.length, state.index + 1);
    """#
}
