import SwiftUI

// Spaces, paged through: in the column, two fingers sideways go from one to
// the next, the rows following them, as in Arc; in the bar across the top,
// the same up and down, the row of tabs following them — or a mouse wheel's
// notch, one space at a time, or the mouse's back and forward buttons with
// the pointer over the tabs. Past the last space a new one is made in
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
    private var buttons: Any?
    private var interrupts: Any?
    private enum Axis { case undecided, across, along }
    private var axis = Axis.undecided
    private var tracking = false
    /// The glide after a swipe that was taken, which is taken too.
    private var gliding = false
    private var gathered = CGSize.zero
    /// When the wheel last turned over the bar, whether a space came of it
    /// or not. A spin of the wheel is a run of notches close together, and
    /// it brings one space: the next waits for the wheel to have rested.
    private var notched = Date.distantPast
    /// Until when a new gesture is let go by: the hand that just brought a
    /// space is often still moving, and its next stroke would take one more.
    private var resting = Date.distantPast
    /// A gesture let go by while resting, kept whole, glide included.
    private var ignoring = false
    /// A gesture begun while resting: let go by only once it shows it goes
    /// back the way the last space came (see moved).
    private var early = false
    /// Which way the last space came: 1 the next, -1 the one before.
    private var lastStep = 0
    /// Where the fingers had the rows lately, for how fast they were going
    /// as they let go (fingerSpeed).
    private var trail: [(at: CFTimeInterval, x: CGFloat)] = []
    /// That speed, in points a second, for the slide that follows (bring);
    /// nil for a slide the fingers didn't start.
    private var letGoSpeed: CGFloat?
    /// When two fingers last moved over the tabs (pressed).
    private var fingersAt: CFTimeInterval = 0
    /// True once the fingers have the rows, a slide they found under way
    /// stopped where it had them (moved), and the rows' place as they did.
    private var holding = false
    private var base: CGFloat = 0
    /// Two fingers resting on the trackpad, moving or not: the hand about
    /// to go on, so the space on its way in isn't taken yet (landSoon).
    private var fingersDown = false
    /// The space on its way in, to be taken a moment after its rows stop.
    private var landing: DispatchWorkItem?

    /// Not quite in place: drawn in place, the map still showing (land).
    static let hair: CGFloat = 0.001

    /// How long after a space comes before another can.
    static let rest: TimeInterval = 0.4

    /// How far the fingers have to go for the next space to come: 50
    /// points in the column; in a bar only 52 tall, most of its height, so
    /// that scrolling the page with the pointer a little high doesn't.
    static func enough(for browser: Browser) -> CGFloat {
        browser.prefs.sidebar ? 50 : Metrics.strip * 0.6
    }

    /// A page of the spaces: the column's width, or the bar's height.
    static func page(_ browser: Browser) -> CGFloat {
        browser.prefs.sidebar ? browser.prefs.columnWidth : Metrics.strip
    }

    func start(for browser: Browser) {
        self.browser = browser
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            MainActor.assumeIsolated { SpaceSwipe.shared.takes(event) } ? nil : event
        }
        buttons = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .swipe]) { event in
            MainActor.assumeIsolated { SpaceSwipe.shared.pressed(event) } ? nil : event
        }
        // ⌃1–⌃9 go on from the space on its way in (Browser.goToSpace).
        interrupts = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { event in
            if event.type != .keyDown || !event.modifierFlags.contains(.control) {
                MainActor.assumeIsolated { SpaceSwipe.shared.interrupted() }
            }
            return event
        }
    }

    /// The mouse's back and forward buttons over the tabs: the space before,
    /// or the one after. Over the page they stay the page's back and forward
    /// (PageView.otherMouseDown). Past the last space, as with the wheel,
    /// the card for a new one.
    ///
    /// Most mice send them as buttons 3 and 4. A Logitech mouse set up with
    /// Logi Options+, Logitech's own driver, doesn't: it turns them into the
    /// swipe a trackpad sends for going back or forward a page — deltaX 1
    /// for back, -1 for forward, which is how Safari reads it. A swipe of
    /// that kind over the tabs is taken the same way, whoever sends it.
    private func pressed(_ event: NSEvent) -> Bool {
        let step: Int
        switch event.type {
        case .otherMouseDown where event.buttonNumber == 3: step = -1
        case .otherMouseDown where event.buttonNumber == 4: step = 1
        case .swipe where event.deltaX != 0:
            // The same stroke over the tabs, sent again as a swipe between
            // pages (Settings › Trackpad), took a second space after the
            // first: only a swipe no fingers are moving the rows for counts
            // — a mouse's, as Logitech's driver sends.
            guard CACurrentMediaTime() - fingersAt > 0.6 else { return true }
            step = event.deltaX > 0 ? -1 : 1
        default: return false
        }
        guard let browser = Browsers.browser(for: event.window), !browser.isPopup, browser.prefs.usesSpaces,
              !browser.folded || browser.peeking, overTabs(event, in: browser) else { return false }
        self.browser = browser
        let here = shown(browser)
        let target = here + step
        if let other = beyond(browser, target) {
            leave(browser, for: other, step: step)
        } else if target >= 0, target <= browser.spaces.count {
            slide(browser, to: target, from: here)
        }
        return true
    }

    /// With profiles in one window, past this window's first space or its
    /// last: the space of the profile that comes before or after.
    private func beyond(_ browser: Browser, _ target: Int) -> UUID? {
        if target < 0 { return browser.spaceBeyond(-1) }
        if target >= browser.spaces.count, !browser.makingSpace { return browser.spaceBeyond(1) }
        return nil
    }

    /// Off to another profile's space: this window's rows go the way the
    /// fingers went, and that profile's window takes this one's place, its
    /// rows coming in from the other side (see OneWindow.swift).
    private func leave(_ browser: Browser, for space: UUID, step: Int) {
        let width = SpaceSwipe.page(browser)
        land(browser)
        browser.spaceStep = step
        resting = Date().addingTimeInterval(SpaceSwipe.rest)
        lastStep = step
        carry(browser, to: CGFloat(-step) * width) {
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) {
                browser.switchSpace(to: space)
                browser.spaceSwipe = 0
            }
            guard let next = Browsers.front, next !== browser, next.spaceID == space else { return }
            self.browser = next
            next.spaceStep = step
            guard !Motion.reduced else { return }
            next.spaceSwipe = CGFloat(step) * width
            SwipeGlide.start(next, to: 0)
        }
    }

    /// Space `id` brought in from the side `step` says: its page in front at
    /// once (Browser.showAhead), its rows — drawn ahead, beside these —
    /// carried into place a frame at a time from wherever the fingers left
    /// them, and only once they stand there the space itself, its rows
    /// drawn where those just stopped. Taking the space first and then
    /// moving its rows, the column made over its whole row before the
    /// first frame of the slide, and the slide began with a jolt.
    ///
    /// In the column the rows are the map's (SideBar.others), and the space
    /// is taken only once they stand still with no fingers moving them: a
    /// stroke begun while they slide carries them on from there, to the
    /// space after, and nothing is built until the hand is done. Taken as
    /// each came, a quick run across the spaces stalled at every one, up to
    /// a fifth of a second for a long space, and its next stroke waited.
    func bring(_ browser: Browser, _ id: UUID, step: Int) {
        let width = SpaceSwipe.page(browser)
        resting = Date().addingTimeInterval(SpaceSwipe.rest)
        lastStep = step
        browser.spaceStep = step
        guard !browser.prefs.sidebar else { return glide(browser, to: id, step: step, width: width) }
        browser.spaceComing = id
        // From further along: the bar's row beside drawn again for it.
        let jumps = browser.spaces.firstIndex { $0.id == id } != taken(browser) + step
        if jumps { browser.mapDrawn.value += 1 }
        browser.showAhead(id)
        SwipeGlide.start(browser, to: -CGFloat(step) * width, speed: letGoSpeed, land: {
            if jumps { browser.mapDrawn.value += 1 }
            browser.spaceComing = nil
            browser.pageAhead = nil
            browser.makingSpace = false
            browser.switchSpace(to: id)
            // Its rows are the column's own now, and their place is its.
            return 0
        })
    }

    /// Along the map to space `id`: the one beside the space it shows, or
    /// back to its own; one from further along (⌃1–⌃9) is drawn beside it
    /// (Browser.mapSlot).
    private func glide(_ browser: Browser, to id: UUID, step: Int, width: CGFloat) {
        SwipeGlide.pause()
        // One that came from further along is taken before going on.
        if let coming = browser.spaceComing, let at = browser.spaces.firstIndex(where: { $0.id == coming }),
           browser.comingSlot != at - taken(browser) {
            land(browser)
        }
        let here = taken(browser), from = shown(browser)
        guard let to = browser.spaces.firstIndex(where: { $0.id == id }) else { return }
        let slot = to == here ? 0 : abs(to - from) <= 1 ? to - here : from - here + step
        let moved = browser.spaceComing != (to == here ? nil : id) || browser.comingSlot != slot
        browser.spaceComing = to == here ? nil : id
        browser.comingSlot = slot
        // Drawn out of its order: the map is drawn again, even mid-swipe.
        if moved, slot != to - here { browser.mapDrawn.value += 1 }
        landing?.cancel()
        // Its page comes as its rows stop: put in front as they set off,
        // the stage's work (and a page asleep woken) stalled the slide's
        // first frames, and on a run across the spaces each one's page was
        // loaded on the way.
        SwipeGlide.start(browser, to: -CGFloat(slot) * width, speed: letGoSpeed) { [weak self, weak browser] in
            guard let self, let browser, browser.spaceComing == id || id == browser.spaceID else { return }
            browser.showAhead(id)
            self.landSoon(browser)
        }
    }

    /// The space on its way in taken once the hand has been still a moment:
    /// taken the moment its rows stopped, a quarter of a second of work for
    /// a long space, a stroke begun just after waited for it. Its rows in
    /// the map are drawn as the column's will be, so nothing shows it.
    private func landSoon(_ browser: Browser) {
        landing?.cancel()
        guard browser.spaceComing != nil else { return }
        let work = DispatchWorkItem { [weak self, weak browser] in
            guard let self, let browser, !self.fingersDown, !(self.tracking && self.holding) else { return }
            self.land(browser)
        }
        landing = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// A key or a click: the space on its way in taken first, for it to
    /// be the one they act on.
    private func interrupted() {
        if let browser { land(browser) }
    }

    /// The space on its way in, taken: its rows the column's own, from
    /// where the map had them — still on their way, if they were.
    func land(_ browser: Browser) {
        guard let id = browser.spaceComing else { return }
        landing?.cancel()
        let width = SpaceSwipe.page(browser)
        let shift = CGFloat(browser.comingSlot) * width
        browser.spaceComing = nil
        browser.comingSlot = 0
        browser.pageAhead = nil
        if browser.makingSpace { browser.makingSpace = false }
        browser.switchSpace(to: id)
        browser.spaceSwipe += shift
        SwipeGlide.rebase(by: shift)
        base += shift
        // Its rows in the map a turn longer, a hair off their place and drawn
        // on it: the column's own scroll to its tab in front can come a pass
        // after the space, and shown at once, they were where the last space
        // left them for a frame, and then jumped.
        if browser.spaceSwipe == 0, SwipeGlide.idle, !holding {
            browser.spaceSwipe = SpaceSwipe.hair
            DispatchQueue.main.async { [weak browser] in
                guard let browser, browser.spaceSwipe == SpaceSwipe.hair else { return }
                browser.spaceSwipe = 0
            }
        }
    }

    /// The space the column has, and the one it shows: the one on its way
    /// in, if one is. One past the last while the card for a new one is up.
    private func taken(_ browser: Browser) -> Int {
        browser.makingSpace ? browser.spaces.count : (browser.spaces.firstIndex { $0.id == browser.spaceID } ?? 0)
    }

    private func shown(_ browser: Browser) -> Int {
        guard !browser.makingSpace, let id = browser.spaceComing else { return taken(browser) }
        return browser.spaces.firstIndex { $0.id == id } ?? taken(browser)
    }

    /// For the bench: ⌃1–⌃9 slide in a hidden window too, where they'd
    /// otherwise switch at once (Browser.goToSpace).
    static var glidesHidden = false

    /// The rows carried on to `offset`, where the next space's lie, and then
    /// `arrived`. With Reduce Motion on nothing travels: `arrived` at once,
    /// and the space is simply there, as a swipe let go short already
    /// snaps back without moving (Motion.settle).
    private func carry(_ browser: Browser, to offset: CGFloat, then arrived: @escaping () -> Void) {
        guard !Motion.reduced else { return arrived() }
        withAnimation(.easeOut(duration: 0.22), completionCriteria: .removed) {
            browser.spaceSwipe = offset
        } completion: {
            arrived()
        }
    }

    /// Where the tabs are: the column, or the bar across the top.
    private func overTabs(_ event: NSEvent, in browser: Browser) -> Bool {
        guard let window = event.window, window === browser.window else { return false }
        if browser.prefs.sidebar {
            return browser.prefs.sidePosition == .right
                ? event.locationInWindow.x >= window.frame.width - browser.prefs.columnWidth
                : event.locationInWindow.x < browser.prefs.columnWidth
        }
        return event.locationInWindow.y > window.frame.height - Metrics.strip
    }

    /// True for an event the swipe keeps for itself.
    private func takes(_ event: NSEvent) -> Bool {
        // The window the fingers are over, at the start of a gesture or a
        // turn of the wheel; the rest of a gesture stays with it.
        if event.phase == .began || !event.hasPreciseScrollingDeltas, let over = Browsers.browser(for: event.window) {
            browser = over
        }
        guard let browser, browser.prefs.usesSpaces, !browser.folded || browser.peeking else { return false }
        // A mouse wheel over the tabs: a notch along the spaces' axis — up or down
        // in the bar, sideways in the column — brings one space. In the column
        // only a notch more sideways than up or down: scrolling the tabs is
        // never taken for it.
        if !event.hasPreciseScrollingDeltas {
            let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
            let step = browser.prefs.sidebar ? (abs(dx) > abs(dy) ? dx : 0) : dy
            guard step != 0, overTabs(event, in: browser) else { return false }
            let now = Date()
            let rested = now.timeIntervalSince(notched) > 0.3 && now > resting
            notched = now
            guard rested else { return true }
            let here = shown(browser)
            let target = here + (step < 0 ? 1 : -1)
            if let other = beyond(browser, target) {
                leave(browser, for: other, step: target - here)
            } else if target >= 0, target <= browser.spaces.count {
                slide(browser, to: target, from: here)
            }
            return true
        }
        if !event.momentumPhase.isEmpty { return gliding }
        if tracking || event.phase == .began { fingersAt = CACurrentMediaTime() }
        switch event.phase {
        case .mayBegin:
            fingersDown = true
            return false
        case .began:
            fingersDown = true
            gliding = false
            ignoring = false
            // Only a gesture that starts over the tabs.
            guard overTabs(event, in: browser) else {
                tracking = false
                return false
            }
            began()
            if ignoring { return true }
            return moved(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY)
        case .changed:
            if ignoring { return true }
            guard tracking else { return false }
            return moved(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY)
        case .ended, .cancelled:
            fingersDown = false
            // Fingers lifted without going anywhere: the space can come.
            if !tracking, SwipeGlide.idle { landSoon(browser) }
            if ignoring {
                ignoring = false
                gliding = true
                return true
            }
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
        // The fingers take the rows from wherever a slide has them: in the
        // column, once they move them (moved), the space on its way in not
        // taken yet; in the bar, taken now.
        if browser?.prefs.sidebar != true { SwipeGlide.stop() }
        holding = false
        axis = .undecided
        gathered = .zero
        trail = []
        // Just after a space came, the hand's next stroke is let go by if
        // it goes back the way it came (moved): that is the hand coming back.
        // On the same way it is the next space, quickly — every stroke let
        // go by for 0.4 s, a quick run across the spaces stalled at each.
        early = Date() <= resting
        ignoring = false
        tracking = true
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
            // Scrolling the rows: those of the space on its way in.
            if axis == .along { land(browser) }
        }
        guard axis == .across else { return false }
        if early {
            early = false
            // Fingers to the left bring the next space (ended).
            let step = gathered.width < 0 ? 1 : -1
            if step != lastStep {
                ignoring = true
                tracking = false
                return true
            }
        }
        if !holding {
            holding = true
            // Scrolled since the map drew this space: drawn again, as the
            // column is now.
            if browser.mapScroll(fits: browser.mapDrew.fits) != browser.mapDrew.scrolled { browser.mapDrawn.value += 1 }
            SwipeGlide.pause()
            // From where they are, not jumping the few points it took to
            // tell which way the fingers go.
            base = browser.spaceSwipe == 0 ? 0 : browser.spaceSwipe - resisted(gathered.width, in: browser)
        }
        browser.spaceSwipe = base + resisted(gathered.width, in: browser)
        let now = CACurrentMediaTime()
        trail.append((now, browser.spaceSwipe))
        trail.removeAll { now - $0.at > 0.08 }
        return true
    }

    /// How fast the fingers were carrying the rows over their last moves.
    private func fingerSpeed() -> CGFloat {
        guard let first = trail.first, let last = trail.last, last.at - first.at > 0.008 else { return 0 }
        return (last.x - first.x) / CGFloat(last.at - first.at)
    }

    /// Along the spaces' axis, whichever it is — for the bench.
    @discardableResult
    func moved(along travel: CGFloat) -> Bool {
        guard let browser else { return false }
        return browser.prefs.sidebar ? moved(dx: travel, dy: 0) : moved(dx: 0, dy: travel)
    }

    func ended(cancelled: Bool = false) {
        let held = holding
        tracking = false
        holding = false
        guard let browser, axis == .across, held else { return }
        let travel = gathered.width
        let speed = fingerSpeed()
        let here = shown(browser)
        // Far enough, or a flick: short, but quick and still going that way
        // as the fingers let go. Only the distance counted, and a quick
        // stroke, over before it had gone far, snapped back as if not made.
        let flick = abs(travel) >= 12 && abs(speed) > 400 && (speed < 0) == (travel < 0)
        let far = abs(travel) >= SpaceSwipe.enough(for: browser) || flick
        // Fingers to the left, or up, bring what is next.
        let target = cancelled || !far ? here : here + (travel < 0 ? 1 : -1)
        if target != here, let other = beyond(browser, target) {
            leave(browser, for: other, step: target - here)
            return
        }
        guard target != here, target >= 0, target <= browser.spaces.count else {
            // Back where they were: the space on screen, or on its way in.
            if let coming = browser.spaceComing, !browser.makingSpace, !Motion.reduced {
                letGoSpeed = speed
                bring(browser, coming, step: lastStep)
                letGoSpeed = nil
            } else if Motion.reduced {
                browser.spaceSwipe = 0
            } else {
                SwipeGlide.start(browser, to: 0, speed: speed)
            }
            return
        }
        letGoSpeed = speed
        slide(browser, to: target, from: here)
        letGoSpeed = nil
    }

    /// Nothing that way: the rows give a little, and come back.
    private func resisted(_ travel: CGFloat, in browser: Browser) -> CGFloat {
        let here = shown(browser)
        let blocked = (travel > 0 && here == 0 && browser.profileBeyond(-1) == nil) || (travel < 0 && here == browser.spaces.count)
        return blocked ? travel / 4 : travel
    }

    /// The pages carry on the way the fingers went until the next one is
    /// where this one was; then it becomes the one on screen, in the same
    /// frame and without anything moving — it was already there. One past
    /// the last space is the card for a new one.
    func slide(_ browser: Browser, to target: Int, from here: Int) {
        if browser.makingSpace, target != browser.spaces.count {
            browser.cancelSpaceCreation()
        }
        let width = SpaceSwipe.page(browser)
        let away: CGFloat = target > here ? -1 : 1
        browser.spaceStep = target > here ? 1 : -1
        resting = Date().addingTimeInterval(SpaceSwipe.rest)
        lastStep = browser.spaceStep
        // Another space: its page in front the moment the fingers let go,
        // its rows carried on into place from where they left them, and the
        // space taken once they stand there (bring). The card for a new
        // space, as before.
        if target < browser.spaces.count, !Motion.reduced {
            bring(browser, browser.spaces[target].id, step: target > here ? 1 : -1)
            return
        }
        // From the space the column shows, taken first.
        land(browser)
        carry(browser, to: away * width) {
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
        browser.cancelSpaceCreation()
        let back = browser.spaces.firstIndex { $0.id == browser.spaceID } ?? 0
        SpaceSwipe.shared.slide(browser, to: back, from: browser.spaces.count)
    }
}

/// How far a swipe between spaces has carried the rows (`Browser.spaceSwipe`).
final class SwipeOffset: ObservableObject {
    @Published var value: CGFloat = 0
    /// One that never moves, for what stands still while the rest move.
    static let still = SwipeOffset()
}

/// Which way a swipe between spaces has carried the rows, -1, 0 or 1
/// (`Browser.swipeSide`): what decides whether a neighbour's rows are drawn.
/// Kept apart, for the pages alone (SwipeSided): published by the browser,
/// each swipe's start and end drew the whole window again, every row with
/// it, and the rows waited up to a tenth of a second to follow the fingers.
final class SwipeSide: ObservableObject {
    @Published var value = 0
}

/// Out of sight while a swipe is under way.
struct SwipeHides: ViewModifier {
    @ObservedObject var side: SwipeSide

    func body(content: Content) -> some View {
        content.opacity(side.value == 0 ? 1 : 0)
    }
}

/// The card for a new space beside the last, while the fingers bring it.
/// Its own view, told only what it needs: drawn by the column, in a closure
/// holding all of it, each swipe's start built the column's graph over
/// again, about 30 ms before the rows moved.
struct SwipeCard: View {
    @ObservedObject var side: SwipeSide
    let browser: Browser
    var at = 0
    var width: CGFloat = 0
    /// In the bar across the top: one row, coming up from below.
    var inline = false

    var body: some View {
        if inline, side.value < 0 {
            NewSpaceCard(browser: browser, inline: true)
                .fixedSize()
                .allowsHitTesting(false)
                .modifier(SwipeShift(offset: browser.spaceSwipeOffset, by: Metrics.strip))
        } else if !inline, side.value < 0, at + 1 >= browser.spaces.count, browser.drawsPage(after: at) {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                NewSpaceCard(browser: browser)
                Spacer(minLength: 0)
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
            .padding(.horizontal, 10)
            .frame(width: width, alignment: .topLeading)
            .modifier(SwipeShift(offset: browser.spaceSwipeOffset, by: width, across: true))
        }
    }
}

/// Content made again only as the swipe turns to another side.
struct SwipeSided<Content: View>: View {
    @ObservedObject var side: SwipeSide
    @ViewBuilder var content: (Int) -> Content

    var body: some View { content(side.value) }
}

/// Moves what it is put on with the swipe, `by` further, along one axis: the
/// one view that redraws as the fingers go.
struct SwipeShift: ViewModifier {
    @ObservedObject var offset: SwipeOffset
    var by: CGFloat = 0
    var across = false
    /// A page's width, for a page of the map: out of the way, standing
    /// still, while nothing moves or while it is a whole page or more away.
    var park: CGFloat?
    @Environment(\.displayScale) private var scale

    func body(content: Content) -> some View {
        let shift = place
        return content.offset(x: across ? shift : 0, y: across ? 0 : shift)
    }

    private var place: CGFloat {
        let shift = offset.value + by
        if let park, offset.value == 0 || abs(shift) >= park { return 4 * park }
        // On the screen's own pixels: moved by fractions of one, the titles
        // were drawn afresh at each frame, a little further between two
        // pixels, and flickered as the rows went slowly by.
        return (shift * scale).rounded() / scale
    }
}

/// The rows carried the rest of the way into place after a space has come
/// — let go of mid-swipe, or with ⌃1–⌃9 — on a spring, a frame at a time,
/// set as the fingers set them. Not a SwiftUI animation: in one, the rows
/// just given another space's tabs (Browser.rowKey) were caught changing —
/// their titles faded over, and the ground of the tab in front glided after
/// its row, out of step with it.
///
/// Critically damped, as Arc's and Dia's spaces move: under way gently with
/// ⌃1–⌃9, or on at the fingers' own speed as they let go, slowing into place
/// and never past it, settled in about a fifth of a second. Eased out over
/// a fixed 0.22 s, it set off at its fastest whatever the fingers had been
/// doing, and the rows whipped across rather than travelled.
@MainActor
final class SwipeGlide: NSObject {
    private static var current: SwipeGlide?

    private let browser: Browser
    private var from: CGFloat
    private var to: CGFloat
    private let speed: CGFloat?
    /// What to do as the rows come within a few points of their place,
    /// once: the space taken there (SpaceSwipe.bring), its rows' place
    /// handed back. Taken only once they stood still, the step that takes
    /// it fell late — a stroke begun before had to wait for it first.
    private var land: (() -> CGFloat)?
    private let done: () -> Void
    private var began: CFTimeInterval?
    private var stepped: CFTimeInterval = 0
    private var link: CADisplayLink?
    /// Steps it on when no frame comes: a window that isn't drawn — a hidden
    /// one, as the bench's — gets none, and the rows stayed out of place.
    private var watch: Timer?
    /// How quickly the spring pulls, a second: most of the way in a tenth
    /// of a second, within a point of its place in a fifth. At 20, a slide
    /// took 0.4 s, and at 26 a third of a second: it felt slow, and the
    /// next stroke often had to wait for it.
    private static let pull: Double = 34

    private init(_ browser: Browser, to: CGFloat, speed: CGFloat?, land: (() -> CGFloat)?, done: @escaping () -> Void) {
        self.browser = browser
        from = browser.spaceSwipe
        self.to = to
        self.speed = speed
        self.land = land
        self.done = done
    }

    /// From where the rows are now to `to`, setting off at `speed` points a
    /// second — the fingers' own; without, at half the spring's own pace —
    /// `land` as they come within a few points of it, and then `done`.
    static func start(_ browser: Browser, to: CGFloat = 0, speed: CGFloat? = nil,
                      land: (() -> CGFloat)? = nil, done: @escaping () -> Void = {}) {
        stop()
        let glide = SwipeGlide(browser, to: to, speed: speed, land: land, done: done)
        guard let view = browser.window?.contentView else {
            glide.finish()
            return
        }
        current = glide
        let link = view.displayLink(target: glide, selector: #selector(frame))
        // As fast as the screen goes, for the moment it lasts:
        // left to choose, the system stepped it at 60 or less on a 120 Hz
        // screen, and the rows moved in visible steps.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        glide.link = link
        link.add(to: .main, forMode: .common)
        let watch = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak glide] _ in
            MainActor.assumeIsolated {
                guard let glide, CACurrentMediaTime() - glide.stepped > 0.05 else { return }
                glide.step(at: CACurrentMediaTime())
            }
        }
        glide.watch = watch
        RunLoop.main.add(watch, forMode: .common)
    }

    /// The fingers have the rows now, or another slide does: this one
    /// done at once, where it was going — a space on its way in comes.
    static func stop() {
        guard let glide = current else { return }
        current = nil
        glide.end()
        glide.finish()
    }

    /// No slide under way.
    static var idle: Bool { current == nil }

    /// The fingers have the rows: this one stopped where it had them, and
    /// nothing more done.
    static func pause() {
        current?.end()
        current = nil
    }

    /// The rows' place moved by `shift` under it, the same frame as the
    /// rows: a space taken while it slides (SpaceSwipe.land).
    static func rebase(by shift: CGFloat) {
        guard let glide = current else { return }
        glide.from += shift
        glide.to += shift
    }

    /// In its place: landed, if it hadn't, and done.
    private func finish() {
        if let land {
            self.land = nil
            to = land()
        }
        browser.spaceSwipe = to
        done()
    }

    private func end() {
        link?.invalidate()
        watch?.invalidate()
    }

    @objc private func frame(_ link: CADisplayLink) { step(at: link.timestamp) }

    private func step(at now: CFTimeInterval) {
        stepped = CACurrentMediaTime()
        // Timed from the first frame, not from the call: the frame that
        // brings a space comes late, and timed from before it, the rows
        // jumped most of the way in at once.
        let began = self.began ?? now
        self.began = began
        let t = now - began
        // How far from its place, and how fast it closes in: x(t) =
        // (x0 + (v0 + ωx0)t)e^(−ωt), its speed (v0 − ω(v0 + ωx0)t)e^(−ωt).
        // Not set off by the fingers (⌃1–⌃9, the menu, the mouse's
        // buttons): under way at once, gently. From rest, the first moment
        // barely moved and the key seemed not to have been taken; at the
        // spring's whole pace, the rows whipped off.
        let w = Self.pull, x0 = Double(from - to), v0 = speed.map(Double.init) ?? -0.5 * w * x0
        let fade = exp(-w * t)
        var x = (x0 + (v0 + w * x0) * t) * fade
        let v = (v0 - w * (v0 + w * x0) * t) * fade
        // A flick faster than the spring would have it goes all the way and
        // stops there, rather than past its place and back.
        if x * x0 < 0 { x = 0 }
        if abs(x) < 3, let land {
            self.land = nil
            to = land()
        }
        browser.spaceSwipe = to + CGFloat(x)
        guard x == 0 || (abs(x) < 1 && abs(v) < 30) || t > 0.8 else { return }
        end()
        if Self.current === self { Self.current = nil }
        finish()
    }
}
