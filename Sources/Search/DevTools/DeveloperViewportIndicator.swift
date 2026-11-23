import SwiftUI
import WebKit

struct DeveloperCSSViewport: Equatable {
    let width: Int
    let height: Int

    private init?(width: CGFloat, height: CGFloat) {
        guard (1...100_000).contains(width), (1...100_000).contains(height) else { return nil }
        self.width = Int(width.rounded())
        self.height = Int(height.rounded())
    }

    @MainActor
    static func estimate(in web: WKWebView) -> DeveloperCSSViewport? {
        let zoom = max(web.pageZoom, 0.01)
        return DeveloperCSSViewport(width: web.frame.width / zoom, height: web.frame.height / zoom)
    }

    @MainActor
    static func measure(in web: WKWebView) async -> DeveloperCSSViewport? {
        let result = try? await web.callAsyncJavaScript(
            "return [window.innerWidth, window.innerHeight];", arguments: [:], in: nil, contentWorld: .defaultClient
        )
        guard let sides = result as? [Double], sides.count == 2 else { return nil }
        return DeveloperCSSViewport(width: sides[0], height: sides[1])
    }

    var text: String { "\(width) × \(height)" }
}

struct DeveloperViewportIndicator: NSViewRepresentable {
    let web: WKWebView?
    let responsive: Bool
    let dock: DeveloperDockPosition

    func makeNSView(context: Context) -> Indicator { Indicator() }

    func updateNSView(_ view: Indicator, context: Context) {
        view.attach(to: web, responsive: responsive, dock: dock)
    }

    static func dismantleNSView(_ view: Indicator, coordinator: ()) {
        view.attach(to: nil, responsive: false, dock: .bottom)
    }

    final class Indicator: NSView {
        private let badge = NSView()
        private let label = NSTextField(labelWithString: "")
        private weak var web: WKWebView?
        private var frameObservation: NSObjectProtocol?
        private var originalFrameNotifications = true
        private var measurement: Task<Void, Never>?
        private var dismissal: Task<Void, Never>?
        private var responsive = false
        private var dock = DeveloperDockPosition.bottom
        private var lastSize = CGSize.zero
        private var shown = false

        init() {
            super.init(frame: .zero)
            badge.wantsLayer = true
            badge.layer?.cornerRadius = 5
            badge.layer?.cornerCurve = .continuous
            badge.layer?.borderWidth = 0.5
            badge.isHidden = true
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            label.textColor = .labelColor
            badge.addSubview(label)
            addSubview(badge)
            updateColors()
        }

        required init?(coder: NSCoder) { return nil }

        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            placeBadge()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { viewportChanged(force: true) }
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            updateColors()
        }

        func attach(to target: WKWebView?, responsive: Bool, dock: DeveloperDockPosition) {
            let layoutChanged = self.responsive != responsive || self.dock != dock
            self.responsive = responsive
            self.dock = dock
            if web !== target {
                stopObserving()
                web = target
                guard let target else { return }
                originalFrameNotifications = target.postsFrameChangedNotifications
                target.postsFrameChangedNotifications = true
                frameObservation = NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification, object: target, queue: nil
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.viewportChanged() }
                }
                viewportChanged(force: true)
            } else if layoutChanged {
                viewportChanged(force: true)
            }
        }

        private func stopObserving() {
            if let frameObservation { NotificationCenter.default.removeObserver(frameObservation) }
            if frameObservation != nil { web?.postsFrameChangedNotifications = originalFrameNotifications }
            frameObservation = nil
            measurement?.cancel()
            measurement = nil
            dismissal?.cancel()
            dismissal = nil
            shown = false
            badge.isHidden = true
            lastSize = .zero
        }

        private func viewportChanged(force: Bool = false) {
            guard let web, let size = DeveloperCSSViewport.estimate(in: web) else { return }
            guard force || lastSize != web.frame.size else { return }
            lastSize = web.frame.size
            shown = true
            show(size, estimated: true)
            scheduleMeasurement()
            dismissal?.cancel()
            dismissal = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(1_200))
                guard !Task.isCancelled, let self else { return }
                shown = false
                badge.isHidden = true
            }
        }

        private func scheduleMeasurement() {
            guard measurement == nil, let web else { return }
            measurement = Task { [weak self, weak web] in
                try? await Task.sleep(for: .milliseconds(70))
                guard !Task.isCancelled, let web else { return }
                let before = web.frame.size
                let measured = await DeveloperCSSViewport.measure(in: web)
                guard !Task.isCancelled, let self, self.web === web else { return }
                measurement = nil
                guard shown else { return }
                if web.frame.size == before {
                    if let measured { show(measured, estimated: false) }
                } else {
                    scheduleMeasurement()
                }
            }
        }

        private func show(_ size: DeveloperCSSViewport, estimated: Bool) {
            label.stringValue = (estimated ? "≈ " : "") + size.text
            label.setAccessibilityLabel((estimated ? "Approximate viewport: " : "Viewport: ") + size.text + " CSS pixels")
            placeBadge()
        }

        private func placeBadge() {
            guard shown, let web, let window, web.window === window else {
                badge.isHidden = true
                return
            }
            let page = convert(web.bounds, from: web).intersection(bounds)
            guard !page.isNull, page.width > 24, page.height > 24 else {
                badge.isHidden = true
                return
            }
            let size = label.fittingSize
            let width = size.width + 14
            let height = size.height + 8
            badge.frame = CGRect(x: max(page.minX, page.maxX - width - 8), y: page.minY + 8,
                                  width: width, height: height)
            label.frame = CGRect(x: 7, y: 4, width: size.width, height: size.height)
            badge.isHidden = false
        }

        private func updateColors() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                badge.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.94).cgColor
                badge.layer?.borderColor = NSColor.separatorColor.cgColor
            }
        }
    }
}
