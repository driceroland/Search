import SwiftUI

// What plays in another tab, at the foot of the sidebar: the tab's icon
// and title, its pause, and a click on it to go there. Paused from here, it
// stays, with its play and a cross to put it away, until it plays again,
// its page goes or the tab sleeps.
//
// A title too long for the card rolls past while the pointer is on it
// (Settings can turn that off).
//
// On unless turned off in Settings › Appearance › Tabs, and only with the
// tabs down the side, titles and all: a sidebar of icons alone has no room
// for its title and buttons. Off, nothing of it reaches a page: the pause
// is two lines of script run in Search's world when it is pressed, and
// never before.
//
// For the newest tab to make a sound that is out of sight: not the page on
// screen, nor the other page of a pair on screen, nor one out in the
// floating window, which has its own controls. Of this space's row only:
// a tab left playing in another space keeps playing (see Spaces.swift), and
// shows here once you are back in its space, if it is still out of sight.
//
// The pause looks in the page and in each frame below it that played (the
// frames MediaKeys keeps), pauses what plays and remembers it; then WebKit
// suspends whatever a script can't reach — a player in a shadow root, one
// never put in the page, as on most music sites. The play lifts that
// suspension, which resumes only what it held, and plays what was
// remembered. So the row always stays, with its play. Gone to, put away
// with its cross, or its page leaving, the pause is handed to the page: the
// suspended players paused as by their own buttons and the suspension
// lifted, so the page plays as it would and the next page holds nothing.

enum Player {
    /// What plays here, paused and remembered: the page sees its media
    /// paused, as by its own button, and nothing of who did it. How many.
    static let still = """
    (function () {
      var held = [];
      document.querySelectorAll('audio, video').forEach(function (el) {
        if (el.paused) return;
        held.push(el);
        el.pause();
      });
      window.__officeStilled = held;
      return held.length;
    })()
    """

    /// What `still` paused, playing again: whatever the page played again
    /// itself, or took out of the page, is left as it is.
    static let again = """
    (function () {
      var held = window.__officeStilled || [];
      window.__officeStilled = null;
      held.forEach(function (el) {
        if (!el.paused || !el.isConnected) return;
        var played = el.play();
        if (played && played.catch) played.catch(function () {});
      });
      return held.length;
    })()
    """
}

extension Browser {
    /// The tab the player is for: the newest to make a sound, of the ones
    /// in this row that are out of sight. Nil with the switch off, with the
    /// tabs across the top, or with the sidebar as icons only or the strip.
    var player: Tab? {
        guard prefs.showsPlayer, prefs.sidebar, !prefs.iconColumn else { return nil }
        let shown = visibleTabIDs
        for id in sounding.reversed() where !shown.contains(id) && id != floating {
            if let tab = tabs.first(where: { $0.id == id }) { return tab }
        }
        return nil
    }

    /// A tab's sound started or stopped, or the player paused it or let it
    /// go. Started, it is the newest; quiet and not paused from the player,
    /// it has nothing to show.
    func heard(_ tab: Tab, noisy: Bool, stilled: Bool) {
        if noisy {
            guard sounding.last != tab.id else { return }
            sounding.removeAll { $0 == tab.id }
            sounding.append(tab.id)
        } else if !stilled {
            sounding.removeAll { $0 == tab.id }
        }
    }
}

/// The card itself, above the doors at the foot of the sidebar: raised off
/// the column on the pills' ground, with their edge and a shadow, so it
/// never reads as one more tab.
struct PlayerRow: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var tab: Tab

    @State private var hovering = false

    /// A little taller than a tab's line.
    static func height(_ prefs: Preferences) -> CGFloat { prefs.sideRow + 10 }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.popoverRadius - 4, style: .continuous)
        HStack(spacing: 8) {
            Mark(icon: tab.icon, letter: tab.monogram, size: prefs.roomyTabs ? 18 : 16)
            ScrollingTitle(title: tab.label, size: prefs.sideTitle, rolling: hovering && prefs.rollsPlayerTitle)
                .fontWeight(.medium)
                .foregroundStyle(Palette.ink)
            if tab.stilled && hovering {
                // Paused from here and not wanted again: the card goes until
                // the tab plays again.
                PlayerButton(symbol: "xmark", help: "Put Away") { tab.handPause() }
                    .transition(.opacity)
            }
            PlayerButton(symbol: tab.stilled ? "play.fill" : "pause.fill", help: tab.stilled ? "Play" : "Pause") {
                if tab.stilled { tab.playAgain() } else { tab.still() }
            }
        }
        .padding(.leading, 11)
        .padding(.trailing, 7)
        .frame(height: Self.height(prefs))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            shape.fill(Palette.lift)
                .shadow(color: .black.opacity(hovering ? 0.28 : 0.18), radius: hovering ? 10 : 6, y: hovering ? 4 : 2)
        )
        .overlay(shape.strokeBorder(Palette.liftEdge, lineWidth: 1))
        .contentShape(shape)
        // The buttons take their own clicks; the rest of the card is the way
        // to the tab.
        .onTapGesture { browser.select(tab) }
        .onHover { hovering = $0 }
        // No tooltip over a title that is being read as it rolls.
        .help(prefs.rollsPlayerTitle ? "" : "Go to the tab")
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: tab.stilled)
    }
}

/// One line, cut short at rest. While `rolling`, one too long for its room
/// waits a moment, then goes slowly round, and waits again at its start.
/// Still with Reduce Motion.
private struct ScrollingTitle: View {
    let title: String
    let size: CGFloat
    let rolling: Bool

    /// The room there is, and what the whole line would take.
    @State private var room: CGFloat = 0
    @State private var full: CGFloat = 0
    @State private var since = Date()

    /// Points a second, the wait at the start, and the space between the end
    /// of the line and its coming round again.
    private static let speed = 24.0
    private static let wait = 0.5
    private static let gap: CGFloat = 36

    private var rolls: Bool { rolling && !Motion.reduced && full > room + 0.5 }

    private var line: some View {
        Text(title).font(.system(size: size)).lineLimit(1)
    }

    var body: some View {
        line.truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(rolls ? 0 : 1)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { room = $0 }
            .background(alignment: .leading) {
                line.fixedSize().hidden()
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { full = $0 }
            }
            .overlay(alignment: .leading) {
                if rolls {
                    TimelineView(.animation) { context in
                        let round = Double(full + Self.gap)
                        let spent = context.date.timeIntervalSince(since)
                            .truncatingRemainder(dividingBy: Self.wait + round / Self.speed)
                        let gone = CGFloat(max(0, spent - Self.wait) * Self.speed)
                        HStack(spacing: Self.gap) {
                            line.fixedSize()
                            line.fixedSize()
                        }
                        .offset(x: -gone)
                        .frame(width: room, alignment: .leading)
                        .mask(fade(leading: min(gone, 10)))
                    }
                    .accessibilityHidden(true)
                }
            }
            .onChange(of: rolling) { since = Date() }
            .onChange(of: title) { since = Date() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
    }

    /// Soft at the edges the words pass under; whole at the start while they
    /// have yet to move.
    private func fade(leading: CGFloat) -> some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: leading)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: 10)
        }
    }
}

/// One of the card's buttons: a symbol on a faint disc, darker under the
/// pointer.
private struct PlayerButton: View {
    let symbol: String
    let help: String
    let act: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: act) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .frame(width: 24, height: 24)
                .background(Palette.ink.opacity(hovering ? 0.16 : 0.08), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .animation(Motion.quick, value: hovering)
    }
}
