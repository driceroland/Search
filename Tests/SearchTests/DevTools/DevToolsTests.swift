import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import Search
import SearchPluginAPI

private typealias PageTab = Search.Tab

/// Developer tools packages, headless, in a window that is never shown.
/// With nothing installed Search is as it was. Developer Tools Lite,
/// installed from a local feed, works on real pages from a loopback server:
/// Lighthouse flags what a bad page gets wrong and not a good one; a
/// recorded form flow plays back; the device toolbar's size and location
/// reach the page; a hostile page sees and reaches nothing of it. Removed,
/// its files are gone. A tampered package, a wrong hash, a wrong signer and
/// a wrong API version are each refused, leaving nothing behind.
///
/// Needs the package built first: SEARCH_TEST_DEVTOOLS names a folder with
/// DevToolsLite-<arch>-<version>.zip and DevToolsLite.entry.json, as
/// `SEARCH_SIGN_IDENTITY=- ./build.sh release devtools` makes in build/devtools.
/// The package, once loaded, stays for the run: the tests are in order.
@MainActor
final class DevToolsTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    private var server: LocalPageServer!
    private var browser: Browser!
    private var window: NSWindow!
    private var tab: PageTab?
    private var scratch: URL!

    override func setUp() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        server = try LocalPageServer(Self.pages)
        browser = Browser(record: WindowRecord())
        window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1100, height: 900),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        browser.window = window
        scratch = TestWorld.home.appendingPathComponent("devtools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        DevToolsPackages.requireRelease = false
    }

    override func tearDown() async throws {
        if let tab { browser.close(tab) }
        server.stop()
        window.orderOut(nil)
        window.close()
        try? FileManager.default.removeItem(at: scratch)
        XCTAssertTrue(NSApp.windows.allSatisfy { !$0.isVisible }, "no window was shown")
        try await super.tearDown()
    }

    private var packages: DevToolsPackages { .shared }

    // MARK: - 1. nothing installed

    func test1NothingInstalledChangesNothing() async throws {
        XCTAssertTrue(packages.installed.isEmpty)
        XCTAssertNil(packages.primary, "no Developer menu")
        XCTAssertTrue(DevToolsPackages.idle, "nothing loaded")
        let tab = try await open("/good")
        XCTAssertTrue(DevToolsPackages.scripts(for: tab).isEmpty)
        XCTAssertFalse(DevToolsPackages.busy(tab))
        let scripts = tab.web.configuration.userContentController.userScripts.count
        packages.open("lighthouse", in: browser)
        tab.web.reload()
        try await waitUntil { !tab.web.isLoading }
        XCTAssertEqual(tab.web.configuration.userContentController.userScripts.count, scripts)
        XCTAssertTrue(DevToolsPackages.idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: DevToolsPackages.folder.path))
    }

    // MARK: - 2. refused, cleanly

    func test2BadPackagesAreRefused() async throws {
        let (zip, offer) = try localPackage()
        // The ZIP with one byte changed: its hash isn't the feed's.
        var bytes = try Data(contentsOf: zip)
        bytes[bytes.count / 2] ^= 0xFF
        let flipped = scratch.appendingPathComponent("flipped.zip")
        try bytes.write(to: flipped)
        try await refused(offer(["url": flipped.absoluteString]), "isn't what the feed lists")
        // A hash that isn't the package's.
        try await refused(offer(["sha256": String(repeating: "0", count: 64)]), "isn't what the feed lists")
        // An API version this Search doesn't speak, either way.
        try await refused(offer(["api": SearchDevToolsAPI.version + 1]), "Update Search")
        try await refused(offer(["api": SearchDevToolsAPI.version - 1]), "Update the package")
        // An executable that isn't the one the feed lists.
        try await refused(offer(["binary": String(repeating: "a", count: 64)]), "isn't the one the feed lists")
        // A hidden entry anywhere in the ZIP, AppleDouble "._" files
        // included, even with the hash and size the feed lists.
        for hidden in ["DevToolsLite.bundle/Contents/.extra", "DevToolsLite.bundle/Contents/MacOS/._DevToolsLite", ".DS_Store"] {
            let folder = scratch.appendingPathComponent("hidden-\(UUID().uuidString)")
            try DevToolsPackages.unzip(zip, into: folder)
            try Data("x".utf8).write(to: folder.appendingPathComponent(hidden))
            let packed = scratch.appendingPathComponent("hidden-\(UUID().uuidString).zip")
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-c", "-k", "--norsrc", "--noextattr", folder.path, packed.path]
            try ditto.run()
            ditto.waitUntilExit()
            let size = try XCTUnwrap(packed.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            try await refused(offer(["url": packed.absoluteString, "sha256": try DevToolsPackages.digest(packed), "size": size]),
                              "laid out")
        }

        // Release checks: an ad-hoc signature isn't Office Commun's
        // Developer ID, for any team.
        let unpacked = scratch.appendingPathComponent("unpacked")
        try DevToolsPackages.unzip(zip, into: unpacked)
        let bundle = unpacked.appendingPathComponent("DevToolsLite.bundle")
        let good = try XCTUnwrap(offer([:]))
        XCTAssertNoThrow(try DevToolsPackages.verify(bundle, offer: good, release: false))
        XCTAssertThrowsError(try DevToolsPackages.verify(bundle, offer: good, release: true)) {
            XCTAssertEqual($0 as? DevToolsPackages.Refused, .signature)
        }
        // Another signer's identifier, even in a test run.
        let other = try XCTUnwrap(offer(["id": "other"]))
        XCTAssertThrowsError(try DevToolsPackages.verify(bundle, offer: other, release: false)) {
            XCTAssertEqual($0 as? DevToolsPackages.Refused, .signature)
        }
        // A byte changed in the executable after it was checked.
        let executable = bundle.appendingPathComponent("Contents/MacOS/DevToolsLite")
        var code = try Data(contentsOf: executable)
        code[code.count / 3] ^= 0xFF
        try code.write(to: executable)
        var patched = good.json
        patched["binary"] = try DevToolsPackages.digest(executable)
        let rehashed = try XCTUnwrap(DevToolsOffer(json: patched, link: { ($0 as? String).flatMap(URL.init(string:)) }))
        XCTAssertThrowsError(try DevToolsPackages.verify(bundle, offer: rehashed, release: false)) {
            XCTAssertEqual($0 as? DevToolsPackages.Refused, .signature, "the signature covers every byte")
        }
        // More than the feed's size is cut off as it streams in, announced
        // or not, and never lands on the disk past the limit.
        let big = String(repeating: "x", count: 300_000)
        let flood = try LocalPageServer(["/said": .init(type: "application/zip", body: big),
                                         "/unsaid": .init(type: "application/zip", body: big, withoutLength: true)])
        defer { flood.stop() }
        for path in ["/said", "/unsaid"] {
            let file = scratch.appendingPathComponent("flood\(path.dropFirst()).zip")
            do {
                try await DevToolsPackages.stream(flood.url(path), session: .shared, into: file, limit: 100_000)
                XCTFail("\(path): more than the limit was taken")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("isn't what the feed lists"), "\(path): \(error)")
            }
            let kept = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            XCTAssertLessThanOrEqual(kept, 100_000, "\(path): nothing past the limit on disk")
        }
        XCTAssertTrue(packages.installed.isEmpty)
        XCTAssertTrue(DevToolsPackages.idle)
        packages.offered = []
    }

    // MARK: - 3. Lite: installed, used, removed

    func test3LiteInstallsWorksAndRemoves() async throws {
        let (_, offer) = try localPackage()
        let lite = try XCTUnwrap(offer([:]))
        packages.offered = [lite]
        packages.install("lite")
        try await waitUntil(timeout: 30) { self.packages.states["lite"] == .idle && self.packages.installed["lite"] != nil }
        let place = DevToolsPackages.folder.appendingPathComponent("lite/1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: place.appendingPathComponent("DevToolsLite.bundle/Contents/MacOS/DevToolsLite").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: DevToolsPackages.folder.path).filter { $0.hasPrefix(".staging") }, [])
        XCTAssertEqual(packages.primary?.offer.menu.map(\.title), ["Lighthouse", "Recorder", "Device Toolbar"])
        XCTAssertTrue(DevToolsPackages.idle, "installed isn't loaded: nothing runs until first use")

        // Lighthouse: the bad page's faults flagged, the good page clean.
        let bad = try await audit("/bad", on: server)
        let audits = try XCTUnwrap(bad["audits"] as? [String: [String: Any]])
        XCTAssertFalse(DevToolsPackages.idle, "loaded on first use")
        for id in ["image-alt", "label", "button-name", "link-name", "document-title", "html-has-lang", "color-contrast",
                   "heading-order", "tabindex", "meta-viewport", "list", "doctype", "meta-description", "link-text",
                   "crawlable-anchors", "is-crawlable", "robots-txt", "aria-valid-attr", "aria-roles", "landmark-one-main"] {
            XCTAssertEqual(audits[id]?["score"] as? Double, 0, "\(id) fails on the bad page: \(String(describing: audits[id]))")
        }
        XCTAssertLessThan(score(bad, "accessibility"), 0.5)
        XCTAssertLessThan(score(bad, "seo"), 0.5)
        var pages = Self.pages
        pages["/robots.txt"] = .init(type: "text/plain", body: "User-agent: *\nDisallow: /private\n")
        let fine = try LocalPageServer(pages)
        defer { fine.stop() }
        let good = try await audit("/good", on: fine)
        for (id, audit) in try XCTUnwrap(good["audits"] as? [String: [String: Any]]) {
            let mode = audit["scoreDisplayMode"] as? String
            guard mode == "binary" || mode == "numeric" else { continue }
            XCTAssertEqual(audit["score"] as? Double, 1, "\(id) passes on the good page")
        }
        XCTAssertEqual(score(good, "accessibility"), 1)
        XCTAssertEqual(score(good, "seo"), 1)

        // Navigation: the load measured, its observer taken out after.
        let tab = try await open("/good", on: fine)
        _ = try await perform("open", ["item": "lighthouse"], tab)
        let before = tab.web.configuration.userContentController.userScripts.map { String($0.source.prefix(50)) }
        let run = try await perform("lighthouse.run", ["mode": "navigation", "form": "desktop",
                                                      "categories": ["performance", "accessibility", "best-practices", "seo"]], tab)
        let loaded = try XCTUnwrap(run["report"] as? [String: Any], "\(run)")
        let measured = try XCTUnwrap(loaded["audits"] as? [String: [String: Any]])
        XCTAssertEqual(measured["http-status-code"]?["score"] as? Double, 1, "the document's status was heard")
        XCTAssertNotNil(measured["total-blocking-time"])
        XCTAssertEqual(measured["errors-in-console"]?["score"] as? Double, 0, "the page's thrown error was seen")
        let after = tab.web.configuration.userContentController.userScripts.map { String($0.source.prefix(50)) }
        XCTAssertEqual(after.count, before.count, "the load observer came out: \(Set(after).symmetricDifference(before))")
        _ = try await perform("close", [:], tab)

        try await recorderFlow()
        try await deviceToolbar()
        try await hostilePage()
        try await importChecks()

        // Removed: every file goes; loaded this run, it says to restart.
        packages.remove("lite")
        XCTAssertFalse(FileManager.default.fileExists(atPath: DevToolsPackages.folder.appendingPathComponent("lite").path))
        XCTAssertEqual(packages.states["lite"], .removedLoaded)
        XCTAssertNil(packages.primary, "no Developer menu")
        XCTAssertTrue(packages.installed.isEmpty, "after a restart, nothing is there to load")
        packages.offered = []
    }

    // MARK: - the probes, through the package's own commands

    private func recorderFlow() async throws {
        let tab = try await open("/form")
        _ = try await perform("open", ["item": "recorder"], tab)
        _ = try await perform("recorder.record", [:], tab)
        try await waitUntil { (try? await self.inTools(tab, "return !!window.__searchDeveloperRecorder")) as? Bool == true }
        try await click(tab, "#name")
        try await type(tab, "Ada")
        try await click(tab, "#go")
        try await waitUntil { tab.web.url?.path == "/done" && !tab.web.isLoading }
        try await waitUntil {
            let steps = (try? await self.perform("recorder.steps", [:], tab))?["steps"] as? [[String: Any]] ?? []
            return steps.contains { $0["assertedEvents"] != nil && $0["type"] as? String == "click" }
        }
        let stopped = try await perform("recorder.stop", [:], tab)
        let steps = try XCTUnwrap(stopped["steps"] as? [[String: Any]])
        XCTAssertEqual(steps.map { $0["type"] as? String }, ["setViewport", "navigate", "click", "change", "click"], "\(steps)")
        XCTAssertEqual(steps[3]["value"] as? String, "Ada")
        XCTAssertTrue((steps[2]["selectors"] as? [[String]])?.contains(["#name"]) == true)
        XCTAssertTrue((steps[4]["selectors"] as? [[String]])?.contains { $0.first?.hasPrefix("aria/Send") == true } == true)

        // Exported, changed, read back and played from the start.
        var edited = steps
        edited[3]["value"] = "Grace"
        let file = String(decoding: try JSONSerialization.data(withJSONObject: ["title": "flow", "steps": edited]), as: UTF8.self)
        let imported = try await perform("recorder.import", ["json": file], tab)
        XCTAssertEqual((imported["steps"] as? [Any])?.count, 5, "\(imported)")
        let played = try await perform("recorder.play", [:], tab)
        XCTAssertEqual(played["state"] as? String, "played", "\(played)")
        XCTAssertEqual(tab.web.url?.query, "name=Grace")
        _ = try await perform("close", [:], tab)
    }

    private func deviceToolbar() async throws {
        let tab = try await open("/geo")
        let host = NSHostingView(rootView: StageProbe(tab: tab, browser: browser))
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 1100, height: 900)
        let opened = try await perform("open", ["item": "device"], tab)
        XCTAssertEqual(opened["open"] as? Bool, true)
        _ = try await perform("device.set", ["device": NSNull(), "width": 390, "height": 700], tab)
        try await waitUntil {
            host.layoutSubtreeIfNeeded()
            return (try? await tab.web.evaluateJavaScript("innerWidth")) as? Int == 390
        }
        let height = try await tab.web.evaluateJavaScript("innerHeight")
        XCTAssertEqual(height as? Int, 700)

        _ = try await perform("device.set", ["location": "Tokyo"], tab)
        try await waitUntil { ((try? await tab.web.evaluateJavaScript("window.found")) as? String) == "35.689487,139.691706" }
        tab.web.reload()
        try await waitUntil { ((try? await tab.web.evaluateJavaScript("window.found")) as? String) == "35.689487,139.691706" }
        _ = try await perform("device.set", ["locationUnavailable": true, "location": NSNull()], tab)
        try await waitUntil { ((try? await tab.web.evaluateJavaScript("window.found")) as? String) == "error 2" }
        _ = try await perform("device.set", ["orientation": "Landscape left"], tab)
        try await waitUntil { ((try? await tab.web.evaluateJavaScript("window.turned")) as? String) == "90,0,-90" }
        _ = try await perform("device.set", ["colorScheme": "dark", "reducedMotion": true, "vision": "deuteranopia"], tab)
        try await waitUntil { (try? await tab.web.evaluateJavaScript("matchMedia('(prefers-color-scheme: dark)').matches")) as? Bool == true }
        try await waitUntil {
            (try? await tab.web.evaluateJavaScript("getComputedStyle(document.body).getPropertyValue('--motion').trim()")) as? String == "reduce"
        }
        try await waitUntil {
            (try? await tab.web.evaluateJavaScript("getComputedStyle(document.documentElement).filter")) as? String == "url(\"#search-developer-vision\")"
        }
        XCTAssertTrue(DevToolsPackages.busy(tab), "kept awake while open")

        _ = try await perform("close", [:], tab)
        try await waitUntil {
            host.layoutSubtreeIfNeeded()
            return (try? await tab.web.evaluateJavaScript("innerWidth")) as? Int == 1100
        }
        try await waitUntil { (try? await tab.web.evaluateJavaScript("getComputedStyle(document.documentElement).filter")) as? String == "none" }
        try await waitUntil { (try? await tab.web.evaluateJavaScript("matchMedia('(prefers-color-scheme: dark)').matches")) as? Bool == false }
        XCTAssertFalse(DevToolsPackages.busy(tab))
        window.contentView = nil
    }

    private func hostilePage() async throws {
        let tab = try await open("/hostile")
        _ = try await perform("open", ["item": "recorder"], tab)
        _ = try await perform("recorder.record", [:], tab)
        try await waitUntil { (try? await self.inTools(tab, "return !!window.__searchDeveloperRecorder")) as? Bool == true }
        _ = try await perform("open", ["item": "device"], tab)
        _ = try await perform("device.set", ["location": "Berlin", "reducedMotion": true], tab)
        _ = try await perform("open", ["item": "lighthouse"], tab)
        let run = try await perform("lighthouse.run", ["mode": "snapshot"], tab)
        let audits = try XCTUnwrap((run["report"] as? [String: Any])?["audits"] as? [String: [String: Any]], "\(run)")
        // The page replaced querySelectorAll, Array.from and JSON on its side;
        // the audit still sees its one image without alt.
        XCTAssertEqual(audits["image-alt"]?["score"] as? Double, 0)
        XCTAssertEqual(((audits["image-alt"]?["details"] as? [String: Any])?["items"] as? [Any])?.count, 1)

        try await click(tab, "#visible")
        try await waitUntil {
            let steps = (try? await self.perform("recorder.steps", [:], tab))?["steps"] as? [[String: Any]] ?? []
            return steps.contains { $0["type"] as? String == "click" }
        }
        _ = try await tab.web.evaluateJavaScript("window.attack(); true")
        try await Task.sleep(nanoseconds: 800_000_000)
        let stopped = try await perform("recorder.stop", [:], tab)

        let answer = try await tab.web.evaluateJavaScript("window.probe")
        let seen = try XCTUnwrap(answer as? [String: Any])
        let probe = "\(seen)"
        XCTAssertEqual(seen["webkit"] as? String, "undefined", "no window.webkit in the page's world: \(probe)")
        XCTAssertEqual(seen["frameWebkit"] as? String, "undefined", "nor in its frame: \(probe)")
        XCTAssertEqual(seen["globals"] as? [String], [], "no new globals: \(probe)")
        XCTAssertEqual(seen["symbols"] as? [String], [], "no symbols on window: \(probe)")
        XCTAssertEqual(seen["attributes"] as? [String], [], "nothing written on the root: \(probe)")
        XCTAssertEqual(seen["posted"] as? String, "refused", "can't reach the handler: \(probe)")
        let clicks = (stopped["steps"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "click" }
        XCTAssertEqual(clicks.count, 1, "only the person's click is a step, not the page's: \(stopped)")
        _ = try await perform("close", [:], tab)
        tab.web.reload()
        try await waitUntil { !tab.web.isLoading }
        let handler = try await inTools(tab, "return typeof (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.searchDeveloper)")
        XCTAssertEqual(handler as? String, "undefined", "no handler once closed")
        XCTAssertTrue(DevToolsPackages.scripts(for: tab).isEmpty, "no scripts once closed")
    }

    private func importChecks() async throws {
        let tab = try await open("/form")
        _ = try await perform("open", ["item": "recorder"], tab)
        let refused = [
            ##"{"steps":[{"type":"customStep","name":"x","parameters":{}}]}"##,
            ##"{"steps":[{"type":"navigate","url":"javascript:alert(1)"}]}"##,
            ##"{"steps":[{"type":"navigate","url":"file:///etc/passwd"}]}"##,
            ##"{"steps":[{"type":"click","selectors":[["#a"]],"frame":[0]}]}"##,
            ##"{"steps":[{"type":"click","target":"https://other.example","selectors":[["#a"]]}]}"##,
            ##"{"steps":[{"type":"click","selectors":[]}]}"##,
            ##"{"steps":[{"type":"change","selectors":[["#a"]],"value":7}]}"##,
            ##"{"steps":"nope"}"##,
            ##"[1,2]"##,
            "{\"steps\":[" + Array(repeating: ##"{"type":"keyDown","key":"a"}"##, count: 2_001).joined(separator: ",") + "]}",
        ]
        for text in refused {
            let answer = try await perform("recorder.import", ["json": text], tab)
            XCTAssertNotNil(answer["error"], String(text.prefix(80)))
        }
        let fine = ##"{"title":"t","steps":[{"type":"navigate","url":"https://example.com/"},{"type":"click","target":"main","selectors":[["#a"],"aria/Go"],"offsetX":1,"offsetY":2},{"type":"keyDown","key":"Enter"}]}"##
        let answer = try await perform("recorder.import", ["json": fine], tab)
        XCTAssertEqual((answer["steps"] as? [Any])?.count, 3, "\(answer)")
        _ = try await perform("close", [:], tab)
    }

    // MARK: - helpers

    /// The package build.sh made, and a feed entry for it at a file address.
    private func localPackage() throws -> (URL, ([String: Any]) -> DevToolsOffer?) {
        guard let folder = ProcessInfo.processInfo.environment["SEARCH_TEST_DEVTOOLS"] else {
            throw XCTSkip("SEARCH_TEST_DEVTOOLS names no built package")
        }
        let built = URL(fileURLWithPath: folder)
        let data = try Data(contentsOf: built.appendingPathComponent("DevToolsLite.entry.json"))
        var entry = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let zip = scratch.appendingPathComponent(try XCTUnwrap(entry["file"] as? String))
        try FileManager.default.copyItem(at: built.appendingPathComponent(zip.lastPathComponent), to: zip)
        entry["file"] = nil
        entry["url"] = zip.absoluteString
        let base = entry
        return (zip, { changes in
            var json = base
            for (key, value) in changes { json[key] = value }
            return DevToolsOffer(json: json, link: { ($0 as? String).flatMap(URL.init(string:)) })
        })
    }

    private func refused(_ offer: DevToolsOffer?, _ why: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let offer = try XCTUnwrap(offer, file: file, line: line)
        packages.offered = [offer]
        packages.install(offer.id)
        try await waitUntil(file: file, line: line) {
            if case .failed = self.packages.states[offer.id] { return true }
            return false
        }
        guard case .failed(let message) = packages.states[offer.id] else { return }
        XCTAssertTrue(message.contains(why), "\(message)", file: file, line: line)
        XCTAssertNil(packages.installed[offer.id], "nothing installed", file: file, line: line)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: DevToolsPackages.folder.path)) ?? []
        XCTAssertEqual(left.filter { $0 != ".DS_Store" && !(packages.installed[$0] != nil) }.filter { $0 != offer.id || true }.filter { $0.hasPrefix(".staging") }, [],
                       "nothing half-installed", file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: DevToolsPackages.folder.appendingPathComponent(offer.id).path),
                       "nothing half-installed", file: file, line: line)
    }

    private func score(_ report: [String: Any], _ category: String) -> Double {
        ((report["categories"] as? [String: Any])?[category] as? [String: Any])?["score"] as? Double ?? -1
    }

    private func perform(_ command: String, _ arguments: [String: Any], _ tab: PageTab) async throws -> [String: Any] {
        let plugin = try XCTUnwrap(packages.plugin("lite"), "the package loads: \(String(describing: packages.states["lite"]))")
        return await withCheckedContinuation { done in
            plugin.perform(command, arguments: arguments, webView: tab.web) { done.resume(returning: $0) }
        }
    }

    private func audit(_ path: String, on origin: LocalPageServer) async throws -> [String: Any] {
        let tab = try await open(path, on: origin)
        packages.open("lighthouse", in: browser)
        let run = try await perform("lighthouse.run", ["mode": "snapshot", "categories": ["performance", "accessibility", "best-practices", "seo"]], tab)
        _ = try await perform("close", [:], tab)
        return try XCTUnwrap(run["report"] as? [String: Any], "\(run)")
    }

    private func open(_ path: String, on origin: LocalPageServer? = nil) async throws -> PageTab {
        if let tab = self.tab { browser.close(tab) }
        let server = origin ?? self.server!
        let tab = browser.open(URL(string: "about:blank")!, foreground: true)
        self.tab = tab
        window.contentView = tab.web
        tab.go(to: server.url(path))
        try await waitUntil { tab.committed == server.url(path) && !tab.loading && !tab.web.isLoading }
        return tab
    }

    private func inTools(_ tab: PageTab, _ body: String) async throws -> Any? {
        let world = WKContentWorld.world(name: "Search Developer lite")
        return try await tab.web.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: world)
    }

    /// A press of the mouse where the element is, as the window hands it to
    /// the page: a trusted click.
    private func click(_ tab: PageTab, _ selector: String) async throws {
        let answer = try await tab.web.evaluateJavaScript(
            "(() => { const r = document.querySelector('\(selector)').getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2] })()")
        let rect = try XCTUnwrap(answer as? [Double])
        let inView = NSPoint(x: rect[0], y: tab.web.isFlipped ? rect[1] : tab.web.bounds.height - rect[1])
        let point = tab.web.convert(inView, to: nil)
        window.makeFirstResponder(tab.web)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
            type == .leftMouseDown ? tab.web.mouseDown(with: event) : tab.web.mouseUp(with: event)
            try await Task.sleep(nanoseconds: 60_000_000)
        }
    }

    private func type(_ tab: PageTab, _ text: String) async throws {
        for character in text {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let event = try XCTUnwrap(NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: String(character),
                    charactersIgnoringModifiers: String(character), isARepeat: false, keyCode: 0))
                type == .keyDown ? tab.web.keyDown(with: event) : tab.web.keyUp(with: event)
            }
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    private func waitUntil(timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line,
                           _ condition: @MainActor () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            XCTAssertTrue(NSApp.windows.allSatisfy { !$0.isVisible }, "no window was shown", file: file, line: line)
            if await condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("timed out", file: file, line: line)
        throw CancellationError()
    }

    // MARK: - pages

    static let pages: [String: LocalPageServer.Page] = [
        "/good": .init(type: "text/html; charset=utf-8", body: """
            <!doctype html><html lang="en"><head><meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>A good page</title><meta name="description" content="A page that does things right.">
            <link rel="canonical" href="/good"></head>
            <body><main><h1>Welcome</h1><h2>Section</h2>
            <p style="color:#111;background:#fff">Readable text.</p>
            <img src="/pixel.svg" alt="A dot" width="1" height="1">
            <form action="/done"><label for="q">Search</label><input id="q" name="q"><button>Find</button></form>
            <ul><li><a href="/about">About this site</a></li></ul>
            <script>setTimeout(() => { throw new Error("thrown on purpose") }, 10)</script>
            </main></body></html>
            """),
        "/bad": .init(type: "text/html", body: """
            <html><head><meta name="robots" content="noindex">
            <meta name="viewport" content="width=device-width, user-scalable=no"></head>
            <body><h1>Hi</h1><h4>Skipped</h4>
            <p style="color:#bbb;background:#fff">Hard to read.</p>
            <img src="/pixel.svg">
            <input id="nameless"><button></button><a href="/x"></a>
            <a href="/more">click here</a><a onclick="go()">no href</a>
            <div tabindex="3" aria-hidd="true" role="buton">x</div>
            <ul><div>not an item</div></ul>
            </body></html>
            """),
        "/robots.txt": .init(type: "text/plain", body: "User-agent: *\nDisallow: /private\nthis line is not valid\n"),
        "/pixel.svg": .init(type: "image/svg+xml", body: "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\"><rect width=\"10\" height=\"10\"/></svg>"),
        "/form": .init(type: "text/html", body: """
            <!doctype html><html lang="en"><title>form</title><body>
            <form action="/done" method="get"><label for="name">Name</label><input id="name" name="name">
            <button id="go" type="submit">Send</button></form></body></html>
            """),
        "/done": .init(type: "text/html", body: "<!doctype html><title>done</title><p>Thanks</p>"),
        "/geo": .init(type: "text/html", body: """
            <!doctype html><title>geo</title>
            <style>body { --motion: full } @media (prefers-reduced-motion: reduce) { body { --motion: reduce } }</style>
            <body><script>
            window.found = "pending";
            navigator.geolocation.getCurrentPosition(
              (p) => { window.found = p.coords.latitude + "," + p.coords.longitude; document.title = "found" },
              (e) => { window.found = "error " + e.code; document.title = "failed" });
            window.addEventListener("deviceorientation", (e) => { window.turned = [e.alpha, e.beta, e.gamma].join(",") });
            setInterval(() => navigator.geolocation.getCurrentPosition(
              (p) => { window.found = p.coords.latitude + "," + p.coords.longitude },
              (e) => { window.found = "error " + e.code }), 200);
            </script></body>
            """),
        "/frame": .init(type: "text/html", body: "<!doctype html><script>parent.probe.frameWebkit = typeof window.webkit</script>"),
        "/hostile": .init(type: "text/html", body: """
            <!doctype html><html lang="en"><title>hostile</title><body>
            <img src="/pixel.svg"><button id="visible">Press</button>
            <script>
            const before = new Set(Object.getOwnPropertyNames(window));
            const symbols = Object.getOwnPropertySymbols(window).length;
            const attributes = Array.from(document.documentElement.attributes).map((a) => a.name);
            window.probe = { webkit: typeof window.webkit, globals: [], symbols: [], attributes: [], posted: "refused" };
            // Tamper with everything a tool might call.
            Element.prototype.querySelectorAll = () => [];
            Document.prototype.querySelectorAll = () => [];
            Array.from = () => [];
            JSON.stringify = () => "{}";
            CSSStyleSheet.prototype.insertRule = () => 0;
            window.attack = () => {
              document.getElementById("visible").click();
              document.getElementById("visible").dispatchEvent(new MouseEvent("click", { bubbles: true, detail: 1 }));
              try { window.webkit.messageHandlers.searchDeveloper.postMessage({ kind: "step", step: { type: "click", selectors: [["#x"]] } }); window.probe.posted = "sent"; } catch (e) {}
            };
            setInterval(() => {
              if (typeof window.webkit !== "undefined") window.probe.webkit = typeof window.webkit;
              for (const name of Object.getOwnPropertyNames(window)) {
                if (!before.has(name) && !/^\\d+$/.test(name) && name !== "probe" && name !== "attack" && !window.probe.globals.includes(name)) window.probe.globals.push(name);
              }
              if (Object.getOwnPropertySymbols(window).length !== symbols) window.probe.symbols = ["changed"];
              for (const a of document.documentElement.attributes) if (!attributes.includes(a.name) && !window.probe.attributes.includes(a.name)) window.probe.attributes.push(a.name);
            }, 50);
            </script><iframe src="/frame" title="frame"></iframe></body></html>
            """),
    ]
}

/// The page under what a loaded package puts around it, as the window has it.
private struct StageProbe: View {
    let tab: PageTab
    let browser: Browser

    var body: some View {
        WebStage(page: tab.web).modifier(DevToolsStage(browser: browser))
    }
}
