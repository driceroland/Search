import AppKit
import WebKit
import XCTest
@testable import Search

/// Performance's local metrics and a recording's page tracks, against a
/// real page: the metrics script in the page's world, read and revealed
/// through the inspector.
@MainActor
final class DeveloperPerformanceMetricsLiveTests: XCTestCase {
    func testLocalMetricsMeasureThePageAndRevealTheLCPElement() async throws {
        let live = try await open("""
            <!doctype html><title>Metrics fixture</title><body style='margin:0'>
            <h1 id=hero style='font-size:64px;margin:0'>The largest text on the page</h1>
            <p id=small>Small text</p>
            </body>
            """, title: "Metrics fixture")
        defer { live.window.close() }
        let model = DeveloperLiveMetricsModel.model(for: live.session)
        do {
            model.attach()
            model.startPolling()
            try await wait("a first reading") { model.metrics != nil }
            let first = try XCTUnwrap(model.metrics)

            // Nothing the page can see by name.
            let names = try await page(live.page, """
                return Object.getOwnPropertyNames(window).filter((name) => /perch/i.test(name)).length;
                """) as? Int
            XCTAssertEqual(names, 0, "the metrics script left a global behind")

            if first.lcpSupported {
                try await wait("LCP and its element") { model.metrics?.lcp != nil && model.metrics?.lcpElement != nil }
                XCTAssertEqual(model.metrics?.lcpElement, "h1#hero")
                if case .value(let value)? = model.metrics?.reading(.lcp) {
                    XCTAssertGreaterThan(value, 0)
                } else {
                    XCTFail("no LCP value")
                }
                model.revealLCP()
                // As the panel does: leaving Performance takes the script
                // (and its hold on the element) out of the page.
                try await wait("Elements") { live.session.panel == .elements }
                model.detach()
                try await wait("the LCP element selected in Elements") {
                    live.session.selectedNode.flatMap { live.session.nodes[$0]?.attributes }?.contains("hero") == true
                }
                model.attach()
                model.startPolling()
                try await wait("a reading again") { model.metrics != nil }
            } else {
                XCTAssertEqual(first.reading(.lcp), .unavailable, "LCP without the entries reads as not available")
            }
            XCTAssertEqual(first.reading(.inp), first.inpSupported ? .waiting : .unavailable)

            // The page replacing what the script uses doesn't stop it: it
            // took its own copies when it went in.
            _ = try await page(live.page, "window.setTimeout = () => { throw new Error('replaced'); }; return true;")
            try await Task.sleep(for: .milliseconds(300))
            _ = try await page(live.page, """
                const block = document.createElement('div');
                block.style.height = '240px';
                document.body.prepend(block);
                return true;
                """)
            try await wait("CLS from the shift", seconds: 10) { (model.metrics?.cls ?? 0) > 0 }
            // The live view's Layout shifts log names what moved; Clear
            // starts it again and leaves CLS as it was.
            try await wait("the shift in the log") {
                model.metrics?.shiftLog.contains { $0.value > 0 && $0.elements.contains("h1#hero") } == true
            }
            let cls = model.metrics?.cls
            model.clearLogs()
            try await Task.sleep(for: .milliseconds(1_500))
            XCTAssertEqual(model.metrics?.shiftLog, [])
            XCTAssertEqual(model.metrics?.cls, cls)
            model.detach()
            await finish(live)
        } catch {
            model.detach()
            await finish(live)
            throw error
        }
    }

