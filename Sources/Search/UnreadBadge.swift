import SwiftUI

/// What a page says is waiting for you, read off the front of its title the
/// way WhatsApp, Messenger, Facebook, X and Discord put it there: "(3)
/// WhatsApp", "(12+) …". A pin shows its icon and never its title, so on a
/// pin the count was only to be had by holding the pointer over it, while
/// the same page in a row said it plainly.
///
/// Only a count at the very front, in brackets: a number further along is
/// as likely to be a year ("Dune (2021) - IMDb") as anything waiting.
enum Unread {
    /// The count as the badge shows it, nil for none: "3", "12+", "99+".
    static func count(in title: String) -> String? {
        let title = title.trimmingCharacters(in: .whitespaces)
        guard title.hasPrefix("("), let close = title.firstIndex(of: ")") else { return nil }
        var inside = title[title.index(after: title.startIndex)..<close].trimmingCharacters(in: .whitespaces)
        let more = inside.hasSuffix("+")
        if more { inside.removeLast() }
        guard (1...5).contains(inside.count), inside.allSatisfy({ $0.isASCII && $0.isNumber }),
              let n = Int(inside), n > 0
        else { return nil }
        if n > 99 { return "99+" }
        return more ? "\(n)+" : "\(n)"
    }
}

/// The count, hung from the top right of a pin's icon as an app's hangs from
/// its icon in the Dock: centred on the icon's corner, wherever the icon sits
/// in its square. Hung from the square's corner instead, it floated off on
/// its own over a wide square, far from the icon it spoke for. Red, so a
/// glance along the pins finds it; ringed in the square's own grey, so it
/// stands clear of the icon it overlaps; drawn only, so a click on it is a
/// click on the pin.
///
/// Hung with `.unreadBadge(_:icon:ring:)` on the icon's frame.
struct UnreadBadge: View {
    let count: String
    /// The icon it hangs from, which it is drawn to.
    var icon: CGFloat = 16
    /// The square's ground, for the ring; none, a soft shadow instead.
    var ring: Color? = nil

    var body: some View {
        Text(count)
            .font(.system(size: max(7, icon * 0.45), weight: .bold).monospacedDigit())
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, icon * 0.14)
            .frame(minWidth: icon * 0.7, minHeight: icon * 0.7)
            // Its own size, whatever it is offered: hung from a point, it
            // was offered none, and "97" spilled out of a one-digit circle.
            .fixedSize()
            .background(Capsule().fill(Color(red: 0.93, green: 0.24, blue: 0.21)))
            .background {
                if let ring { Capsule().fill(ring).padding(-1.5) }
            }
            .shadow(color: .black.opacity(ring == nil ? 0.2 : 0), radius: 1, y: 0.5)
            .allowsHitTesting(false)
            .accessibilityLabel(Text("\(count) unread"))
    }
}

extension View {
    /// `count`'s badge with its middle on this view's top right corner, a
    /// touch outside it: hung from a point there, not by alignment guides,
    /// which an overlay here ignored and so drew the badge over the middle
    /// of the icon, hiding it. Nil, none.
    func unreadBadge(_ count: String?, icon: CGFloat, ring: Color?) -> some View {
        overlay(alignment: .topTrailing) {
            if let count {
                Color.clear
                    .frame(width: 0, height: 0)
                    .overlay { UnreadBadge(count: count, icon: icon, ring: ring) }
                    .offset(x: icon * 0.15, y: -icon * 0.12)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .animation(Motion.quick, value: count)
    }
}

extension Tab {
    /// The badge's count for this tab as a pin, nil for none: the page's own
    /// title, not the name the pin was given (Tab.label), and nothing while
    /// it sleeps, when the last count it heard could be long out of date.
    var unread: String? {
        asleep ? nil : Unread.count(in: title)
    }
}
