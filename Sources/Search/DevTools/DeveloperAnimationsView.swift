import SwiftUI

/// Chrome's Animations drawer tool: clear, pause all and the playback
/// speeds along the top; the groups heard so far as small previews; and
/// the selected group's timeline, a row per animation under a ruler, with
/// a scrubber to drag and Replay. Dragging a bar changes the animation's
/// delay; dragging the end of its first iteration changes its duration.
struct DeveloperAnimationsView: View {
    let session: DeveloperToolsSession
    @ObservedObject private var animations: DeveloperAnimations

    init(session: DeveloperToolsSession) {
        self.session = session
        animations = DeveloperAnimations.model(for: session)
    }

    /// Chrome's per-animation colours, a Material set.
    static let colors: [Color] = [
        Color(red: 0.61, green: 0.15, blue: 0.69), Color(red: 0.01, green: 0.66, blue: 0.96),
        Color(red: 1.00, green: 0.34, blue: 0.13), Color(red: 0.30, green: 0.69, blue: 0.31),
        Color(red: 0.91, green: 0.12, blue: 0.39), Color(red: 0.00, green: 0.59, blue: 0.53),
        Color(red: 1.00, green: 0.76, blue: 0.03), Color(red: 0.25, green: 0.32, blue: 0.71),
    ]

    static func color(_ animation: DeveloperAnimation) -> Color {
        colors[DeveloperAnimationTimeline.colorIndex(for: animation.title, count: colors.count)]
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let problem = animations.problem {
                DeveloperProblemNote(text: problem)
            }
            if animations.groups.isEmpty {
                placeholder(animations.listening ? "Listening for animations…" : "Waiting for the page…")
            } else {
                previews
                Divider()
                if let group = animations.selectedGroup, group.kind == .scrollDriven {
                    DeveloperScrollDrivenView(session: session, group: group)
                } else if let group = animations.selectedGroup {
                    DeveloperAnimationTimelineView(session: session, animations: animations, group: group)
                } else {
                    placeholder("Select an animation group above to inspect and modify it.")
                }
            }
        }
        .onAppear { animations.start() }
        .onDisappear { animations.stop() }
        .accessibilityIdentifier("developer-animations")
    }

    private var toolbar: some View {
        HStack(spacing: DeveloperToolsStyle.controlSpacing) {
            DeveloperPanelIcon(symbol: "nosign", title: "Clear all", action: animations.clear)
            DeveloperPanelIcon(symbol: animations.paused ? "play.fill" : "pause.fill",
                               title: animations.paused ? "Resume all" : "Pause all",
                               active: animations.paused, action: animations.togglePause)
            Divider().frame(height: 14)
            ForEach(DeveloperAnimations.rates, id: \.self) { rate in
                let selected = animations.rate == rate
                Button { animations.setRate(rate) } label: {
                    Text("\(Int((rate * 100).rounded()))%")
                        .developerTab(selected: selected)
                }
                .buttonStyle(.plain)
                .help("Set speed to \(Int((rate * 100).rounded()))%")
            }
            Spacer(minLength: 0)
            if let note = supportNote {
                Text(note).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    .help(note)
            }
        }
        .padding(.horizontal, DeveloperToolsStyle.gutter)
        .frame(height: DeveloperToolsStyle.toolbarHeight)
        .background(DeveloperToolsStyle.chrome)
    }

    /// What this WebKit lacks of what the tool lists, as the page found.
    private var supportNote: String? {
        var missing: [String] = []
        if animations.scrollTimelinesSupported == false { missing.append("scroll-driven animations") }
        if animations.viewTransitionsSupported == false { missing.append("view transitions") }
        guard !missing.isEmpty else { return nil }
        return "This version of WebKit doesn't support " + missing.joined(separator: " or ") + "."
    }

    /// The groups, oldest first, each a small picture of its timeline.
    private var previews: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal) {
                HStack(spacing: DeveloperToolsStyle.gutter) {
                    ForEach(animations.groups) { group in
                        DeveloperAnimationPreview(group: group, selected: animations.selection == group.id) {
                            animations.selection = group.id
                        }
                        .id(group.id)
                    }
                }
                .padding(DeveloperToolsStyle.gutter)
            }
            .scrollIndicators(.automatic)
            .onChange(of: animations.groups.last?.id) { _, last in
                if let last { withAnimation { reader.scrollTo(last, anchor: .trailing) } }
            }
        }
        .frame(height: 74)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A group in the list: a line per animation (the first several), where
