import CryptoKit
import class SwiftUI.NSHostingView
import AppKit
import WebKit
import XCTest
@testable import Search

/// The Memory, Coverage, Animations and Changes tools against a real page
/// and WebKit's real inspector: each checks what the tool's own code reads
/// from the protocol (the heap snapshot's format, basic block offsets, the
/// Animation domain's payloads, style sheet text before and after an edit).
/// Pages come from a loopback server with inline content; nothing leaves
/// the machine.
@MainActor
final class DeveloperNewToolsLiveTests: XCTestCase {
    // MARK: Memory

    func testHeapSnapshotParsesClassesRootAndComparison() async throws {
        let live = try await open("""
            <!doctype html><title>Memory fixture</title>
            <body>
            <script>
            class PerchLeak { constructor(i) { this.i = i; } }
            window.perchLeaks = [];
            for (let i = 0; i < 500; i++) perchLeaks.push(new PerchLeak(i));
            function leakMore(count) {
                for (let i = 0; i < count; i++) perchLeaks.push(new PerchLeak(i));
                return perchLeaks.length;
            }
            </script>
            """, title: "Memory fixture")
        defer { live.window.close() }
        let session = live.session
        let memory = DeveloperMemory.store(for: session)
        memory.clear()
        try await live.run {
            memory.takeSnapshot()
            try await wait("first heap snapshot", seconds: 30) { memory.snapshots.count == 1 || memory.message != nil }
            XCTAssertNil(memory.message)
            let first = try XCTUnwrap(memory.snapshots.first?.snapshot)

            // The root: id 0, JavaScriptCore's "<root>" class, holding everything.
            XCTAssertEqual(first.ids[first.root], 0)
            XCTAssertEqual(first.classNames[first.classIndexes[first.root]], "<root>")
            XCTAssertGreaterThan(first.totalSize, 0)
            XCTAssertGreaterThan(first.nodeCount, 500)

            let leak = try XCTUnwrap(first.classes.first { $0.name == "PerchLeak" },
                                     "classes: \(first.classes.map(\.name).prefix(40))")
            XCTAssertGreaterThanOrEqual(leak.count, 500)
            XCTAssertGreaterThan(leak.shallowSize, 0)
            XCTAssertGreaterThanOrEqual(leak.retainedSize, leak.shallowSize)
            XCTAssertEqual(first.instances(of: leak.index).count, leak.count)
            XCTAssertFalse(first.summary(filter: "PerchLeak").isEmpty)

            // Heap.gc is accepted.
            memory.collectGarbage()
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertNil(memory.message, "Heap.gc")

            // More objects, a second snapshot: ids stay the same for the old
            // objects, so Comparison counts only the new ones.
            let total = try await page(live.page, "return leakMore(250);") as? Int
            XCTAssertEqual(total, 750)
            memory.takeSnapshot()
            try await wait("second heap snapshot", seconds: 30) { memory.snapshots.count == 2 || memory.message != nil }
            XCTAssertNil(memory.message)
            let second = try XCTUnwrap(memory.snapshots.last?.snapshot)
            let delta = try XCTUnwrap(second.comparison(from: first).first { $0.name == "PerchLeak" })
            XCTAssertGreaterThanOrEqual(delta.added, 250)
            XCTAssertGreaterThan(delta.delta, 0)
            XCTAssertGreaterThan(delta.allocatedSize, 0)
            let leakNow = try XCTUnwrap(second.classes.first { $0.name == "PerchLeak" })
            XCTAssertGreaterThanOrEqual(leakNow.count, 750)

            // Heap.getPreview on one of them, by its snapshot id.
            let instance = try XCTUnwrap(second.instances(of: leakNow.index).first)
            let preview = await memory.preview(second.ids[instance])
            XCTAssertTrue(preview.contains("PerchLeak"), preview)
        }
    }

