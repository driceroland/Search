import AppKit
import SwiftUI
import WebKit

// Where a link goes, at the bottom of the page while the pointer is on it.
//
// Off unless turned on in Settings › General. Off, not a line of it reaches
// a page: the listener is only put into pages while the switch is on.

/// Reports the destination under the pointer to the tab that owns the page.
/// WebKit retains this relay; the tab is weak so closing it releases the page.
final class HoveredLink: NSObject, WKScriptMessageHandler {
    static let name = "link"
    /// Whether pages get the listener. Set from Settings.
    @MainActor static var on = false

    /// For a page already up when it is turned off: its listener goes quiet.
    static let off = "if (window.__searchLinks) window.__searchLinks.on = false;"

    // One passive listener in every frame reports the resolved link address
    // only when it changes. The isolated client world keeps it out of the page's reach.
    static let script = """
    (() => {
        // Turned back on over a page that already has it: the same listener
        // speaks again rather than a second one beside it.
        if (window.__searchLinks) { window.__searchLinks.on = true; return; }
        const state = { on: true };
        window.__searchLinks = state;
        let shown = '';

        function report(address) {
            if (!state.on || address === shown) return;
            shown = address;
            webkit.messageHandlers.link.postMessage(address);
        }

        // The composed path reaches links inside open shadow trees, where `target` stops at the host.
        function linkIn(path) {
            for (const node of path) {
                if (node.nodeType !== 1 || (node.localName !== 'a' && node.localName !== 'area')) continue;
                // An SVG link's href is an object, and its address may be relative.
                const href = typeof node.href === 'string' ? node.href : node.href && node.href.baseVal;
                if (!href) continue;
                try {
                    const address = new URL(href, node.baseURI).href;
                    // A script link goes nowhere worth showing.
                    return address.startsWith('javascript:') ? '' : address.slice(0, 600);
                } catch {
                    return '';
                }
            }
            return '';
        }

        addEventListener('mouseover', event => report(linkIn(event.composedPath())), { passive: true, capture: true });
        // Leaving the frame altogether: there is no next element to enter.
        addEventListener('mouseout', event => { if (!event.relatedTarget) report(''); }, { passive: true, capture: true });
        addEventListener('pagehide', () => report(''));
    })();
    """

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