    /// A recording's Timings, Interactions and long tasks: the page's mark
    /// and measure land on the timeline where its work did, by the sync
    /// timestamp, which doesn't stay in the recording.
    func testRecordingCarriesPageTimingsInteractionsAndLongTasks() async throws {
        let live = try await open("""
            <!doctype html><title>Timings fixture</title><body>
            <button id=go>Go</button>
            <script>
            go.addEventListener('click', () => { document.body.dataset.clicked = 'yes'; });
            function busy(ms) { const until = performance.now() + ms; while (performance.now() < until) window.spin = Math.random(); }
            </script></body>
            """, title: "Timings fixture")
        defer { live.window.close() }
        do {
            live.session.toggleTimeline()
            try await wait("recording") { live.session.recordingTimeline }
            _ = try await page(live.page, """
                performance.mark('fixture-start');
                await new Promise((resolve) => setTimeout(resolve, 60));
                await new Promise((resolve) => setTimeout(() => { busy(120); resolve(); }, 0));
                performance.measure('fixture-work', 'fixture-start');
                await new Promise((resolve) => setTimeout(resolve, 60));
                go.click();
                return true;
                """)
            live.session.toggleTimeline()
            try await wait("page timings in the recording") {
                !live.session.recordingTimeline && live.session.timeline.contains { $0.type == "PageTiming" }
            }
            XCTAssertFalse(live.session.timeline.contains { $0.data["message"]?.hasPrefix(DeveloperPerformancePageTimings.syncPrefix) == true },
                           "the sync timestamp is left in the recording")
            let profile = DeveloperPerformanceProfile(live.session.timeline)
            let mark = try XCTUnwrap(profile.pageTimings.first { $0.name == "fixture-start" })
            let measure = try XCTUnwrap(profile.pageTimings.first { $0.name == "fixture-work" })
            XCTAssertEqual(measure.start, mark.start, accuracy: 0.5)
            XCTAssertTrue(profile.bounds.contains(mark.start) && profile.bounds.contains(measure.end))

            let task = try XCTUnwrap(profile.longTasks.map { profile.events[$0] }.first { $0.duration > 100 },
                                     "no long task: \(profile.events.filter { $0.parent == nil }.map { "\($0.type) \($0.duration)" })")
            // The page's clock and the timeline's agree: the busy task ran
            // after the mark and ended as the measure did.
            XCTAssertLessThan(mark.start, task.start)
            XCTAssertEqual(measure.end, task.end, accuracy: 30)

            let click = try XCTUnwrap(profile.interactions.first { $0.type == "click" })
            XCTAssertGreaterThan(click.start, measure.end)
            XCTAssertEqual(profile.events[click.event].type, "EventDispatch")
            await finish(live)
        } catch {
            await finish(live)
            throw error
        }
    }

    /// A recording's Layout shifts track: a block pushed in above the
    /// page's heading shifts it, and the heading, named in the shift, is
    /// revealed in Elements.
    func testRecordingCarriesLayoutShiftsWhoseNodesRevealInElements() async throws {
        let live = try await open("""
            <!doctype html><title>Shift fixture</title><body style='margin:0'>
            <h1 id=moved style='margin:0;font-size:40px'>Heading that moves</h1>
            <p>Below it</p>
            </body>
            """, title: "Shift fixture")
        defer { live.window.close() }
        do {
            live.session.toggleTimeline()
            try await wait("recording") { live.session.recordingTimeline }
            try await Task.sleep(for: .milliseconds(1_500))
            _ = try await page(live.page, """
                const block = document.createElement('div');
                block.style.height = '300px';
                document.body.prepend(block);
                return true;
                """)
            try await Task.sleep(for: .milliseconds(1_500))
            live.session.toggleTimeline()
            try await wait("a layout shift in the recording") {
                !live.session.recordingTimeline && live.session.timeline.contains { $0.type == "LayoutShift" }
            }
            let profile = DeveloperPerformanceProfile(live.session.timeline)
            let shift = try XCTUnwrap(profile.layoutShifts.first)
            XCTAssertGreaterThan(shift.score, 0)
            XCTAssertTrue(profile.bounds.contains(shift.time))
            XCTAssertNotNil(profile.cluster(of: 0))
            let node = try XCTUnwrap(shift.nodes.firstIndex(of: "h1#moved"), "affected nodes \(shift.nodes)")
            let index = try XCTUnwrap(shift.index)

            DeveloperLiveMetricsModel.model(for: live.session).revealShiftNode(index: index, node: node)
            try await wait("the shifted heading selected in Elements") {
                live.session.selectedNode.flatMap { live.session.nodes[$0]?.attributes }?.contains("moved") == true
            }
            await finish(live)
        } catch {
            await finish(live)
            throw error
        }
    }

