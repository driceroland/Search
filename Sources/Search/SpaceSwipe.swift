import SwiftUI

// Spaces, paged through: in the column, two fingers sideways go from one to
// the next, the rows following them, as in Arc; in the bar across the top,
// the same up and down, the row of tabs following them — or a mouse wheel's
// notch, one space at a time. Past the last space a new one is made in
// place. The space's icon turns over as it goes (see SpaceDot).

/// The swipe between spaces. It reads the trackpad's own scroll events
/// before anything else sees them, and takes only a gesture that starts over
/// the tabs and sets off clearly along the spaces' axis — sideways in the
/// column, up or down in the bar; everything else (scrolling the tabs, a
/// long row of them sideways) goes on as it would have.
@MainActor
final class SpaceSwipe {
    static let shared = SpaceSwipe()

    private weak var browser: Browser?
    private var monitor: Any?
    private enum Axis { case undecided, across, along }
    private var axis = Axis.undecided
    private var tracking = false
    /// The glide after a swipe that was taken, which is taken too.
    private var gliding = false
    private var gathered = CGSize.zero
    /// When a mouse wheel last went to another space, so one notch is one space.
    private var notched = Date.distantPast

    /// How far the fingers have to go for the next space to come: 50
    /// points in the column, less in a bar only 52 tall.
    static func enough(for browser: Browser) -> CGFloat {
        browser.prefs.sidebar ? 50 : Metrics.strip * 0.4
    }

    func start(for browser: Browser) {
        self.browser = browser
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            MainActor.assumeIsolated { SpaceSwipe.shared.takes(event) } ? nil : event
        }
    }

    /// Where the tabs are: the column, or the bar across the top.
    private func overTabs(_ event: NSEvent, in browser: Browser) -> Bool {
        guard event.window === Links.window, let window = event.window else { return false }
        if browser.prefs.sidebar { return event.locationInWindow.x < browser.prefs.sideWidth }
        return event.locationInWindow.y > window.frame.height - Metrics.strip
    }

    /// True for an event the swipe keeps for itself.
    private func takes(_ event: NSEvent) -> Bool {
        guard let browser, browser.prefs.usesSpaces, !browser.folded || browser.peeking else { return false }
        // A mouse wheel over the bar: a notch, a space.
        if !event.hasPreciseScrollingDeltas {
            guard !browser.prefs.sidebar, event.scrollingDeltaY != 0, overTabs(event, in: browser) else { return false }
            guard Date().timeIntervalSince(notched) > 0.3 else { return true }
            notched = Date()
            let here = browser.makingSpace ? browser.spaces.count : (browser.spaces.firstIndex { $0.id == browser.spaceID } ?? 0)
            let target = here + (event.scrollingDeltaY < 0 ? 1 : -1)
            if target >= 0, target <= browser.spaces.count { slide(browser, to: target, from: here) }
            return true
        }
        if !event.momentumPhase.isEmpty { return gliding }
        switch event.phase {
        case .began:
            gliding = false
            // Only a gesture that starts over the tabs.
            guard overTabs(event, in: browser) else {
                tracking = false
                return false
            }
            began()
            return moved(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY)
        case .changed:
            guard tracking else { return false }
            return moved(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY)
        case .ended, .cancelled:
            guard tracking else { return false }
            let taken = axis == .across
            ended(cancelled: event.phase == .cancelled)
            gliding = taken
            return taken
        default:
            return false
        }
    }

    // MARK: - the gesture, apart from where its events come from (the bench drives these)

    func began() {
        tracking = true
        axis = .undecided
        gathered = .zero
    }

    /// True while the gesture is this one's to take. The spaces lie
    /// sideways in the column and one above the other in the bar.
    @discardableResult
    func moved(dx: CGFloat, dy: CGFloat) -> Bool {
        guard tracking, let browser else { return false }
        let (step, aside) = browser.prefs.sidebar ? (dx, dy) : (dy, dx)
        gathered.width += step
        gathered.height += aside
        if axis == .undecided {
            guard abs(gathered.width) + abs(gathered.height) > 6 else { return false }
            axis = abs(gathered.width) > abs(gathered.height) * 1.5 ? .across : .along
        }
        guard axis == .across else { return false }
        browser.spaceSwipe = resisted(gathered.width, in: browser)
        return true
    }

    /// Along the spaces' axis, whichever it is — for the bench.
    @discardableResult
    func moved(along travel: CGFloat) -> Bool {
        guard let browser else { return false }
        return browser.prefs.sidebar ? moved(dx: travel, dy: 0) : moved(dx: 0, dy: travel)
    }

    func ended(cancelled: Bool = false) {
        defer { tracking = false }
        guard let browser, axis == .across else { return }
        let travel = gathered.width
        let here = browser.makingSpace ? browser.spaces.count : (browser.spaces.firstIndex { $0.id == browser.spaceID } ?? 0)
        // Fingers to the left, or up, bring what is next.
        let target = cancelled || abs(travel) < SpaceSwipe.enough(for: browser) ? here : here + (travel < 0 ? 1 : -1)
        guard target != here, target >= 0, target <= browser.spaces.count else {
            withAnimation(Motion.settle) { browser.spaceSwipe = 0 }
            return
        }
        slide(browser, to: target, from: here)
    }

    /// Nothing that way: the rows give a little, and come back.
    private func resisted(_ travel: CGFloat, in browser: Browser) -> CGFloat {
        let here = browser.makingSpace ? browser.spaces.count : (browser.spaces.firstIndex { $0.id == browser.spaceID } ?? 0)
        let blocked = (travel > 0 && here == 0) || (travel < 0 && here == browser.spaces.count)
        return blocked ? travel / 4 : travel
    }

    /// The pages carry on the way the fingers went until the next one is
    /// where this one was; then it becomes the one on screen, in the same
    /// frame and without anything moving — it was already there. One past
    /// the last space is the card for a new one.
    func slide(_ browser: Browser, to target: Int, from here: Int) {
        // A page is the column's width, or the bar's height.
        let width = browser.prefs.sidebar ? browser.prefs.sideWidth : Metrics.strip
        let away: CGFloat = target > here ? -1 : 1
        browser.spaceStep = target > here ? 1 : -1
        withAnimation(.easeOut(duration: 0.22), completionCriteria: .removed) {
            browser.spaceSwipe = away * width
        } completion: {
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) {
                if target == browser.spaces.count {
                    browser.makingSpace = true
                } else {
                    browser.makingSpace = false
                    browser.switchSpace(to: browser.spaces[target].id)
                }
                browser.spaceSwipe = 0
            }
        }
    }
}

