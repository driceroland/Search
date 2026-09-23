import SwiftUI

// Spaces in the column: two fingers sideways go from one to the next, the
// rows following them, as in Arc. Past the last space the column offers to
// make a new one, in place. The dots at its foot are the spaces in order —
// a click goes to one, dragging one puts it elsewhere.

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

    /// Out the way the fingers went, and the next one in from the other side.
    /// One past the last space is the card for a new one.
    func slide(_ browser: Browser, to target: Int, from here: Int) {
        let width = browser.prefs.sideWidth
        let away: CGFloat = target > here ? -1 : 1
        withAnimation(.easeIn(duration: 0.12)) { browser.spaceSwipe = away * width }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            if target == browser.spaces.count {
                browser.makingSpace = true
            } else {
                browser.makingSpace = false
                browser.switchSpace(to: browser.spaces[target].id)
            }
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) { browser.spaceSwipe = -away * width }
            withAnimation(Motion.glide) { browser.spaceSwipe = 0 }
        }
    }
}

// MARK: - the card

/// A new space, made where the next one would have been: its name, its
/// colour, and on its way. Escape, Cancel or two fingers back leave it.
struct NewSpaceCard: View {
    @ObservedObject var browser: Browser
    @State private var name = ""
    @State private var colour = 0
    @FocusState private var typing: Bool

    var body: some View {
        VStack(spacing: 12) {
            Circle()
                .fill(Spaces.colours[colour % Spaces.colours.count])
                .frame(width: 22, height: 22)
            VStack(spacing: 4) {
                Text("New space")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text("Its own tabs, cookies and sign-ins.")
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
            HStack(spacing: 8) {
                ForEach(Spaces.colours.indices, id: \.self) { i in
                    Circle()
                        .fill(Spaces.colours[i])
                        .frame(width: 14, height: 14)
                        .overlay(
                            Circle().strokeBorder(Palette.ink.opacity(i == colour ? 0.55 : 0), lineWidth: 1.5)
                                .frame(width: 20, height: 20)
                        )
                        .frame(width: 20, height: 20)
                        .contentShape(Circle())
                        .onTapGesture { colour = i }
                        .help(Spaces.colourNames[i])
                }
            }
            HStack(spacing: 8) {
                Pill("Cancel") { cancel() }
                Pill("Create", filled: true) { create() }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .onAppear {
            colour = browser.freeColour
            DispatchQueue.main.async { typing = true }
        }
        .onExitCommand(perform: cancel)
    }

    private func create() {
        let named = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !named.isEmpty else { typing = true; return }
        browser.addSpace(named: named, colour: colour)
    }

    private func cancel() {
        withAnimation(Motion.glide) { browser.makingSpace = false }
    }
}

// MARK: - the dots

/// Every space, in order, as a dot of its colour at the column's foot — the
/// one on screen larger. A click goes to a space, a click on the one on
/// screen opens its menu, and a dot dragged sideways takes its space to
/// another place in the order (⌃1–⌃9 follow it).
struct SpaceDots: View {
    @ObservedObject var browser: Browser

    @State private var dragging: UUID?
    @State private var from = 0
    @State private var travel: CGFloat = 0

    static let step: CGFloat = 18

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(browser.spaces.enumerated()), id: \.element.id) { index, space in
                let held = dragging == space.id
                let here = space.id == browser.spaceID && !browser.makingSpace
                Circle()
                    .fill(Spaces.colours[space.colour % Spaces.colours.count])
                    .frame(width: here ? 9 : 6, height: here ? 9 : 6)
                    .opacity(here || held ? 1 : 0.45)
                    .frame(width: SpaceDots.step, height: 26)
                    .contentShape(Rectangle())
                    // The row makes way while the dot keeps to the hand (see the tabs').
                    .offset(x: held ? travel - CGFloat(index - from) * SpaceDots.step : 0)
                    .transaction { if held { $0.animation = nil } }
                    .zIndex(held ? 1 : 0)
                    .onTapGesture {
                        if here { SpaceMenu.show(for: browser) } else { browser.switchSpace(to: space.id) }
                    }
                    .gesture(reorder(space, index: index))
                    .help(here ? "\(space.name) — click for its menu" : space.name)
            }
            if browser.makingSpace {
                Image(systemName: "plus")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Palette.ink)
                    .frame(width: SpaceDots.step, height: 26)
                    .transition(.opacity)
            }
        }
        .animation(Motion.settle, value: browser.spaces.map(\.id))
        .animation(Motion.quick, value: browser.spaceID)
        .animation(Motion.quick, value: browser.makingSpace)
    }

    private func reorder(_ space: Space, index: Int) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { value in
                if dragging != space.id {
                    dragging = space.id
                    from = index
                }
                travel = value.translation.width
                let target = min(max(0, from + Int((travel / SpaceDots.step).rounded())), browser.spaces.count - 1)
                if target != index {
                    withAnimation(Motion.settle) { browser.moveSpace(space.id, to: target) }
                }
            }
            .onEnded { _ in
                withAnimation(Motion.settle) {
                    dragging = nil
                    travel = 0
                }
            }
    }
}
