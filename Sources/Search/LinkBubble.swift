import AppKit
import SwiftUI
import WebKit

/// Reports the destination under the pointer to the tab that owns the page.
/// WebKit retains this relay; the tab is weak so closing it releases the page.
final class HoveredLink: NSObject, WKScriptMessageHandler {
    static let name = "link"
    static let script = (Bundle.module.url(forResource: "HoveredLink", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }) ?? ""

    weak var tab: Tab?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let address = message.body as? String else { return }
        MainActor.assumeIsolated {
            guard let tab, message.webView === tab.built else { return }
            tab.onLink?(tab, address.isEmpty ? nil : address)
        }
    }
}

/// Holds one link destination for the page overlay. Only changes from a page
/// cause a redraw; pointer movements only matter when they cross the bubble.
@MainActor
final class LinkStatus: ObservableObject {
    @Published private(set) var destination: String?
    @Published private(set) var onRight = false
    private var hiding: DispatchWorkItem?
    private var mouseMonitor: Any?

    func show(_ address: String?) {
        hiding?.cancel()
        guard let address else {
            let work = DispatchWorkItem { [weak self] in self?.dismiss() }
            hiding = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
            return
        }
        if destination != address { destination = address }
        if mouseMonitor == nil {
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
                if event.window === Links.window { self?.place(for: event.locationInWindow) }
                return event
            }
        }
        if let window = Links.window { place(for: window.mouseLocationOutsideOfEventStream) }
    }

    /// A tab change or navigation clears the old destination without waiting.
    func dismiss() {
        hiding?.cancel()
        hiding = nil
        destination = nil
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
    }

    private func place(for point: NSPoint) {
        guard let width = Links.window?.contentView?.bounds.width else { return }
        let right = point.y < 50 && point.x < min(width * 0.6, 640) + 22
        if onRight != right { onRight = right }
    }
}

/// A small, click-through address card at the page's bottom edge. If the
/// pointer is there, it sits at the other corner instead.
struct LinkBubble: View {
    @ObservedObject var status: LinkStatus

    var body: some View {
        GeometryReader { space in
            if let address = status.destination {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    HStack(spacing: 0) {
                        if status.onRight { Spacer(minLength: 0) }
                        Text(address)
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal, 11)
                            .frame(height: 26)
                            .background(Palette.ground, in: Capsule())
                            .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
                            .shadow(color: .black.opacity(0.08), radius: 12, y: 3)
                            .frame(maxWidth: min(space.size.width * 0.6, 640),
                                   alignment: status.onRight ? .trailing : .leading)
                        if !status.onRight { Spacer(minLength: 0) }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
                .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.12), value: status.destination == nil)
    }
}
