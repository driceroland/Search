import SwiftUI

// "Update ready" in the window, not only in the Search menu: while a newer
// build is in place and runs at the next launch (Updater.Stage.ready), a
// quiet card at the foot of the column, just above its doors, with Restart;
// with the tabs across the top, a small pill at the far end of the strip.
// Installing on its own switched off, the same card says "Update available"
// with Install. Nothing while the feed is read or the build fetched, and
// nothing for a disk image offered instead: that stays in the menu.
//
// On by default, unlike Search's other additions, because it is only ever
// there when an update really is (Settings › About › Show when an update is
// ready). Its × or Hide puts it away until a newer build is ready: the build
// put away is kept in the settings. Chrome only: never over a page, a sheet
// or anything private, and it never takes the keys.

enum UpdateNotice {
    static let key = "update.notice"
    static let hiddenKey = "update.notice.hidden"

    enum Kind: Equatable {
        /// Swapped in: Restart.
        case ready
        /// Found, waiting for Install (installing on its own is off).
        case waiting
    }

    /// What there is to show for a stage, if anything.
    static func shown(_ stage: Updater.Stage, on: Bool, hidden: Int) -> (kind: Kind, build: Int)? {
        guard on else { return nil }
        switch stage {
        case .ready(let release) where release.build != hidden: return (.ready, release.build)
        case .waiting(let release) where release.build != hidden: return (.waiting, release.build)
        default: return nil
        }
    }

    @MainActor
    static func shown(_ updater: Updater, _ prefs: Preferences) -> (kind: Kind, build: Int)? {
        shown(updater.stage, on: prefs.showsUpdateReady, hidden: prefs.updateHiddenBuild)
    }

    static func title(_ kind: Kind) -> String { kind == .ready ? "Update ready" : "Update available" }
    static func button(_ kind: Kind) -> String { kind == .ready ? "Restart" : "Install" }

    @MainActor
    static func act(_ kind: Kind) {
        switch kind {
        case .ready: Updater.shared.relaunch()
        case .waiting: Updater.shared.install()
        }
    }
}

/// The card at the foot of the column: drawn as the player's row is, a
/// hairline round the column's own ground, so it sits on the glass or the
/// solid ground alike and never reads as one more tab.
struct UpdateNoticeRow: View {
    @Environment(\.greys) private var greys
    @ObservedObject var prefs: Preferences
    @ObservedObject private var updater = Updater.shared

    @State private var hovering = false

    var body: some View {
        if let shown = UpdateNotice.shown(updater, prefs) {
            HStack(spacing: 8) {
                // The icon goes first in a narrow column, as on the agent's
                // card: the words are what must be read whole.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.muted)
                        title(shown.kind)
                    }
                    title(shown.kind)
                    // Narrowest of all: the button says the rest.
                    title("Update")
                }
                Spacer(minLength: 0)
                if hovering {
                    UpdateNoticeCross { prefs.updateHiddenBuild = shown.build }
                        .transition(.opacity)
                }
                CardButton(title: UpdateNotice.button(shown.kind)) { UpdateNotice.act(shown.kind) }
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
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
            .onHover { hovering = $0 }
            .contextMenu {
                Button(UpdateNotice.button(shown.kind)) { UpdateNotice.act(shown.kind) }
                Button("Hide") { prefs.updateHiddenBuild = shown.build }
            }
            .help(shown.kind == .ready
                  ? "A new version of Search is ready. Restart to use it, or it starts the next time you open Search."
                  : "A new version of Search is out. Install fetches it; it starts at the next launch.")
            .animation(Motion.quick, value: hovering)
        }
    }

    private func title(_ kind: UpdateNotice.Kind) -> some View { title(UpdateNotice.title(kind)) }

    private func title(_ words: String) -> some View {
        Text(words)
            .font(.system(size: prefs.sideTitle))
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(hovering ? Palette.ink.opacity(0.7) : Palette.muted)
    }
}

/// With the tabs across the top: a small pill at the far end of the strip,
/// the click Restart (or Install), Hide on a right-click.
struct UpdateNoticePill: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject private var updater = Updater.shared

    @State private var hovering = false

    var body: some View {
        if let shown = UpdateNotice.shown(updater, prefs) {
            Button { UpdateNotice.act(shown.kind) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 10, weight: .medium))
                    Text(UpdateNotice.title(shown.kind))
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(hovering ? Palette.ink : Palette.ink.opacity(0.75))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Palette.ground.opacity(hovering ? 1 : 0.6), in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
                .contentShape(Capsule())
                .fixedSize()
            }
            .buttonStyle(.plain)
            .focusable(false)
            .onHover { hovering = $0 }
            .contextMenu {
                Button(UpdateNotice.button(shown.kind)) { UpdateNotice.act(shown.kind) }
                Button("Hide") { prefs.updateHiddenBuild = shown.build }
            }
            .help(shown.kind == .ready
                  ? "A new version of Search is ready. Click to restart and use it."
                  : "A new version of Search is out. Click to install it.")
            .animation(Motion.quick, value: hovering)
        }
    }
}

/// Restart or Install, and the coding agent's Stop on its card
/// (AgentBanner): a small capsule on the ground, under a hairline. `spot`
/// is drawn behind the label, for a control that has to know where it is.
struct CardButton<Spot: View>: View {
    let title: String
    let act: () -> Void
    let spot: Spot
    @State private var hovering = false

    init(title: String, act: @escaping () -> Void, @ViewBuilder spot: () -> Spot) {
        self.title = title
        self.act = act
        self.spot = spot()
    }

    var body: some View {
        Button(action: act) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hovering ? Palette.ink : Palette.ink.opacity(0.8))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Palette.ground, in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
                .contentShape(Capsule())
                .background(spot)
                .fixedSize()
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
    }
}

extension CardButton where Spot == EmptyView {
    init(title: String, act: @escaping () -> Void) {
        self.init(title: title, act: act) { EmptyView() }
    }
}

/// Put away, until a newer build is ready: the player row's cross.
private struct UpdateNoticeCross: View {
    let act: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: act) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Palette.muted)
                .frame(width: 15, height: 15)
                .background(Palette.ink.opacity(hovering ? 0.07 : 0), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
        .help("Hide until the next version")
    }
}
