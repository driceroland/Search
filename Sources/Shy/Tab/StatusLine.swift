import AppKit
import SwiftUI
import WebKit

// Where a link goes, at the bottom of the page while the pointer is on it.

/// Reports the destination under the pointer to the tab that owns the page.
/// WebKit retains this relay; the tab is weak so closing it releases the page.
final class HoveredLink: NSObject, WKScriptMessageHandler {
    static let name = "link"
    // One passive listener in every frame reports the resolved link address
    // only when it changes. The isolated client world keeps it out of the page's reach.
    static let script = Scripts.load("status-line")

    weak var tab: Tab?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let address = message.body as? String else { return }
        MainActor.assumeIsolated {
            guard let tab, message.webView === tab.built else { return }
            tab.onLink?(tab, address.isEmpty ? nil : address)
        }
    }
}

/// Holds one link destination for the page overlay. Only a page's message
/// causes a redraw: nothing here watches the pointer move.
@MainActor
final class LinkStatus: ObservableObject {
    @Published private(set) var destination: String?
    @Published private(set) var onRight = false
    /// The page the link is on — with two pages up, the bubble stands over
    /// that one (see PaneLayers).
    @Published private(set) var page: ObjectIdentifier?
    private var hiding: DispatchWorkItem?

    /// `page`: the view the page is drawn in, to learn where the pointer is.
    func show(_ address: String?, over page: NSView?) {
        hiding?.cancel()
        guard let address else {
            let work = DispatchWorkItem { [weak self] in self?.dismiss() }
            hiding = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
            return
        }
        if destination != address { destination = address }
        let id = page.map(ObjectIdentifier.init)
        if self.page != id { self.page = id }
        if let page { place(over: page) }
    }

    /// A tab change or navigation clears the old destination without waiting.
    func dismiss() {
        hiding?.cancel()
        hiding = nil
        if destination != nil { destination = nil }
    }

    /// A link under the bubble's corner gets the bubble in the other one.
    /// The pointer is asked where it is once, as the link under it changes,
    /// rather than followed on every move.
    private func place(over page: NSView) {
        guard let window = page.window else { return }
        let point = page.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let size = page.bounds.size
        let fromBottom = page.isFlipped ? size.height - point.y : point.y
        let right = fromBottom < 50 && point.x < min(size.width * 0.6, 640) + 22
        if onRight != right { onRight = right }
    }
}

/// A small, click-through address card at the page's bottom edge. If the
/// pointer is there, it sits at the other corner instead.
struct LinkBubble: View {
    @ObservedObject var status: LinkStatus
    /// With two pages up, the one this bubble stands over: it shows only a
    /// link on that page.
    var page: NSView? = nil

    var body: some View {
        GeometryReader { space in
            if let address = status.destination, page.map({ status.page == ObjectIdentifier($0) }) ?? true {
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
