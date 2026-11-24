import AppKit
import WebKit
import XCTest
@testable import Search

/// Drawer tools on a real page, end to end: a Uint8Array revealed in the
/// Memory inspector reads its bytes; the Protocol monitor's raw command
/// goes out and shows its answer; Media logs a muted clip's playback.
@MainActor
final class DeveloperDrawerPathsLiveTests: XCTestCase {
    private static let fixture = """
        <!doctype html><title>Drawer paths fixture</title><p>paths</p>
        <script>
        window.buf = new Uint8Array([72, 101, 108, 108, 111, 0, 1, 2, 3, 250]);
        // A quarter second of silent 8 kHz mono WAV, made here.
        window.silentClip = () => {
            const samples = 2000, data = new DataView(new ArrayBuffer(44 + samples));
            const text = (at, value) => [...value].forEach((c, i) => data.setUint8(at + i, c.charCodeAt(0)));
            text(0, "RIFF"); data.setUint32(4, 36 + samples, true); text(8, "WAVE"); text(12, "fmt ");
            data.setUint32(16, 16, true); data.setUint16(20, 1, true); data.setUint16(22, 1, true);
            data.setUint32(24, 8000, true); data.setUint32(28, 8000, true); data.setUint16(32, 1, true);
            data.setUint16(34, 8, true); text(36, "data"); data.setUint32(40, samples, true);
            for (let i = 0; i < samples; i++) data.setUint8(44 + i, 128);
            return URL.createObjectURL(new Blob([data.buffer], {type: "audio/wav"}));
        };
        </script>
        """

    func testAUint8ArrayRevealedInTheMemoryInspectorReadsItsBytes() async throws {
        let live = try await open()
        defer { live.window.close() }
        try await live.run {
            let reply = try await live.session.command("Runtime.evaluate", [
                "expression": "window.buf", "objectGroup": "console",
            ], targetID: live.session.runtimeTargetID)
            let result = try XCTUnwrap(reply["result"] as? [String: Any])
            let objectId = try XCTUnwrap(result["objectId"] as? String)
            DeveloperMemoryInspectorModel.reveal(session: live.session, objectId: objectId, targetID: live.session.runtimeTargetID,
                                                 className: result["className"] as? String,
                                                 description: result["description"] as? String)
            let model = DeveloperMemoryInspectorModel.model(for: live.session)
            try await wait("the buffer's bytes", state: { "buffers \(model.buffers.map { "\($0.title) \($0.length) \($0.bytes.prefix(10))" }), problem \(model.problem ?? "none")" }) {
                model.selected?.bytes.count ?? 0 >= 10
            }
            let buffer = try XCTUnwrap(model.selected)
            XCTAssertEqual(buffer.className, "Uint8Array")
            XCTAssertEqual(buffer.length, 10)
            XCTAssertEqual(Array(buffer.bytes.prefix(10)), [72, 101, 108, 108, 111, 0, 1, 2, 3, 250])

            // A byte written in the inspector lands in the page's array.
            model.write(0, value: 74)
            try await wait("the write in the page") {
                false
            } orAsync: {
                (try? await self.page(live.page, "return buf[0];") as? Int) == 74
            }

            // A view on the same memory reuses the tab, its own bytes highlighted, as in Chrome.
            let viewReply = try await live.session.command("Runtime.evaluate", [
                "expression": "new DataView(buf.buffer, 2, 4)", "objectGroup": "console",
            ], targetID: live.session.runtimeTargetID)
            let view = try XCTUnwrap(viewReply["result"] as? [String: Any])
            let viewID = try XCTUnwrap(view["objectId"] as? String)
            DeveloperMemoryInspectorModel.reveal(session: live.session, objectId: viewID, targetID: live.session.runtimeTargetID,
                                                 className: view["className"] as? String,
                                                 description: view["description"] as? String)
            try await wait("the view in the same tab", state: { "buffers \(model.buffers.map { "\($0.title) \($0.regionStart)+\($0.regionLength)" })" }) {
                model.selected?.regionStart == 2
            }
            XCTAssertEqual(model.buffers.count, 1)
            XCTAssertEqual(model.selected?.id, buffer.id)
            XCTAssertEqual(model.selected?.regionLength, 4)
            model.close(buffer.id)
        }
    }