    func testAllocationTimelineFindsSurvivorsAndGarbageCollections() async throws {
        let live = try await open("""
            <!doctype html><title>Allocation fixture</title><script>
            class Foo { constructor(index) { this.index = index; } }
            window.existingFoo = new Foo(-1);
            </script>
            """, title: "Allocation fixture")
        defer { live.window.close() }
        let session = live.session
        let memory = DeveloperMemory.store(for: session)
        try await live.run {
            memory.startAllocations()
            try await wait("allocation recording to start", seconds: 30) {
                memory.recordingAllocations || memory.message != nil
            }
            XCTAssertNil(memory.message)
            XCTAssertTrue(memory.recordingAllocations)
            let allocated = try await page(live.page, """
                window.newFoos = Array.from({length: 1000}, (_, index) => new Foo(index));
                return newFoos.length;
                """) as? Int
            XCTAssertEqual(allocated, 1000)
            _ = try await session.command("Heap.gc")
            memory.stopAllocations()
            try await wait("allocation profile", seconds: 30) {
                memory.selectedEntry?.allocations != nil || memory.message != nil
            }
            XCTAssertNil(memory.message)
            let entry = try XCTUnwrap(memory.selectedEntry)
            let profile = try XCTUnwrap(entry.allocations)
            let foo = try XCTUnwrap(profile.classes.first { $0.name == "Foo" })
            XCTAssertEqual(foo.count, 1000)
            XCTAssertEqual(profile.instances[foo.index].count, 1000)
            XCTAssertEqual(profile.start.classes.first { $0.name == "Foo" }?.count, 1)
            XCTAssertGreaterThan(entry.snapshot.timestamp, profile.start.timestamp)
            XCTAssertTrue(profile.collections.contains { $0.full })
            // The strip has a mark for each, whatever WebKit's clock says.
            XCTAssertEqual(profile.marks(end: entry.snapshot.timestamp).count, profile.collections.count)
        }
    }

    func testHeapObjectCanBeStoredAsGlobalAndDOMNodeRevealed() async throws {
        let live = try await open("""
            <!doctype html><title>Heap actions fixture</title>
            <progress id="heap-action-node"></progress>
            <script>
            class HeapActionObject { constructor() { this.answer = 42; } }
            window.heapActionObject = new HeapActionObject();
            window.heapActionNode = document.getElementById('heap-action-node');
            window.temp1 = 'existing';
            </script>
            """, title: "Heap actions fixture")
        defer { live.window.close() }
        let session = live.session
        let memory = DeveloperMemory.store(for: session)
        try await live.run {
            session.select(.memory)
            memory.takeSnapshot()
            try await wait("snapshot for object actions", seconds: 30) {
                memory.selectedEntry != nil || memory.message != nil
            }
            XCTAssertNil(memory.message)
            let entry = try XCTUnwrap(memory.selectedEntry)
            let snapshot = entry.snapshot
            let objectClass = try XCTUnwrap(snapshot.classes.first { $0.name == "HeapActionObject" })
            let object = try XCTUnwrap(snapshot.instances(of: objectClass.index).first)
            let stored = await memory.storeAsGlobal(object, in: entry)
            XCTAssertEqual(stored, "temp2")
            let check = try await page(live.page, "return temp2 === heapActionObject && temp1 === 'existing';")
            XCTAssertEqual(check as? Bool, true)

            let elementClass = try XCTUnwrap(snapshot.classes.first { $0.name.hasSuffix("HTMLProgressElement") })
            let candidates = snapshot.instances(of: elementClass.index).filter(snapshot.suggestsDOMNode)
            var revealed: Int?
            for element in candidates {
                if await memory.revealInElements(element, in: entry) {
                    revealed = element
                    break
                }
            }
            _ = try XCTUnwrap(revealed, "Candidates \(candidates.map { snapshot.ids[$0] }): \(memory.message ?? "no error")")
            try await wait("heap DOM node to be selected") {
                session.selectedNode.flatMap { session.nodes[$0]?.attributes }?.contains("heap-action-node") == true
            }
            XCTAssertEqual(session.panel, .elements)
        }
    }

    // MARK: Coverage

