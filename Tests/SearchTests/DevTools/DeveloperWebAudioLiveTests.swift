import AppKit
import WebKit
import XCTest
@testable import Search

/// The WebAudio tool on a real page: an OscillatorNode connected to the
/// destination shows as two nodes and one edge, a disconnect takes the
/// edge away, and closing DevTools puts the page's constructors back.
@MainActor
final class DeveloperWebAudioLiveTests: XCTestCase {
    func testOscillatorConnectedToDestinationShowsTwoNodesAndOneEdge() async throws {
        _ = NSApplication.shared
        let server = try LocalPageServer([
            "/": .init(type: "text/html", body: "<!doctype html><title>WebAudio fixture</title>"),
        ])
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        Web.inspector(configuration.preferences)
        let page = PageView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let window = NSWindow(contentRect: CGRect(x: -4_000, y: -4_000, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderFrontRegardless()
        defer { window.close() }
        page.load(URLRequest(url: server.url("/")))
        try await DeveloperTestSupport.wait("page to load", in: "DeveloperWebAudioLiveTests") { page.title == "WebAudio fixture" }
        _ = try await page.evaluateJavaScript("""
            window.nativeOffline = window.OfflineAudioContext;
            window.nativeConnect = AudioNode.prototype.connect;
            0
            """)

        let tab = Tab(shy: true)
        let session = DeveloperToolsSession(tab: tab, web: page, after: nil)
        do {
            try await DeveloperTestSupport.wait("inspector", in: "DeveloperWebAudioLiveTests") { session.ready }
            let audio = DeveloperWebAudioModel.model(for: session)
            audio.start()
            XCTAssertTrue(audio.listening)
            try await DeveloperTestSupport.wait("capture to report in", in: "DeveloperWebAudioLiveTests") {
                audio.reportedFrames > 0
            }
            let unnoticed = try await page.evaluateJavaScript("""
                OfflineAudioContext.prototype.constructor === OfflineAudioContext
                    && !Object.keys(window).some((name) => name.toLowerCase().includes('perch'))
                    && /\\[native code\\]/.test(Function.prototype.toString.call(AudioNode.prototype.connect))
                """)
            XCTAssertEqual(unnoticed as? Bool, true)

            _ = try await page.evaluateJavaScript("""
                window.audio = new OfflineAudioContext(1, 44100, 44100);
                window.tone = audio.createOscillator();
                window.connected = tone.connect(audio.destination) === audio.destination;
                0
                """)
            try await DeveloperTestSupport.wait("graph", in: "DeveloperWebAudioLiveTests", state: {
                audio.contexts.map { "\($0.graph.nodes.map(\.type)) \($0.graph.edges.count)" }.joined(separator: "; ")
            }) {
                audio.selected?.graph.nodes.count == 2 && audio.selected?.graph.edges.count == 1
            }
            let context = try XCTUnwrap(audio.selected)
            XCTAssertEqual(context.type, "offline")
            XCTAssertEqual(context.sampleRate, 44_100)
            XCTAssertEqual(Set(context.graph.nodes.map(\.type)), ["OscillatorNode", "AudioDestinationNode"])
            let oscillator = try XCTUnwrap(context.graph.nodes.first { $0.type == "OscillatorNode" })
            XCTAssertTrue(oscillator.params.contains { $0.name == "frequency" && $0.value == 440 })
            let connected = try await page.evaluateJavaScript("connected")
            XCTAssertEqual(connected as? Bool, true)

            // A value set after the node was made shows, as the page has it
            // now. The capture reads values on a timer, which a hidden
            // test window throttles, so this is only checked when visible.
            let hidden = try await page.evaluateJavaScript("tone.frequency.value = 880; document.visibilityState === 'hidden'")
            if hidden as? Bool != true {
                try await DeveloperTestSupport.wait("the new frequency", in: "DeveloperWebAudioLiveTests") {
                    audio.selected?.graph.nodes.first { $0.type == "OscillatorNode" }?
                        .params.contains { $0.name == "frequency" && $0.value == 880 } == true
                }
            }

            _ = try await page.evaluateJavaScript("tone.disconnect(); 0")
            try await DeveloperTestSupport.wait("disconnect", in: "DeveloperWebAudioLiveTests") {
                audio.selected?.graph.edges.isEmpty == true
            }

            // DevTools closing takes the hooks out of the page.
            DeveloperWebAudioModel.closed(session)
            XCTAssertFalse(audio.listening)
            var restored = false
            for _ in 0..<50 {
                let value = try await page.evaluateJavaScript("""
                    window.OfflineAudioContext === window.nativeOffline
                        && AudioNode.prototype.connect === window.nativeConnect
                        && globalThis[Symbol.for('perch.webAudioCapture')] === undefined
                    """)
                restored = value as? Bool == true
                if restored { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertTrue(restored)
        } catch {
            await DeveloperTestSupport.finish(session, page: page, keeping: tab, server)
            throw error
        }
        await DeveloperTestSupport.finish(session, page: page, keeping: tab, server)
    }
}
