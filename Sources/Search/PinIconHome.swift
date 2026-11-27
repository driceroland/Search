import AppKit
import SwiftUI

// A pinned row's icon, once the pin has wandered from the page it was
// pinned at: a click on the icon takes it back home, as Arc's pinned tabs
// do (idea 1076). The square of a pin you're on already goes home on a
// double-click, and the row's menu has Back to Pinned Page; the row itself
// keeps its own click (the address, or the tab), so only the icon answers,
// and only while there is somewhere to go back to. Under the pointer the
// icon becomes a back arrow, to say so.

struct PinIconHome: ViewModifier {
    let browser: Browser
    @ObservedObject var tab: Tab
    /// The column's own row, not the map of every space's rows, and not
    /// while its address is being typed.
    let enabled: Bool
    @State private var hovering = false

    /// A pinned row away from its page.
    static func wandered(_ tab: Tab) -> Bool {
        guard tab.pin != nil, tab.listed, let home = tab.home, let address = tab.address else { return false }
        return !Browser.samePage(home, address)
    }

    /// The icon clicked: the pin picked if it wasn't the tab on screen, and
    /// taken back to its page. False, and nothing done, for a pin at home,
    /// whose icon is the row's like any other.
    @discardableResult
    static func clicked(_ tab: Tab, in browser: Browser) -> Bool {
        guard wandered(tab) else { return false }
        browser.clearTabSelection()
        if browser.activeID != tab.id { browser.select(tab) }
        browser.goHome(tab)
        return true
    }

    func body(content: Content) -> some View {
        if enabled && PinIconHome.wandered(tab) {
            content
                .opacity(hovering ? 0 : 1)
                .overlay {
                    if hovering {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Palette.muted)
                    }
                }
                .padding(3)
                .contentShape(Rectangle())
                .padding(-3)
                .onHover { hovering = $0 }
                .help("Back to Pinned Page")
                // Before the row's own click: a gesture on the icon is asked
                // first, so the row's click doesn't also open the address.
                .onTapGesture {
                    guard TabClick.flags.intersection([.command, .shift, .option, .control]).isEmpty else { return }
                    PinIconHome.clicked(tab, in: browser)
                }
                .background { if Store.testing { Spot(id: tab.id) } }
        } else {
            content
        }
    }

    // MARK: - for the bench

    /// Each armed icon on screen, by its tab: where the bench clicks.
    private static let spots = NSMapTable<NSString, NSView>.strongToWeakObjects()

    /// The icon's centre, in the window's points from its top left corner.
    static func centre(of id: Tab.ID) -> [Double]? {
        guard let view = spots.object(forKey: id.uuidString as NSString), let window = view.window else { return nil }
        let rect = view.convert(view.bounds, to: nil)
        return [Double(rect.midX), Double(window.frame.height - rect.midY)]
    }

    private struct Spot: NSViewRepresentable {
        let id: Tab.ID
        func makeNSView(context: Context) -> NSView {
            let view = Blind()
            PinIconHome.spots.setObject(view, forKey: id.uuidString as NSString)
            return view
        }
        func updateNSView(_ view: NSView, context: Context) {
            PinIconHome.spots.setObject(view, forKey: id.uuidString as NSString)
        }
        private final class Blind: NSView {
            override func hitTest(_ point: NSPoint) -> NSView? { nil }
        }
    }
}

/// A double-click on a pin's square takes a pin that wandered back to its
/// page, as Arc's do (#141, idea 1216): from the square you are on, and from
/// another, whose first click makes it the one on screen. On the square you
/// are on, at home already, it changes the letter, as it always did
/// (Browser.goHome); on another one at home, the double-click only picks it.
enum PinDouble {
    /// Whether the double-click goes to Browser.goHome. `opened`: its first
    /// click made the pin the one on screen; `live`: it is now.
    static func goesHome(clicks: Int, live: Bool, opened: Bool, wandered: Bool) -> Bool {
        guard clicks == 2 else { return false }
        return opened ? wandered : live
    }

    /// A pin away from the page it was pinned at, square or row.
    @MainActor
    static func wandered(_ tab: Tab) -> Bool {
        guard tab.pin != nil, let home = tab.home else { return false }
        return !Browser.samePage(home, tab.address)
    }
}