    func testCoverageMarksTheUncalledFunctionAndTheUnmatchedRule() async throws {
        let html = """
            <!doctype html><title>Coverage fixture</title>
            <style>
            .present { color: rgb(1, 2, 3); }
            .absent { color: rgb(4, 5, 6); }
            </style>
            <div class="present">here</div>
            <script>
            function perchCalled() {
                return "ran";
            }
            function perchNeverCalled() {
                return "never";
            }
            perchCalled();
            </script>
            """
        let live = try await open(html, title: "Coverage fixture")
        defer { live.window.close() }
        let session = live.session
        let coverage = session.coverage
        let url = live.server.url("/").absoluteString
        // 1-based lines of the page, as the Sources gutter numbers them.
        let lines = html.components(separatedBy: "\n")
        let ranLine = try XCTUnwrap(lines.firstIndex { $0.contains("return \"ran\"") }) + 1
        let neverLine = try XCTUnwrap(lines.firstIndex { $0.contains("return \"never\"") }) + 1
        do {
            coverage.startAndReload()
            try await wait("recording to start") { coverage.recording || coverage.message != nil }
            XCTAssertNil(coverage.message)
            try await wait("basic blocks for the inline script", seconds: 20, state: {
                "lines \(coverage.lineUsage(for: url).sorted { $0.key < $1.key }), entries \(coverage.entries)"
            }) {
                let marks = coverage.lineUsage(for: url)
                return marks[ranLine] == true && marks[neverLine] == false
            }

            // The ranges themselves: the never-called function's body is
            // unused, up to and including its closing brace (endOffset is
            // the block's last character), the called one's used.
            let script = try XCTUnwrap(coverage.scriptRanges(for: url).first { $0.source.contains("perchNeverCalled") })
            let source = script.source as NSString
            func range(at text: String) throws -> DeveloperCoverageMath.Range {
                let offset = source.range(of: text).location
                XCTAssertNotEqual(offset, NSNotFound, text)
                return try XCTUnwrap(script.ranges.first { $0.start <= offset && offset < $0.end }, text)
            }
            let never = try range(at: "return \"never\"")
            XCTAssertFalse(never.used)
            let neverText = source.substring(with: NSRange(location: never.start, length: never.length))
            XCTAssertTrue(neverText.hasSuffix("}"), "unused range ends at its brace: \(neverText.debugDescription)")
            XCTAssertFalse(neverText.contains("perchCalled();"), neverText)
            XCTAssertTrue(try range(at: "return \"ran\"").used)
            XCTAssertTrue(try range(at: "perchCalled();").used)
            let js = try XCTUnwrap(coverage.entries.first { $0.kind == .javaScript && DeveloperDebugger.sameScript($0.url, url) })
            XCTAssertGreaterThan(js.unused, 0)
            XCTAssertGreaterThan(js.used, 0)

            // CSS: the rule that matches the div is used, the other isn't.
            try await wait("CSS usage", state: { "entries \(coverage.entries)" }) {
                coverage.entries.contains { $0.kind == .css }
            }
            let css = try XCTUnwrap(coverage.entries.first { $0.kind == .css })
            let sizes = try await page(live.page, """
                const rules = document.styleSheets[0].cssRules;
                return [rules[0].cssText.length, rules[1].cssText.length];
                """) as? [Int]
            let lengths = try XCTUnwrap(sizes)
            XCTAssertTrue(DeveloperDebugger.sameScript(css.url, url), css.url)
            XCTAssertEqual(css.total, lengths[0] + lengths[1])
            XCTAssertEqual(css.unused, lengths[1])
            coverage.stop()
        } catch {
            coverage.stop()
            await live.finish()
            throw error
        }
        await live.finish()
    }

    // MARK: Animations

