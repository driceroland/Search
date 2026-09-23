import SwiftUI

// Spaces in the column: two fingers sideways go from one to the next, the
// rows following them, as in Arc. Past the last space the column offers to
// make a new one, in place. The space's icon at the column's foot turns
// over as it goes (see SpaceDot).

/// The sideways swipe over the column. It reads the trackpad's own scroll
/// events before anything else sees them, and takes only a gesture that
/// starts over the column and sets off clearly sideways; everything else —
/// scrolling the tabs, a mouse wheel — goes on as it would have.
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

    /// How far the fingers have to go for the next space to come.
    static let enough: CGFloat = 50

    func start(for browser: Browser) {
        self.browser = browser
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            MainActor.assumeIsolated { SpaceSwipe.shared.takes(event) } ? nil : event
        }
    }

    /// True for an event the swipe keeps for itself.
    private func takes(_ event: NSEvent) -> Bool {
        guard let browser, browser.prefs.usesSpaces, browser.prefs.sidebar,
              !browser.folded || browser.peeking, event.hasPreciseScrollingDeltas
        else { return false }
        if !event.momentumPhase.isEmpty { return gliding }
        switch event.phase {
        case .began:
            gliding = false
            // Only a gesture that starts over the column.
            guard event.window === Links.window, event.locationInWindow.x < browser.prefs.sideWidth else {
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

    /// True while the gesture is this one's to take.
    @discardableResult
    func moved(dx: CGFloat, dy: CGFloat) -> Bool {
        guard tracking, let browser else { return false }
        gathered.width += dx
        gathered.height += dy
        if axis == .undecided {
            guard abs(gathered.width) + abs(gathered.height) > 6 else { return false }
            axis = abs(gathered.width) > abs(gathered.height) * 1.5 ? .across : .along
        }
        guard axis == .across else { return false }
        browser.spaceSwipe = resisted(gathered.width, in: browser)
        return true
    }

    func ended(cancelled: Bool = false) {
        defer { tracking = false }
        guard let browser, axis == .across else { return }
        let travel = gathered.width
        let here = browser.makingSpace ? browser.spaces.count : (browser.spaces.firstIndex { $0.id == browser.spaceID } ?? 0)
        // Fingers to the left bring what is to the right.
        let target = cancelled || abs(travel) < SpaceSwipe.enough ? here : here + (travel < 0 ? 1 : -1)
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
        let width = browser.prefs.sideWidth
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
    @State private var name = ""
    @State private var icon = "briefcase"
    @State private var choosing = false
    /// Signed in where the other spaces are, or starting afresh.
    @State private var shared = true
    @State private var hovering = false
    @FocusState private var typing: Bool

    var body: some View {
        VStack(spacing: 12) {
            // The space's icon, and a click on it for the others: they
            // aren't all laid out on the card.
            Button { choosing = true } label: {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 44, height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(hovering || choosing ? Palette.hover : .clear)
                    )
                    .contentShape(Rectangle())
                    .id(icon)
                    .transition(.opacity)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("Choose an icon")
            .popover(isPresented: $choosing, arrowEdge: .bottom) { icons }
            VStack(spacing: 4) {
                Text("New space")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text("Its own tabs.")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.center)
            }
            TextField("Name", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.wash))
                .focused($typing)
                .onSubmit(create)
            // Most people want Google and the rest to know them here too;
            // some want a clean slate.
            VStack(spacing: 6) {
                Segmented(options: [(true, "Same sign-ins"), (false, "Signed out")], selection: $shared, wide: true)
                Text(shared ? "Signed in wherever your other spaces are." : "Its own cookies and sign-ins, starting from none.")
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
        .onAppear {
            icon = browser.freeIcon
            DispatchQueue.main.async { typing = true }
        }
        .onExitCommand(perform: cancel)
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

    private func cancel() {
        withAnimation(Motion.glide) { browser.makingSpace = false }
    }
}
