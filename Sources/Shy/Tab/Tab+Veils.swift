import Combine
import ImageIO
import SwiftUI
import WebKit

// Taking things off the page (Curtain.swift): the tab's side of it.
extension Tab {
    /// What gets injected into the *next* document: the scroll reporter, the
    /// pointing mode, and this site's stylesheet of things you have hidden. The
    /// stylesheet goes in before the document has a body, so nothing is ever
    /// seen arriving and then leaving again.
    /// `to`: where the next document comes from, when that isn't the page up
    /// now (a navigation just decided). Dark pages hand that one site's
    /// answer over, and nothing at all to a page that isn't to be darkened.
    func arm(hiding css: String, to url: URL? = nil) {
        veils = css
        guard let built else { return }
        let controller = built.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(PopupGestureRelay.userScript)
        controller.addUserScript(
            WKUserScript(source: ScrollRelay.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Web.world)
        )
        controller.addUserScript(
            WKUserScript(source: Veiling.picker, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Web.world)
        )
        controller.addUserScript(
            WKUserScript(source: FormRelay.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Web.world)
        )
        controller.addUserScript(
            WKUserScript(source: IconRelay.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Web.world)
        )
        if AutoScroll.on {
            controller.addUserScript(
                WKUserScript(source: AutoScroll.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Web.world)
            )
        }
        // Every frame: a swipe over an embedded map is the map's, and only the
        // map's own document can say so.
        controller.addUserScript(
            WKUserScript(source: Swipe.watch, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Web.world)
        )
        controller.addUserScript(
            WKUserScript(source: ImageRelay.watch, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Web.world)
        )
        // Every frame, in Shy's world: a paused video gives the media keys
        // back (see MediaKeys.swift).
        controller.addUserScript(
            WKUserScript(source: MediaKeys.watch, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Web.world)
        )
        // The store's "Add to Shy" only where Shy can add extensions.
        // Before macOS 15.4 it was drawn all the same, and pressing it did
        // nothing at all; Settings › Extensions says what they need instead.
        if #available(macOS 15.4, *) {
            controller.addUserScript(
                WKUserScript(source: StoreRelay.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Web.world)
            )
        }
        controller.addUserScript(WKUserScript(
            source: HoveredLink.script, injectionTime: .atDocumentStart,
            forMainFrameOnly: false, in: .defaultClient
        ))
        // The main frame only: a middle-click on a link inside an ad iframe is
        // that frame's own business, and its link is not this tab's to open.
        controller.addUserScript(
            WKUserScript(source: MiddleRelay.watch, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Web.world)
        )
        // Every frame, in the page's own world and ahead of its scripts: a
        // live player's speed nudges go through it (see LiveRate.swift).
        controller.addUserScript(
            WKUserScript(source: LiveRate.script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
        )
        // Every frame, in the page's own world: a page an extension lists
        // reaches it as chrome.runtime (see ExtensionExternal.swift).
        if #available(macOS 15.4, *), let external = ExtensionExternal.script(shy: shy, in: Extensions.owner(of: extensionController)) {
            controller.addUserScript(
                WKUserScript(source: external, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
            )
        }
        // Passkeys stand in the page's own world — they replace the page's
        // functions — and reach Shy through a bridge in Shy's, off or on:
        // an extension's page script can carry the patch either way (see
        // Passkeys.swift and ExtensionShims.passkeys).
        if !FormRelay.passkeysOffered {
            controller.addUserScript(
                WKUserScript(source: FormRelay.withoutPasskeys, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
            )
        } else {
            controller.addUserScript(
                WKUserScript(source: PasskeyRelay.page, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
            )
        }
        controller.addUserScript(
            WKUserScript(source: PasskeyRelay.bridge, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Web.world)
        )
        // Every frame but the top, only while Translate Page is switched on:
        // a frame of another site says it's there, to be translated too.
        if PageTranslator.enabled {
            controller.addUserScript(
                WKUserScript(source: PageTranslator.announce, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: Web.world)
            )
        }
        // Only with Developer Mode on for this tab: what its bar says of the
        // page (see DeveloperBar.swift).
        DevTools.arm(controller, for: self, to: url)
        guard !css.isEmpty else { return }
        controller.addUserScript(
            WKUserScript(source: Veiling.style(css), injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Web.world)
        )
    }

    /// The same stylesheet, for the page that is already up.
    func applyVeils(_ css: String) {
        built?.evaluateInShy(Veiling.style(css))
    }

    func startPicking() { web.evaluateInShy("window.__officeVeil && window.__officeVeil.on()") }

    func stopPicking() { web.evaluateInShy("window.__officeVeil && window.__officeVeil.off()") }
}
