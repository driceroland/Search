import AppKit
import WebKit

// Develop › Capture screenshot, Capture full size screenshot and Capture node
// screenshot, as Chrome DevTools has them in its command menu (the node one
// also in the Elements panel's menu on a node). Each is a PNG at the
// screen's resolution, saved to the downloads folder as "Screenshot
// <host> <date>.png" and shown in the Finder, the way Chrome saves its own.
// Nothing goes on the clipboard and nothing is sent anywhere.
//
// Took the place of Search's Capture… (Snap.swift): its arithmetic for a
// whole page is kept here. takeSnapshot paints only what the page has on
// screen and leaves the rest of a long page white, so a full size
// screenshot is drawn from the PDF WebKit makes of the whole document.

enum DeveloperScreenshot {
    /// The tallest picture taken, in points: past it, a page that keeps
    /// loading more as it is scrolled has no end.
    static let tallest: CGFloat = 30_000
    /// The most pixels a picture may have, about 256 MB as WebKit draws it.
    static let budget: CGFloat = 64_000_000

    /// "Screenshot example.com 2026-11-22 at 14.03.22.png". No host for a
    /// private tab's, which would give the site away in the Downloads folder.
    static func fileName(host: String?, date: Date = Date(), in zone: TimeZone = .current) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = zone
        format.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        var site = host ?? ""
        if site.hasPrefix("www.") { site.removeFirst(4) }
        site = String(site.map { "/\\:?*\"<>|".contains($0) ? "_" : $0 })
        return ["Screenshot", site, format.string(from: date)].filter { !$0.isEmpty }.joined(separator: " ") + ".png"
    }

    /// The picture as a PNG at its full resolution, tagged with its size in
    /// points so a Retina screenshot opens at the size it was on screen.
    static func png(_ image: NSImage) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        if image.size.width > 0, image.size.height > 0 { rep.size = image.size }
        return rep.representation(using: .png, properties: [:])
    }

    /// Written under a name not yet taken in `folder`, and shown in the Finder.
    @discardableResult @MainActor
    static func save(_ png: Data, host: String?, in folder: URL) throws -> URL {
        let file = Browser.free(fileName(host: host), in: folder)
        try png.write(to: file, options: .atomic)
        // Not on a test run, which never brings the Finder forward.
        if !Store.testing { NSWorkspace.shared.activateFileViewerSelecting([file]) }
        return file
    }

    /// A whole page, from the PDF WebKit makes of it: how big to draw it.
    /// `scale` is pixels a point: the screen's, or less for a picture past
    /// `budget`. Nil for a page with no size.
    static func raster(_ page: CGSize, backing: CGFloat) -> (size: CGSize, scale: CGFloat, cropped: Bool)? {
        guard page.width >= 2, page.height >= 2 else { return nil }
        let size = CGSize(width: page.width.rounded(.down), height: min(page.height, tallest).rounded(.down))
        var scale = backing
        let pixels = size.width * size.height * scale * scale
        if pixels > budget { scale = (budget / (size.width * size.height)).squareRoot() }
        return (size, scale, page.height > tallest)
    }

    /// The first page of a PDF as a bitmap, on white as the page's own
    /// ground is.
    static func draw(pdf data: Data, backing: CGFloat) -> (image: NSImage, cropped: Bool)? {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider), let first = document.page(at: 1) else { return nil }
        let box = first.getBoxRect(.mediaBox)
        guard let plan = raster(box.size, backing: backing) else { return nil }
        let (size, scale, cropped) = plan
        let wide = Int((size.width * scale).rounded(.down)), high = Int((size.height * scale).rounded(.down))
        guard wide > 0, high > 0, let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: wide, height: high, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: wide, height: high))
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        // PDF space runs up from the bottom: the page's top is lined up with
        // the bitmap's, so a page cut short keeps its top.
        context.translateBy(x: -box.minX, y: size.height - box.maxY)
        context.drawPDFPage(first)
        guard let cg = context.makeImage() else { return nil }
        return (NSImage(cgImage: cg, size: size), cropped)
    }

    /// The rectangle dragged from `start` to `end`, kept inside `bounds`;
    /// nil when it is too small to be a picture (a click, not a drag).
    static func area(from start: CGPoint, to end: CGPoint, in bounds: CGRect) -> CGRect? {
        let dragged = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                             width: abs(end.x - start.x), height: abs(end.y - start.y))
        let kept = dragged.intersection(bounds).integral
        guard !kept.isNull, kept.width >= 2, kept.height >= 2 else { return nil }
        return kept
    }
}

/// The layer Capture area screenshot puts over the page while a rectangle
/// is dragged: the page dimmed, the rectangle clear with a border and its
/// size beside it.
@MainActor
final class DeveloperAreaCapture: NSView {
    private var start: CGPoint?
    private var current: CGPoint?
    private var finish: ((CGRect?) -> Void)?
    private weak var previousResponder: NSResponder?

