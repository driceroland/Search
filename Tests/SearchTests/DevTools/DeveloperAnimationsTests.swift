import XCTest
@testable import Search

/// The Animations drawer's pure logic: parsing WebKit's effects, grouping
/// by start time, the timeline's durations and geometry, and keyframes.
final class DeveloperAnimationsTests: XCTestCase {
    private typealias Timeline = DeveloperAnimationTimeline

    private func animation(_ id: String, at arrival: Double, duration: Double = 1000, delay: Double = 0,
                           iterations: Double = 1, endDelay: Double = 0) -> DeveloperAnimation {
        DeveloperAnimation(id: id, name: id, kind: .cssAnimation,
                           effect: .init(startDelay: delay, endDelay: endDelay, iterationCount: iterations,
                                         iterationDuration: duration),
                           arrival: arrival)
    }

    // MARK: Parsing

    func testAnEffectReadsWebKitsFieldsAndAnEndlessCount() {
        let effect = DeveloperAnimationEffect(raw: [
            "startDelay": 200, "endDelay": 50, "iterationCount": -1, "iterationDuration": 1500,
            "timingFunction": "ease-in-out", "playbackDirection": "alternate", "fillMode": "both",
            "keyframes": [["offset": 0, "style": "opacity: 0"], ["offset": 0.5], ["offset": 1, "easing": "linear"]],
        ])
        XCTAssertEqual(effect.startDelay, 200)
        XCTAssertEqual(effect.endDelay, 50)
        XCTAssertTrue(effect.infinite)
        XCTAssertEqual(effect.iterationDuration, 1500)
        XCTAssertEqual(effect.timingFunction, "ease-in-out")
        XCTAssertEqual(effect.keyframes.map(\.offset), [0, 0.5, 1])
        XCTAssertEqual(effect.keyframes.last?.easing, "linear")
        XCTAssertTrue(DeveloperAnimationEffect(raw: ["iterationCount": "Infinity"]).infinite)
        // A missing count is one iteration, as the spec's default.
        XCTAssertEqual(DeveloperAnimationEffect(raw: [:]).iterationCount, 1)
    }

    func testAnAnimationIsNamedByItsKeyframesItsPropertyOrItsScriptName() {
        let css = DeveloperAnimation(raw: ["animationId": "1", "cssAnimationName": "spin", "name": "spin"], arrival: 0)
        XCTAssertEqual(css?.kind, .cssAnimation)
        XCTAssertEqual(css?.title, "spin")
        let transition = DeveloperAnimation(raw: ["animationId": "2", "cssTransitionProperty": "opacity"], arrival: 0)
        XCTAssertEqual(transition?.kind, .cssTransition)
        XCTAssertEqual(transition?.title, "opacity")
        let script = DeveloperAnimation(raw: ["animationId": "3", "name": ""], arrival: 0)
        XCTAssertEqual(script?.kind, .script)
        XCTAssertEqual(script?.title, "(anonymous)")
        XCTAssertNil(DeveloperAnimation(raw: ["name": "no id"], arrival: 0))
    }

    // MARK: Grouping

    func testAnimationsStartedWithinAFrameShareAGroup() {
        let groups = Timeline.groups([
            animation("a", at: 1000), animation("b", at: 1010), animation("c", at: 1016),
            animation("d", at: 1040), animation("e", at: 5000),
        ])
        XCTAssertEqual(groups.map { $0.animations.map(\.id) }, [["a", "b", "c"], ["d"], ["e"]])
        XCTAssertEqual(groups.map(\.id), ["a", "d", "e"])
        XCTAssertEqual(groups[0].offset(of: groups[0].animations[1]), 10)
    }

    func testGroupingGoesByStartTimeNotTheOrderHeard() {
        let groups = Timeline.groups([animation("late", at: 2000), animation("early", at: 1000), animation("b", at: 1005)])
        XCTAssertEqual(groups.map { $0.animations.map(\.id) }, [["early", "b"], ["late"]])
        // A group is measured from its first animation, so a chain of
        // animations a few ms apart doesn't grow into one group.
        let chain = Timeline.groups((0..<5).map { animation("\($0)", at: Double($0) * 10) })
        XCTAssertEqual(chain.map(\.animations.count), [2, 2, 1])
        XCTAssertTrue(Timeline.groups([]).isEmpty)
    }

    // MARK: Durations

