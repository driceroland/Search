import AppKit
import ImageIO
import UniformTypeIdentifiers

extension Browser {
    var canAddSiteApp: Bool {
        guard let tab = active, !tab.shy, let url = tab.address else { return false }
        return SiteAppBundle.accepts(url)
    }

    func addSiteApp() {
        guard canAddSiteApp, let tab = active, let url = tab.address, let window = Links.window else { return }
        let title = (try? SiteAppBundle.name(from: tab.title)) ?? url.host ?? "Website"
        let icon = SiteApps.icon(tab.icon)
        let alert = NSAlert()
        alert.messageText = "Add to Dock"
        alert.informativeText = "Create an app for \(url.absoluteString) in your Applications folder, with its own window and sign-ins. After it opens, choose Options → Keep in Dock from its Dock menu."
        alert.addButton(withTitle: "Create App")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: title)
        field.frame = NSRect(x: 0, y: 0, width: 340, height: 24)
        field.setAccessibilityLabel("App name")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] answer in
            guard answer == .alertFirstButtonReturn else { return }
            let name = field.stringValue
            let applications = Store.testing
                ? Store.folder.appendingPathComponent("Site Apps", isDirectory: true)
                : FileManager.default.urls(for: .applicationDirectory, in: .userDomainMask)[0]
            // Signing and writing an app should never hold up a page.
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { () throws -> URL in
                    let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/SearchSite")
                    return try SiteAppBundle.create(name: name, url: url, in: applications,
                                                    helper: helper, browser: .main, icon: icon)
                }
                DispatchQueue.main.async {
                    switch result {
                    case .success(let app):
                        NSWorkspace.shared.openApplication(at: app, configuration: .init()) { _, error in
                            DispatchQueue.main.async {
                                if let error {
                                    SiteApps.failure("The app was created, but could not open", error: error, over: window)
                                    NSWorkspace.shared.activateFileViewerSelecting([app])
                                } else {
                                    self?.announce("App created. Choose Options → Keep in Dock from its Dock menu.")
                                }
                            }
                        }
                    case .failure(let error):
                        SiteApps.failure("Could not create the app", error: error, over: window)
                    }
                }
            }
        }
    }
}

private enum SiteApps {
    static func failure(_ message: String, error: Error, over window: NSWindow) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window)
    }

    /// Only an icon the tab already fetched. Creating an app makes no extra
    /// request to a site or to an icon service.
    static func icon(_ image: NSImage?) -> Data? {
        guard let image else {
            return Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap { try? Data(contentsOf: $0) }
        }
        let canvas = NSImage(size: NSSize(width: 512, height: 512), flipped: false) { rect in
            NSColor.white.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 24, dy: 24), xRadius: 100, yRadius: 100).fill()
            image.draw(in: rect.insetBy(dx: 80, dy: 80))
            return true
        }
        // NSImage renders at the screen's scale. An explicit bitmap keeps
        // ImageIO's ICNS writer at 512 pixels on Retina displays too.
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 512, pixelsHigh: 512,
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                           isPlanar: false, colorSpaceName: .deviceRGB,
                                           bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        canvas.draw(in: NSRect(x: 0, y: 0, width: 512, height: 512))
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = bitmap.cgImage else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.icns.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cg, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