// MARK: - the card

/// A new space, made where the next one would have been: its name, its
/// icon, and on its way. Escape, Cancel or two fingers back leave it.
struct NewSpaceCard: View {
    @ObservedObject var browser: Browser
    /// In the bar across the top: one row, the height of the tabs.
    var inline = false
    @State private var name = ""
    @State private var icon = "briefcase"
    @State private var choosing = false
    /// Signed in where the other spaces are, or starting afresh.
    @State private var shared = true
    @State private var hovering = false
    @FocusState private var typing: Bool

    private var saying: String {
        shared ? "Signed in wherever your other spaces are." : "Its own cookies and sign-ins, starting from none."
    }

    var body: some View {
        Group {
            if inline {
                // The bar's row: the icon, the name, the sign-ins, and on its way.
                HStack(spacing: 8) {
                    pick(size: 13, box: CGSize(width: 28, height: 26))
                    field
                        .frame(width: 170)
                    Segmented(options: [(true, "Signed in"), (false, "Signed out")], selection: $shared)
                        .fixedSize()
                        .help(saying)
                    Pill("Cancel") { cancel() }
                    Pill("Create", filled: true) { create() }
                }
                .frame(height: Metrics.strip)
            } else {
                VStack(spacing: 12) {
                    pick(size: 20, box: CGSize(width: 44, height: 40))
                    VStack(spacing: 4) {
                        Text("New space")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                        Text("Its own tabs.")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.muted)
                            .multilineTextAlignment(.center)
                    }
                    field
                    // Most people want Google and the rest to know them here too;
                    // some want a clean slate.
                    VStack(spacing: 6) {
                        Segmented(options: [(true, "Signed in"), (false, "Signed out")], selection: $shared, wide: true)
                        Text(saying)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.muted)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        Pill("Cancel") { cancel() }
                        Pill("Create", filled: true) { create() }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            icon = browser.freeIcon
            DispatchQueue.main.async { typing = true }
        }
        .onExitCommand(perform: cancel)
    }

    /// The space's icon, and a click on it for the others: they aren't all
    /// laid out in the card.
    private func pick(size: CGFloat, box: CGSize) -> some View {
        Button { choosing = true } label: {
            Image(systemName: icon)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(Palette.ink)
                .frame(width: box.width, height: box.height)
                .background(
                    RoundedRectangle(cornerRadius: inline ? 8 : 10, style: .continuous)
                        .fill(hovering || choosing ? Palette.hover : .clear)
                )
                .contentShape(Rectangle())
                .id(icon)
                .transition(.opacity)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(inline ? "New space — choose its icon" : "Choose an icon")
        .popover(isPresented: $choosing, arrowEdge: .bottom) { icons }
    }

    private var field: some View {
        TextField(inline ? "New space" : "Name", text: $name)
            .textFieldStyle(.plain)
            .font(.system(size: inline ? 12.5 : 13))
            .padding(.horizontal, 10)
            .frame(height: inline ? 26 : 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.wash))
            .focused($typing)
            .onSubmit(create)
    }

    /// Every icon, a few to a row, the chosen one on a grey of its own;
    /// picking one puts the list away.
    private var icons: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 4), count: 6), spacing: 4) {
            ForEach(Array(zip(Spaces.icons, Spaces.iconNames)), id: \.0) { symbol, name in
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(symbol == icon ? Palette.ink : Palette.muted)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(symbol == icon ? Palette.wash : .clear)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(Motion.quick) { icon = symbol }
                        choosing = false
                        typing = true
                    }
                    .help(name)
            }
        }
        .padding(10)
    }

    private func create() {
        let named = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !named.isEmpty else { typing = true; return }
        browser.addSpace(named: named, icon: icon, sharesSignIns: shared)
    }

    /// Back to the space it was made from, the way it came.
    private func cancel() {
        let back = browser.spaces.firstIndex { $0.id == browser.spaceID } ?? 0
        SpaceSwipe.shared.slide(browser, to: back, from: browser.spaces.count)
    }
}
