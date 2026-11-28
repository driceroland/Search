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
    private let findField = NSTextField()
    private var generation: UInt64 = 0
    private var spec: Spec?
    private var checks = 0
    private var failures = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 460, height: 380), configuration: configuration)
        window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 460, height: 420),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 420))
        web.frame.origin.y = 40
        content.addSubview(web)
        findField.frame = NSRect(x: 10, y: 5, width: 300, height: 30)
        content.addSubview(findField)
        window.contentView = content
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
        <div style="visibility:hidden">hiddenparent <span style="visibility:visible">shownchild</span></div>
        <p>docu&shy;mentation zero&#8203;width</p>
        <x-card id="card"><span>slottedword</span><b slot="none">unslottedword</b></x-card>
        <script>
        customElements.define("x-card", class extends HTMLElement {
            constructor() {
                super();
                this.attachShadow({ mode: "open" }).innerHTML =
                    "<div>shadowword one <slot></slot> shadowword two</div>";
            }
        });
        </script>
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
        let painted = (try? await evaluate(
            "[CSS.highlights.get('search-find-match')?.size ?? 0, CSS.highlights.get('search-find-current')?.size ?? 0]"
        )) as? [Int]
        check((painted?[0] ?? 0) > 1 && painted?[1] == 1, "Matches are painted, the current one on its own (got \(painted ?? []))")

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
        let shown = await update("shownchild")
        expect(shown, count: 1, index: 1, "A child that sets visibility: visible inside a hidden parent is found")
        let parent = await update("hiddenparent")
        check(!parent.found && parent.count == 0, "The hidden parent's own text stays excluded")
        let hyphen = await update("documentation")
        expect(hyphen, count: 1, index: 1, "A soft hyphen inside a word doesn't stop it matching, as WebKit's find")
        let zeroWidth = await update("zerowidth")
        expect(zeroWidth, count: 1, index: 1, "A zero-width space inside a word doesn't stop it matching")
        await checkShadowTrees()
        let literal = await update(#"A "quote" and path\segment"#)
        expect(literal, count: 1, index: 1, "Quotes and backslashes are passed as literal query text")
        let absent = await update("not-on-this-page")
        check(!absent.found && absent.count == 0 && absent.index == nil, "No matches reports zero and no current index")

        await checkSameQuerySelectionCleanup()
        await checkFrameAndSelectionRestoration()
        await checkControlsAndMutation()
        await checkVisibleControlMatches()
        await checkPersistentFieldHighlights()
        await checkFieldHighlightLayout()
        await checkStyledFieldHighlights()
        await checkDOMMutationBeforeNext()
        await checkStaleRequestsAndClear()
        await checkHorizontalHitScrollsIntoView()
        await checkLongHitScrollsIntoView()
        await checkCutWalkFallsBackToWebKit()
    }

    /// Text in an open shadow tree, and light text slotted into it, is found
    /// once each, painted, and kept up to date when the tree changes.
    private func checkShadowTrees() async {
        let shadow = await update("shadowword")
        expect(shadow, count: 2, index: 1, "Text inside an open shadow tree is found")
        let next = await update("shadowword")
        expect(next, count: 2, index: 2, "Next moves on inside the shadow tree")
        let slotted = await update("slottedword")
        expect(slotted, count: 1, index: 1, "Light text slotted into a shadow tree is found once")
        let unslotted = await update("unslottedword")
        check(!unslotted.found && unslotted.count == 0, "Light text no slot takes isn't drawn, so isn't found")
        _ = await update("shadowword")
        // Read in Search's world: the page's own view of a highlight Search
        // changed can lag behind what WebKit paints.
        let painted = (try? await web.callAsyncJavaScript("""
            return [CSS.highlights.get('search-find-match')?.size ?? 0,
                    CSS.highlights.get('search-find-current')?.size ?? 0,
                    document.querySelector('#card').shadowRoot.adoptedStyleSheets.length]
            """, arguments: [:], in: nil, contentWorld: Web.world)) as? [Int]
        check(painted == [2, 1, 1], "Shadow matches are painted, the shadow root given the find's sheet (got \(painted ?? []))")
        _ = try? await evaluate("document.querySelector('#card').shadowRoot.firstElementChild.append(' shadowword three')")
        let mutated = await update("shadowword")
        check(mutated.count == 3, "A change inside the shadow tree is seen before Next (got \(describe(mutated)))")
    }

    /// Past the walk's element budget, a word in the part not read is left
    /// to WebKit's own find rather than reported missing.
    private func checkCutWalkFallsBackToWebKit() async {
        let rows = String(repeating: "<div><span>row</span></div>", count: 35_000)
        web.loadHTMLString("<!doctype html><body><p>startword</p>\(rows)<p>pastbudgetword</p></body>",
                           baseURL: URL(string: "https://find-tests.invalid/big")!)
        for _ in 0..<200 {
            if (try? await evaluate("document.readyState === 'complete' && document.body.lastElementChild?.textContent === 'pastbudgetword'")) as? Bool == true { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        let early = await update("startword")
        check(early.found && early.count == 1 && early.more, "A cut walk counts what it read and says more may follow (got \(describe(early)))")
        let past = await update("pastbudgetword")
        check(past.found && past.nativeFallback, "A word past the budget is found by WebKit's find (got \(describe(past)))")
        let absent = await update("nowhereword")
        check(!absent.found && absent.available, "A word on no part of the page still reports no match")
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
        let selectedControl = (try? await evaluate("window.getSelection().toString()")) as? String
        let inputRange = (try? await evaluate("[document.querySelector('#sharedcontrol').selectionStart, document.querySelector('#sharedcontrol').selectionEnd]")) as? [Int]
        check(selectedControl == "sharedmark", "The focused control exposes the selected match")
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

    private func checkVisibleControlMatches() async {
        _ = try? await evaluate("document.querySelector('#field').value = document.querySelector('#area').value = 'a this.word b'")
        for selector in ["#field", "#area"] {
            _ = await clear()
            _ = try? await evaluate("""
            (() => {
                const control = document.querySelector('\(selector)');
                control.blur();
                control.setSelectionRange(2, 4);
                control.scrollIntoView({ block: 'center' });
            })()
            """)
            findField.stringValue = ".word"
            window.makeFirstResponder(findField)
            do {
                let before = try await controlSnapshot(selector)
                var hit = await update(".word")
                if selector == "#area" { hit = await update(".word") }
                expect(hit, count: 2, index: selector == "#field" ? 1 : 2,
                       "A literal substring in \(selector) is found")
                let after = try await controlSnapshot(selector)
                let selection = (try? await evaluate("""
                    (() => { const c = document.querySelector('\(selector)');
                    return [c.selectionStart, c.selectionEnd]; })()
                    """)) as? [Int]
                check(selection == [6, 11], "Only .word is selected in \(selector), not the whole field")
                check(window.firstResponder === findField.currentEditor(),
                      "Find keeps keyboard focus after selecting \(selector)")
                check((try? highlightPixels(after).orange) ?? 0 > 20,
                      "The current match in \(selector) is painted orange")
                _ = await clear()
                let cleared = try await controlSnapshot(selector)
                check(before == cleared, "Clearing Find removes the visible selection in \(selector)")
            } catch {
                check(false, "Could not capture \(selector): \(error)")
            }
        }
    }

    private func controlSnapshot(_ selector: String) async throws -> Data {
        try await Task.sleep(for: .milliseconds(100))
        let value = try await evaluate("""
            (() => { const r = document.querySelector('\(selector)').getBoundingClientRect();
            return [r.x, r.y, r.width, r.height]; })()
            """)
        guard let box = value as? [Double], box.count == 4 else { throw CocoaError(.coderInvalidValue) }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: box[0], y: box[1], width: box[2], height: box[3])
        let image = try await web.takeSnapshot(configuration: configuration)
        guard let pixels = image.tiffRepresentation else { throw CocoaError(.coderInvalidValue) }
        return pixels
    }

    private func checkPersistentFieldHighlights() async {
        _ = await clear()
        _ = try? await evaluate("""
            (() => {
                const fixture = document.createElement('section');
                fixture.id = 'field-paint';
                fixture.innerHTML = `<p>paintword</p>
                    <input id="paint-input" value="paintword gap paintword">
                    <textarea id="paint-area">paintword gap paintword</textarea>`;
                document.body.prepend(fixture);
                for (const field of fixture.querySelectorAll('input, textarea')) {
                    field.style.cssText = 'display:block;box-sizing:border-box;width:340px;height:40px;margin:8px;font:16px/20px monospace;padding:4px;border:2px solid #777';
                }
            })()
            """)
        findField.stringValue = "paintword"
        window.makeFirstResponder(findField)
        _ = try? await evaluate("document.querySelector('#field-paint').scrollIntoView({ block: 'start' })")
        let before = try? await controlSnapshot("#paint-input")
        let textBefore = try? await pageSelectionText()
        let first = await update("paintword")
        expect(first, count: 5, index: 1, "Page text and repeated matches in two fields share one result list")
        do {
            let input = try highlightPixels(await controlSnapshot("#paint-input"))
            let area = try highlightPixels(await controlSnapshot("#paint-area"))
            check(input.yellow > 200 && input.orange == 0,
                  "Input matches are yellow while the current result is page text")
            check(area.yellow > 200 && area.orange == 0,
                  "Textarea matches are yellow while the current result is page text")
            if let before {
                let native = try highlightPixels(before)
                let difference = native.ink.symmetricDifference(input.ink).count
                check(Double(difference) / Double(max(1, native.ink.count)) < 0.05,
                      "Painting keeps the input's original glyph positions")
            }
            let selectedText = try await pageSelectionText()
            check(selectedText == textBefore, "Page selection does not copy mirrored field values")
            let hit = try await evaluate("""
                (() => { const field = document.querySelector('#paint-input');
                const r = field.getBoundingClientRect();
                return document.elementFromPoint(r.left + 10, r.top + 10) === field; })()
                """) as? Bool
            check(hit == true, "Highlights let pointer events reach the real input")
            _ = try? await evaluate("""
                (() => { const cover = document.createElement('div'); cover.id = 'paint-cover';
                cover.style.cssText = 'position:fixed;inset:0;background:white;z-index:999999';
                document.body.append(cover); })()
                """)
            let covered = try highlightPixels(await controlSnapshot("#paint-input"))
            check(covered.yellow + covered.orange == 0, "Field highlights do not draw over a covering page panel")
            _ = try? await evaluate("document.querySelector('#paint-cover').remove()")
            let uncovered = try highlightPixels(await controlSnapshot("#paint-input"))
            check(uncovered.yellow > 200, "Removing a covering panel restores field highlights")
            let next = await update("paintword")
            expect(next, count: 5, index: 2, "Next enters the first input match")
            let current = try highlightPixels(await controlSnapshot("#paint-input"))
            check(current.orange > 100 && current.yellow > 100,
                  "One field can show an orange current match and a yellow other match")
            check(window.firstResponder === findField.currentEditor(), "Painting keeps typing in Find")

            _ = try? await evaluate("document.querySelector('#paint-input').value = 'paintword' + ' gap'.repeat(50) + ' paintword'")
            let lastInput = await update("paintword")
            expect(lastInput, count: 5, index: 3, "Next reaches the far-right input match")
            _ = try? await evaluate("document.querySelector('#paint-input').scrollLeft = 10000")
            let scrolledInput = try highlightPixels(await controlSnapshot("#paint-input"))
            check(scrolledInput.orange > 100, "The far-right input match stays orange after internal scrolling")

            _ = try? await evaluate("document.querySelector('#paint-area').value = 'paintword\\n' + 'filler\\n'.repeat(12) + 'paintword'")
            _ = await update("paintword")
            _ = try? await evaluate("document.querySelector('#paint-area').scrollTop = 10000")
            let scrolledArea = try highlightPixels(await controlSnapshot("#paint-area"))
            check(scrolledArea.yellow > 100 && scrolledArea.orange == 0,
                  "Textarea scrolling reveals the other match and clips the off-screen current match")
            let lastArea = await update("paintword")
            expect(lastArea, count: 5, index: 5, "Next reaches the final textarea match")
            let final = try highlightPixels(await controlSnapshot("#paint-area"))
            check(final.orange > 100, "The final textarea match is orange at its scrolled position")

            _ = await clear()
            let clearedInput = try highlightPixels(await controlSnapshot("#paint-input"))
            let clearedArea = try highlightPixels(await controlSnapshot("#paint-area"))
            check(clearedInput.yellow + clearedInput.orange + clearedArea.yellow + clearedArea.orange == 0,
                  "Clear removes every colored field highlight")
            let hosts = try await evaluate("document.querySelectorAll('search-find-fields').length") as? Int
            check(hosts == 0, "Clear removes the field painting surface")
        } catch {
            check(false, "Could not inspect field highlighting: \(error)")
        }
        _ = await clear()
        _ = try? await evaluate("document.querySelector('#field-paint').remove()")
    }

    private func checkFieldHighlightLayout() async {
        _ = await clear()
        _ = try? await evaluate("""
            (() => {
                const fixture = document.createElement('section');
                fixture.id = 'field-layout';
                fixture.innerHTML = `<p>fixedword</p>
                    <input id="paint-disabled" disabled value="fixedword">
                    <input id="paint-readonly" readonly value="fixedword">
                    <div id="paint-clip" style="width:120px;height:40px;overflow:auto">
                        <input id="paint-clipped" value="${'gap '.repeat(24)}clipword">
                    </div>
                    <textarea id="paint-mask" style="-webkit-text-security:disc">maskword</textarea>
                    <div id="paint-scale"><textarea id="paint-wrap">${'wrapword'.repeat(3)}</textarea></div>`;
                document.body.prepend(fixture);
                for (const control of fixture.querySelectorAll('input, textarea')) {
                    Object.assign(control.style, { display: 'block', width: '320px', height: '40px',
                        boxSizing: 'border-box', padding: '4px', font: '17px/22px serif' });
                }
                Object.assign(fixture.querySelector('#paint-wrap').style, { width: '120px', height: '80px' });
                const shadow = document.createElement('input');
                shadow.id = 'nested-paint'; shadow.value = 'nestedpaint';
                document.querySelector('#card').shadowRoot.append(shadow);
                document.querySelector('#card').style.display = 'block';
                const frame = document.querySelector('#frame');
                frame.dataset.fieldPaintOriginal = frame.getAttribute('srcdoc') || '';
                frame.style.height = '100px';
                const area = frame.contentDocument.createElement('textarea');
                area.id = 'nested-paint'; area.value = 'nestedpaint';
                frame.contentDocument.body.prepend(area);
                const label = document.createElement('p'); label.textContent = 'nestedpaint';
                fixture.append(label);
            })()
            """)
        findField.stringValue = "fixedword"
        window.makeFirstResponder(findField)
        expect(await update("fixedword"), count: 3, index: 1, "Disabled and readonly values remain searchable")
        do {
            let disabled = try highlightPixels(await controlSnapshot("#paint-disabled"))
            let readonly = try highlightPixels(await controlSnapshot("#paint-readonly"))
            check(disabled.yellow > 100 && readonly.yellow > 100,
                  "Disabled and readonly fields are highlighted without focusing them")
            _ = await update("fixedword")
            let current = try highlightPixels(await controlSnapshot("#paint-disabled"))
            check(current.orange > 100, "A disabled field can paint the current match")

            _ = await update("clipword")
            _ = try? await evaluate("document.querySelector('#paint-clip').scrollLeft = 0")
            let clipped = try highlightPixels(await controlSnapshot("#paint-clip"))
            check(clipped.orange == 0, "An overflow container clips a field highlight outside its visible area")
            _ = try? await evaluate("document.querySelector('#paint-clip').scrollLeft = 10000")
            var revealed = try highlightPixels(await controlSnapshot("#paint-clip"))
            for _ in 0..<5 where revealed.orange <= 100 {
                revealed = try highlightPixels(await controlSnapshot("#paint-clip"))
            }
            check(revealed.orange > 100, "Scrolling an ancestor reveals the correctly positioned field highlight")

            _ = try? await evaluate("document.querySelector('#paint-mask').scrollIntoView({block:'center'})")
            let maskedBefore = try highlightPixels(await controlSnapshot("#paint-mask"))
            _ = await update("maskword")
            let masked = try highlightPixels(await controlSnapshot("#paint-mask"))
            check(masked.orange > 100, "CSS-masked text gets a visible match")
            let mask = try await evaluate("getComputedStyle(document.querySelector('#paint-mask')).webkitTextSecurity") as? String
            check(mask == "disc", "Painting preserves the field's CSS masking")
            check(Double(maskedBefore.ink.symmetricDifference(masked.ink).count) / Double(max(1, maskedBefore.ink.count)) < 0.05,
                  "Masked field highlights retain the original dots instead of revealing letters")
            _ = try? await evaluate("document.querySelector('#paint-mask').value = 'changed';")
            try await Task.sleep(for: .milliseconds(300))
            let edited = try highlightPixels(await controlSnapshot("#paint-mask"))
            check(edited.orange + edited.yellow == 0, "A programmatic value change cannot leave stale mirrored text")

            _ = try? await evaluate("document.querySelector('#paint-wrap').scrollIntoView({block:'center'})")
            let wrapBefore = try highlightPixels(await controlSnapshot("#paint-wrap"))
            expect(await update(String(repeating: "wrapword", count: 3)), count: 1, index: 1,
                   "One textarea match can wrap over several lines")
            let wrapped = try highlightPixels(await controlSnapshot("#paint-wrap"))
            check(wrapped.orange > 500 && Double(wrapBefore.ink.symmetricDifference(wrapped.ink).count) / Double(max(1, wrapBefore.ink.count)) < 0.05,
                  "Wrapped highlighting follows the native textarea's glyph positions")
            _ = try? await evaluate("document.querySelector('#paint-scale').style.transform = 'scale(0.8)'")
            _ = await update(String(repeating: "wrapword", count: 3))
            let scaled = try highlightPixels(await controlSnapshot("#paint-wrap"))
            check(scaled.orange > 200, "Field highlights follow a scaled ancestor")
            expect(await update("nestedpaint"), count: 3, index: 1,
                   "One query spans the main page, an open shadow tree, and an iframe field")
            _ = try? await evaluate("document.querySelector('#card').scrollIntoView({block:'center'})")
            var shadow = try highlightPixels(await controlSnapshot("#card"))
            for _ in 0..<5 {
                if shadow.yellow > 100 { break }
                shadow = try highlightPixels(await controlSnapshot("#card"))
            }
            check(shadow.yellow > 100, "A field inside an open shadow tree has a yellow match")
            _ = try? await evaluate("document.querySelector('#frame').scrollIntoView({block:'center'})")
            let frame = try highlightPixels(await controlSnapshot("#frame"))
            check(frame.yellow > 100, "A same-origin iframe field has a yellow match")
            _ = try? await evaluate("""
                document.querySelector('#frame').srcdoc = '<input value="nestedpaint"><script>window.framePaintReady=true;window.frameTicks=0;setInterval(()=>frameTicks++,20);</script>';
                """)
            for _ in 0..<100 {
                if (try? await evaluate("document.querySelector('#frame').contentWindow.framePaintReady")) as? Bool == true { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            expect(await update("nestedpaint"), count: 3, index: 2,
                   "Replacing an iframe document refreshes the shared result list")
            let replaced = try highlightPixels(await controlSnapshot("#frame"))
            check(replaced.yellow > 100, "A replacement iframe document receives its own highlight stylesheet")
            let ticks = try await evaluate("document.querySelector('#frame').contentWindow.frameTicks") as? Int
            check((ticks ?? 0) > 1, "Retiring an iframe painter does not cancel the new page's timers")
            _ = try? await evaluate("document.querySelector('#frame').removeAttribute('srcdoc'); document.querySelector('#frame').src = 'data:text/html,<input value=nestedpaint>'")
            for _ in 0..<100 {
                if (try? await evaluate("document.querySelector('#frame').contentDocument === null")) as? Bool == true { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            expect(await update("nestedpaint"), count: 2, index: 1,
                   "A cross-origin iframe navigation retires its painter without breaking Find")
            _ = await clear()
            let hosts = try await evaluate("document.querySelectorAll('search-find-fields').length") as? Int
            check(hosts == 0, "Clear removes remaining field painters after iframe navigation")
        } catch {
            check(false, "Could not inspect field layout: \(error)")
        }
        _ = await clear()
        _ = try? await evaluate("""
            document.querySelector('#field-layout').remove();
            document.querySelector('#card').shadowRoot.querySelector('#nested-paint').remove();
            document.querySelector('#card').style.display = '';
            const frame = document.querySelector('#frame');
            frame.srcdoc = frame.dataset.fieldPaintOriginal;
            delete frame.dataset.fieldPaintOriginal;
            frame.style.height = '';
            """)
        try? await waitForPage()
    }

    private func checkStyledFieldHighlights() async {
        let cases = [
            ("search", "prefix styledword suffix", "text-align:left"),
            ("text", "prefix styledword suffix", "text-align:center"),
            ("text", "\u{05D0}\u{05D1}\u{05D2} styledword xyz", "direction:rtl;text-align:start"),
            ("text", "styledword", "text-align:right;-webkit-text-security:disc")
        ]
        for (type, value, style) in cases {
            _ = await clear()
            _ = try? await web.callAsyncJavaScript("""
                const fixture = document.createElement('section'); fixture.id = 'field-style';
                const label = document.createElement('p'); label.textContent = 'styledword';
                const input = document.createElement('input'); input.id = 'styled-input';
                input.type = type; input.value = value;
                input.style.cssText = 'font:17px/24px serif;width:330px;height:42px;box-sizing:border-box;padding:5px;border:2px solid #777;' + style;
                fixture.append(label, input); document.body.prepend(fixture);
                fixture.scrollIntoView({block:'start'});
                """, arguments: ["type": type, "value": value, "style": style], in: nil, contentWorld: .page)
            findField.stringValue = "styledword"
            window.makeFirstResponder(findField)
            do {
                let before = try highlightPixels(await controlSnapshot("#styled-input"))
                expect(await update("styledword"), count: 2, index: 1, "Styled field matches are counted (\(type), \(style))")
                let after = try highlightPixels(await controlSnapshot("#styled-input"))
                let difference = Double(before.ink.symmetricDifference(after.ink).count) / Double(max(1, before.ink.count))
                check(after.yellow > 100 && difference < 0.05,
                      "Styled field highlighting preserves glyph positions (\(type), \(style), difference=\(difference))")
                if style == "text-align:center" {
                    _ = try await evaluate("void document.querySelector('#styled-input').animate([{transform:'translateX(0)'},{transform:'translateX(40px)'}], {duration:100,fill:'forwards'})")
                    try await Task.sleep(for: .milliseconds(350))
                    var moved = try highlightPixels(await controlSnapshot("#styled-input"))
                    for _ in 0..<5 where moved.yellow <= 100 {
                        moved = try highlightPixels(await controlSnapshot("#styled-input"))
                    }
                    check(moved.yellow > 100 && Double(before.ink.symmetricDifference(moved.ink).count) / Double(max(1, before.ink.count)) < 0.05,
                          "Field highlights follow layout changes that emit no DOM mutation or resize")
                }
            } catch {
                check(false, "Could not inspect styled field: \(error)")
            }
            _ = await clear()
            _ = try? await evaluate("document.querySelector('#field-style').remove()")
        }
    }

    private func pageSelectionText() async throws -> String? {
        try await evaluate("""
            (() => {
                const selection = window.getSelection();
                const saved = Array.from({length: selection.rangeCount}, (_, i) => selection.getRangeAt(i).cloneRange());
                document.execCommand('selectAll');
                const text = selection.toString();
                selection.removeAllRanges();
                for (const range of saved) selection.addRange(range);
                return text;
            })()
            """) as? String
    }

    private func highlightPixels(_ data: Data) throws -> (yellow: Int, orange: Int, ink: Set<Int>) {
        guard let bitmap = NSBitmapImageRep(data: data) else { throw CocoaError(.coderInvalidValue) }
        var yellow = 0, orange = 0
        var ink = Set<Int>()
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if max(color.redComponent, color.greenComponent, color.blueComponent) < 0.4 {
                    ink.insert(y * bitmap.pixelsWide + x)
                }
                if color.redComponent > 0.9 && color.blueComponent < 0.3 {
                    if color.greenComponent > 0.9 { yellow += 1 }
                    else if color.greenComponent > 0.5 && color.greenComponent < 0.7 { orange += 1 }
                }
            }
        }
        return (yellow, orange, ink)
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
        let unpainted = (try? await evaluate(
            "[window, document.querySelector('#frame').contentWindow].reduce((sum, win) => sum + [...win.CSS.highlights.values()].reduce((n, h) => n + h.size, 0), 0)"
        )) as? Int
        check(unpainted == 0, "Clear takes the painted matches away in either document")
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