    func testAGroupLastsUntilItsLastAnimationEndsDelaysAndIterationsIncluded() {
        let group = DeveloperAnimationGroup(id: "a", start: 0, animations: [
            animation("a", at: 0, duration: 500, delay: 100, iterations: 2),
            animation("b", at: 10, duration: 300, delay: 0, iterations: 1, endDelay: 200),
        ])
        XCTAssertEqual(Timeline.bar(group.animations[0], in: group), 100...1100)
        XCTAssertEqual(Timeline.end(of: group.animations[1], in: group), 510)
        XCTAssertEqual(Timeline.duration(of: group), 1100)
        XCTAssertFalse(Timeline.loops(group))
    }

    func testAnEndlessAnimationIsDrawnForAFewIterationsAndTheScrubberLoops() {
        let endless = animation("spin", at: 0, duration: 1000, iterations: .infinity)
        XCTAssertEqual(Timeline.iterationsShown(endless.effect), 3)
        XCTAssertEqual(Timeline.activeDuration(endless.effect), 3000)
        let group = DeveloperAnimationGroup(id: "spin", start: 0, animations: [endless])
        XCTAssertEqual(Timeline.duration(of: group), 3000)
        XCTAssertTrue(Timeline.loops(group))
        XCTAssertEqual(Timeline.position(elapsed: 4500, duration: 3000, loops: true), 1500)
        XCTAssertEqual(Timeline.position(elapsed: 4500, duration: 3000, loops: false), 3000)
        XCTAssertEqual(Timeline.position(elapsed: -20, duration: 3000, loops: false), 0)
        // A huge finite count is capped too, and a zero-length group still has room.
        XCTAssertEqual(Timeline.iterationsShown(animation("x", at: 0, iterations: 1e6).effect), 100)
        let instant = DeveloperAnimationGroup(id: "i", start: 0, animations: [animation("i", at: 0, duration: 0)])
        XCTAssertEqual(Timeline.duration(of: instant), Timeline.minimumDuration)
    }

    // MARK: Geometry

    func testTimesAndPointsOnTheTrackConvertBothWaysAndStayOnIt() {
        XCTAssertEqual(Timeline.x(500, duration: 2000, width: 400), 100)
        XCTAssertEqual(Timeline.time(atX: 100, duration: 2000, width: 400), 500)
        XCTAssertEqual(Timeline.time(atX: -30, duration: 2000, width: 400), 0)
        XCTAssertEqual(Timeline.time(atX: 900, duration: 2000, width: 400), 2000)
        XCTAssertEqual(Timeline.x(10, duration: 0, width: 400), 0)
    }

    func testTheRulerPicksARoundStepThatFits() {
        XCTAssertEqual(Timeline.ticks(duration: 1000, width: 700), [0, 100, 200, 300, 400, 500, 600, 700, 800, 900, 1000])
        XCTAssertEqual(Timeline.ticks(duration: 1000, width: 300), [0, 500, 1000])
        XCTAssertEqual(Timeline.ticks(duration: 3000, width: 500), [0, 500, 1000, 1500, 2000, 2500, 3000])
        XCTAssertEqual(Timeline.ticks(duration: 0, width: 500), [0])
    }

    func testTimesAreLabelledAsChromeLabelsThem() {
        XCTAssertEqual(Timeline.label(0), "0")
        XCTAssertEqual(Timeline.label(250), "250 ms")
        XCTAssertEqual(Timeline.label(1000), "1 s")
        XCTAssertEqual(Timeline.label(1500), "1.5 s")
        XCTAssertEqual(Timeline.label(1234), "1.23 s")
        XCTAssertEqual(Timeline.label(.infinity), "∞")
    }

    // MARK: Keyframes

    func testKeyframeOffsetsAreSortedAndATransitionGoesFromStartToEnd() {
        let effect = DeveloperAnimationEffect(keyframes: [.init(offset: 1), .init(offset: 0.25), .init(offset: 0), .init(offset: 0.25)])
        XCTAssertEqual(Timeline.keyframeOffsets(effect), [0, 0.25, 1])
        XCTAssertEqual(Timeline.keyframeOffsets(DeveloperAnimationEffect()), [0, 1])
    }