    func testAnimationsReportTheCSSAnimationItsTimingAndTarget() async throws {
        let live = try await open("""
            <!doctype html><title>Animations fixture</title>
            <style>
            @keyframes spin { from { transform: rotate(0deg); } to { transform: rotate(360deg); } }
            .spin { animation: spin 1s infinite; }
            </style>
            <div id="spinner">spinner</div>
            """, title: "Animations fixture")
        defer { live.window.close() }
        let session = live.session
        let model = DeveloperAnimations.model(for: session)
        do {
            try await wait("the document") { session.root != nil }
            model.start()
            try await wait("Animation.enable", state: { "problem \(model.problem ?? "none")" }) {
                model.listening || model.problem != nil
            }
            XCTAssertNil(model.problem)
            // Started after the domain was enabled, so animationCreated reports it.
            _ = try await page(live.page, "document.getElementById('spinner').classList.add('spin'); return true;")
            try await wait("the spin animation with its timing and target", state: {
                model.animations.map { animation in
                    let node = animation.node.map { "\($0)" } ?? "nil"
                    return "\(animation.title) \(animation.kind) \(animation.effect.iterationDuration)ms"
                        + " x\(animation.effect.iterationCount) node \(node) \(animation.label ?? "nil")"
                }
                    .joined(separator: " | ") + ", problem \(model.problem ?? "none")"
            }) {
                model.animations.contains {
                    $0.name == "spin" && $0.effect.iterationDuration > 0 && $0.node != nil && $0.label != nil
                }
            }
            let spin = try XCTUnwrap(model.animations.first { $0.name == "spin" })
            XCTAssertEqual(spin.kind, .cssAnimation)
            XCTAssertEqual(spin.title, "spin")
            XCTAssertEqual(spin.effect.iterationDuration, 1000, accuracy: 0.5)
            XCTAssertTrue(spin.effect.infinite, "iterationCount \(spin.effect.iterationCount)")
            XCTAssertEqual(DeveloperAnimationTimeline.iterationsShown(spin.effect), DeveloperAnimationTimeline.infiniteIterationsShown)
            XCTAssertEqual(spin.label, "div#spinner.spin")
            XCTAssertFalse(model.groups.isEmpty)

            // requestEffectTarget's node is the element.
            let node = try XCTUnwrap(spin.node)
            let resolved = try await session.command("DOM.resolveNode", ["nodeId": node], targetID: session.domTargetID)
            let objectID = try XCTUnwrap((resolved["object"] as? [String: Any])?["objectId"] as? String, "\(resolved)")
            let reply = try await session.command("Runtime.callFunctionOn", [
                "objectId": objectID, "functionDeclaration": "function() { return this.id; }", "returnByValue": true,
            ], targetID: session.domTargetID)
            XCTAssertEqual((reply["result"] as? [String: Any])?["value"] as? String, "spinner")
            model.stop()
        } catch {
            model.stop()
            await live.finish()
            throw error
        }
        await live.finish()
    }

    /// document.startViewTransition, caught by the page hook: its
    /// ::view-transition animations listed as one "View transition" group.
    func testAnimationsListAViewTransitionsPseudoElementAnimations() async throws {
        let live = try await open("""
            <!doctype html><title>View transition fixture</title>
            <style>::view-transition-group(root) { animation-duration: 1.5s; }</style>
            <p id="text">before</p>
            """, title: "View transition fixture")
        defer { live.window.close() }
        let supported = try await page(live.page, "return typeof document.startViewTransition === 'function';") as? Bool
        guard supported == true else {
            await live.finish()
            throw XCTSkip("This WebKit has no document.startViewTransition.")
        }
        let session = live.session
        let model = DeveloperAnimations.model(for: session)
        do {
            model.start()
            try await wait("the page hook", state: { "problem \(model.problem ?? "none")" }) {
                model.viewTransitionsSupported != nil
            }
            XCTAssertEqual(model.viewTransitionsSupported, true)
            // The hook doesn't show: the method still reads as the page's own.
            let named = try await page(live.page, "return document.startViewTransition.name;") as? String
            XCTAssertEqual(named, "startViewTransition")
            // The spec skips a view transition in a hidden document, as the
            // off-screen test window's is.
            if try await page(live.page, "return document.visibilityState;") as? String == "hidden" {
                model.stop()
                await live.finish()
                throw XCTSkip("View transitions are skipped while the document is hidden.")
            }
            _ = try await page(live.page, """
                document.startViewTransition(() => { document.getElementById('text').textContent = 'after'; });
                return true;
                """)
            try await wait("the view transition", state: {
                "transitions \(model.viewTransitionCount); groups "
                    + model.groups.map { "\($0.title ?? "timed"): \($0.animations.map(\.title))" }.joined(separator: " | ")
            }) {
                model.viewTransitionCount > 0 && model.groups.contains { $0.kind == .viewTransition }
            }
            let group = try XCTUnwrap(model.groups.last { $0.kind == .viewTransition })
            XCTAssertEqual(group.title, "View transition")
            XCTAssertFalse(group.playable)
            XCTAssertEqual(model.selection, group.id)
            XCTAssertTrue(group.animations.allSatisfy { $0.label?.hasPrefix("html::view-transition") == true },
                          "\(group.animations.map(\.label))")
            XCTAssertTrue(group.animations.contains { $0.effect.iterationDuration == 1500 },
                          "\(group.animations.map(\.effect.iterationDuration))")
            // WebKit's own reports of those pseudo-elements aren't listed twice.
            XCTAssertFalse(model.groups.contains { $0.kind == .time && $0.animations.contains(where: \.isViewTransitionPseudo) })
            model.stop()
        } catch {
            model.stop()
            await live.finish()
            throw error
        }
        await live.finish()
    }