    /// Puts the layer over `web`; `done` gets the rectangle in the web
    /// view's coordinates, or nil when it was cancelled.
    static func begin(on web: WKWebView, done: @escaping (CGRect?) -> Void) {
        web.subviews.compactMap { $0 as? DeveloperAreaCapture }.forEach { $0.end(nil) }
        let layer = DeveloperAreaCapture(frame: web.bounds)
        layer.autoresizingMask = [.width, .height]
        layer.finish = done
        layer.previousResponder = web.window?.firstResponder
        web.addSubview(layer)
        web.window?.makeFirstResponder(layer)
        layer.setAccessibilityRole(.layoutArea)
        layer.setAccessibilityLabel("Drag to capture an area of the page. Press Escape to cancel.")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    private var selection: CGRect? {
        guard let start, let current else { return nil }
        return DeveloperScreenshot.area(from: start, to: current, in: bounds)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.3).setFill()
        let shade = NSBezierPath(rect: bounds)
        if let selection {
            shade.append(NSBezierPath(rect: selection))
            shade.windingRule = .evenOdd
        }
        shade.fill()
        guard let selection else { return }
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
        let label = "\(Int(selection.width)) × \(Int(selection.height))" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = label.size(withAttributes: attributes)
        var origin = CGPoint(x: selection.minX, y: selection.maxY + 4)
        if origin.y + size.height + 4 > bounds.maxY { origin.y = selection.minY - size.height - 8 }
        let back = CGRect(x: origin.x, y: origin.y, width: size.width + 8, height: size.height + 4)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: back, xRadius: 3, yRadius: 3).fill()
        label.draw(at: CGPoint(x: back.minX + 4, y: back.minY + 2), withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        guard let selection, let web = superview else { return end(nil) }
        end(convert(selection, to: web))
    }

    override func rightMouseDown(with event: NSEvent) { end(nil) }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { end(nil) } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { end(nil) }

    private func end(_ rect: CGRect?) {
        let done = finish
        finish = nil
        let window = self.window
        removeFromSuperview()
        if let previousResponder, window?.firstResponder == nil || window?.firstResponder === window {
            window?.makeFirstResponder(previousResponder)
        }
        // After the layer is gone, so it isn't in the picture.
        if let done { DispatchQueue.main.async { done(rect) } }
    }
}

extension Browser {
    /// Whether the tab in front has a page to take a picture of.
    var canCaptureScreenshot: Bool { active?.isWeb == true }

    /// Whether DevTools is open on the tab in front with a node picked.
    var canCaptureNodeScreenshot: Bool {
        guard let session = DeveloperTools.shared.session, let tab = active else { return false }
        return session.tab === tab && session.selectedNode != nil
    }

    /// The page in front to take a picture of, the host to name it by (none
    /// for a private tab) and the folder it goes in.
    private var screenshotTarget: (web: PageView, host: String?, folder: URL)? {
        guard let tab = active, tab.isWeb else { return nil }
        return (tab.web, tab.shy ? nil : tab.web.url?.host(), downloadsFolder)
    }

    /// Capture screenshot: what the page shows now, as it is on screen.
    func captureScreenshot() {
        guard let target = screenshotTarget else { return }
        snapshot(target.web, nil, host: target.host, in: target.folder)
    }

    /// Capture full size screenshot: the whole page, top to bottom.
    func captureFullSizeScreenshot() {
        guard let target = screenshotTarget else { return }
        let web = target.web, host = target.host, folder = target.folder
        let backing = web.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        web.createPDF(configuration: WKPDFConfiguration()) { [weak self] result in
            MainActor.assumeIsolated {
                switch result {
                case .success(let pdf):
                    guard let drawn = DeveloperScreenshot.draw(pdf: pdf, backing: backing) else {
                        self?.screenshotFailed(); return
                    }
                    self?.keepScreenshot(drawn.image, host: host, in: folder, cropped: drawn.cropped)
                case .failure:
                    self?.screenshotFailed()
                }
            }
        }
    }

    /// Capture node screenshot: the node picked in DevTools' Elements panel.
    func captureNodeScreenshot() {
        guard canCaptureNodeScreenshot, let session = DeveloperTools.shared.session,
              let node = session.selectedNode else {
            announce("Pick a node in the Elements panel first")
            return
        }
        session.captureScreenshot(node)
    }

    /// Capture area screenshot: drag a rectangle over the page, and what is
    /// inside it is saved as the other screenshots are. Esc or a click
    /// without a drag cancels.
    func captureAreaScreenshot() {
        guard let target = screenshotTarget else { return }
        let host = target.host, folder = target.folder
        DeveloperAreaCapture.begin(on: target.web) { [weak self, weak web = target.web] rect in
            guard let self, let web, let rect else { return }
            let configuration = WKSnapshotConfiguration()
            configuration.rect = rect
            snapshot(web, configuration, host: host, in: folder)
        }
    }

    /// The page's snapshot (of `configuration`'s rect, or what it shows), kept.
    private func snapshot(_ web: WKWebView, _ configuration: WKSnapshotConfiguration?, host: String?, in folder: URL) {
        web.takeSnapshot(with: configuration) { [weak self] image, _ in
            MainActor.assumeIsolated {
                guard let image else { self?.screenshotFailed(); return }
                self?.keepScreenshot(image, host: host, in: folder)
            }
        }
    }

    private func keepScreenshot(_ image: NSImage, host: String?, in folder: URL, cropped: Bool = false) {
        guard let png = DeveloperScreenshot.png(image) else { return screenshotFailed() }
        do {
            let file = try DeveloperScreenshot.save(png, host: host, in: folder)
            announce(cropped ? "The top of the page saved to \(folder.lastPathComponent)"
                             : "Saved to \(folder.lastPathComponent)", file: file)
        } catch {
            screenshotFailed()
        }
    }

    private func screenshotFailed() {
        announce("Couldn't capture this page")
    }
}