    func testKeyframesFallOnEveryIterationAndBackwardIterationsMirrorThem() {
        let frames: [DeveloperAnimationEffect.Keyframe] = [.init(offset: 0), .init(offset: 0.25), .init(offset: 1)]
        let normal = DeveloperAnimationEffect(iterationCount: 2, iterationDuration: 100, keyframes: frames)
        XCTAssertEqual(Timeline.keyframeTimes(normal, start: 50), [50, 75, 150, 175, 250])
        let alternate = DeveloperAnimationEffect(iterationCount: 2, iterationDuration: 100,
                                                 playbackDirection: "alternate", keyframes: frames)
        XCTAssertEqual(Timeline.keyframeTimes(alternate, start: 0), [0, 25, 100, 175, 200])
        let reverse = DeveloperAnimationEffect(iterationCount: 1, iterationDuration: 100,
                                               playbackDirection: "reverse", keyframes: frames)
        XCTAssertEqual(Timeline.keyframeTimes(reverse, start: 0), [0, 75, 100])
        // A partial last iteration stops where the animation does.
        let partial = DeveloperAnimationEffect(iterationCount: 1.5, iterationDuration: 100, keyframes: frames)
        XCTAssertEqual(Timeline.keyframeTimes(partial, start: 0), [0, 25, 100, 125])
        XCTAssertEqual(Timeline.iterationBoundaries(partial, start: 0), [100])
        XCTAssertEqual(Timeline.iterationBoundaries(normal, start: 50), [150])
    }

    func testIterationDirections() {
        XCTAssertFalse(Timeline.reversed(0, direction: "normal"))
        XCTAssertTrue(Timeline.reversed(3, direction: "reverse"))
        XCTAssertEqual((0..<3).map { Timeline.reversed($0, direction: "alternate") }, [false, true, false])
        XCTAssertEqual((0..<3).map { Timeline.reversed($0, direction: "alternate-reverse") }, [true, false, true])
    }

    // MARK: Presentation

    func testOneNameKeepsOneColour() {
        let first = Timeline.colorIndex(for: "spin", count: 8)
        XCTAssertEqual(first, Timeline.colorIndex(for: "spin", count: 8))
        XCTAssertTrue((0..<8).contains(first))
        XCTAssertEqual(Timeline.colorIndex(for: "spin", count: 0), 0)
    }

    func testHoveringABarSummarisesItsTiming() {
        var spin = animation("spin", at: 0, duration: 1200, delay: 300, iterations: .infinity)
        spin.effect.timingFunction = "ease-in"
        spin.effect.playbackDirection = "alternate"
        let summary = Timeline.summary(spin)
        XCTAssertTrue(summary.contains("Duration: 1.2 s"))
        XCTAssertTrue(summary.contains("Delay: 300 ms"))
        XCTAssertTrue(summary.contains("Iterations: infinite"))
        XCTAssertTrue(summary.contains("Easing: ease-in"))
        XCTAssertTrue(summary.contains("Direction: alternate"))
    }

    // MARK: Editing timing

    func testDraggingTheBarMovesTheDelayAndItsEndStretchesTheDuration() {
        let group = DeveloperAnimationGroup(id: "a", start: 0, animations: [animation("a", at: 0, duration: 1000, delay: 500, iterations: 2)])
        let spin = group.animations[0]
        // The timeline is 2500 ms over 250 pt: 10 ms a point. The bar runs
        // 50…250 pt, its first iteration ending at 150.
        XCTAssertEqual(Timeline.handle(atX: 150, spin, in: group, duration: 2500, width: 250), .end)
        XCTAssertEqual(Timeline.handle(atX: 100, spin, in: group, duration: 2500, width: 250), .body)
        XCTAssertEqual(Timeline.handle(atX: 230, spin, in: group, duration: 2500, width: 250), .body)
        XCTAssertNil(Timeline.handle(atX: 20, spin, in: group, duration: 2500, width: 250))
        let moved = Timeline.retimed(spin.effect, .body, by: 249.6)
        XCTAssertEqual(moved.delay, 750)
        XCTAssertEqual(moved.duration, 1000)
        XCTAssertEqual(Timeline.retimed(spin.effect, .body, by: -900).delay, 0, "never before the start")
        let stretched = Timeline.retimed(spin.effect, .end, by: 300)
        XCTAssertEqual(stretched.delay, 500)
        XCTAssertEqual(stretched.duration, 1300)
        XCTAssertEqual(Timeline.retimed(spin.effect, .end, by: -5000).duration, 0)
    }

    // MARK: Scroll-driven animations and view transitions