    /// Transforms move what's painted, not the layout: Chrome counts no
    /// shift for a spinning or sliding element, and neither may the DevTools
    /// estimate (which once read every frame of them as one).
    func testTransformAnimationsAreNotLayoutShifts() async throws {
        let live = try await open("""
            <!doctype html><title>Transform fixture</title><body style='margin:0'>
            <div id=spin style='width:80px;height:80px;background:#c63'></div>
            <div id=slide style='width:80px;height:80px;background:#36c'></div>
            <div id=fixed style='position:fixed;top:10px;right:10px;width:40px;height:40px;background:#3a3'></div>
            <script>
            // Set by script, not animated: an off-screen test window's
            // animations are paused, its timers aren't.
            let step = 0;
            setInterval(() => {
                step++;
                spin.style.transform = `rotate(${step * 30}deg)`;
                slide.style.transform = `translateX(${(step % 2) * 300}px)`;
            }, 120);
            </script>
            </body>
            """, title: "Transform fixture")
        defer { live.window.close() }
        do {
            live.session.toggleTimeline()
            try await wait("recording") { live.session.recordingTimeline }
            try await Task.sleep(for: .milliseconds(1_500))
            live.session.toggleTimeline()
            try await wait("the recording") { !live.session.recordingTimeline && !live.session.timeline.isEmpty }
            try await Task.sleep(for: .milliseconds(300))
            let shifts = live.session.timeline.filter { $0.type == "LayoutShift" }
            XCTAssertTrue(shifts.isEmpty, "shifts from transforms: \(shifts.map { $0.data["nodes"] ?? "" })")
            await finish(live)
        } catch {
            await finish(live)
            throw error
        }
    }

    /// Capture settings' "Disable JavaScript samples": the sampling
    /// profiler stays off for the recording, and the timeline still records.
    func testDisablingJavaScriptSamplesLeavesTheProfilerOff() async throws {
        let live = try await open("""
            <!doctype html><title>Samples fixture</title><body>
            <script>setInterval(() => { let x = 0; for (let i = 0; i < 2e5; i++) x += i; }, 50);</script>
            </body>
            """, title: "Samples fixture")
        defer { live.window.close() }
        let saved = DeveloperPerformanceCapture.jsSamplesDisabled
        DeveloperPerformanceCapture.jsSamplesDisabled = true
        defer { DeveloperPerformanceCapture.jsSamplesDisabled = saved }
        do {
            live.session.toggleTimeline()
            try await wait("recording") { live.session.recordingTimeline }
            XCTAssertFalse(live.session.scriptProfilerStarted)
            try await Task.sleep(for: .milliseconds(800))
            live.session.toggleTimeline()
            try await wait("the recording") { !live.session.recordingTimeline && !live.session.timeline.isEmpty }
            XCTAssertTrue(live.session.timeline.contains { $0.type == "TimerFire" || $0.type == "FunctionCall" },
                          "types \(Set(live.session.timeline.map(\.type)))")
            await finish(live)
        } catch {
            await finish(live)
            throw error
        }
    }

    // MARK: Fixture

    private struct Live {
        let server: LocalPageServer
        let page: WKWebView
        let window: NSWindow
        let tab: Tab
        let session: DeveloperToolsSession
    }

    /// The page in an on-screen borderless window, off to the side, loaded,
    /// with a DevTools session attached and ready.
    private func open(_ html: String, title: String, resources: [String: LocalPageServer.Page] = [:]) async throws -> Live {
        _ = NSApplication.shared
        var pages = resources
        pages["/"] = .init(type: "text/html", body: html)
        let server = try LocalPageServer(pages)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        Web.inspector(configuration.preferences)
        let page = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let window = NSWindow(contentRect: CGRect(x: -4_000, y: -4_000, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderFrontRegardless()
        page.load(URLRequest(url: server.url("/")))
        do {
            try await wait("page to load") { page.title == title }
        } catch {
            window.close()
            throw error
        }
        let tab = Tab(shy: true)
        let session = DeveloperToolsSession(tab: tab, web: page, after: nil)
        watched = session
        let live = Live(server: server, page: page, window: window, tab: tab, session: session)
        do {
            try await wait("inspector") { session.ready }
        } catch {
            await finish(live)
            window.close()
            throw error
        }
        return live
    }

    private func finish(_ live: Live) async {
        await DeveloperTestSupport.finish(live.session, page: live.page, keeping: live.tab, live.server)
    }

    private func page(_ page: WKWebView, _ body: String) async throws -> Any? {
        try await page.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
    }

    /// The session the waits describe when they time out.
    private weak var watched: DeveloperToolsSession?

    private func wait(_ action: String, seconds: Double = 8, until condition: () -> Bool) async throws {
        try await DeveloperTestSupport.wait(action, seconds: seconds, in: "DeveloperPerformanceMetricsLiveTests", state: { [watched] in
            guard let watched else { return "" }
            return "ready \(watched.ready), message \(watched.message ?? "none"), timeline \(watched.timeline.count)"
        }, until: condition)
    }
}
