import AppKit
import Darwin
import Foundation
import WebKit

/// Search's own world, as the app defines it (Web.swift).
enum Web { @MainActor static let world = WKContentWorld.world(name: "Search") }

@MainActor
private final class PageFindHarness: NSObject, NSApplicationDelegate {
    private struct Spec: Equatable {
        let query: String
        let matchCase: Bool
        let wholeWords: Bool
    }

    private let finder = PageFind()
    private var web: WKWebView!
    private var window: NSWindow!
    private var generation: UInt64 = 0
    private var spec: Spec?
    private var checks = 0
    private var failures = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 460, height: 380), configuration: configuration)
        window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 460, height: 380),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = web
        // WebKit needs a sized view attached to a window to lay out the page.
        // The probe lives well outside every screen so it never covers the user's work.
        window.orderFrontRegardless()
        web.loadHTMLString(Self.fixture, baseURL: URL(string: "https://find-tests.invalid/")!)

        Task { @MainActor in
            do {
                try await waitForPage()
                await run()
            } catch {
                report("Harness could not load its page: \(error)")
                failures += 1
            }
            print("PageFind: \(checks - failures)/\(checks) checks passed")
            window.close()
            fflush(stdout)
            fflush(stderr)
            Darwin.exit(failures == 0 ? 0 : 1)
        }
    }

    private static let fixture: String = {
        let seventeen = String(repeating: "<span>orchid</span>", count: 16) + "<span>or</span><b>chid</b>"
        let longText = String(repeating: "filler words keep this paragraph well beyond the viewport. ", count: 220)
        return """
        <!doctype html><html><head><meta charset="utf-8"><style>
        html, body { margin: 0; font: 16px sans-serif; }
        #long { width: 240px; }
        </style></head><body>
        <div id="seventeen">\(seventeen)</div>
        <p id="case">Alpha alpha ALPHA</p>
        <p id="words">cat scatter concatenate</p>
        <p id="unicode">ÄÖÜ äöü café CAFÉ cafe\u{0301} cafeine</p>
        <p id="literal">A "quote" and path\\segment</p>
        <div hidden>ghostword</div><div style="display:none">ghostword</div>
        <div style="visibility:hidden">ghostword</div><span>ghostword</span>
        <input id="field" value="fieldpivot">
        <textarea id="area">areapivot</textarea>
        <p><i id="mainoriginal">mainoriginal</i> <span id="sharedmain">sharedmark</span></p>
        <input id="sharedcontrol" value="sharedmark">
        <iframe id="frame" srcdoc="&lt;p&gt;&lt;i id='original'&gt;originalframe&lt;/i&gt; frameword &lt;span&gt;sharedmark&lt;/span&gt;&lt;/p&gt;"></iframe>
        <div id="dynamic"><span>dynamicword</span></div>
        <div id="live" style="display:none">livepivot</div>
        <div id="horizontal" style="width:180px;height:48px;overflow:auto;white-space:nowrap"><span>\(String(repeating: "side filler ", count: 70)) horizontalword</span></div>
        <p id="long">\(longText) farendword</p>
        </body></html>
        """
    }()

    private func waitForPage() async throws {
        for _ in 0..<200 {
            if (try? await evaluate("document.readyState")) as? String == "complete" {
                let frameReady = (try? await evaluate("document.querySelector('#frame')?.contentDocument?.body?.textContent")) as? String
                if frameReady?.contains("frameword") == true { return }
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw HarnessError.timeout("page or same-origin frame did not finish loading")
    }

    private func update(
        _ query: String,
        matchCase: Bool = false,
        wholeWords: Bool = false,
        forward: Bool = true
    ) async -> PageFind.Result {
        let nextSpec = Spec(query: query, matchCase: matchCase, wholeWords: wholeWords)
        let fresh = spec != nextSpec
        if fresh {
            generation += 1
            spec = nextSpec
        }
        return await finder.update(
            on: web,
            query: query,
            matchCase: matchCase,
            wholeWords: wholeWords,
            steps: fresh ? 0 : (forward ? 1 : -1),
            generation: generation
        )
    }

    private func clear() async -> PageFind.Result {
        generation += 1
        spec = nil
        return await finder.clear(on: web, generation: generation)
    }

    private func run() async {
        let first = await update("orchid")
        expect(first, count: 17, index: 1, "17 hits start at 1 / 17, including text split across inline nodes")
        let second = await update("orchid")
        expect(second, count: 17, index: 2, "Next advances to 2 / 17")
        let previous = await update("orchid", forward: false)
        expect(previous, count: 17, index: 1, "Previous returns to 1 / 17")
        let wrapsBack = await update("orchid", forward: false)
        expect(wrapsBack, count: 17, index: 17, "Previous wraps from the first hit to the last")
        let wrapsForward = await update("orchid")
        expect(wrapsForward, count: 17, index: 1, "Next wraps from the last hit to the first")

        await checkRapidNextRequests()

        let insensitive = await update("alpha")
        expect(insensitive, count: 3, index: 1, "Case-insensitive search finds all three case variants")
        let sensitive = await update("alpha", matchCase: true)
        expect(sensitive, count: 1, index: 1, "Case-sensitive search finds only the lowercase occurrence")
        let broad = await update("cat")
        expect(broad, count: 3, index: 1, "Substring search includes prefix and suffix matches")
        let whole = await update("cat", wholeWords: true)
        expect(whole, count: 1, index: 1, "Whole-word search excludes embedded prefix and suffix matches")
        check(whole.wholeWordsAvailable, "Whole-word matching reports available on an HTML page")

        let umlauts = await update("äöü")
        expect(umlauts, count: 2, index: 1, "Unicode case folding finds upper and lower German umlauts")
        let composed = await update("café")
        expect(composed, count: 3, index: 1, "Composed query matches composed and decomposed café text")
        let unaccented = await update("cafe")
        expect(unaccented, count: 4, index: 1, "A letter typed without its accent finds it with one, as WebKit's find does")
        let unaccentedCase = await update("cafe", matchCase: true)
        expect(unaccentedCase, count: 1, index: 1, "With Match case, accents count")

        let hidden = await update("ghostword")
        expect(hidden, count: 1, index: 1, "Hidden, display:none, and visibility:hidden text is excluded")
        let literal = await update(#"A "quote" and path\segment"#)
        expect(literal, count: 1, index: 1, "Quotes and backslashes are passed as literal query text")
        let absent = await update("not-on-this-page")
        check(!absent.found && absent.count == 0 && absent.index == nil, "No matches reports zero and no current index")

        await checkSameQuerySelectionCleanup()
        await checkFrameAndSelectionRestoration()
        await checkControlsAndMutation()
        await checkDOMMutationBeforeNext()
        await checkStaleRequestsAndClear()
        await checkHorizontalHitScrollsIntoView()
        await checkLongHitScrollsIntoView()
    }

    private func checkFrameAndSelectionRestoration() async {
        _ = try? await evaluate("""
        (() => {
          window.getSelection().removeAllRanges();
          const frame = document.querySelector('#frame');
          const doc = frame.contentDocument;
          const range = doc.createRange();
          range.selectNodeContents(doc.querySelector('#original'));
          const selection = frame.contentWindow.getSelection();
          selection.removeAllRanges(); selection.addRange(range);
          return true;
        })()
        """)
        let frameHit = await update("frameword")
        expect(frameHit, count: 1, index: 1, "Search includes a same-origin iframe")
        let frameSelected = (try? await evaluate("document.querySelector('#frame').contentWindow.getSelection().toString()")) as? String
        check(frameSelected == "frameword", "The current iframe match is selected in its own frame")

        let mainHit = await update("farendword")
        expect(mainHit, count: 1, index: 1, "Search can move from an iframe hit back to the main document")
        let restoredFrame = (try? await evaluate("document.querySelector('#frame').contentWindow.getSelection().toString()")) as? String
        let mainSelected = (try? await evaluate("window.getSelection().toString()")) as? String
        check(restoredFrame == "originalframe", "Moving out of the frame restores its prior selection")
        check(mainSelected == "farendword", "The new main-document hit is selected")
        let cleared = await clear()
        check(cleared.count == 0 && !cleared.found, "Clear returns the empty result")
        let mainAfterClear = (try? await evaluate("window.getSelection().toString()")) as? String
        let frameAfterClear = (try? await evaluate("document.querySelector('#frame').contentWindow.getSelection().toString()")) as? String
        check(mainAfterClear?.isEmpty == true, "Clear removes the find selection from the main document")
        check(frameAfterClear == "originalframe", "Clear leaves the iframe's restored prior selection intact")
    }

    private func checkSameQuerySelectionCleanup() async {
        _ = try? await evaluate("""
        (() => {
          const mainRange = document.createRange();
          mainRange.selectNodeContents(document.querySelector('#mainoriginal'));
          const mainSelection = window.getSelection();
          mainSelection.removeAllRanges(); mainSelection.addRange(mainRange);
          document.querySelector('#sharedcontrol').setSelectionRange(2, 4);
          const frame = document.querySelector('#frame');
          const frameRange = frame.contentDocument.createRange();
          frameRange.selectNodeContents(frame.contentDocument.querySelector('#original'));
          const frameSelection = frame.contentWindow.getSelection();
          frameSelection.removeAllRanges(); frameSelection.addRange(frameRange);
          return true;
        })()
        """)

        let mainHit = await update("sharedmark")
        expect(mainHit, count: 3, index: 1, "The same query has one main, one input, and one iframe hit")
        let inputHit = await update("sharedmark")
        expect(inputHit, count: 3, index: 2, "Next moves from the main document into the input")
        let restoredMain = (try? await evaluate("window.getSelection().toString()")) as? String
        let inputRange = (try? await evaluate("[document.querySelector('#sharedcontrol').selectionStart, document.querySelector('#sharedcontrol').selectionEnd]")) as? [Int]
        check(restoredMain == "mainoriginal", "Next restores the main document's prior selection when entering a control")
        check(inputRange == [0, 10], "The current control hit is selected")

        let frameHit = await update("sharedmark")
        expect(frameHit, count: 3, index: 3, "Next moves from the input into the iframe")
        let restoredInput = (try? await evaluate("[document.querySelector('#sharedcontrol').selectionStart, document.querySelector('#sharedcontrol').selectionEnd]")) as? [Int]
        let currentFrame = (try? await evaluate("document.querySelector('#frame').contentWindow.getSelection().toString()")) as? String
        check(restoredInput == [2, 4], "Next restores the input's prior selection when leaving the control")
        check(currentFrame == "sharedmark", "The current iframe hit replaces its prior selection")

        _ = await clear()
        let mainAfterClear = (try? await evaluate("window.getSelection().toString()")) as? String
        let inputAfterClear = (try? await evaluate("[document.querySelector('#sharedcontrol').selectionStart, document.querySelector('#sharedcontrol').selectionEnd]")) as? [Int]
        let frameAfterClear = (try? await evaluate("document.querySelector('#frame').contentWindow.getSelection().toString()")) as? String
        check(mainAfterClear == "mainoriginal", "Clear keeps the main document's selection after cross-context navigation")
        check(inputAfterClear == [2, 4], "Clear keeps the input's original selection after cross-context navigation")
        check(frameAfterClear == "originalframe", "Clear restores the iframe's prior selection after cross-context navigation")
    }

    private func checkControlsAndMutation() async {
        _ = try? await evaluate("document.querySelector('#field').setSelectionRange(2, 4)")
        let inputHit = await update("fieldpivot")
        expect(inputHit, count: 1, index: 1, "Visible input values participate in search")
        let inputSelection = (try? await evaluate("[document.querySelector('#field').selectionStart, document.querySelector('#field').selectionEnd]")) as? [Int]
        check(inputSelection == [0, 10], "A found input value is selected without changing its DOM value")
        let clearedInput = await clear()
        check(clearedInput.count == 0, "Clearing after an input hit succeeds")
        let restoredInput = (try? await evaluate("[document.querySelector('#field').selectionStart, document.querySelector('#field').selectionEnd]")) as? [Int]
        check(restoredInput == [2, 4], "Clear restores the input's earlier caret selection")

        let areaHit = await update("areapivot")
        expect(areaHit, count: 1, index: 1, "Visible textarea values participate in search")
        let clearedArea = await clear()
        check(clearedArea.count == 0, "Clearing after a textarea hit succeeds")

        _ = try? await evaluate("document.querySelector('#field').value = 'oldpivot'")
        let oldField = await update("oldpivot")
        expect(oldField, count: 1, index: 1, "Initial input value is indexed")
        _ = try? await evaluate("document.querySelector('#field').value = 'newpivot'")
        let oldAfterEdit = await update("oldpivot")
        check(!oldAfterEdit.found && oldAfterEdit.count == 0, "Next drops a match after a control value changes")
        let newAfterEdit = await update("newpivot")
        expect(newAfterEdit, count: 1, index: 1, "Next sees a newly entered control value")
        _ = await clear()
    }

    private func checkDOMMutationBeforeNext() async {
        let initial = await update("dynamicword")
        expect(initial, count: 1, index: 1, "The initial dynamic DOM has one hit")
        _ = try? await evaluate("""
        (() => { const el = document.createElement('span'); el.textContent = ' dynamicword';
                 document.querySelector('#dynamic').append(el); return true; })()
        """)
        let after = await update("dynamicword")
        expect(after, count: 2, index: 2, "Next refreshes the hit list after a DOM mutation")
    }

    private func checkStaleRequestsAndClear() async {
        _ = try? await evaluate("document.querySelector('#frame').contentWindow.getSelection().removeAllRanges()")
        generation += 1
        spec = nil
        let oldGeneration = generation
        let staleTask = Task { @MainActor in
            await finder.update(
                on: web, query: "orchid", matchCase: false, wholeWords: false,
                steps: 0, generation: oldGeneration
            )
        }
        let winnerGeneration = oldGeneration + 1
        let winner = await finder.update(
            on: web, query: "frameword", matchCase: false, wholeWords: false,
            steps: 0, generation: winnerGeneration
        )
        generation = winnerGeneration
        spec = Spec(query: "frameword", matchCase: false, wholeWords: false)
        let stale = await staleTask.value
        expect(winner, count: 1, index: 1, "The newest rapid query wins")
        check(stale.stale, "An older async result is marked stale after a newer query")
        let winnerSelection = (try? await evaluate("document.querySelector('#frame').contentWindow.getSelection().toString()")) as? String
        check(winnerSelection == "frameword", "The stale response cannot replace the newest frame highlight")

        let pendingGeneration = winnerGeneration + 1
        let pending = Task { @MainActor in
            await finder.update(
                on: web, query: "dynamicword", matchCase: false, wholeWords: false,
                steps: 0, generation: pendingGeneration
            )
        }
        let cleared = await finder.clear(on: web, generation: pendingGeneration + 1)
        generation = pendingGeneration + 1
        spec = nil
        let cancelled = await pending.value
        check(cleared.count == 0 && !cleared.found, "Clear invalidates an in-flight find")
        check(cancelled.stale, "An in-flight result arriving after clear is marked stale")
        let mainSelection = (try? await evaluate("window.getSelection().toString()")) as? String
        let frameSelection = (try? await evaluate("document.querySelector('#frame').contentWindow.getSelection().toString()")) as? String
        check(mainSelection?.isEmpty == true && frameSelection?.isEmpty == true, "Clear leaves no stale highlight in either document")
    }

    private func checkRapidNextRequests() async {
        generation += 1
        let sameGeneration = generation
        spec = Spec(query: "orchid", matchCase: false, wholeWords: false)
        let firstTask = Task { @MainActor in
            await finder.update(
                on: web, query: "orchid", matchCase: false, wholeWords: false,
                steps: 0, generation: sameGeneration
            )
        }
        let secondTask = Task { @MainActor in
            await finder.update(
                on: web, query: "orchid", matchCase: false, wholeWords: false,
                steps: 1, generation: sameGeneration
            )
        }
        let first = await firstTask.value
        let second = await secondTask.value
        let results = [first, second]
        check(results.allSatisfy { $0.available && $0.count == 17 && !$0.stale }, "Rapid Next requests both return the shared 17-hit list")
        check(results.compactMap(\.index).sorted() == [1, 2], "Two rapid Next requests advance to consecutive hits")
    }

    private func checkLongHitScrollsIntoView() async {
        _ = try? await evaluate("window.scrollTo(0, 0)")
        let result = await update("farendword")
        expect(result, count: 1, index: 1, "The long paragraph contains its final hit")
        let rect = try? await evaluate("""
        (() => {
          const selection = window.getSelection();
          if (!selection || !selection.rangeCount) return null;
          const r = selection.getRangeAt(0).getBoundingClientRect();
          return { top: r.top, bottom: r.bottom, height: innerHeight, scrollY: scrollY };
        })()
        """) as? [String: Double]
        if let rect {
            check(rect["scrollY", default: 0] > 0, "Searching the lower paragraph scrolls the page")
            print("OBSERVE: long hit rect top=\(rect["top", default: -1]), bottom=\(rect["bottom", default: -1]), viewport=\(rect["height", default: -1]), scrollY=\(rect["scrollY", default: -1])")
            check(rect["top", default: -1] >= 0 && rect["bottom", default: 9999] <= rect["height", default: 0],
                  "The selected range itself is inside the viewport")
        } else {
            check(false, "The current DOM range has a measurable rectangle")
        }
    }

    private func checkHorizontalHitScrollsIntoView() async {
        _ = try? await evaluate("document.querySelector('#horizontal').scrollLeft = 0")
        let result = await update("horizontalword")
        expect(result, count: 1, index: 1, "The far-right horizontal target is indexed")
        let geometry = try? await evaluate("""
        (() => {
          const box = document.querySelector('#horizontal');
          const range = window.getSelection()?.getRangeAt(0);
          if (!range) return null;
          const target = range.getBoundingClientRect();
          const viewport = box.getBoundingClientRect();
          return { left: target.left, right: target.right, boxLeft: viewport.left,
                   boxRight: viewport.right, scrollLeft: box.scrollLeft };
        })()
        """) as? [String: Double]
        if let geometry {
            print("OBSERVE: horizontal hit left=\(geometry["left", default: -1]), right=\(geometry["right", default: -1]), boxLeft=\(geometry["boxLeft", default: -1]), boxRight=\(geometry["boxRight", default: -1]), scrollLeft=\(geometry["scrollLeft", default: -1])")
            check(geometry["scrollLeft", default: 0] > 0, "Searching a far-right hit scrolls its horizontal container")
            let tolerance = 1.0 // WebKit snaps scrollLeft to whole CSS pixels.
            check(geometry["left", default: -1] >= geometry["boxLeft", default: 0] - tolerance
                  && geometry["right", default: 9999] <= geometry["boxRight", default: 0] + tolerance,
                  "The selected range is visible within one CSS pixel in the horizontal container")
        } else {
            check(false, "The horizontal hit has a measurable rectangle")
        }
    }

    private func expect(_ result: PageFind.Result, count: Int, index: Int?, _ label: String) {
        check(result.available && result.found && result.count == count && result.index == index, label + " (got \(describe(result)))")
    }

    private func describe(_ result: PageFind.Result) -> String {
        "count=\(result.count.map(String.init) ?? "nil"), index=\(result.index.map(String.init) ?? "nil"), " +
        "found=\(result.found), stale=\(result.stale), available=\(result.available)"
    }

    private func check(_ condition: Bool, _ label: String) {
        checks += 1
        if condition {
            print("PASS: \(label)")
        } else {
            failures += 1
            fputs("FAIL: \(label)\n", stderr)
        }
    }

    private func report(_ message: String) {
        checks += 1
        fputs("FAIL: \(message)\n", stderr)
    }

    private func evaluate(_ script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            web.evaluateJavaScript(script) { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value) }
            }
        }
    }
}

private enum HarnessError: Error, CustomStringConvertible {
    case timeout(String)
    var description: String {
        switch self { case let .timeout(message): return message }
    }
}

@main
@MainActor
private struct PageFindTestApp {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let harness = PageFindHarness()
        app.delegate = harness
        app.run()
        _ = harness
    }
}