/// it runs in the group, coloured as its timeline row.
private struct DeveloperAnimationPreview: View {
    let group: DeveloperAnimationGroup
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Canvas { context, size in draw(in: &context, size: size) }
                    .frame(width: 120, height: 34)
                Text(caption)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(5)
            .background(fill, in: RoundedRectangle(cornerRadius: DeveloperToolsStyle.controlRadius))
            .overlay {
                RoundedRectangle(cornerRadius: DeveloperToolsStyle.controlRadius)
                    .strokeBorder(selected ? DeveloperToolsStyle.tint : DeveloperToolsStyle.rule, lineWidth: selected ? 1.5 : 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(group.animations.prefix(6).map(\.title).joined(separator: ", "))
        .accessibilityLabel("Animation group, " + caption)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var fill: Color {
        selected ? DeveloperToolsStyle.selected : hovering ? DeveloperToolsStyle.raised : Color.clear
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let duration: Double = DeveloperAnimationTimeline.duration(of: group)
        let shown: [DeveloperAnimation] = Array(group.animations.prefix(8))
        let step: CGFloat = size.height / CGFloat(max(shown.count, 1))
        let scrollDriven: Bool = group.kind == .scrollDriven
        let style = StrokeStyle(lineWidth: min(3, max(1.5, step - 1.5)), lineCap: .round)
        for (row, animation) in shown.enumerated() {
            let bar = DeveloperAnimationTimeline.bar(animation, in: group)
            // A scroll-driven one runs over the whole scroll.
            let start: CGFloat = scrollDriven ? 0 : DeveloperAnimationTimeline.x(bar.lowerBound, duration: duration, width: size.width)
            let end: CGFloat = scrollDriven ? size.width
                : max(start + 2, DeveloperAnimationTimeline.x(bar.upperBound, duration: duration, width: size.width))
            let y: CGFloat = step * (CGFloat(row) + 0.5)
            var line = Path()
            line.move(to: CGPoint(x: start, y: y))
            line.addLine(to: CGPoint(x: end, y: y))
            context.stroke(line, with: .color(DeveloperAnimationsView.color(animation)), style: style)
        }
    }

    private var caption: String {
        let count = group.animations.count
        let animations = "\(count) animation\(count == 1 ? "" : "s")"
        if group.kind == .scrollDriven { return "Scroll-driven · " + animations }
        let time = DeveloperAnimationTimeline.label(DeveloperAnimationTimeline.duration(of: group))
        if let title = group.title { return title + " · " + time }
        return animations + " · " + time
    }
}

/// The selected group: Replay and the scrubber's time over the names,
/// the ruler over the bars, and a row per animation.
private struct DeveloperAnimationTimelineView: View {
    let session: DeveloperToolsSession
    @ObservedObject var animations: DeveloperAnimations
    let group: DeveloperAnimationGroup

    private static let labelWidth: CGFloat = 220
    private static let rulerHeight: CGFloat = 22

    var body: some View {
        GeometryReader { proxy in
            let track = max(40, proxy.size.width - Self.labelWidth - DeveloperToolsStyle.gutter * 2)
            let duration = DeveloperAnimationTimeline.duration(of: group)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    controls(duration: duration)
                        .frame(width: Self.labelWidth, alignment: .leading)
                    ruler(duration: duration, width: track)
                        .frame(width: track, height: Self.rulerHeight)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                            animations.scrub(to: DeveloperAnimationTimeline.time(atX: drag.location.x, duration: duration, width: track))
                        })
                    Spacer(minLength: 0)
                }
                .frame(height: Self.rulerHeight)
                .background(DeveloperToolsStyle.chrome)
                Divider()
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(group.animations) { animation in
                            row(animation, duration: duration, width: track)
                        }
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                scrubber(duration: duration, width: track, height: proxy.size.height)
                    .offset(x: Self.labelWidth)
                    .allowsHitTesting(false)
            }
        }
    }

    private func controls(duration: Double) -> some View {
        HStack(spacing: DeveloperToolsStyle.controlSpacing) {
            if group.playable {
                DeveloperPanelIcon(symbol: "arrow.counterclockwise", title: "Replay timeline", size: 18, action: animations.replay)
            } else if let title = group.title {
                Text(title).fontWeight(.semibold).lineLimit(1)
            }
            TimelineView(.animation(paused: !animations.playing)) { context in
                Text(DeveloperAnimationTimeline.label(animations.position(at: context.date.timeIntervalSince1970 * 1000)))
                    .font(DeveloperToolsStyle.code)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, DeveloperToolsStyle.gutter)
    }

    private func ruler(duration: Double, width: CGFloat) -> some View {
        Canvas { context, size in
            for tick in DeveloperAnimationTimeline.ticks(duration: duration, width: width) {
                let x = DeveloperAnimationTimeline.x(tick, duration: duration, width: width)
                var line = Path()
                line.move(to: CGPoint(x: x, y: size.height - 5))
                line.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(line, with: .color(.secondary.opacity(0.6)), lineWidth: 1)
                context.draw(Text(DeveloperAnimationTimeline.label(tick)).font(.system(size: 9)).foregroundColor(.secondary),
                             at: CGPoint(x: min(x + 3, size.width - 2), y: size.height / 2 - 2), anchor: .leading)
            }
        }
    }

    /// The scrubber: a line down the ruler and the rows, moving with the
    /// group as it plays, held where it was dragged to.
    private func scrubber(duration: Double, width: CGFloat, height: CGFloat) -> some View {
        TimelineView(.animation(paused: !animations.playing)) { context in
            let time = animations.position(at: context.date.timeIntervalSince1970 * 1000)
            let x = DeveloperAnimationTimeline.x(time, duration: duration, width: width)
            ZStack(alignment: .top) {
                Rectangle().fill(Color.red.opacity(0.85)).frame(width: 1, height: height)
                Image(systemName: "arrowtriangle.down.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(Color.red.opacity(0.85))
                    .offset(y: Self.rulerHeight - 9)
            }
            .offset(x: x - 0.5)
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }

    private func row(_ animation: DeveloperAnimation, duration: Double, width: CGFloat) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                DeveloperAnimationTarget(session: session, animation: animation, truncation: .middle)
                Text(animation.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(animation.destroyed ? Color.secondary : Palette.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DeveloperToolsStyle.gutter)
            .frame(width: Self.labelWidth, alignment: .leading)
            DeveloperAnimationBar(animation: animation, group: group, duration: duration, width: width,
                                  color: DeveloperAnimationsView.color(animation)) { delay, length in
                animations.retime(animation.id, delay: delay, duration: length)
            }
                .frame(width: width, height: DeveloperToolsStyle.rowHeight + 4)
                .help(DeveloperAnimationTimeline.summary(animation))
                .opacity(animation.destroyed ? 0.5 : 1)
            Spacer(minLength: 0)
        }
        .frame(height: DeveloperToolsStyle.rowHeight + 4)
        .overlay(alignment: .bottom) { Rectangle().fill(DeveloperToolsStyle.rule).frame(height: 1) }
        .contextMenu {
            if let node = animation.node {
                Button("Reveal in Elements panel") {
                    session.select(.elements)
                    session.selectNode(node)
                }
            }
        }
    }
}

/// A scroll-driven group: a row per animation with the timeline it follows
/// and the part of the scroll it runs over, in place of a time; no
/// playback controls, as its progress is the page's scroll position.
private struct DeveloperScrollDrivenView: View {
    let session: DeveloperToolsSession
    let group: DeveloperAnimationGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DeveloperToolsStyle.controlSpacing) {
                Text("Scroll-driven").fontWeight(.semibold)
                if let timeline = group.animations.first?.scrollTimeline {
                    Text((timeline.kind == .view ? "View timeline of " : "Scroll timeline of ") + timeline.source)
                        .font(DeveloperToolsStyle.code).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Text("Progress follows scrolling, not time").foregroundStyle(.secondary)
            }
            .padding(.horizontal, DeveloperToolsStyle.gutter)
            .frame(height: 22)
            .background(DeveloperToolsStyle.chrome)
            Divider()
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(group.animations) { animation in
                        row(animation)
                    }
                }
            }
        }
    }

    private func row(_ animation: DeveloperAnimation) -> some View {
        HStack(spacing: 8) {
            DeveloperAnimationTarget(session: session, animation: animation)
            Text(animation.title).lineLimit(1)
                .foregroundStyle(animation.destroyed ? Color.secondary : Palette.ink)
            Spacer(minLength: 8)
            Text(animation.scrollTimeline?.range ?? "")
                .font(DeveloperToolsStyle.code)
                .foregroundStyle(DeveloperAnimationsView.color(animation))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, DeveloperToolsStyle.gutter)
        .frame(height: DeveloperToolsStyle.rowHeight + 4)
        .overlay(alignment: .bottom) { Rectangle().fill(DeveloperToolsStyle.rule).frame(height: 1) }
        .help(animation.scrollTimeline?.range ?? animation.title)
    }
}