    func testScrollAndViewTimelinesAreClassifiedAndTheDocumentsIsnt() throws {
        let scroll = try XCTUnwrap(Timeline.scrollTimeline(["type": "ScrollTimeline", "axis": "block", "source": "html"]))
        XCTAssertEqual(scroll.kind, .scroll)
        XCTAssertEqual(scroll.source, "html")
        XCTAssertEqual(scroll.range, "scroll(block) of html: 0% – 100%")
        let view = try XCTUnwrap(Timeline.scrollTimeline([
            "type": "ViewTimeline", "axis": "inline", "source": "div#card", "rangeStart": "entry 0%", "rangeEnd": "normal",
        ]))
        XCTAssertEqual(view.kind, .view)
        XCTAssertEqual(view.range, "view(inline) of div#card: entry 0% – cover 100%")
        // No axis or source said: the defaults.
        let bare = try XCTUnwrap(Timeline.scrollTimeline(["type": "ScrollTimeline"]))
        XCTAssertEqual(bare.axis, "block")
        XCTAssertEqual(bare.source, "(scroller)")
        // The document's timeline, or nothing: a timed animation.
        XCTAssertNil(Timeline.scrollTimeline(["type": "DocumentTimeline"]))
        XCTAssertNil(Timeline.scrollTimeline(nil))
        XCTAssertNil(Timeline.scrollTimeline(NSNull()))
        XCTAssertNotEqual(scroll.key, view.key)
    }

    func testScrollDrivenAnimationsAreGroupedByTheirTimelineApartFromTimedOnes() {
        var progress = animation("progress", at: 1000)
        progress.scrollTimeline = Timeline.scrollTimeline(["type": "ScrollTimeline", "source": "html"])
        var fade = animation("fade", at: 1005)
        fade.scrollTimeline = Timeline.scrollTimeline(["type": "ScrollTimeline", "source": "html"])
        var reveal = animation("reveal", at: 1008)
        reveal.scrollTimeline = Timeline.scrollTimeline(["type": "ViewTimeline", "source": "img"])
        let spin = animation("spin", at: 1002)
        let later = animation("later", at: 9000)
        var lateProgress = animation("late-progress", at: 9001)
        lateProgress.scrollTimeline = Timeline.scrollTimeline(["type": "ScrollTimeline", "source": "html"])
        let groups = Timeline.groups([progress, spin, fade, reveal, later, lateProgress])
        XCTAssertEqual(groups.map { $0.animations.map(\.id) },
                       [["progress", "fade", "late-progress"], ["spin"], ["reveal"], ["later"]])
        XCTAssertEqual(groups.map(\.kind), [.scrollDriven, .time, .scrollDriven, .time])
        XCTAssertEqual(groups[0].title, "Scroll-driven")
        XCTAssertFalse(groups[0].playable)
        XCTAssertNil(groups[1].title)
        XCTAssertTrue(groups[1].playable)
    }

    func testAViewTransitionsAnimationsAreOneGroup() throws {
        let raw: [String: Any] = [
            "id": 3, "time": 2000, "skipped": false,
            "animations": [
                ["name": "-ua-view-transition-fade-out", "pseudo": "::view-transition-old(root)", "duration": 250,
                 "delay": 0, "iterations": 1, "easing": "ease", "fill": "both"],
                ["name": "", "pseudo": "::view-transition-group(root)", "duration": 250, "iterations": -1],
            ],
        ]
        let made = Timeline.viewTransitionAnimations(raw)
        XCTAssertEqual(made.map(\.id), ["view-transition:3:0", "view-transition:3:1"])
        XCTAssertEqual(made[0].title, "-ua-view-transition-fade-out")
        XCTAssertEqual(made[1].title, "::view-transition-group(root)")
        XCTAssertEqual(made[0].label, "html::view-transition-old(root)")
        XCTAssertEqual(made[0].pseudo, "view-transition-old(root)")
        XCTAssertEqual(made[0].effect.iterationDuration, 250)
        XCTAssertEqual(made[0].effect.timingFunction, "ease")
        XCTAssertTrue(made[1].effect.infinite)
        XCTAssertTrue(made.allSatisfy(\.isViewTransitionPseudo))
        XCTAssertTrue(Timeline.viewTransitionAnimations(["animations": []]).isEmpty)

        // WebKit's own report of the same pseudo-element, left out when the hook listed it.
        var reported = animation("webkit", at: 2001)
        reported.pseudo = "view-transition-old(root)"
        let other = animation("spin", at: 2002)
        let hidden = Timeline.groups(made + [reported, other], hidingViewTransitionPseudos: true)
        XCTAssertEqual(hidden.map(\.kind), [.viewTransition, .time])
        XCTAssertEqual(hidden[0].id, "view-transition:3")
        XCTAssertEqual(hidden[0].title, "View transition")
        XCTAssertEqual(hidden[0].animations.count, 2)
        XCTAssertEqual(hidden[1].animations.map(\.id), ["spin"])
        let shown = Timeline.groups(made + [reported, other])
        XCTAssertEqual(shown.map { $0.animations.map(\.id) },
                       [["view-transition:3:0", "view-transition:3:1"], ["webkit", "spin"]])
    }
}
