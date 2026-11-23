import AppKit
import SwiftUI
import XCTest
@testable import Search

/// The two spaces a swipe has in sight, the window's colour going from the
/// one to the other as the rows do, and where the mark under the space
/// buttons stands on the way.
@MainActor
final class SwipeBlendTests: XCTestCase {
    private var browser: Browser!
    private var ids: [UUID] = []
    private var oldUsesSpaces = false
    private var oldSidebar = true
    private var oldSpaces: [Space] = []

    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        oldUsesSpaces = browser.prefs.usesSpaces
        oldSidebar = browser.prefs.sidebar
        oldSpaces = browser.spaces
        browser.prefs.usesSpaces = true
        browser.prefs.sidebar = true
        let first = browser.spaceID
        ids = [first, UUID(), UUID(), UUID()]
        browser.spaces = [Space(id: ids[0], name: "One", colour: 1),
                          Space(id: ids[1], name: "Two", colour: 2),
                          Space(id: ids[2], name: "Three", colour: 0),
                          Space(id: ids[3], name: "Four", colour: 3)]
        browser.closeAll()
        browser.showRow([], active: nil, blank: true)
    }

    override func tearDown() {
        browser.spaceComing = nil
        browser.comingSlot = 0
        browser.spaceStep = 1
        browser.spaceSwipe = 0
        browser.closeAll()
        browser.prefs.usesSpaces = oldUsesSpaces
        browser.prefs.sidebar = oldSidebar
        browser.spaces = oldSpaces
        browser = nil
        super.tearDown()
    }

    private var page: CGFloat { SpaceSwipe.page(browser) }
    private var ends: SwipeEnds? { browser.swipeBlend.ends }
    private var toward: CGFloat { browser.swipeToward.value }
    private var place: CGFloat? { ends?.place(toward, count: browser.spaces.count) }

    /// A quarter of the way to the next space, a quarter of its colour;
    /// brought back, this space's alone, and nothing under way.
    func testTheColourGoesWithTheRowsAndBack() {
        browser.spaceSwipe = -0.25 * page
        XCTAssertEqual(ends?.near.id, ids[0])
        XCTAssertEqual(ends?.far.id, ids[1])
        XCTAssertEqual(toward, 0.25, accuracy: 0.001)
        browser.spaceSwipe = -0.75 * page
        XCTAssertEqual(toward, 0.75, accuracy: 0.001)
        browser.spaceSwipe = 0
        XCTAssertNil(ends)
        XCTAssertEqual(toward, 0)
    }

    /// The one lit is the one more than half in sight; at half, still this one.
    func testTheSpaceMoreThanHalfInSight() {
        browser.spaceSwipe = -0.5 * page
        XCTAssertEqual(browser.swipeBlend.space?.id, ids[0])
        browser.spaceSwipe = -0.6 * page
        XCTAssertEqual(browser.swipeBlend.space?.id, ids[1])
        browser.spaceSwipe = -0.3 * page
        XCTAssertEqual(browser.swipeBlend.space?.id, ids[0])
    }

    /// Going back, the space before fades in, and past a whole page the
    /// pair is the next two along.
    func testBackAndOnPastAPage() {
        browser.switchSpace(to: ids[1])
        browser.spaceSwipe = 0.3 * page
        XCTAssertEqual(ends?.near.id, ids[0])
        XCTAssertEqual(ends?.far.id, ids[1])
        XCTAssertEqual(toward, 0.7, accuracy: 0.001)
        browser.spaceSwipe = -1.4 * page
        XCTAssertEqual(ends?.near.id, ids[2])
        XCTAssertEqual(ends?.far.id, ids[3])
        XCTAssertEqual(place ?? -1, 2.4, accuracy: 0.001)
    }

    /// Before the first space nothing is drawn: its colour stays, and the
    /// mark stops at its button.
    func testNothingBeforeTheFirst() {
        browser.spaceSwipe = 0.3 * page
        XCTAssertEqual(ends?.near.id, ids[0])
        XCTAssertEqual(ends?.far.id, ids[0])
        XCTAssertEqual(place ?? -1, 0, accuracy: 0.001)
    }

    /// A space from further along slides in beside this one (⌃4): that is
    /// the one faded to, and the mark crosses the buttons between as the
    /// rows cover one page. Carried on past it, the space that lies there
    /// in order comes next, the mark turning back to its button.
    func testSpaceFromFurtherAlong() {
        browser.spaceComing = ids[3]
        browser.comingSlot = 1
        // Told once both are, as the slide sets off (SpaceSwipe.glide).
        browser.swipeShown()
        XCTAssertEqual(ends?.near.id, ids[0])
        XCTAssertEqual(toward, 0)
        browser.spaceSwipe = -0.3 * page
        XCTAssertEqual(ends?.far.id, ids[3])
        XCTAssertEqual(place ?? -1, 0.9, accuracy: 0.001)
        browser.spaceSwipe = -1.6 * page
        XCTAssertEqual(ends?.near.id, ids[3])
        XCTAssertEqual(ends?.far.id, ids[2])
        XCTAssertEqual(browser.swipeBlend.space?.id, ids[2])
        XCTAssertEqual(place ?? -1, 2.4, accuracy: 0.001)
    }

    /// The card for a new space has no colour of its own: nothing is faded.
    func testNothingWhileMakingASpace() {
        browser.makingSpace = true
        defer { browser.makingSpace = false }
        browser.spaceSwipe = -0.9 * page
        XCTAssertNil(ends)
    }

    /// A space given a new colour, or taken away, under the fingers: the
    /// washes read it as it is now, and the next step tells it again.
    func testTheSpacesChangingMidSwipe() {
        browser.spaceSwipe = -0.7 * page
        browser.spaces[1].colour = 5
        if let far = ends?.far {
            XCTAssertEqual(SwipeBlend.look(of: far, in: browser.spaces).look, .colour(5))
        } else {
            XCTFail("nothing in sight")
        }
        browser.spaceSwipe = -0.71 * page
        XCTAssertEqual(ends?.far.colour, 5)
        browser.spaces.remove(at: 1)
        browser.spaceSwipe = -0.72 * page
        XCTAssertEqual(ends?.far.id, ids[2])
    }

    /// What a space washes with: its look, as strongly as it asks, and
    /// Subtle for one with none.
    func testTheLookOfASpace() {
        var two = browser.spaces[1]
        two.strength = .vivid
        XCTAssertEqual(SwipeBlend.look(of: two, in: []).look, .colour(2))
        XCTAssertEqual(SwipeBlend.look(of: two, in: []).strength, .vivid)
        var three = browser.spaces[2]
        three.strength = .vivid
        XCTAssertNil(SwipeBlend.look(of: three, in: []).look)
        XCTAssertEqual(SwipeBlend.look(of: three, in: []).strength, .subtle)
    }

    /// In the bar across the top only the space above or below is drawn,
    /// one sliding in from further along on the side it comes from.
    func testInTheBarOnlyTheSpaceAboveOrBelow() {
        browser.prefs.sidebar = false
        browser.spaceSwipe = -0.6 * page
        XCTAssertEqual(ends?.far.id, ids[1])
        browser.spaceSwipe = -1.6 * page
        XCTAssertEqual(ends?.near.id, ids[1])
        XCTAssertEqual(ends?.far.id, ids[1])
        browser.spaceComing = ids[3]
        browser.spaceStep = 1
        browser.spaceSwipe = -0.5 * page
        XCTAssertEqual(ends?.far.id, ids[3])
        XCTAssertEqual(place ?? -1, 1.5, accuracy: 0.001)
    }

    /// Spaces off: nothing faded whatever the rows do.
    func testNothingWithSpacesOff() {
        browser.prefs.usesSpaces = false
        browser.spaceSwipe = -0.6 * page
        XCTAssertNil(ends)
    }

    /// Squeezed in a narrowed column (idea 1010), each button narrower than
    /// 26: the mark stands under the lit one, as wide as it, not where 26
    /// points each would put it.
    func testTheMarkUnderSqueezedButtons() throws {
        let oldButtons = browser.prefs.spaceButtons
        defer { browser.prefs.spaceButtons = oldButtons; browser.spaceHeading = nil }
        browser.prefs.spaceButtons = true
        browser.spaceHeading = ids[3]
        // Four buttons 22 wide, 2 between: the last from 72 to 94.
        let width: CGFloat = 94
        let host = NSHostingView(rootView: SpaceButtons(browser: browser, squeezes: true)
            .frame(width: width, height: 26)
            .background(Color.white))
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: width, height: 26),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / width
        // Orange, the fourth space's: the mark and its glyph, where the
        // other buttons' glyphs are grey.
        let orange: [Int] = (0..<rep.pixelsWide).filter { x in
            guard let c = rep.colorAt(x: x, y: Int(13 * scale))?.usingColorSpace(.deviceRGB) else { return false }
            return c.redComponent - c.blueComponent > 0.08
        }
        let first = try XCTUnwrap(orange.first, "the mark is drawn")
        let last = try XCTUnwrap(orange.last)
        XCTAssertEqual(CGFloat(first) / scale, 72, accuracy: 1)
        XCTAssertEqual(CGFloat(last + 1) / scale, 94, accuracy: 1)
    }
}
