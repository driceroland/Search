import SwiftUI

// What plays in another tab, at the foot of the sidebar: the tab's icon
// and title, its pause, and a click on it to go there. Paused from here, it
// stays, with its play and a cross to put it away, until it plays again,
// its page goes or the tab sleeps.
//
// On unless turned off in Settings › Appearance › Tabs, and only with the
// tabs down the side, titles and all: a sidebar of icons alone has no room
// for its title and buttons. Off, nothing of it reaches a page: the pause
// is two lines of script run in Search's world when it is pressed, and
// never before.
//
// A row for each tab making a sound out of sight, the newest at the top:
// not the page on screen, nor the other page of a pair on screen, nor one
// out in the floating window, which has its own controls. A tab left
// playing in another space keeps playing (see Spaces.swift) and has its
// row too; a click on it goes to its space.
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
    /// The tabs the player is for: every one making a sound out of sight,
    /// pinned or not, in this space or left playing in another, the newest
    /// first. Each has its own row (idea 1332: only the newest showed, so
    /// three of four playing tabs had no row). Empty with the switch off,
    /// with the tabs across the top, or with the sidebar as icons only.
    var players: [Tab] {
        guard prefs.showsPlayer, prefs.sidebar, !prefs.iconColumn, !sounding.isEmpty else { return [] }
        let shown = visibleTabIDs
        let all = tabs + parkedTabs
        return sounding.reversed().compactMap { id in
            guard !shown.contains(id), id != floating, id != pictured else { return nil }
            guard let tab = all.first(where: { $0.id == id }), !tab.inPictureInPicture else { return nil }
            return tab
        }
    }

    /// The newest of them.
    var player: Tab? { players.first }

    /// A tab from the player, wherever it is: its space comes on screen
    /// first when it was left playing in another.
    func goToPlayer(_ tab: Tab) {
        if !tabs.contains(where: { $0.id == tab.id }),
           let space = parked.first(where: { $0.value.tabs.contains { $0.id == tab.id } })?.key {
            switchSpace(to: space)
        }
        guard let tab = tabs.first(where: { $0.id == tab.id }) else { return }
        select(tab)
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

/// The row itself, above the doors at the foot of the sidebar. A card's
/// hairline rather than a tab's ground, so it never reads as one more tab.
struct PlayerRow: View {
    @Environment(\.greys) private var greys
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var tab: Tab

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Mark(icon: tab.icon, letter: tab.monogram, size: prefs.roomyTabs ? 17 : 15)
            Text(tab.label)
                .font(.system(size: prefs.sideTitle))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(hovering ? Palette.ink.opacity(0.7) : Palette.muted)
            Spacer(minLength: 0)
            if tab.stilled && hovering {
                // Paused from here and not wanted again: the row goes until
                // the tab plays again.
                PlayerButton(symbol: "xmark", help: "Put Away") { tab.handPause() }
                    .transition(.opacity)
            }
            PlayerButton(symbol: tab.stilled ? "play.fill" : "pause.fill", help: tab.stilled ? "Play" : "Pause") {
                if tab.stilled { tab.playAgain() } else { tab.still() }
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 7)
        .frame(height: prefs.sideRow)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(hovering ? greys.hover : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        // The buttons take their own clicks; the rest of the row is the way
        // to the tab.
        .onTapGesture { browser.goToPlayer(tab) }
        .onHover { hovering = $0 }
        .help("Go to the tab")
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: tab.stilled)
    }
}

/// One of the row's buttons, drawn as the tab's speaker is: a symbol, with
/// the cross's faint disc behind it under the pointer.
private struct PlayerButton: View {
    let symbol: String
    let help: String
    let act: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: act) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Palette.muted)
                .frame(width: 15, height: 15)
                .background(Palette.ink.opacity(hovering ? 0.07 : 0), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .animation(Motion.quick, value: hovering)
    }
}