/// One animation's bar: its delay as a thin line, then its iterations,
/// with a dot at each keyframe and a tick between iterations; an endless
/// one fades out after the iterations drawn. Dragged, it shows the new
/// delay or duration and sets it when let go.
private struct DeveloperAnimationBar: View {
    let animation: DeveloperAnimation
    let group: DeveloperAnimationGroup
    let duration: Double
    let width: CGFloat
    let color: Color
    let retime: (_ delay: Double, _ duration: Double) -> Void

    private struct Drag {
        var handle: DeveloperAnimationTimeline.Handle
        var delay: Double
        var duration: Double
    }

    @State private var drag: Drag?
    @State private var cursor = false

    /// The animation as drawn: with the dragged timing while dragging.
    private var shown: DeveloperAnimation {
        guard let drag else { return animation }
        var copy = animation
        copy.effect.startDelay = drag.delay
        copy.effect.iterationDuration = drag.duration
        return copy
    }

    var body: some View {
        canvas
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                var resize = false
                if case .active(let point) = phase, !animation.destroyed {
                    resize = DeveloperAnimationTimeline.handle(atX: point.x, animation, in: group, duration: duration,
                                                               width: width) != nil
                }
                guard resize != cursor else { return }
                cursor = resize
                if resize { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .onDisappear { if cursor { NSCursor.pop(); cursor = false } }
            .gesture(DragGesture(minimumDistance: 2).onChanged { value in
                guard !animation.destroyed, let handle = drag?.handle ?? DeveloperAnimationTimeline.handle(
                    atX: value.startLocation.x, animation, in: group, duration: duration, width: width) else { return }
                let delta = width > 0 ? Double(value.translation.width / width) * duration : 0
                let timing = DeveloperAnimationTimeline.retimed(animation.effect, handle, by: delta)
                drag = Drag(handle: handle, delay: timing.delay, duration: timing.duration)
            }.onEnded { _ in
                guard let drag else { return }
                self.drag = nil
                retime(drag.delay, drag.duration)
            })
            .overlay(alignment: .topLeading) {
                if let drag {
                    Text(drag.handle == .body ? "Delay: " + DeveloperAnimationTimeline.label(drag.delay)
                         : "Duration: " + DeveloperAnimationTimeline.label(drag.duration))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 3)
                        .background(DeveloperToolsStyle.surface.opacity(0.9))
                        .allowsHitTesting(false)
                }
            }
    }

