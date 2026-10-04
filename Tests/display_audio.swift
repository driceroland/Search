// Probe the installed WebKit with synthetic capture devices only (#540).
// swiftc Tests/display_audio.swift -o build/display-audio-probe && build/display-audio-probe
// No screen, microphone, or system audio is captured; nothing is sent over a network.
import AppKit
import WebKit

final class Probe: NSObject, WKNavigationDelegate {
    let web: WKWebView
    let window: NSWindow
    var results: [[String: Any]] = []

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        // Fail closed if a future WebKit removes the test hooks.
        for (key, value) in [("mockCaptureDevicesEnabled", true), ("mockCaptureDevicesPromptEnabled", false),
                             ("screenCaptureEnabled", true), ("mediaDevicesEnabled", true),
                             ("getUserMediaRequiresFocus", false), ("mediaCaptureRequiresSecureConnection", false)] {
            let setter = NSSelectorFromString("_set" + key.prefix(1).uppercased() + key.dropFirst() + ":")
            guard config.preferences.responds(to: setter) else {
                fputs("Missing WebKit test hook: \(key)\n", stderr)
                exit(2)
            }
            typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(config.preferences.method(for: setter), to: Setter.self)(config.preferences, setter, value)
        }
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480), configuration: config)
        window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 640, height: 480),
                          styleMask: .borderless, backing: .buffered, defer: false)
        super.init()
        let occlusion = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        guard web.responds(to: occlusion) else { exit(2) }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(web.method(for: occlusion), to: Setter.self)(web, occlusion, false)
        web.navigationDelegate = self
        window.contentView = web
        window.orderBack(nil)
        web.loadHTMLString("<!doctype html><title>Synthetic capture probe</title>", baseURL: URL(string: "https://example.test"))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        capture(audio: false)
    }

    func capture(audio: Bool, microphone: Bool = false) {
        web.callAsyncJavaScript("""
            const stream = microphone
                ? await navigator.mediaDevices.getUserMedia({ audio: true })
                : await navigator.mediaDevices.getDisplayMedia({ video: true, audio });
            try {
                return { source: microphone ? 'microphone' : 'display', requestedAudio: audio, videoTracks: stream.getVideoTracks().length,
                         audioTracks: stream.getAudioTracks().length, userAgent: navigator.userAgent };
            } finally { stream.getTracks().forEach(track => track.stop()); }
            """, arguments: ["audio": audio, "microphone": microphone], in: nil, in: .page) { result in
                switch result {
                case .success(let value):
                    guard let value = value as? [String: Any] else { exit(2) }
                    self.results.append(value)
                    if !audio { self.capture(audio: true); return }
                    if !microphone { self.capture(audio: true, microphone: true); return }
                    guard value["audioTracks"] as? Int == 1,
                          self.results.prefix(2).allSatisfy({ $0["videoTracks"] as? Int == 1 }) else {
                        fputs("Synthetic capture controls failed\n", stderr); exit(2)
                    }
                    do {
                        let data = try JSONSerialization.data(withJSONObject: self.results, options: [.prettyPrinted, .sortedKeys])
                        print(String(decoding: data, as: UTF8.self))
                        exit(0)
                    } catch { fputs("\(error)\n", stderr); exit(2) }
                case .failure(let error):
                    fputs("Capture probe failed: \(error)\n", stderr)
                    exit(2)
                }
            }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let probe = Probe()
DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
    fputs("Capture probe timed out\n", stderr)
    exit(2)
}
app.run()