    func testARawCommandFromTheProtocolMonitorShowsItsAnswer() async throws {
        let live = try await open()
        defer { live.window.close() }
        let monitor = live.session.protocolMonitor
        monitor.viewerOpened()
        defer { monitor.viewerClosed() }
        try await live.run {
            live.session.sendRawProtocolCommand(method: "Runtime.evaluate",
                                                parameters: #"{"expression": "6 * 7", "returnByValue": true}"#, target: "")
            try await wait("the answer in the monitor", state: { "entries \(monitor.entries.map { "\($0.method) \($0.response?.prefix(80) ?? "-")" })" }) {
                monitor.entries.contains { $0.method == "Runtime.evaluate" && $0.response?.contains("42") == true }
            }
            let entry = try XCTUnwrap(monitor.entries.last { $0.method == "Runtime.evaluate" && $0.params.contains("6 * 7") })
            XCTAssertNil(entry.error)
            XCTAssertNotNil(entry.elapsed)

            // Parameters that aren't a JSON object don't go out.
            let count = monitor.entries.count
            live.session.sendRawProtocolCommand(method: "Runtime.evaluate", parameters: "[1, 2]", target: "")
            XCTAssertEqual(live.session.message, "The parameters aren’t a JSON object.")
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(monitor.entries.filter { $0.direction == .sent }.count,
                           monitor.entries.prefix(count).filter { $0.direction == .sent }.count)
        }
    }

    func testMediaLogsAClipsPlayback() async throws {
        let live = try await open()
        defer { live.window.close() }
        let media = DeveloperMediaModel.model(for: live.session)
        media.start()
        defer { media.stop() }
        try await live.run {
            try await wait("Media listening", state: { "problem \(media.problem ?? "none")" }) { media.listening }
            _ = try await page(live.page, """
                const audio = document.createElement("audio");
                audio.id = "clip"; audio.muted = true; audio.src = silentClip();
                document.body.append(audio);
                await audio.play();
                return true;
                """)
            try await wait("the player and its events", seconds: 10, state: {
                "players \(media.players.map { "\($0.id) \($0.tag) \($0.duration ?? -1)" }), events \(media.players.map { media.log($0.id).map(\.name) })"
            }) {
                media.players.contains { player in
                    player.tag == "audio" && Set(media.log(player.id).map(\.name)).isSuperset(of: ["play", "playing", "ended"])
                }
            }
            let player = try XCTUnwrap(media.players.first { $0.tag == "audio" })
            XCTAssertEqual(player.duration ?? 0, 0.25, accuracy: 0.01)
            let names = media.log(player.id).map(\.name)
            XCTAssertLessThan(try XCTUnwrap(names.firstIndex(of: "play")), try XCTUnwrap(names.firstIndex(of: "ended")))
        }
    }

    /// Sensors: a location and an orientation reach the page's own APIs.
    func testSensorLocationAndOrientationReachThePage() async throws {
        let live = try await open()
        defer { live.window.close() }
        try await live.run {
            var state = DeveloperToolsSensors.State()
            state.location = .coordinates(latitude: 52.52, longitude: 13.405, accuracy: 150)
            state.orientation = .init(alpha: 90, beta: 45, gamma: -30)
            live.session.applySensors(state)
            // Asked before the override is in, the page would wait on the
            // real permission prompt.
            try await wait("the overrides applied") { live.session.sensorOverride == state }
            try await wait("the location in the page") {
                false
            } orAsync: {
                let coords = try? await self.page(live.page, """
                    return await new Promise((done) => navigator.geolocation.getCurrentPosition(
                        (p) => done([p.coords.latitude, p.coords.longitude, p.coords.accuracy]),
                        (e) => done(["error", e.code]), {timeout: 2000}));
                    """) as? [Double]
                return coords == [52.52, 13.405, 150]
            }
            try await wait("the orientation in the page") {
                false
            } orAsync: {
                let angles = try? await self.page(live.page, """
                    return await new Promise((done) => {
                        addEventListener("deviceorientation", (e) => done([e.alpha, e.beta, e.gamma]), {once: true});
                        setTimeout(() => done(null), 1500);
                    });
                    """) as? [Double]
                return angles == [90, 45, -30]
            }
            live.session.resetSensors()
        }
    }

    /// Network conditions: Disable cache sends requests with no-cache, and a
    /// throttling preset holds each request for its latency.
    func testDisableCacheAndThrottlingReachTheRequests() async throws {
        let live = try await open(extra: ["/cached.txt": .init(type: "text/plain", body: "cached")])
        defer { live.window.close() }
        let session = live.session
        try await live.run {
            let fetch = #"const t = performance.now(); await (await fetch("/cached.txt")).text(); return performance.now() - t;"#
            _ = try await page(live.page, fetch)
            let before = [live.server.header("Cache-Control", of: "/cached.txt"), live.server.header("Pragma", of: "/cached.txt")]
            XCTAssertEqual(before, [nil, nil])
            session.setCacheDisabled(true)
            try await wait("cache disabled") { session.cacheDisabled }
            _ = try await page(live.page, fetch)
            let after = [live.server.header("Cache-Control", of: "/cached.txt"), live.server.header("Pragma", of: "/cached.txt")]
            // As Chrome's: requests ask past every cache.
            XCTAssertEqual(after, ["no-cache", "no-cache"])

            session.setNetwork(.fast4G)
            try await wait("Fast 4G") { session.throttle == .fast4G }
            let throttledValue = try await page(live.page, fetch)
            let throttled = try XCTUnwrap(throttledValue as? Double)
            XCTAssertGreaterThanOrEqual(throttled, DeveloperToolsSession.NetworkCondition.fast4G.latency - 5)

            session.setNetwork(.unrestricted)
            try await wait("no throttling") { session.throttle == .unrestricted }
            let freeValue = try await page(live.page, fetch)
            let free = try XCTUnwrap(freeValue as? Double)
            XCTAssertLessThan(free, DeveloperToolsSession.NetworkCondition.fast4G.latency)
            session.setCacheDisabled(false)
        }
    }

    // MARK: Support

    private typealias Live = DeveloperLivePage

    private func open(extra: [String: LocalPageServer.Page] = [:]) async throws -> Live {
        try await Live.open(["/": .init(type: "text/html", body: Self.fixture)].merging(extra) { $1 },
                            title: "Drawer paths fixture",
                            configure: { $0.mediaTypesRequiringUserActionForPlayback = [] },
                            wait: { try await wait($0, until: $1) })
    }

    private func page(_ page: WKWebView, _ body: String) async throws -> Any? {
        try await page.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
    }

    private func wait(_ action: String, seconds: Double = 8, state: (() -> String)? = nil,
                      until condition: () -> Bool) async throws {
        try await DeveloperTestSupport.wait(action, seconds: seconds, in: "DeveloperDrawerPathsLiveTests",
                                            state: state ?? { "" }, until: condition)
    }

    /// Waits for an async check, polling.
    private func wait(_ action: String, seconds: Double = 8, until _: () -> Bool,
                      orAsync check: () async -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if await check() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Timed out waiting for \(action)")
    }
}