    private var canvas: some View {
        let animation = shown
        return Canvas { context, size in
            let x = { (time: Double) in DeveloperAnimationTimeline.x(time, duration: duration, width: size.width) }
            let bar = DeveloperAnimationTimeline.bar(animation, in: group)
            let middle = size.height / 2
            let offset = group.offset(of: animation)
            if animation.effect.startDelay > 0 {
                var delay = Path()
                delay.move(to: CGPoint(x: x(offset), y: middle))
                delay.addLine(to: CGPoint(x: x(bar.lowerBound), y: middle))
                context.stroke(delay, with: .color(color.opacity(0.45)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }
            let start = x(bar.lowerBound)
            let end = max(start + 2, x(bar.upperBound))
            let rect = CGRect(x: start, y: middle - 5, width: end - start, height: 10)
            if animation.effect.infinite {
                context.fill(Path(roundedRect: rect, cornerRadius: 3),
                             with: .linearGradient(Gradient(colors: [color.opacity(0.35), color.opacity(0.35), color.opacity(0.04)]),
                                                   startPoint: CGPoint(x: start, y: middle), endPoint: CGPoint(x: end, y: middle)))
            } else {
                context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(color.opacity(0.3)))
            }
            var top = Path()
            top.move(to: CGPoint(x: start, y: middle - 5))
            top.addLine(to: CGPoint(x: end, y: middle - 5))
            context.stroke(top, with: .color(color), lineWidth: 1.5)
            for boundary in DeveloperAnimationTimeline.iterationBoundaries(animation.effect, start: bar.lowerBound) {
                var line = Path()
                line.move(to: CGPoint(x: x(boundary), y: middle - 5))
                line.addLine(to: CGPoint(x: x(boundary), y: middle + 5))
                context.stroke(line, with: .color(color.opacity(0.7)), lineWidth: 1)
            }
            // Keyframe dots, thinned out when they would overlap.
            var last = -CGFloat.infinity
            for time in DeveloperAnimationTimeline.keyframeTimes(animation.effect, start: bar.lowerBound) {
                let at = x(time)
                guard at - last >= 4 else { continue }
                last = at
                let dot = CGRect(x: at - 3, y: middle - 3, width: 6, height: 6)
                context.fill(Path(ellipseIn: dot), with: .color(DeveloperToolsStyle.surface))
                context.stroke(Path(ellipseIn: dot), with: .color(color), lineWidth: 1.5)
            }
        }
        .accessibilityLabel(DeveloperAnimationTimeline.summary(animation))
    }
}

/// An animation's element, a link to it in Elements that highlights it on
/// the page; or, with no node, the animation's label.
private struct DeveloperAnimationTarget: View {
    let session: DeveloperToolsSession
    let animation: DeveloperAnimation
    var truncation: Text.TruncationMode = .tail

    var body: some View {
        if let node = animation.node {
            Button {
                session.select(.elements)
                session.selectNode(node)
            } label: {
                Text(animation.label ?? "element")
                    .font(DeveloperToolsStyle.code)
                    .foregroundStyle(DeveloperToolsStyle.tint)
                    .lineLimit(1)
                    .truncationMode(truncation)
            }
            .buttonStyle(.plain)
            .onHover { session.highlightNode($0 ? node : nil) }
            .help("Reveal in Elements panel")
        } else if let label = animation.label {
            Text(label).font(DeveloperToolsStyle.code).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}
