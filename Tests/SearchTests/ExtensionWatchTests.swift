import XCTest
@testable import Search

/// What the browser keeps for extensions that listen for tab groups or for
/// idleness (ExtensionWatch.swift): nothing at all while none does, and one
/// word on a port, not a reading for each, when something changes.
@MainActor
final class ExtensionWatchTests: XCTestCase {
    /// A context to speak to, and what it was told.
    @MainActor private final class Context {
        var told: [[String: Any]] = []
        var alive = true
        lazy var ear = ExtensionEar(extensionID: "test", say: { [unowned self] in told.append($0) }, hears: { [unowned self] in alive })
    }

    // MARK: groups

    private func shape(_ id: Int, _ name: String, collapsed: Bool = false) -> GroupWatch.Shape {
        GroupWatch.Shape(id: UUID(uuid: (UInt8(id), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)), name: name, collapsed: collapsed)
    }

    @MainActor private final class Groups {
        var now: Set<GroupWatch.Shape> = []
        var reads = 0
        var deferred: [() -> Void] = []
        lazy var watch = GroupWatch(read: { [unowned self] in reads += 1; return now }, soon: { [unowned self] in deferred.append($0) })
        func run() { let work = deferred; deferred = []; work.forEach { $0() } }
    }

    func testGroupsAreNeitherReadNorScheduledWhileNobodyListens() {
        let groups = Groups()
        for _ in 0..<5 { groups.watch.changed() }
        XCTAssertEqual(groups.reads, 0)
        XCTAssertTrue(groups.deferred.isEmpty)
        XCTAssertFalse(groups.watch.isListened)
    }

    func testAGroupChangeIsOneWordToEachListener() {
        let groups = Groups(), first = Context(), second = Context()
        groups.now = [shape(1, "Reading")]
        groups.watch.add(first.ear)
        groups.watch.add(second.ear)
        groups.watch.add(second.ear)
        XCTAssertEqual(groups.reads, 1, "the groups as they are, once, as the first one starts to listen")

        groups.now = [shape(1, "Later"), shape(2, "Work")]
        for _ in 0..<4 { groups.watch.changed() }
        XCTAssertEqual(groups.deferred.count, 1, "several changes at once are one look")
        XCTAssertTrue(first.told.isEmpty, "nothing is said before the change has been made")
        groups.run()
        XCTAssertEqual(groups.reads, 2)
        XCTAssertEqual(first.told.count, 1)
        XCTAssertEqual(first.told.first?["changed"] as? Bool, true)
        XCTAssertEqual(second.told.count, 1, "listening twice is still one ear")
    }

    func testAChangeAnExtensionCannotSeeIsNotSaid() {
        let groups = Groups(), context = Context()
        groups.now = [shape(1, "Reading")]
        groups.watch.add(context.ear)
        // A tab opened or closed in a group that stays what it was.
        groups.watch.changed()
        groups.run()
        XCTAssertTrue(context.told.isEmpty)
        // Folded, which an extension sees.
        groups.now = [shape(1, "Reading", collapsed: true)]
        groups.watch.changed()
        groups.run()
        XCTAssertEqual(context.told.count, 1)
        // The same again says nothing more.
        groups.watch.changed()
        groups.run()
        XCTAssertEqual(context.told.count, 1)
    }

    func testAContextThatHasGoneIsDroppedAndTheLastOneGoingStopsTheWatch() {
        let groups = Groups(), gone = Context(), staying = Context()
        groups.watch.add(gone.ear)
        groups.watch.add(staying.ear)
        gone.alive = false
        groups.now = [shape(1, "New")]
        groups.watch.changed()
        groups.run()
        XCTAssertTrue(gone.told.isEmpty)
        XCTAssertEqual(staying.told.count, 1)
        groups.watch.remove(staying.ear)
        XCTAssertFalse(groups.watch.isListened)
        let reads = groups.reads
        groups.watch.changed()
        XCTAssertTrue(groups.deferred.isEmpty)
        XCTAssertEqual(groups.reads, reads)
    }

    // MARK: idle

    /// A clock that never ticks by itself: what was scheduled and cancelled.
    @MainActor private final class Idle {
        var reading = IdleWatch.Reading(locked: false, quiet: 0)
        var scheduled: [(delay: TimeInterval, work: () -> Void, cancelled: Bool)] = []
        var observing = 0
        var stoppedObserving = 0
        lazy var watch = IdleWatch(
            read: { [unowned self] in reading },
            after: { [unowned self] delay, work in
                scheduled.append((delay, work, false))
                let index = scheduled.count - 1
                return { [unowned self] in scheduled[index].cancelled = true }
            },
            signals: { [unowned self] _ in
                observing += 1
                return { [unowned self] in stoppedObserving += 1 }
            })
        var pending: [(delay: TimeInterval, work: () -> Void, cancelled: Bool)] { scheduled.filter { !$0.cancelled } }
        /// Time passes to the next look, which is made.
        func tick() { pending.last?.work() }
    }

    func testNothingIsScheduledOrObservedForIdlenessWhileNobodyListens() {
        let idle = Idle()
        XCTAssertFalse(idle.watch.isRunning)
        XCTAssertTrue(idle.scheduled.isEmpty)
        XCTAssertEqual(idle.observing, 0)
    }