    /// The speed buttons set the page's animations' playbackRate, and a
    /// bar dragged to a new delay and duration sets them in the page.
    func testAnimationsSpeedAndRetimingChangeThePagesAnimation() async throws {
        let live = try await open("""
            <!doctype html><title>Animations timing fixture</title>
            <style>
            @keyframes slide { from { transform: translateX(0); } to { transform: translateX(100px); } }
            .slide { animation: slide 2s 3; }
            </style>
            <div id="slider">slider</div>
            """, title: "Animations timing fixture")
        defer { live.window.close() }
        let session = live.session
        let model = DeveloperAnimations.model(for: session)
        let readTiming = "const a = document.getAnimations()[0]; if (!a) return null; const t = a.effect.getTiming();"
            + " return [a.playbackRate, t.delay, t.duration];"
        do {
            try await wait("the document") { session.root != nil }
            model.start()
            try await wait("Animation.enable", state: { "problem \(model.problem ?? "none")" }) {
                model.listening || model.problem != nil
            }
            XCTAssertNil(model.problem)
            _ = try await page(live.page, "document.getElementById('slider').classList.add('slide'); return true;")
            try await wait("the slide animation", state: {
                model.animations.map { "\($0.title) \($0.effect.iterationDuration)ms" }.joined(separator: " | ")
            }) {
                model.animations.contains { $0.name == "slide" && $0.effect.iterationDuration > 0 }
            }
            let slide = try XCTUnwrap(model.animations.first { $0.name == "slide" })

            model.setRate(0.25)
            XCTAssertEqual(model.rate, 0.25)
            var values: [Double] = []
            for _ in 0..<40 {
                values = (try await page(live.page, readTiming) as? [NSNumber] ?? []).map(\.doubleValue)
                if values.first == 0.25 { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertEqual(values.first, 0.25, "the page's animation runs at 25%: \(values)")

            model.retime(slide.id, delay: 400, duration: 3000)
            XCTAssertEqual(model.animations.first { $0.id == slide.id }?.effect.startDelay, 400, "shown at once")
            for _ in 0..<40 {
                values = (try await page(live.page, readTiming) as? [NSNumber] ?? []).map(\.doubleValue)
                if values.count == 3, values[1] == 400, values[2] == 3000 { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertEqual(values, [0.25, 400, 3000], "the page's animation has the new delay and duration")
            try await wait("the drawer to keep the new timing", state: {
                let effect = model.animations.first { $0.id == slide.id }?.effect
                return "delay \(effect?.startDelay ?? -1), duration \(effect?.iterationDuration ?? -1)"
            }) {
                let effect = model.animations.first { $0.id == slide.id }?.effect
                return effect?.startDelay == 400 && effect?.iterationDuration == 3000
            }
            model.setRate(1)
            model.stop()
        } catch {
            model.setRate(1)
            model.stop()
            await live.finish()
            throw error
        }
        await live.finish()
    }

    // MARK: Changes

    func testChangesTracksAStylesEditAndRevertsIt() async throws {
        let live = try await open("""
            <!doctype html><title>Changes fixture</title>
            <style>
            #target { color: rgb(10, 20, 30); }
            </style>
            <div id="target">changes</div>
            """, title: "Changes fixture")
        defer { live.window.close() }
        let session = live.session
        let changes = DeveloperChanges.of(session)
        func color() async throws -> String? {
            try await page(live.page, "return getComputedStyle(document.getElementById('target')).color;") as? String
        }
        try await live.run {
            try await wait("the document") { session.root != nil }
            let found = await session.searchDOM("#target")
            let target = try XCTUnwrap(found.first, "#target in the tree")
            session.selectNode(target)
            try await wait("the #target rule", state: { "rules \(session.matchedStyles.map(\.selector))" }) {
                session.matchedStyles.contains { $0.selector == "#target" && $0.editable }
            }
            let rule = try XCTUnwrap(session.matchedStyles.first { $0.selector == "#target" })
            session.editRule(rule.id, properties: rule.properties.map {
                var property = $0
                if property.name == "color" { property.value = "rgb(200, 0, 0)" }
                return property
            })
            try await wait("the edit, tracked", state: {
                "changed \(changes.changed.map(\.name)), message \(session.message ?? "none")"
            }) {
                session.styles.contains { $0.name == "color" && $0.value == "rgb(200, 0, 0)" } && !changes.changed.isEmpty
            }
            let edited = try await color()
            XCTAssertEqual(edited, "rgb(200, 0, 0)")

            let file = try XCTUnwrap(changes.changed.first)
            XCTAssertEqual(changes.changed.count, 1)
            XCTAssertEqual(file.kind, .styleSheet)
            XCTAssertTrue(file.original.contains("rgb(10, 20, 30)"), file.original)
            XCTAssertFalse(file.original.contains("rgb(200, 0, 0)"), file.original)
            XCTAssertTrue(file.current.contains("rgb(200, 0, 0)"), file.current)
            XCTAssertFalse(file.current.contains("rgb(10, 20, 30)"), file.current)
            let diff = DeveloperChangesDiff.diff(file.original, file.current)
            let counts = DeveloperChangesDiff.counts(diff)
            XCTAssertEqual(counts.insertions, 1, DeveloperChangesDiff.unified(diff))
            XCTAssertEqual(counts.deletions, 1, DeveloperChangesDiff.unified(diff))

            // Revert: CSS.setStyleSheetText with the first text.
            changes.revert(file)
            try await wait("the revert", state: {
                "changed \(changes.changed.map(\.name)), message \(session.message ?? "none")"
            }) { changes.changed.isEmpty }
            XCTAssertNil(session.message)
            let reverted = try await color()
            XCTAssertEqual(reverted, "rgb(10, 20, 30)")
            try await wait("Styles read again") {
                session.styles.contains { $0.name == "color" && $0.value == "rgb(10, 20, 30)" }
            }
        }
    }

    /// The font editor's edits, as its popover makes them, on a live rule:
    /// each declaration set where it is, a new one appended, the page's
    /// computed font following.
    func testFontEditorSetsTheRulesFontDeclarationsInPlace() async throws {
        let live = try await open("""
            <!doctype html><title>Font fixture</title>
            <style>
            #target { font-size: 12px; color: rgb(10, 20, 30); font-family: serif; }
            </style>
            <div id="target">font</div>
            """, title: "Font fixture")
        defer { live.window.close() }
        let session = live.session
        func computed(_ name: String) async throws -> String? {
            try await page(live.page, "return getComputedStyle(document.getElementById('target')).getPropertyValue('\(name)');") as? String
        }
        try await live.run {
            try await wait("the document") { session.root != nil }
            let found = await session.searchDOM("#target")
            let target = try XCTUnwrap(found.first, "#target in the tree")
            session.selectNode(target)
            try await wait("the #target rule", state: { "rules \(session.matchedStyles.map(\.selector))" }) {
                session.matchedStyles.contains { $0.selector == "#target" && $0.editable }
            }
            @MainActor func rule() throws -> DeveloperToolsSession.StyleRule {
                try XCTUnwrap(session.matchedStyles.first { $0.selector == "#target" })
            }
            XCTAssertTrue(DeveloperFontEditor.carriesButton(try rule().properties, at: 0))
            /// One edit as the popover makes it, then the page's computed
            /// `property` until it reads `expected`.
            @MainActor func set(_ name: String, _ value: String?, computed property: String, _ expected: String) async throws {
                let current = try rule()
                session.editStyle(current.id, properties: DeveloperFontEditor.setting(name, value, in: current.properties))
                let deadline = Date().addingTimeInterval(6)
                var seen: String?
                while Date() < deadline {
                    seen = try await computed(property)
                    if seen == expected { return }
                    try await Task.sleep(for: .milliseconds(100))
                }
                XCTFail("\(name): \(value ?? "removed") left \(property) at \(seen ?? "nil"); rule \((try? rule().properties.map { "\($0.name): \($0.value)" }) ?? []), message \(session.message ?? "none")")
            }
            try await set("font-size", "20px", computed: "font-size", "20px")
            try await set("font-family", DeveloperFontEditor.familyCSS(["Helvetica Neue", "sans-serif"]),
                          computed: "font-family", "Helvetica Neue, sans-serif")  // WebKit's serialization, unquoted
            try await set("font-weight", "700", computed: "font-weight", "700")
            XCTAssertEqual(try rule().properties.map(\.name), ["font-size", "color", "font-family", "font-weight"])
            try await set("font-weight", nil, computed: "font-weight", "400")
            XCTAssertEqual(try rule().properties.map(\.name), ["font-size", "color", "font-family"])
        }
    }

    /// The WebAuthn tool's virtual authenticator answering the page's own
    /// navigator.credentials.create() and get(); the assertion verifies
    /// with the public key the registration handed the page.
    func testWebAuthnVirtualAuthenticatorRegistersAndSignsIn() async throws {
        let live = try await open("<!doctype html><title>WebAuthn fixture</title><p>passkeys</p>", title: "WebAuthn fixture")
        defer { live.window.close() }
        let model = DeveloperWebAuthnModel.model(for: live.session)
        defer { model.setEnabled(false) }
        try await live.run {
            model.setEnabled(true)
            XCTAssertTrue(model.enabled, model.problem ?? "")
            model.addAuthenticator(DeveloperVirtualAuthenticator(name: "", transport: .internal, residentKeys: true,
                                                                 userVerification: true))
            let hooked = try await page(live.page, "return navigator.credentials.__perchWebAuthn === true;") as? Bool
            XCTAssertEqual(hooked, true)
            let madeRaw = try await page(live.page, """
                const enc = (b) => btoa(String.fromCharCode(...new Uint8Array(b))).replace(/\\+/g, '-').replace(/\\//g, '_').replace(/=+$/, '');
                const credential = await navigator.credentials.create({publicKey: {
                    rp: {name: 'Fixture'}, challenge: new Uint8Array([1, 2, 3, 4]),
                    user: {id: new Uint8Array([9, 9, 9]), name: 'ada', displayName: 'Ada'},
                    pubKeyCredParams: [{type: 'public-key', alg: -7}],
                    authenticatorSelection: {residentKey: 'required', userVerification: 'required'}}});
                return {id: credential.id, isPKC: credential instanceof PublicKeyCredential,
                        attestationResponse: credential.response instanceof AuthenticatorAttestationResponse,
                        clientData: new TextDecoder().decode(credential.response.clientDataJSON),
                        publicKey: enc(credential.response.getPublicKey()), alg: credential.response.getPublicKeyAlgorithm(),
                        transports: credential.response.getTransports(), attachment: credential.authenticatorAttachment,
                        json: JSON.stringify(credential).length};
                """)
            let made = try XCTUnwrap(madeRaw as? [String: Any])
            XCTAssertEqual(made["isPKC"] as? Bool, true)
            XCTAssertEqual(made["attestationResponse"] as? Bool, true)
            XCTAssertEqual(made["alg"] as? Int, -7)
            XCTAssertEqual(made["transports"] as? [String], ["internal"])
            XCTAssertEqual(made["attachment"] as? String, "platform")
            let clientData = try XCTUnwrap(made["clientData"] as? String)
            let origin = "http://127.0.0.1:\(live.server.url("/").port!)"
            XCTAssertEqual(clientData, #"{"type":"webauthn.create","challenge":"AQIDBA","origin":"\#(origin)","crossOrigin":false}"#)
            let credentials = model.authenticators.first?.credentials ?? []
            XCTAssertEqual(credentials.map(\.idString), [made["id"] as? String ?? "?"])
            XCTAssertEqual(credentials.first?.rpID, "127.0.0.1")

            let signedRaw = try await page(live.page, """
                const enc = (b) => btoa(String.fromCharCode(...new Uint8Array(b))).replace(/\\+/g, '-').replace(/\\//g, '_').replace(/=+$/, '');
                const assertion = await navigator.credentials.get({publicKey: {challenge: new Uint8Array([5, 6]), userVerification: 'required'}});
                return {id: assertion.id, authenticatorData: enc(assertion.response.authenticatorData),
                        clientData: enc(assertion.response.clientDataJSON), signature: enc(assertion.response.signature),
                        userHandle: enc(assertion.response.userHandle)};
                """)
            let signed = try XCTUnwrap(signedRaw as? [String: Any])
            XCTAssertEqual(signed["id"] as? String, made["id"] as? String)
            XCTAssertEqual(signed["userHandle"] as? String, "CQkJ")
            func bytes(_ value: Any?) throws -> Data { try XCTUnwrap(DeveloperWebAuthn.data(base64url: XCTUnwrap(value as? String))) }
            let key = try P256.Signing.PublicKey(derRepresentation: bytes(made["publicKey"]))
            let signature = try P256.Signing.ECDSASignature(derRepresentation: bytes(signed["signature"]))
            let authData = try bytes(signed["authenticatorData"])
            XCTAssertTrue(key.isValidSignature(signature, for: authData + Data(SHA256.hash(data: try bytes(signed["clientData"])))))
            XCTAssertEqual(model.authenticators.first?.credentials.first?.signCount, 1)

            let refused = try await page(live.page, """
                try {
                    await navigator.credentials.create({publicKey: {rp: {name: 'F'}, challenge: new Uint8Array([1]),
                        user: {id: new Uint8Array([1]), name: 'a', displayName: 'a'}, pubKeyCredParams: [{type: 'public-key', alg: -7}],
                        excludeCredentials: [{type: 'public-key', id: Uint8Array.from(atob(id.replace(/-/g, '+').replace(/_/g, '/') + '=='.slice(0, (4 - id.length % 4) % 4)), (c) => c.charCodeAt(0))}]}});
                    return 'created';
                } catch (error) { return error.name; }
                """.replacingOccurrences(of: "atob(id", with: "atob('\(made["id"] as? String ?? "")'").replacingOccurrences(of: "id.length", with: "\((made["id"] as? String ?? "").count)"))
            XCTAssertEqual(refused as? String, "InvalidStateError")
            XCTAssertEqual(model.log.count, 3, "\(model.log)")
            if let dir = ProcessInfo.processInfo.environment["PERCH_RENDER_DIR"] {
                let host = NSHostingView(rootView: DeveloperWebAuthnView(session: live.session))
                let panel = NSWindow(contentRect: CGRect(x: -4_000, y: -3_000, width: 760, height: 560),
                                     styleMask: [.borderless], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false
                panel.contentView = host
                panel.orderFrontRegardless()
                try await Task.sleep(for: .seconds(0.5))
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("webauthn.png"))
                }
                panel.close()
            }
        }
    }

    // MARK: Support

    private typealias Live = DeveloperLivePage

    private func open(_ html: String, title: String) async throws -> Live {
        try await Live.open(["/": .init(type: "text/html", body: html)], title: title, opened: { watched = $0 },
                            wait: { try await wait($0, until: $1) })
    }

    private func page(_ page: WKWebView, _ body: String) async throws -> Any? {
        try await page.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
    }

    /// The session the waits describe when they time out.
    private weak var watched: DeveloperToolsSession?

    private func wait(_ action: String, seconds: Double = 8, state: (() -> String)? = nil,
                      until condition: () -> Bool) async throws {
        try await DeveloperTestSupport.wait(action, seconds: seconds, in: "DeveloperNewToolsLiveTests", state: { [watched] in
            var parts: [String] = []
            if let watched {
                parts.append("ready \(watched.ready), message \(watched.message ?? "none")")
            }
            if let state { parts.append(state()) }
            return parts.joined(separator: "; ")
        }, until: condition)
    }
}