    func testIdleIsLookedForWhenItCouldBeginNotEveryFifteenSeconds() {
        let idle = Idle(), context = Context()
        idle.reading = .init(locked: false, quiet: 10)
        idle.watch.add(context.ear, threshold: 60)
        XCTAssertTrue(context.told.isEmpty, "active, as the shim begins")
        XCTAssertEqual(idle.pending.count, 1, "one look, not a timer that repeats")
        XCTAssertEqual(idle.pending.first?.delay, 51, "the 50 s still to go, and a second over")
        XCTAssertEqual(idle.observing, 1)

        idle.reading = .init(locked: false, quiet: 61)
        idle.tick()
        XCTAssertEqual(context.told.map { $0["state"] as? String }, ["idle"])
        XCTAssertEqual(idle.pending.count, 1)
        XCTAssertEqual(idle.pending.first?.delay, 15, "coming back is looked for as often as it was")
    }

    func testSomeoneWhoWasActiveInTheMeantimePutsTheLookOff() {
        let idle = Idle(), context = Context()
        idle.reading = .init(locked: false, quiet: 10)
        idle.watch.add(context.ear, threshold: 60)
        idle.reading = .init(locked: false, quiet: 2)
        idle.tick()
        XCTAssertTrue(context.told.isEmpty)
        XCTAssertEqual(idle.pending.first?.delay, 59)
    }

    func testLockingIsToldAtOnceAndWaitsForTheUnlock() {
        let idle = Idle(), context = Context()
        idle.watch.add(context.ear, threshold: 60)
        idle.reading = .init(locked: true, quiet: 3)
        idle.watch.check()
        XCTAssertEqual(context.told.map { $0["state"] as? String }, ["locked"])
        XCTAssertEqual(idle.pending.count, 1)
        XCTAssertGreaterThanOrEqual(idle.pending.first?.delay ?? 0, 60, "no quick look while locked")
        idle.reading = .init(locked: false, quiet: 1)
        idle.watch.check()
        XCTAssertEqual(context.told.map { $0["state"] as? String }, ["locked", "active"])
    }

    func testTheNearestLookServesEveryListener() {
        let idle = Idle(), short = Context(), long = Context()
        idle.reading = .init(locked: false, quiet: 20)
        idle.watch.add(long.ear, threshold: 300)
        idle.watch.add(short.ear, threshold: 30)
        XCTAssertEqual(idle.pending.count, 1, "the earlier look is put off, not kept")
        XCTAssertEqual(idle.pending.first?.delay, 11)
        idle.reading = .init(locked: false, quiet: 31)
        idle.tick()
        XCTAssertEqual(short.told.count, 1)
        XCTAssertTrue(long.told.isEmpty)
    }

    func testTheLastListenerGoingEndsTheLooksAndTheObserving() {
        let idle = Idle(), first = Context(), second = Context()
        idle.watch.add(first.ear, threshold: 60)
        idle.watch.add(second.ear, threshold: 60)
        XCTAssertEqual(idle.observing, 1, "one observer for both")
        idle.watch.remove(first.ear)
        XCTAssertTrue(idle.watch.isRunning)
        idle.watch.remove(second.ear)
        XCTAssertFalse(idle.watch.isRunning)
        XCTAssertTrue(idle.pending.isEmpty, "nothing left scheduled")
        XCTAssertEqual(idle.stoppedObserving, 1)
    }

    func testAContextThatHasGoneEndsTheLooksAtTheNextOne() {
        let idle = Idle(), context = Context()
        idle.watch.add(context.ear, threshold: 60)
        context.alive = false
        idle.tick()
        XCTAssertFalse(idle.watch.isRunning)
        XCTAssertTrue(idle.pending.isEmpty)
    }

    func testAListenerAddedAgainIsToldWhatItMayHaveMissed() {
        let idle = Idle(), context = Context()
        idle.reading = .init(locked: false, quiet: 100)
        idle.watch.add(context.ear, threshold: 60)
        XCTAssertEqual(context.told.count, 1)
        // The shim says hello again (its first may have been lost): it starts
        // from active, so idle is said once more.
        context.ear.told = "active"
        idle.watch.add(context.ear, threshold: 60)
        XCTAssertEqual(context.told.count, 2)
        XCTAssertEqual(idle.pending.count, 1)
    }

    func testStateAndWait() {
        typealias R = IdleWatch.Reading
        XCTAssertEqual(IdleWatch.state(R(locked: false, quiet: 59), threshold: 60), "active")
        XCTAssertEqual(IdleWatch.state(R(locked: false, quiet: 60), threshold: 60), "idle")
        XCTAssertEqual(IdleWatch.state(R(locked: true, quiet: 600), threshold: 60), "locked", "locked beats idle")
        XCTAssertEqual(IdleWatch.wait(after: "active", quiet: 0, threshold: 60), 61)
        XCTAssertEqual(IdleWatch.wait(after: "active", quiet: 59, threshold: 60), 2)
        XCTAssertEqual(IdleWatch.wait(after: "idle", quiet: 90, threshold: 60), 15)
    }
}
