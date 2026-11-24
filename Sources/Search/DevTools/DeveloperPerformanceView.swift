import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

extension DeveloperPerformanceCategory {
    /// As in Chrome DevTools: blue loading, yellow scripting, purple
    /// rendering, green painting and grey system.
    var color: Color {
        switch self {
        case .loading: Color(red: 0.35, green: 0.55, blue: 0.91)
        case .scripting: Color(red: 0.94, green: 0.77, blue: 0.31)
        case .rendering: Color(red: 0.62, green: 0.49, blue: 0.88)
        case .painting: Color(red: 0.43, green: 0.74, blue: 0.42)
        case .system: Color(red: 0.78, green: 0.78, blue: 0.78)
        }
    }
}

/// The Performance panel, as in Chrome DevTools: Record (⌘E) and Start
/// profiling and reload page (⇧⌘E), then an overview of the recording to
/// drag a range in, a flame chart of what ran (W and S zoom, A and D pan,
/// pinch or ⌘-scroll zooms, scrolling pans), and Summary, Bottom-up, Call
/// tree and Event log for the range shown. Save profile (⌘S) and Load
/// profile (⌘O) write and read Chrome's trace files (DeveloperPerformanceTrace).
struct DeveloperPerformanceView: View {
    @ObservedObject var session: DeveloperToolsSession

    @State private var profile = DeveloperPerformanceProfile()
    @State private var window = DeveloperFlameWindow(lower: 0, upper: 1)
    @State private var selected: Int?
    /// A layout shift chosen in its track, in `profile.layoutShifts`.
    @State private var selectedShift: Int?
    /// An entry of a custom track, or an extension marker, chosen
    /// (DeveloperPerformanceExtensions).
    @State private var selectedCustom: DeveloperPerformanceExtensions.Selection?
    /// The custom track groups collapsed to their header.
    @State private var collapsedGroups: Set<String> = []
    @State private var hovered: Int?
    @State private var pointer: CGPoint?
    /// How far the flame chart's rows are scrolled down.
    @State private var offset: CGFloat = 0
    @State private var flameSize = CGSize(width: 1, height: 1)
    @State private var overviewDrag: OverviewDrag?
    @State private var flameDrag: FlameDrag?
    /// The recording last cleared, so it isn't shown again.
    @State private var cleared: String?
    /// Set by Start profiling and reload page: stop once the page has loaded.
    @State private var stopAfterLoad = false
    @State private var sawLoading = false
    @State private var input = DeveloperPerformanceInput()
    @State private var screenshots = DeveloperPerformanceScreenshots.enabled
    /// Chrome's capture settings row, under the toolbar, and its one
    /// recording option WebKit can honour.
    @State private var captureSettingsShown = false
    @State private var jsSamplesDisabled = DeveloperPerformanceCapture.jsSamplesDisabled
    @State private var addingAnnotation = false
    @State private var annotationLabel = ""
    @State private var annotationRange: ClosedRange<Double>?
    @AppStorage(DeveloperPerformanceMemory.key, store: Store.settings) private var memory = false
    /// Where the pointer is over the overview, for its screenshot.
    @State private var overviewHover: CGPoint?
    /// The sidebar's Insights, worked out when the recording changes, and
    /// the card opened and the one under the pointer, by id.
    @State private var insights: [DeveloperPerformanceInsight] = []
    @State private var openInsight: String?
    @State private var hoveredInsight: String?
    /// Reading the page's scripts for Duplicated and Legacy JavaScript.
    @State private var scriptInsights: Task<Void, Never>?
    @AppStorage("developerTools.performance.sidebar", store: Store.settings) private var showSidebar = true
    /// Dim 3rd parties, and the Main track's entries it greys.
    @AppStorage(DeveloperPerformanceThirdParties.key, store: Store.settings) private var dimThirdParties = false
    @State private var thirdParty: Set<Int> = []
    /// The ranges zoomed into from the overview, above it.
    @State private var breadcrumbs = DeveloperPerformanceBreadcrumbs()
    @FocusState private var flameFocused: Bool
    /// Find (⌘F, DeveloperPerformanceFind): the bar shown, its text, the
    /// entries matching (ids in `profile.shown`, and as a set for drawing),
    /// the one stepped to, and a count bumped to put the keyboard back in it.
    @State private var findShown = false
    @State private var findQuery = ""
    @State private var findMatches: [Int] = []
    @State private var findMatchSet: Set<Int> = []
    @State private var findIndex: Int?
    @State private var findFocus = 0
    /// Link entries: the entry an arrow is being drawn from, until the
    /// next click picks the one it goes to.
    @State private var linkingFrom: Int?
    /// The entries links drawn, as ids in `profile.shown`.
    @State private var links: [(from: Int, to: Int)] = []
    /// The session's recordings, to switch back to (DeveloperPerformanceRecordings).
    @ObservedObject private var history: DeveloperPerformanceHistoryStore

    init(session: DeveloperToolsSession) {
        _session = ObservedObject(wrappedValue: session)
        _history = ObservedObject(wrappedValue: DeveloperPerformanceHistoryStore.of(session))
    }

    private static let rulerHeight: CGFloat = 18
    /// Chrome's track header over the lanes: "Main — the page".
    private static let trackHeight: CGFloat = 18
    /// Where the lanes begin, under the ruler and the track header.
    private static let auxiliaryTrackHeight: CGFloat = 48
    private var annotationHeight: CGFloat { rangeAnnotations.isEmpty ? 0 : 22 }
    /// The labels on a range or an event, which the strip over the tracks
    /// shows; entries links are drawn as arrows instead.
    private var rangeAnnotations: [DeveloperPerformanceAnnotation] {
        session.timelineAnnotations.filter { $0.link == nil }
    }
    private var lanesTop: CGFloat {
        Self.rulerHeight + annotationHeight + Self.trackHeight + tracks.reduce(0) { $0 + $1.height }
    }
    private static let rowHeight: CGFloat = 17
    /// A row of the Timings and Interactions tracks.
    private static let barHeight: CGFloat = 14

    /// The tracks over Main, as Chrome orders them, each with its height.
    /// After them, as Chrome adds them, the custom tracks of its
    /// extensibility API: a group's header, then its tracks unless it's
    /// collapsed (`customGroup`), and each track, by its place in
    /// `profile.customTracks` (`custom`).
    private enum Track: Equatable {
        case network, frames, animations, timings, interactions, layoutShifts, heap, cpu
        case customGroup(String)
        case custom(Int)
    }

    private var tracks: [(track: Track, height: CGFloat)] {
        var list: [(track: Track, height: CGFloat)] = []
        if !profile.network.isEmpty { list.append((track: .network, height: Self.auxiliaryTrackHeight)) }
        if !profile.frames.isEmpty { list.append((track: .frames, height: Self.trackHeight + 18)) }
        if !profile.animations.isEmpty {
            list.append((track: .animations, height: Self.trackHeight + 4 + CGFloat(max(1, profile.animationRows)) * Self.barHeight))
        }
        if !profile.markers.isEmpty || !profile.pageTimings.isEmpty || !profile.extensionMarkers.isEmpty {
            list.append((track: .timings, height: Self.trackHeight + 18 + CGFloat(profile.timingRows) * Self.barHeight))
        }
        if !profile.interactions.isEmpty {
            list.append((track: .interactions, height: Self.trackHeight + 4 + CGFloat(max(1, profile.interactionRows)) * Self.barHeight))
        }
        if !profile.layoutShifts.isEmpty { list.append((track: .layoutShifts, height: Self.trackHeight + 20)) }
        if !profile.heap.isEmpty { list.append((track: .heap, height: Self.auxiliaryTrackHeight)) }
        if !profile.cpu.isEmpty { list.append((track: .cpu, height: Self.auxiliaryTrackHeight)) }
        var group: String?
        for (index, custom) in profile.customTracks.enumerated() {
            if let name = custom.group {
                if name != group { list.append((track: .customGroup(name), height: Self.trackHeight)) }
                group = name
                if collapsedGroups.contains(name) { continue }
            } else {
                group = nil
            }
            list.append((track: .custom(index), height: Self.trackHeight + 4 + CGFloat(max(1, custom.rows)) * Self.barHeight))
        }
        return list
    }

    /// The track at `y` in the flame chart, and where it begins.
    private func track(at y: CGFloat) -> (track: Track, top: CGFloat)? {
        var top = Self.rulerHeight + annotationHeight
        for entry in tracks {
            if y >= top && y < top + entry.height { return (entry.track, top) }
            top += entry.height
        }
        return nil
    }

    /// Chrome's colours for its markers and tracks.
    private static func markerColor(_ kind: String) -> Color {
        switch kind {
        case "DCL": Color(red: 0.03, green: 0.40, blue: 0.80)
        case "L": Color(red: 0.70, green: 0.08, blue: 0.07)
        case "LCP": Color(red: 0.10, green: 0.20, blue: 0.13)
        default: Color(red: 0.10, green: 0.41, blue: 0.22)
        }
    }
    static let longTaskColor = Color(red: 0.85, green: 0.19, blue: 0.15)
    private static let interactionColor = Color(red: 0.45, green: 0.62, blue: 0.86)
    private static let measureColor = Color(red: 0.96, green: 0.70, blue: 0.48)
    private static let frameColor = Color(red: 0.55, green: 0.80, blue: 0.47)
    static let layoutShiftColor = Color(red: 0.48, green: 0.38, blue: 1.0)
    private static let insightColor = Color(red: 0.95, green: 0.45, blue: 0.10)
    private static let animationColor = Color(red: 0.55, green: 0.33, blue: 0.80)
    /// Find matches, and the arrows of entries links.
    private static let findColor = Color(red: 0.98, green: 0.80, blue: 0.10)
    private static let linkColor = Color(red: 0.10, green: 0.45, blue: 0.91)
    /// A dimmed 3rd party's entry, greyed as Chrome draws it.
    private static let dimmedColor = Color(white: 0.86)

    /// A palette name of Chrome's extensibility API as its colour.
    static func extensionColor(_ name: String) -> Color {
        let rgb = DeveloperPerformanceExtensions.rgb(name)
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    private struct OverviewDrag {
        let grab: DeveloperOverviewDrag.Grab
        let original: DeveloperFlameWindow
        let from: Double
    }

    private struct FlameDrag {
        let window: DeveloperFlameWindow
        let offset: CGFloat
    }

    private var timelineKey: String { DeveloperPerformanceRecordings.key(session.timeline) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            content
        }
        .onAppear {
            rebuild()
            input.scroll = { scrolled($0) }
            input.key = { pressed($0) }
            input.start()
            lendKeys()
            DeveloperLiveMetricsModel.model(for: session).attach()
        }
        .onDisappear {
            input.stop()
            DeveloperPanelKeys.performance = nil
            DeveloperLiveMetricsModel.model(for: session).detach()
        }
        .onChange(of: timelineKey) { _, _ in if !session.recordingTimeline { rebuild() } }
        .onChange(of: session.recordingTimeline) { _, recording in
            if recording { cleared = nil } else { stopAfterLoad = false; rebuild() }
        }
        .onChange(of: session.timelineAnnotations) { _, now in annotationsChanged(now) }
        .onChange(of: findQuery) { _, _ in refind(jump: true) }
        .onReceive(loads) { loading in
            guard stopAfterLoad else { return }
            if loading { sawLoading = true; return }
            guard sawLoading else { return }
            stopAfterLoad = false
            // As in Chrome, a little of what follows the load is kept.
            Task {
                try? await Task.sleep(for: .seconds(2))
                if session.recordingTimeline { session.toggleTimeline() }
            }
        }
        .alert("Add annotation", isPresented: $addingAnnotation) {
            TextField("Label", text: $annotationLabel)
            Button("Cancel", role: .cancel) {}
            Button("Add") {
                if let annotationRange { session.annotateTimeline(annotationRange, label: annotationLabel) }
            }
            .disabled(annotationLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .accessibilityIdentifier("developer-performance")
    }

    private var loads: AnyPublisher<Bool, Never> {
        session.web?.publisher(for: \.isLoading, options: [.new]).eraseToAnyPublisher() ?? Empty<Bool, Never>().eraseToAnyPublisher()
    }

    // MARK: Toolbar

    /// Chrome's capture settings: the options WebKit can honour, the
    /// network throttling Network shares, and a word on what it can't.
    private var captureSettings: some View {
        HStack(spacing: DeveloperToolsStyle.controlSpacing * 2) {
            checkbox("Disable JavaScript samples", Binding(get: { jsSamplesDisabled }, set: {
                jsSamplesDisabled = $0
                DeveloperPerformanceCapture.jsSamplesDisabled = $0
            }), help: "Reduces the overhead of recording; the Main track then has no JavaScript call frames.",
                     id: "developer-performance-disable-js-samples")
            .disabled(session.recordingTimeline)
            HStack(spacing: DeveloperToolsStyle.controlSpacing) {
                Image(systemName: "wifi").font(.system(size: 10)).foregroundStyle(.secondary)
                Text("Network:").font(.system(size: 11)).foregroundStyle(.secondary)
                Menu {
                    ForEach(DeveloperToolsSession.NetworkCondition.allCases) { condition in
                        Button {
                            session.networkTools.apply(condition)
                        } label: {
                            if session.networkTools.activeProfile == nil && session.throttle == condition {
                                Label(condition.rawValue, systemImage: "checkmark")
                            } else {
                                Text(condition.rawValue)
                            }
                        }
                    }
                } label: {
                    Text(session.networkTools.activeProfileName ?? session.throttle.rawValue).font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(!session.requestInterception)
                .accessibilityLabel("Network throttling")
            }
            .fixedSize()
            Spacer(minLength: 0)
        }
        .help("WebKit has no CPU throttling, advanced paint instrumentation or CSS selector stats to offer here.")
        .developerToolbarRow()
    }

    private var toolbar: some View {
        VStack(spacing: 0) {
            HStack(spacing: DeveloperToolsStyle.controlSpacing) {
                DeveloperPanelIcon(symbol: "sidebar.left", title: showSidebar ? "Collapse sidebar" : "Expand sidebar",
                                   active: showSidebar) { showSidebar.toggle() }
                    .disabled(session.recordingTimeline || profile.isEmpty)
                    .accessibilityIdentifier("developer-performance-sidebar-toggle")
                toolbarDivider
                DeveloperPanelIcon(symbol: session.recordingTimeline ? "stop.circle.fill" : "record.circle",
                                   title: session.recordingTimeline ? "Stop (⌘E)" : "Record (⌘E)",
                                   active: session.recordingTimeline) { record() }
                    .accessibilityIdentifier("developer-performance-record")
                DeveloperPanelIcon(symbol: "arrow.clockwise", title: "Start profiling and reload page (⇧⌘E)") {
                    reloadAndRecord()
                }
                .disabled(session.recordingTimeline)
                .accessibilityIdentifier("developer-performance-reload")
                DeveloperPanelIcon(symbol: "nosign", title: "Clear") { clear() }
                    .disabled(session.recordingTimeline || profile.isEmpty)
                toolbarDivider
                DeveloperPanelIcon(symbol: "arrow.up.to.line", title: "Load profile… (⌘O)") { loadProfile() }
                    .disabled(session.recordingTimeline)
                    .accessibilityIdentifier("developer-performance-load")
                DeveloperPanelIcon(symbol: "arrow.down.to.line", title: "Save profile… (⌘S)") { saveProfile() }
                    .disabled(session.recordingTimeline || profile.isEmpty)
                    .accessibilityIdentifier("developer-performance-save")
                historyAndFind
                DeveloperPanelIcon(symbol: "text.bubble", title: "Add annotation…") {
                    beginAnnotation(selectedEvent.map { $0.start...$0.end } ?? window.range)
                }
                .disabled(session.recordingTimeline || profile.isEmpty || session.timelineAnnotations.count >= 256)
                .accessibilityIdentifier("developer-performance-annotation")
                toolbarDivider
                checkbox("Screenshots", Binding(get: { screenshots }, set: {
                    screenshots = $0
                    DeveloperPerformanceScreenshots.enabled = $0
                }), help: "Capture screenshots while recording", id: "developer-performance-screenshots")
                .disabled(session.recordingTimeline)
                checkbox("Memory", $memory, help: "Capture JavaScript heap usage while recording",
                         id: "developer-performance-memory")
                    .disabled(session.recordingTimeline)
                checkbox("Dim 3rd parties", $dimThirdParties, help: "Dim entries from 3rd-party scripts in the Main track",
                         id: "developer-performance-dim-third-parties")
                toolbarDivider
                if !profile.isEmpty && !session.recordingTimeline {
                    // Shown while there's room for it; a narrow dock keeps
                    // the buttons and the capture settings gear instead.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: DeveloperToolsStyle.controlSpacing) {
                            Text("\(DeveloperPerformanceRuler.label(window.lower)) – \(DeveloperPerformanceRuler.label(window.upper))")
                                .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary).fixedSize()
                            wholeRecordingButton
                        }
                        wholeRecordingButton
                        Color.clear.frame(width: 0, height: 0)
                    }
                }
                Spacer(minLength: 0)
            }
            .developerToolbarRow()
            // Pinned at the right, outside the row that clips in a narrow dock.
            .overlay(alignment: .trailing) {
                DeveloperPanelIcon(symbol: "gearshape", title: captureSettingsShown ? "Hide capture settings" : "Capture settings",
                                   active: captureSettingsShown || jsSamplesDisabled || session.throttle != .unrestricted) {
                    captureSettingsShown.toggle()
                }
                .padding(.leading, DeveloperToolsStyle.controlSpacing)
                .padding(.trailing, DeveloperToolsStyle.gutter)
                .frame(maxHeight: .infinity)
                .background(DeveloperToolsStyle.chrome)
                .accessibilityIdentifier("developer-performance-capture-settings")
            }
            Divider()
            if captureSettingsShown {
                captureSettings
                Divider()
            }
        }
    }

    private var toolbarDivider: some View { Divider().frame(height: 16).padding(.horizontal, 2) }

    private var wholeRecordingButton: some View {
        DeveloperPanelIcon(symbol: "arrow.up.left.and.arrow.down.right", title: "Show the whole recording") {
            window = breadcrumbs.select(0)
        }
    }

    private func checkbox(_ title: String, _ isOn: Binding<Bool>, help: String, id: String) -> some View {
        Toggle(title, isOn: isOn).toggleStyle(.developerCheckbox).font(.system(size: 11))
            .help(help).accessibilityIdentifier(id)
    }

    /// The recording history menu, as in Chrome. ⌘F (Find in the
    /// timeline) comes through DevTools' keys (DeveloperPanelKeys).
    private var historyAndFind: some View {
        DeveloperPerformanceHistoryMenu(entries: history.history.entries, current: timelineKey) {
            showRecording($0)
        }
        .disabled(session.recordingTimeline || history.history.entries.isEmpty)
    }

    @ViewBuilder private var content: some View {
        if session.recordingTimeline {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(stopAfterLoad ? "Recording the page load…" : "Recording…").font(.system(size: 13, weight: .semibold))
                Text("\(session.timeline.count) events").monospacedDigit().foregroundStyle(.secondary)
                Button("Stop") { record() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if profile.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                DeveloperLiveMetricsView(session: session)
                    .padding(.bottom, 10)
                landing("record.circle", "Click Record or press ⌘E to start a new recording.")
                landing("arrow.clockwise", "Click Start profiling and reload page or press ⇧⌘E to record the page load.")
                landing("arrow.up.to.line", "Click Load profile or press ⌘O to open a saved profile, from Search or Chrome.")
                HStack {
                    Button("Record") { record() }
                    Button("Record and reload") { reloadAndRecord() }
                    Button("Load profile…") { loadProfile() }
                }
                .padding(.top, 4)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 0) {
                if showSidebar {
                    DeveloperPerformanceSidebar(
                        insights: insights, annotations: session.timelineAnnotations,
                        open: $openInsight, hovered: $hoveredInsight,
                        chooseInsight: { chooseInsight($0) },
                        chooseRow: { chooseRow($0, $1) },
                        showAnnotation: { show($0.range) },
                        deleteAnnotation: { session.removeTimelineAnnotation($0) },
                        askAI: insightAI)
                        .frame(width: 270)
                    Divider()
                }
                timeline
            }
        }
    }

    /// An insight card's Ask AI, while AI assistance is turned on.
    private var insightAI: ((DeveloperPerformanceInsight) -> Void)? {
        guard DeveloperAIAssistance.enabled else { return nil }
        let assistance = session.aiAssistance
        return { insight in assistance.askAboutInsight(insight) }
    }

    private var timeline: some View {
        VSplitView {
            VStack(spacing: 0) {
                if findShown {
                    DeveloperPerformanceFindBar(query: $findQuery, current: findIndex, count: findMatches.count,
                                                focusRequest: findFocus, step: { stepFind(backwards: $0) },
                                                close: { closeFind() })
                }
                if breadcrumbs.crumbs.count > 1 {
                    breadcrumbBar
                    Divider()
                }
                VStack(spacing: 0) {
                    overview.frame(height: 64)
                    if !profile.screenshots.isEmpty {
                        DeveloperPerformanceFilmstrip(profile: profile).equatable()
                            .frame(height: 40).allowsHitTesting(false)
                    }
                }
                .onContinuousHover { phase in
                    if case .active(let point) = phase { overviewHover = point } else { overviewHover = nil }
                }
                .overlay(alignment: .topLeading) { hoverShot }
                .zIndex(1)
                Divider()
                flame
            }
            .frame(minHeight: 150, idealHeight: 280)
            DeveloperPerformanceDetails(session: session, profile: profile, range: window.range,
                                        selected: selectedEvent,
                                        shift: selectedShift.flatMap { profile.layoutShifts.indices.contains($0) ? $0 : nil },
                                        custom: selectedCustom.flatMap { profile.customSummary($0) },
                                        choose: { select($0) },
                                        reveal: { index, node in
                                            DeveloperLiveMetricsModel.model(for: session).revealShiftNode(index: index, node: node)
                                        })
                .equatable()
                .frame(minHeight: 110, idealHeight: 200)
        }
    }

    private var selectedEvent: DeveloperPerformanceEvent? {
        selected.flatMap { profile.events.indices.contains($0) ? profile.events[$0] : nil }
    }

    /// The insight the timeline highlights: the card under the pointer, or the one open.
    private var highlightedInsight: DeveloperPerformanceInsight? {
        guard let id = hoveredInsight ?? openInsight else { return nil }
        return insights.first { $0.id == id }
    }

    private func landing(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).foregroundStyle(.secondary)
    }

    /// Chrome's breadcrumbs over the overview: the ranges zoomed into.
    private var breadcrumbBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(breadcrumbs.crumbs.indices, id: \.self) { index in
                    if index > 0 {
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    let active = index == breadcrumbs.active
                    Button(breadcrumbs.label(index)) { window = breadcrumbs.select(index) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: active ? .semibold : .regular))
                        .monospacedDigit()
                        .foregroundStyle(active ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(active ? DeveloperToolsStyle.tint.opacity(0.14) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 3))
                        .accessibilityIdentifier("developer-performance-breadcrumb-\(index)")
                }
            }
            .padding(.horizontal, DeveloperToolsStyle.gutter)
        }
        .frame(height: 22)
        .background(DeveloperToolsStyle.chrome)
    }

    // MARK: Overview

    private var overview: some View {
        GeometryReader { geometry in
            let width = Double(geometry.size.width)
            let total = profile.bounds.upperBound
            ZStack(alignment: .topLeading) {
                DeveloperPerformanceOverviewChart(profile: profile).equatable()
                Canvas { context, size in
                    let lower = CGFloat(window.lower / total) * size.width
                    let upper = CGFloat(window.upper / total) * size.width
                    let shade = Color.black.opacity(0.12)
                    context.fill(Path(CGRect(x: 0, y: 0, width: max(0, lower), height: size.height)), with: .color(shade))
                    context.fill(Path(CGRect(x: upper, y: 0, width: max(0, size.width - upper), height: size.height)),
                                 with: .color(shade))
                    for x in [lower, upper] {
                        context.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)),
                                     with: .color(DeveloperToolsStyle.tint))
                    }
                }
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let time = { (x: CGFloat) in Double(x) / max(width, 1) * total }
                if overviewDrag == nil {
                    let lowerX = window.lower / total * width, upperX = window.upper / total * width
                    let startX = Double(value.startLocation.x)
                    overviewDrag = OverviewDrag(grab: DeveloperOverviewDrag.grab(atX: startX, lowerX: lowerX,
                                                                                 upperX: upperX),
                                                original: window, from: time(value.startLocation.x))
                }
                guard let drag = overviewDrag else { return }
                if drag.grab == .choose, abs(value.translation.width) < 3 { return }
                window = DeveloperOverviewDrag.window(drag.grab, original: drag.original, from: drag.from,
                                                      to: time(value.location.x), bounds: profile.bounds)
            }.onEnded { _ in
                // A range chosen or resized is a breadcrumb, as Chrome adds one.
                if let drag = overviewDrag, drag.original != window { breadcrumbs.push(window) }
                overviewDrag = nil
            })
            .simultaneousGesture(TapGesture(count: 2).onEnded { window = breadcrumbs.select(0) })
            .help("Drag to choose a range; double-click to show the whole recording")
        }
        .accessibilityElement()
        .accessibilityLabel("Recording overview")
        .accessibilityValue("\(DeveloperPerformanceRuler.label(window.lower)) to \(DeveloperPerformanceRuler.label(window.upper))")
    }

    /// Chrome's screenshot under the pointer, enlarged below the overview.
    @ViewBuilder private var hoverShot: some View {
        GeometryReader { geometry in
            if let point = overviewHover, !profile.screenshots.isEmpty,
               let shot = profile.screenshot(at: Double(point.x / max(geometry.size.width, 1)) * profile.bounds.upperBound),
               let image = shot.image {
                let height: CGFloat = 180
                let width = height * image.size.width / max(image.size.height, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: width, height: height)
                    Text(DeveloperPerformanceRuler.label(shot.time)).font(.system(size: 10)).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .padding(4)
                .background(DeveloperToolsStyle.raised, in: RoundedRectangle(cornerRadius: 4))
                .shadow(radius: 3)
                .offset(x: min(max(0, point.x - width / 2), max(0, geometry.size.width - width - 8)),
                        y: geometry.size.height + 4)
                .allowsHitTesting(false)
            }
        }
    }

    // MARK: Flame chart

    private var flame: some View {
        GeometryReader { geometry in
            Canvas { context, size in draw(in: &context, size: size) }
                .overlay(alignment: .topLeading) { annotations }
                .overlay(alignment: .topLeading) { tooltip(width: geometry.size.width) }
                .overlay(alignment: .topLeading) { cpuTooltip(width: geometry.size.width) }
                .overlay(alignment: .topLeading) { customTooltip(width: geometry.size.width) }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        pointer = location
                        hovered = hit(location)?.id
                    case .ended:
                        pointer = nil
                        hovered = nil
                    }
                }
                .gesture(SpatialTapGesture().onEnded { value in
                    choose(at: value.location)
                    flameFocused = true
                })
                .contextMenu { entryMenu }
                .simultaneousGesture(DragGesture(minimumDistance: 4).onChanged { value in
                    // Dragging pans, as in Chrome's flame chart.
                    let start = flameDrag ?? FlameDrag(window: window, offset: offset)
                    flameDrag = start
                    let delta = -Double(value.translation.width) / max(Double(flameSize.width), 1) * start.window.span
                    window = start.window.panned(by: delta, in: profile.bounds)
                    offset = clampedOffset(start.offset - value.translation.height)
                }.onEnded { _ in flameDrag = nil })
                .onAppear { flameSize = geometry.size }
                .onChange(of: geometry.size) { _, size in
                    flameSize = size
                    offset = clampedOffset(offset)
                }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($flameFocused)
        .onKeyPress(characters: CharacterSet(charactersIn: "wasdWASD"), phases: [.down, .repeat]) { press in
            navigate(press.characters.lowercased())
            return .handled
        }
        .onKeyPress(.escape) {
            guard linkingFrom != nil else { return .ignored }
            linkingFrom = nil
            return .handled
        }
        .overlay(alignment: .bottomLeading) { linkingHint }
        .accessibilityElement()
        .accessibilityLabel("Flame chart")
        .accessibilityHint("W and S zoom, A and D pan")
    }

    /// While an entries link is being drawn: what the next click does.
    @ViewBuilder private var linkingHint: some View {
        if linkingFrom != nil {
            Text("Click the entry to link to. Esc cancels.")
                .font(.system(size: 11))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(DeveloperToolsStyle.rule))
                .padding(8)
                .allowsHitTesting(false)
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let width = Double(size.width)
        let ruler = Self.rulerHeight, row = Self.rowHeight
        context.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: ruler)), with: .color(DeveloperToolsStyle.chrome))
        DeveloperPerformanceRuler.draw(in: &context, window: window, size: size, labelY: ruler / 2)
        let mainTop = drawAuxiliaryTracks(in: &context, width: size.width, from: ruler + annotationHeight)
        // Main's header stays put as its lanes scroll.
        context.fill(Path(CGRect(x: 0, y: mainTop, width: size.width, height: Self.trackHeight)),
                     with: .color(DeveloperToolsStyle.chrome))
        context.fill(Path(CGRect(x: 0, y: mainTop + Self.trackHeight - 0.5, width: size.width, height: 0.5)),
                     with: .color(DeveloperToolsStyle.rule))
        let page = session.address.map { " — " + $0.absoluteString } ?? ""
        context.draw(Text("Main" + page).font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary),
                     at: CGPoint(x: 8, y: mainTop + Self.trackHeight / 2), anchor: .leading)
        let top = lanesTop
        let first = max(0, Int(offset / row)), last = Int((offset + size.height - top) / row)
        var lanes = context
        lanes.clip(to: Path(CGRect(x: 0, y: top, width: size.width, height: max(0, size.height - top))))
        let insight = highlightedInsight
        let highlighted = Set(insight?.events ?? [])
        let found: Set<Int> = findShown ? findMatchSet : []
        for event in profile.shown where !event.isHidden && event.row >= first && event.row <= last
            && event.end >= window.lower && event.start <= window.upper {
            let left = CGFloat(max(-1, window.x(event.start, width: width)))
            let right = CGFloat(min(width + 1, window.x(event.end, width: width)))
            let rect = CGRect(x: left, y: top + CGFloat(event.row) * row - offset,
                              width: max(1, right - left), height: row - 1)
            var color = event.category.color
            let dim = dimThirdParties && thirdParty.contains(event.id)
            if dim { color = Self.dimmedColor }
            if hovered == event.id { color = color.opacity(0.75) }
            lanes.fill(Path(rect), with: .color(color))
            if profile.events[event.id].parent == nil, event.duration > DeveloperPerformanceProfile.longTask {
                // A long task: what ran past 50 ms striped red, as Chrome marks it.
                let over = CGFloat(window.x(event.start + DeveloperPerformanceProfile.longTask, width: width))
                let from = max(rect.minX, over)
                Self.overrun(&lanes, CGRect(x: from, y: rect.minY, width: max(0, rect.maxX - from), height: rect.height))
            }
            if highlighted.contains(event.id) {
                lanes.stroke(Path(rect.insetBy(dx: 0.5, dy: 0.5)), with: .color(Self.insightColor), lineWidth: 2)
            }
            if found.contains(event.id) {
                // A find match, outlined as Chrome marks its search results.
                lanes.fill(Path(rect), with: .color(Self.findColor.opacity(0.35)))
                lanes.stroke(Path(rect.insetBy(dx: 0.5, dy: 0.5)), with: .color(Self.findColor), lineWidth: 1.5)
            }
            if selected == event.id { Self.outline(&lanes, rect) }
            let decorated = event.hidesChildren && rect.width > 8
            if decorated {
                // Chrome's mark on an entry whose children are hidden: a
                // small triangle at its right end.
                var triangle = Path()
                triangle.move(to: CGPoint(x: rect.maxX - 7, y: rect.minY + 3))
                triangle.addLine(to: CGPoint(x: rect.maxX - 1, y: rect.minY + 3))
                triangle.addLine(to: CGPoint(x: rect.maxX - 4, y: rect.maxY - 3))
                triangle.closeSubpath()
                lanes.fill(triangle, with: .color(.black.opacity(0.7)))
            }
            if rect.width > 28 {
                var label = lanes
                label.clip(to: Path(CGRect(x: rect.minX + 3, y: rect.minY,
                                           width: max(0, rect.width - 6 - (decorated ? 8 : 0)), height: rect.height)))
                label.draw(Text(event.detail.map { "\(event.title) · \($0)" } ?? event.title)
                    .font(.system(size: 10)).foregroundColor(.black.opacity(dim ? 0.45 : 0.82)),
                           at: CGPoint(x: rect.minX + 3, y: rect.midY), anchor: .leading)
            }
        }
        drawLinks(in: &lanes, width: width, top: top)
        drawMarkerLines(in: &context, size: size)
        if let insight { drawInsight(insight, in: &context, size: size) }
    }

    /// Where an entry of the Main track is drawn.
    private func entryRect(_ event: DeveloperPerformanceEvent, width: Double, top: CGFloat) -> CGRect {
        let left = CGFloat(window.x(event.start, width: width))
        let right = CGFloat(window.x(event.end, width: width))
        return CGRect(x: left, y: top + CGFloat(event.row) * Self.rowHeight - offset,
                      width: max(1, right - left), height: Self.rowHeight - 1)
    }

    /// Chrome's entries links: an arrow from the end of one entry to the
    /// start of the other, and the one being drawn, to the pointer.
    private func drawLinks(in context: inout GraphicsContext, width: Double, top: CGFloat) {
        for link in links where profile.shown.indices.contains(link.from) && profile.shown.indices.contains(link.to) {
            let from = profile.shown[link.from], to = profile.shown[link.to]
            guard !from.isHidden, !to.isHidden else { continue }
            let start = entryRect(from, width: width, top: top), end = entryRect(to, width: width, top: top)
            Self.arrow(&context, from: CGPoint(x: start.maxX, y: start.midY), to: CGPoint(x: end.minX, y: end.midY),
                       dashed: false)
        }
        if let linkingFrom, profile.shown.indices.contains(linkingFrom), let pointer {
            let start = entryRect(profile.shown[linkingFrom], width: width, top: top)
            Self.arrow(&context, from: CGPoint(x: start.maxX, y: start.midY), to: pointer, dashed: true)
        }
    }

    private static func arrow(_ context: inout GraphicsContext, from start: CGPoint, to end: CGPoint, dashed: Bool) {
        let bend = max(16, abs(end.x - start.x) / 3)
        var path = Path()
        path.move(to: start)
        path.addCurve(to: end, control1: CGPoint(x: start.x + bend, y: start.y),
                      control2: CGPoint(x: end.x - bend, y: end.y))
        context.stroke(path, with: .color(linkColor), style: StrokeStyle(lineWidth: 1.5, dash: dashed ? [4, 3] : []))
        var head = Path()
        head.move(to: CGPoint(x: end.x - 7, y: end.y - 4))
        head.addLine(to: end)
        head.addLine(to: CGPoint(x: end.x - 7, y: end.y + 4))
        head.closeSubpath()
        context.fill(head, with: .color(linkColor))
        context.fill(Path(ellipseIn: CGRect(x: start.x - 2.5, y: start.y - 2.5, width: 5, height: 5)),
                     with: .color(linkColor))
    }

    /// An insight's ranges as bands down the tracks and lanes, as Chrome
    /// shades what a hovered insight is about.
    private func drawInsight(_ insight: DeveloperPerformanceInsight, in context: inout GraphicsContext, size: CGSize) {
        let width = Double(size.width)
        let top = Self.rulerHeight
        for range in insight.ranges.prefix(300) where range.upperBound >= window.lower && range.lowerBound <= window.upper {
            let left = CGFloat(max(-2, window.x(range.lowerBound, width: width)))
            let right = CGFloat(min(width + 2, window.x(range.upperBound, width: width)))
            let band = CGRect(x: left, y: top, width: max(2, right - left), height: max(0, size.height - top))
            context.fill(Path(band), with: .color(Self.insightColor.opacity(0.12)))
            for x in [band.minX, band.maxX] {
                context.fill(Path(CGRect(x: x - 0.5, y: top, width: 1, height: band.height)),
                             with: .color(Self.insightColor.opacity(0.7)))
            }
        }
    }

    @ViewBuilder private var annotations: some View {
        if annotationHeight > 0 {
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(DeveloperToolsStyle.chrome))
                for annotation in rangeAnnotations where annotation.range.overlaps(window.range) {
                    let x = max(0, window.x(annotation.range.lowerBound, width: size.width))
                    let end = min(size.width, window.x(annotation.range.upperBound, width: size.width))
                    let bar = CGRect(x: x, y: size.height - 3, width: max(1, end - x), height: 2)
                    context.fill(Path(bar), with: .color(DeveloperToolsStyle.tint))
                    var label = context
                    label.clip(to: Path(CGRect(x: x, y: 0, width: max(0, size.width - x), height: size.height)))
                    label.draw(Text(annotation.label).font(.system(size: 10, weight: .medium)).foregroundColor(.primary),
                               at: CGPoint(x: x + 4, y: (size.height - 3) / 2), anchor: .leading)
                }
            }
            .frame(height: annotationHeight)
            .allowsHitTesting(false)
            .accessibilityLabel(rangeAnnotations.map(\.label).joined(separator: ", "))
            .overlay(alignment: .topLeading) { annotationTargets }
            .offset(y: Self.rulerHeight)
        }
    }

    /// Each label answers a right-click with Delete annotation, as in Chrome.
    private var annotationTargets: some View {
        GeometryReader { geometry in
            let width = Double(geometry.size.width)
            ForEach(rangeAnnotations.filter { $0.range.overlaps(window.range) }) { annotation in
                let x = max(0, window.x(annotation.range.lowerBound, width: width))
                let end = min(width, window.x(annotation.range.upperBound, width: width))
                Color.clear
                    .frame(width: CGFloat(max(1, min(width - x, max(end - x, 80)))), height: annotationHeight)
                    .contentShape(Rectangle())
                    .help(annotation.label)
                    .contextMenu {
                        Button("Delete annotation") { session.removeTimelineAnnotation(annotation.id) }
                    }
                    .accessibilityElement()
                    .accessibilityLabel(annotation.label)
                    .accessibilityAction(named: "Delete annotation") { session.removeTimelineAnnotation(annotation.id) }
                    .offset(x: CGFloat(x))
            }
        }
        .frame(height: annotationHeight)
    }

    /// Chrome's context menu on a Main track entry: hiding functions and
    /// children, and undoing it.
    @ViewBuilder private var entryMenu: some View {
        if let id = hovered, profile.shown.indices.contains(id), !profile.shown[id].isHidden {
            Button("Hide function") { profile.hideFunction(id); afterHide() }
            Button("Hide children") { profile.hideChildren(id); afterHide() }
                .disabled(!profile.canHideChildren(id))
            Button("Hide repeating children") { profile.hideRepeatingChildren(id); afterHide() }
                .disabled(!profile.canHideRepeatingChildren(id))
            Button("Reset children") { profile.resetChildren(id); afterHide() }
                .disabled(!profile.canResetChildren(id))
            Divider()
            // Chrome's entries link: this entry, then a click on the other.
            Button("Link entries") { linkingFrom = id; flameFocused = true }
                .disabled(session.timelineAnnotations.count >= 256)
            if DeveloperAIAssistance.enabled {
                Button("Ask AI") { askAI(about: id) }
            }
            Divider()
        }
        Button("Reset trace") { profile.resetTrace(); afterHide() }
            .disabled(profile.hides.isEmpty)
    }

    /// After a hide: what's selected or hovered may have merged away.
    private func afterHide() {
        if let selected, profile.shown.indices.contains(selected), profile.shown[selected].isHidden { self.selected = nil }
        hovered = nil
        offset = clampedOffset(offset)
        if findShown { refind(jump: false) }
    }

    private func drawAuxiliaryTracks(in context: inout GraphicsContext, width: CGFloat, from start: CGFloat) -> CGFloat {
        var y = start
        for entry in tracks {
            let height: CGFloat = entry.height
            defer { y += height }
            guard let title = trackTitle(entry.track) else { continue }
            trackHeader(title, in: &context, width: width, y: y, height: height)
            switch entry.track {
            case .network: drawNetworkTrack(in: &context, width: width, y: y)
            case .frames: drawFramesTrack(in: &context, width: width, y: y)
            case .animations: drawAnimationsTrack(in: &context, width: width, y: y)
            case .timings: drawTimingsTrack(in: &context, width: width, y: y)
            case .interactions: drawInteractionsTrack(in: &context, width: width, y: y)
            case .layoutShifts: drawLayoutShiftsTrack(in: &context, width: width, y: y)
            case .heap:
                let maximum = heapMaximum
                let graph = CGRect(x: 0, y: y + Self.trackHeight, width: width, height: height - Self.trackHeight)
                var line = Path()
                for (index, point) in profile.heap.enumerated() {
                    let position = CGPoint(x: window.x(point.time, width: width),
                                           y: graph.maxY - 3 - (graph.height - 6) * point.bytes / maximum)
                    if profile.heap.count == 1 {
                        line.addEllipse(in: CGRect(x: position.x - 1, y: position.y - 1, width: 2, height: 2))
                    } else if index == 0 { line.move(to: position) } else { line.addLine(to: position) }
                }
                var clipped = context
                clipped.clip(to: Path(graph))
                clipped.stroke(line, with: .color(DeveloperToolsStyle.tint), lineWidth: 1.5)
            case .cpu:
                let graph = CGRect(x: 0, y: y + Self.trackHeight, width: width, height: height - Self.trackHeight - 1)
                var clipped = context
                clipped.clip(to: Path(graph))
                Self.drawCPU(profile.cpu, in: &clipped, graph: graph, window: window, scale: max(100, cpuBusiest))
            case .customGroup: break
            case .custom(let index): drawCustomTrack(index, in: &context, width: width, y: y)
            }
        }
        return y
    }

    private var heapMaximum: Double { max(1, profile.heap.map(\.bytes).max() ?? 0) }
    private var cpuBusiest: Double { profile.cpu.map(\.usage).max() ?? 0 }

    /// A track's header title; nil for a custom track that's gone.
    private func trackTitle(_ track: Track) -> String? {
        switch track {
        case .network: "Network"
        case .frames: "Frames"
        case .animations: "Animations"
        case .timings: "Timings"
        case .interactions: "Interactions"
        case .layoutShifts: "Layout shifts"
        case .heap: "JS heap size (\(DeveloperMetricFormat.bytes(heapMaximum)) max)"
        case .cpu: "CPU (\(DeveloperPerformanceCPU.percent(cpuBusiest)) max)"
        case .customGroup(let name): (collapsedGroups.contains(name) ? "▸ " : "▾ ") + name
        case .custom(let index):
            profile.customTracks.indices.contains(index)
                ? (profile.customTracks[index].group == nil ? "" : "    ") + profile.customTracks[index].name : nil
        }
    }

    /// A track's title bar, and the rule under the track.
    private func trackHeader(_ title: String, in context: inout GraphicsContext, width: CGFloat, y: CGFloat,
                             height: CGFloat) {
        context.fill(Path(CGRect(x: 0, y: y, width: width, height: Self.trackHeight)), with: .color(DeveloperToolsStyle.chrome))
        context.draw(Text(title).font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary),
                     at: CGPoint(x: 8, y: y + Self.trackHeight / 2), anchor: .leading)
        context.fill(Path(CGRect(x: 0, y: y + height - 0.5, width: width, height: 0.5)), with: .color(DeveloperToolsStyle.rule))
    }

    /// Where a stretch of time starts and ends across the track, a point
    /// past either edge at most.
    private func trackSpan(_ start: Double, _ end: Double, width: CGFloat) -> (left: CGFloat, right: CGFloat) {
        (CGFloat(max(-1, window.x(start, width: width))), CGFloat(min(width + 1, window.x(end, width: width))))
    }

    /// A bar's name inside it, when it has room for one.
    private static func trackLabel(_ text: String, in rect: CGRect, context: GraphicsContext, size: CGFloat = 9,
                                   color: Color = .black.opacity(0.82)) {
        guard rect.width > 24 else { return }
        var clipped = context
        clipped.clip(to: Path(rect.insetBy(dx: 2, dy: 0)))
        clipped.draw(Text(text).font(.system(size: size)).foregroundColor(color),
                     at: CGPoint(x: rect.minX + 3, y: rect.midY), anchor: .leading)
    }

    private func drawNetworkTrack(in context: inout GraphicsContext, width: CGFloat, y: CGFloat) {
        let rows = 3
        var available = Array(repeating: -Double.infinity, count: rows)
        for bar in profile.network where bar.end >= window.lower && bar.start <= window.upper {
            let row: Int = available.firstIndex { $0 <= bar.start } ?? rows - 1
            available[row] = max(available[row], bar.end)
            let left: CGFloat = max(0, window.x(bar.start, width: width))
            let right: CGFloat = min(width, window.x(bar.end, width: width))
            let barY: CGFloat = y + Self.trackHeight + CGFloat(row) * 9 + 2
            context.fill(Path(CGRect(x: left, y: barY, width: max(1, right - left), height: 7)),
                         with: .color(DeveloperPerformanceCategory.loading.color))
            if right - left > 30 {
                var named = context
                named.clip(to: Path(CGRect(x: left + 2, y: barY, width: right - left - 4, height: 7)))
                let file = URL(string: bar.url)?.lastPathComponent ?? bar.url
                named.draw(Text(file).font(.system(size: 7)).foregroundColor(.black.opacity(0.8)),
                           at: CGPoint(x: left + 2, y: barY + 3.5), anchor: .leading)
            }
        }
    }

    private func drawFramesTrack(in context: inout GraphicsContext, width: CGFloat, y: CGFloat) {
        for id in profile.frames {
            let frame = profile.events[id]
            guard frame.end >= window.lower && frame.start <= window.upper else { continue }
            let (left, right) = trackSpan(frame.start, frame.end, width: width)
            let rect = CGRect(x: left, y: y + Self.trackHeight + 1, width: max(1, right - left), height: 15)
            // As Chrome: a frame that took over two vsyncs is drawn as dropped.
            let dropped: Bool = frame.duration > 1_000 / 30
            let fill: Color = dropped ? Self.longTaskColor.opacity(0.35) : Self.frameColor.opacity(0.55)
            context.fill(Path(rect), with: .color(fill))
            context.stroke(Path(rect), with: .color(DeveloperToolsStyle.rule), lineWidth: 0.5)
            if selected == id { Self.outline(&context, rect) }
            Self.trackLabel(DeveloperPerformanceRuler.label(frame.duration), in: rect, context: context)
        }
    }

    private func drawAnimationsTrack(in context: inout GraphicsContext, width: CGFloat, y: CGFloat) {
        for bar in profile.animations where bar.end >= window.lower && bar.start <= window.upper {
            let (left, right) = trackSpan(bar.start, bar.end, width: width)
            let rect = CGRect(x: left, y: y + Self.trackHeight + 2 + CGFloat(bar.row) * Self.barHeight,
                              width: max(2, right - left), height: Self.barHeight - 2)
            // The delay lighter, as Chrome draws an animation's.
            let (_, delayEnd) = trackSpan(bar.start, bar.activeStart, width: width)
            let activeStart: CGFloat = max(rect.minX, delayEnd)
            let active = CGRect(x: activeStart, y: rect.minY, width: max(0, rect.maxX - activeStart), height: rect.height)
            let opacity: Double = bar.state == "canceled" ? 0.5 : 0.85
            context.fill(Path(rect), with: .color(Self.animationColor.opacity(0.3)))
            context.fill(Path(active), with: .color(Self.animationColor.opacity(opacity)))
            Self.trackLabel(bar.name, in: rect, context: context, color: .white)
        }
    }

    private func drawTimingsTrack(in context: inout GraphicsContext, width: CGFloat, y: CGFloat) {
        let chipY: CGFloat = y + Self.trackHeight + 1
        for marker in profile.markers where marker.start >= window.lower && marker.start <= window.upper {
            let x = CGFloat(window.x(marker.start, width: width))
            let text = context.resolve(Text(marker.kind).font(.system(size: 9, weight: .semibold)).foregroundColor(.white))
            let size: CGSize = text.measure(in: CGSize(width: 80, height: 14))
            let chip = CGRect(x: x - size.width / 2 - 3, y: chipY, width: size.width + 6, height: 14)
            context.fill(Path(roundedRect: chip, cornerRadius: 3), with: .color(Self.markerColor(marker.kind)))
            context.draw(text, at: CGPoint(x: chip.midX, y: chip.midY))
        }
        // The page's own markers, named, as Chrome draws them.
        for (index, marker) in profile.extensionMarkers.enumerated()
            where marker.time >= window.lower && marker.time <= window.upper {
            let x = CGFloat(window.x(marker.time, width: width))
            let ink: Color = DeveloperPerformanceExtensions.isLight(marker.color) ? .black.opacity(0.82) : .white
            let text = context.resolve(Text(marker.name).font(.system(size: 9, weight: .semibold)).foregroundColor(ink))
            let size: CGSize = text.measure(in: CGSize(width: 160, height: 14))
            let chipWidth: CGFloat = min(size.width, 160)
            let chip = CGRect(x: x - chipWidth / 2 - 3, y: chipY, width: chipWidth + 6, height: 14)
            context.fill(Path(roundedRect: chip, cornerRadius: 3), with: .color(Self.extensionColor(marker.color)))
            if selectedCustom == DeveloperPerformanceExtensions.Selection(track: nil, index: index) {
                context.stroke(Path(roundedRect: chip.insetBy(dx: -1, dy: -1), cornerRadius: 3),
                               with: .color(DeveloperToolsStyle.tint), lineWidth: 1.5)
            }
            var clipped = context
            clipped.clip(to: Path(chip))
            clipped.draw(text, at: CGPoint(x: chip.midX, y: chip.midY))
        }
        for timing in profile.pageTimings where timing.end >= window.lower && timing.start <= window.upper {
            let barY: CGFloat = y + Self.trackHeight + 18 + CGFloat(timing.row) * Self.barHeight
            let (left, right) = trackSpan(timing.start, timing.end, width: width)
            if timing.kind == "measure" {
                let rect = CGRect(x: left, y: barY, width: max(1, right - left), height: Self.barHeight - 2)
                let fill: Color = timing.color.map { Self.extensionColor($0) } ?? Self.measureColor
                context.fill(Path(rect), with: .color(fill))
                let light: Bool = timing.color.map { DeveloperPerformanceExtensions.isLight($0) } ?? true
                Self.trackLabel(timing.name, in: rect, context: context, color: light ? .black.opacity(0.82) : .white)
            } else {
                // A mark: a tick, named beside it.
                context.fill(Path(CGRect(x: left - 0.5, y: barY, width: 1.5, height: Self.barHeight - 2)),
                             with: .color(Self.markerColor("mark")))
                Self.trackLabel(timing.name, in: CGRect(x: left + 1, y: barY, width: 140, height: Self.barHeight - 2),
                                context: context, color: .secondary)
            }
        }
    }

    private func drawInteractionsTrack(in context: inout GraphicsContext, width: CGFloat, y: CGFloat) {
        for interaction in profile.interactions
            where interaction.end >= window.lower && interaction.start <= window.upper {
            let (left, right) = trackSpan(interaction.start, interaction.end, width: width)
            let whole = CGRect(x: left, y: y + Self.trackHeight + 2 + CGFloat(interaction.row) * Self.barHeight,
                               width: max(2, right - left), height: Self.barHeight - 2)
            // As Chrome: the handlers' time a box, the input delay
            // and presentation delay whiskers either side of it.
            let (boxLeft, boxRight) = trackSpan(interaction.processingStart, interaction.processingEnd, width: width)
            let rect = CGRect(x: boxLeft, y: whole.minY, width: max(2, boxRight - boxLeft), height: whole.height)
            var whiskers = Path()
            if rect.minX - whole.minX > 1 {
                whiskers.move(to: CGPoint(x: whole.minX, y: whole.midY))
                whiskers.addLine(to: CGPoint(x: rect.minX, y: whole.midY))
                whiskers.move(to: CGPoint(x: whole.minX, y: whole.minY + 2))
                whiskers.addLine(to: CGPoint(x: whole.minX, y: whole.maxY - 2))
            }
            if whole.maxX - rect.maxX > 1 {
                whiskers.move(to: CGPoint(x: rect.maxX, y: whole.midY))
                whiskers.addLine(to: CGPoint(x: whole.maxX, y: whole.midY))
                whiskers.move(to: CGPoint(x: whole.maxX, y: whole.minY + 2))
                whiskers.addLine(to: CGPoint(x: whole.maxX, y: whole.maxY - 2))
            }
            context.stroke(whiskers, with: .color(Self.interactionColor), lineWidth: 1)
            context.fill(Path(rect), with: .color(Self.interactionColor))
            if interaction.duration > DeveloperPerformanceProfile.longInteraction {
                // Past 200 ms, Chrome's long interaction: striped red, a triangle at its end.
                let over = CGFloat(window.x(interaction.start + DeveloperPerformanceProfile.longInteraction, width: width))
                let from: CGFloat = max(rect.minX, over)
                Self.overrun(&context, CGRect(x: from, y: rect.minY, width: max(0, rect.maxX - from), height: rect.height))
            }
            if selected == interaction.event { Self.outline(&context, whole) }
            Self.trackLabel(interaction.type, in: rect, context: context)
        }
    }

    private func drawLayoutShiftsTrack(in context: inout GraphicsContext, width: CGFloat, y: CGFloat) {
        let midY: CGFloat = y + Self.trackHeight + 9
        // Each cluster a band from its first shift to its last, its
        // shifts diamonds on it, as Chrome draws them.
        for cluster in profile.shiftClusters where cluster.end >= window.lower && cluster.start <= window.upper {
            let (left, right) = trackSpan(cluster.start, cluster.end, width: width)
            let band = CGRect(x: left - 4, y: midY - 7, width: max(8, right - left + 8), height: 14)
            context.fill(Path(roundedRect: band, cornerRadius: 3), with: .color(Self.layoutShiftColor.opacity(0.16)))
        }
        let slack: Double = window.span * 0.01
        for (index, shift) in profile.layoutShifts.enumerated()
            where shift.time >= window.lower - slack && shift.time <= window.upper + slack {
            let x = CGFloat(window.x(shift.time, width: width))
            var diamond = Path()
            diamond.move(to: CGPoint(x: x, y: midY - 5))
            diamond.addLine(to: CGPoint(x: x + 5, y: midY))
            diamond.addLine(to: CGPoint(x: x, y: midY + 5))
            diamond.addLine(to: CGPoint(x: x - 5, y: midY))
            diamond.closeSubpath()
            context.fill(diamond, with: .color(Self.layoutShiftColor))
            if selectedShift == index {
                context.stroke(diamond, with: .color(DeveloperToolsStyle.tint), lineWidth: 1.5)
            }
        }
    }

    private func drawCustomTrack(_ index: Int, in context: inout GraphicsContext, width: CGFloat, y: CGFloat) {
        let custom = profile.customTracks[index]
        for (entryIndex, entry) in custom.entries.enumerated()
            where entry.end >= window.lower && entry.start <= window.upper {
            let (left, right) = trackSpan(entry.start, entry.end, width: width)
            let rect = CGRect(x: left, y: y + Self.trackHeight + 2 + CGFloat(entry.row) * Self.barHeight,
                              width: max(2, right - left), height: Self.barHeight - 2)
            context.fill(Path(rect), with: .color(Self.extensionColor(entry.color)))
            if selectedCustom == DeveloperPerformanceExtensions.Selection(track: index, index: entryIndex) {
                Self.outline(&context, rect)
            }
            let ink: Color = DeveloperPerformanceExtensions.isLight(entry.color) ? .black.opacity(0.82) : .white
            Self.trackLabel(entry.name, in: rect, context: context, color: ink)
        }
    }

    /// The chosen entry's outline.
    private static func outline(_ context: inout GraphicsContext, _ rect: CGRect) {
        context.stroke(Path(rect.insetBy(dx: 0.75, dy: 0.75)), with: .color(DeveloperToolsStyle.tint), lineWidth: 1.5)
    }

    /// Chrome's mark for work past its budget: red stripes over the part
    /// that ran over, and a red triangle in the bar's top right corner.
    private static func overrun(_ context: inout GraphicsContext, _ rect: CGRect) {
        guard rect.width > 0, rect.height > 0 else { return }
        var striped = context
        striped.clip(to: Path(rect))
        striped.fill(Path(rect), with: .color(longTaskColor.opacity(0.25)))
        var lines = Path()
        // Lined up with the view, not the bar, so the stripes don't crawl as it pans.
        var x = (rect.minX / 6).rounded(.down) * 6 - rect.height
        while x < rect.maxX {
            lines.move(to: CGPoint(x: x, y: rect.maxY))
            lines.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += 6
        }
        striped.stroke(lines, with: .color(longTaskColor.opacity(0.85)), lineWidth: 1)
        let side = min(6, rect.height)
        var triangle = Path()
        triangle.move(to: CGPoint(x: rect.maxX - side, y: rect.minY))
        triangle.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        triangle.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + side))
        triangle.closeSubpath()
        context.fill(triangle, with: .color(longTaskColor))
    }

    /// The CPU track's threads, bottom up, as Web Inspector stacks them.
    private static let cpuLayers: [(name: String, color: Color)] = [
        ("Main thread", DeveloperPerformanceCategory.loading.color),
        ("Worker threads", DeveloperPerformanceCategory.painting.color),
        ("WebKit threads", DeveloperPerformanceCategory.rendering.color),
        ("Other threads", DeveloperPerformanceCategory.system.color),
    ]

    /// Each layer's top for a sample: main, then workers, then WebKit's
    /// threads stacked on it, the whole usage on top.
    private static func cpuTops(_ sample: DeveloperPerformanceCPU.Sample) -> [Double] {
        let main = sample.main ?? 0
        let workers = main + (sample.workers ?? 0)
        let webkit = workers + (sample.webkit ?? 0)
        return [main, workers, webkit, max(webkit, sample.usage)]
    }

    /// The CPU track's stacked area: each reading covers the half second
    /// before it, as WebKit samples.
    private static func drawCPU(_ samples: [DeveloperPerformanceCPU.Sample], in context: inout GraphicsContext,
                                graph: CGRect, window: DeveloperFlameWindow, scale: Double) {
        guard !samples.isEmpty else { return }
        let width = Double(graph.width)
        func y(_ value: Double) -> CGFloat {
            graph.maxY - (graph.height - 2) * CGFloat(min(max(0, value), scale) / max(scale, 1))
        }
        // Only the readings in view, and one either side.
        let first = max(0, (samples.firstIndex { $0.time >= window.lower } ?? samples.count) - 1)
        let last = min(samples.count - 1, (samples.firstIndex { $0.time > window.upper + 500 } ?? samples.count - 1))
        guard first <= last else { return }
        for layer in cpuLayers.indices.reversed() {
            var area = Path()
            var previous = first > 0 ? samples[first - 1].time : -Double.infinity
            area.move(to: CGPoint(x: window.x(max(previous, samples[first].time - 500), width: width), y: graph.maxY))
            for index in first...last {
                let sample = samples[index]
                let top = y(cpuTops(sample)[layer])
                let from = CGFloat(window.x(max(previous, sample.time - 500), width: width))
                let to = CGFloat(window.x(sample.time, width: width))
                area.addLine(to: CGPoint(x: from, y: top))
                area.addLine(to: CGPoint(x: to, y: top))
                previous = sample.time
            }
            area.addLine(to: CGPoint(x: window.x(samples[last].time, width: width), y: graph.maxY))
            area.closeSubpath()
            context.fill(area, with: .color(cpuLayers[layer].color.opacity(0.85)))
        }
    }

    /// The CPU track's reading under the pointer, broken down by thread.
    @ViewBuilder private func cpuTooltip(width: CGFloat) -> some View {
        if let pointer, flameDrag == nil, track(at: pointer.y)?.track == .cpu,
           let sample = DeveloperPerformanceCPU.sample(
               at: window.time(atX: Double(pointer.x), width: chartWidth), in: profile.cpu) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(DeveloperPerformanceRuler.label(sample.time)).monospacedDigit().foregroundStyle(.secondary)
                    Text("CPU usage \(DeveloperPerformanceCPU.percent(sample.usage))").fontWeight(.medium)
                }
                if sample.hasThreads {
                    let values = [sample.main ?? 0, sample.workers ?? 0, sample.webkit ?? 0,
                                  max(0, sample.usage - (sample.main ?? 0) - (sample.workers ?? 0) - (sample.webkit ?? 0))]
                    ForEach(Self.cpuLayers.indices, id: \.self) { index in
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2).fill(Self.cpuLayers[index].color).frame(width: 9, height: 9)
                            Text(index == 1 && sample.workerCount > 0
                                 ? "\(Self.cpuLayers[index].name) (\(sample.workerCount))" : Self.cpuLayers[index].name)
                            Spacer(minLength: 8)
                            Text(DeveloperPerformanceCPU.percent(values[index])).monospacedDigit()
                        }
                    }
                }
            }
            .flameTooltip(at: pointer, in: width, width: 200, fixed: true)
        }
    }

    /// The page's milestones as dashed lines down the tracks and lanes.
    private func drawMarkerLines(in context: inout GraphicsContext, size: CGSize) {
        func line(at time: Double) -> Path {
            let x = CGFloat(window.x(time, width: Double(size.width)))
            return Path { $0.move(to: CGPoint(x: x, y: Self.rulerHeight)); $0.addLine(to: CGPoint(x: x, y: size.height)) }
        }
        for marker in profile.markers where marker.start >= window.lower && marker.start <= window.upper {
            context.stroke(line(at: marker.start), with: .color(Self.markerColor(marker.kind).opacity(0.7)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        for marker in profile.extensionMarkers where marker.time >= window.lower && marker.time <= window.upper {
            context.stroke(line(at: marker.time), with: .color(Self.extensionColor(marker.color).opacity(0.8)), lineWidth: 1)
        }
    }

    @ViewBuilder private func tooltip(width: CGFloat) -> some View {
        if let pointer, let hovered, profile.shown.indices.contains(hovered), flameDrag == nil {
            let event = profile.shown[hovered]
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(DeveloperPerformanceRuler.label(event.duration)).monospacedDigit().foregroundStyle(.secondary)
                    Text(event.title).fontWeight(.medium)
                }
                if let detail = event.detail { Text(detail).foregroundStyle(.secondary).lineLimit(1) }
                if event.selfTime < event.duration {
                    Text("Self time \(DeveloperPerformanceRuler.label(event.selfTime))").foregroundStyle(.secondary)
                }
                if let frame = event.stack.first { Text(frame).font(DeveloperToolsStyle.code).lineLimit(1) }
            }
            .flameTooltip(at: pointer, in: width)
        }
    }

    // MARK: Navigation

    /// A click in the flame chart: a record in the lanes, or a frame or an
    /// interaction in its track, shown in Summary.
    private func choose(at location: CGPoint) {
        if let from = linkingFrom {
            // The click that ends an entries link: the entry it goes to.
            linkingFrom = nil
            if let target = hit(location), target.id != from { link(from, to: target.id) }
            return
        }
        selectedShift = nil
        selectedCustom = nil
        guard let found = track(at: location.y) else {
            selected = hit(location)?.id
            return
        }
        let top = found.top
        let width = chartWidth
        let time = window.time(atX: Double(location.x), width: width)
        let slack = 3 / width * window.span
        switch found.track {
        case .frames:
            selected = profile.frames.first { profile.events[$0].start - slack <= time && time <= profile.events[$0].end + slack }
        case .interactions:
            let row = Int((location.y - top - Self.trackHeight - 2) / Self.barHeight)
            selected = profile.interactions.first {
                $0.row == row && $0.start - slack <= time && time <= $0.end + slack
            }?.event
        case .layoutShifts:
            // The nearest diamond within a few points.
            selected = nil
            let reach = 6 / width * window.span
            selectedShift = profile.layoutShifts.indices
                .filter { abs(profile.layoutShifts[$0].time - time) <= reach }
                .min { abs(profile.layoutShifts[$0].time - time) < abs(profile.layoutShifts[$1].time - time) }
        case .customGroup(let name):
            // A group's header collapses and expands its tracks.
            selected = nil
            if collapsedGroups.contains(name) { collapsedGroups.remove(name) } else { collapsedGroups.insert(name) }
            offset = clampedOffset(offset)
        case .custom, .timings:
            selected = nil
            selectedCustom = customHit(location)
        default:
            selected = nil
        }
    }

    /// The custom track entry or extension marker at `location`.
    private func customHit(_ location: CGPoint) -> DeveloperPerformanceExtensions.Selection? {
        guard let found = track(at: location.y) else { return nil }
        let width = chartWidth
        let time = window.time(atX: Double(location.x), width: width)
        switch found.track {
        case .custom(let index):
            let row = Int((location.y - found.top - Self.trackHeight - 2) / Self.barHeight)
            guard let entry = profile.customEntry(track: index, at: time, row: row, tolerance: 3 / width * window.span) else {
                return nil
            }
            return DeveloperPerformanceExtensions.Selection(track: index, index: entry)
        case .timings:
            // The chips' row, where the markers are named.
            guard location.y < found.top + Self.trackHeight + 16,
                  let marker = profile.customMarker(at: time, tolerance: 30 / width * window.span) else { return nil }
            return DeveloperPerformanceExtensions.Selection(track: nil, index: marker)
        default:
            return nil
        }
    }

    /// An extension entry's or marker's name, length and tooltipText
    /// under the pointer, as Chrome shows them on hover.
    @ViewBuilder private func customTooltip(width: CGFloat) -> some View {
        if let pointer, flameDrag == nil, let hit = customHit(pointer), let item = profile.customSummary(hit) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let duration = item.duration {
                        Text(DeveloperPerformanceRuler.label(duration)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Text(item.title).fontWeight(.medium)
                }
                if let tooltip = item.tooltip { Text(tooltip).foregroundStyle(.secondary).lineLimit(4) }
            }
            .flameTooltip(at: pointer, in: width)
        }
    }

    private func hit(_ location: CGPoint) -> DeveloperPerformanceEvent? {
        guard location.y > lanesTop else { return nil }
        let row = Int((location.y - lanesTop + offset) / Self.rowHeight)
        let width = chartWidth
        let time = window.time(atX: Double(location.x), width: width)
        return profile.event(at: time, row: row, tolerance: 2 / width * window.span)
    }

    private func clampedOffset(_ value: CGFloat) -> CGFloat {
        let content = CGFloat(profile.shownRows) * Self.rowHeight + lanesTop
        return min(max(0, content - flameSize.height + Self.rowHeight), max(0, value))
    }

    /// The time under the pointer, or the window's middle.
    private var anchor: Double {
        guard let pointer else { return (window.lower + window.upper) / 2 }
        return window.time(atX: Double(pointer.x), width: chartWidth)
    }

    private var chartWidth: Double { Double(max(flameSize.width, 1)) }

    /// As in Chrome DevTools: W zooms in, S out, A pans earlier, D later.
    private func navigate(_ key: String) {
        switch key {
        case "w": window = window.zoomed(by: 1.25, around: anchor, in: profile.bounds)
        case "s": window = window.zoomed(by: 0.8, around: anchor, in: profile.bounds)
        case "a": window = window.panned(by: -window.span * 0.1, in: profile.bounds)
        case "d": window = window.panned(by: window.span * 0.1, in: profile.bounds)
        default: break
        }
    }

    /// Pinch zooms around the pointer; a scroll zooms, pans or moves the
    /// rows as Settings' flame chart navigation (Modern or Classic) says.
    private func scrolled(_ event: NSEvent) -> Bool {
        guard pointer != nil, !profile.isEmpty, !session.recordingTimeline else { return false }
        if event.type == .magnify {
            window = window.zoomed(by: 1 + Double(event.magnification), around: anchor, in: profile.bounds)
            return true
        }
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let move = DeveloperFlameChartNavigation.current.move(
            dx: event.scrollingDeltaX * scale, dy: event.scrollingDeltaY * scale,
            zoomKey: flags.contains(.command) || flags.contains(.control), shift: flags.contains(.shift))
        if move.zoom != 0 {
            window = window.zoomed(by: pow(1.01, Double(move.zoom)), around: anchor, in: profile.bounds)
        }
        if move.pan != 0 {
            window = window.panned(by: -Double(move.pan) / chartWidth * window.span, in: profile.bounds)
        }
        if move.scroll != 0 { offset = clampedOffset(offset - move.scroll) }
        return true
    }

    /// ⌘E and ⇧⌘E while DevTools, not the page, has the keyboard.
    private func pressed(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags == .command || flags == [.command, .shift],
              event.charactersIgnoringModifiers?.lowercased() == "e",
              DeveloperTools.shared.session === session else { return false }
        if let web = session.web, let responder = event.window?.firstResponder as? NSView,
           responder === web || responder.isDescendant(of: web) {
            return false
        }
        if flags.contains(.shift) {
            guard !session.recordingTimeline else { return true }
            reloadAndRecord()
        } else {
            record()
        }
        return true
    }

    // MARK: Insights

    /// Shows `range` in the flame chart, with a little either side.
    private func show(_ range: ClosedRange<Double>) {
        let span = range.upperBound - range.lowerBound
        let pad = max(span * 0.15, 2, DeveloperFlameWindow.least)
        let bounds = profile.bounds
        let lower = max(bounds.lowerBound, range.lowerBound - pad)
        let upper = min(bounds.upperBound, max(lower + DeveloperFlameWindow.least, range.upperBound + pad))
        window = DeveloperFlameWindow(lower: lower, upper: upper).clamped(to: bounds)
    }

    /// A card's header: opens it (closing another) and shows what it's about.
    private func chooseInsight(_ insight: DeveloperPerformanceInsight) {
        if openInsight == insight.id {
            openInsight = nil
            return
        }
        openInsight = insight.id
        if let span = insight.span(in: profile) { show(span) }
    }

    /// A row of a card: its record selected in Summary, or its time shown.
    private func chooseRow(_ insight: DeveloperPerformanceInsight, _ row: DeveloperPerformanceInsight.Row) {
        openInsight = insight.id
        if let event = row.event, profile.events.indices.contains(event) {
            select(event)
            show(profile.events[event].start...profile.events[event].end)
        } else if let range = row.range {
            if case .layoutShifts = insight.kind, profile.layoutShifts.indices.contains(row.id) {
                select(nil, shift: row.id)
            }
            show(range)
        }
    }

    // MARK: Recording

    /// A Main track entry, or a layout shift, chosen in place of what was.
    private func select(_ id: Int?, shift: Int? = nil) {
        selected = id
        selectedShift = shift
        selectedCustom = nil
    }

    /// Nothing chosen, hovered, open or being linked, for a recording new or cleared.
    private func resetSelection() {
        select(nil)
        openInsight = nil
        hoveredInsight = nil
        hovered = nil
        linkingFrom = nil
    }

    private func record() {
        stopAfterLoad = false
        session.toggleTimeline()
    }

    private func beginAnnotation(_ range: ClosedRange<Double>) {
        annotationRange = range
        annotationLabel = ""
        addingAnnotation = true
    }

    private func reloadAndRecord() {
        guard !session.recordingTimeline else { return }
        stopAfterLoad = true
        sawLoading = false
        session.toggleTimeline(reloading: true)
    }

    private func clear() {
        cleared = timelineKey
        session.clearTimelineAnnotations()
        profile = DeveloperPerformanceProfile()
        breadcrumbs = DeveloperPerformanceBreadcrumbs()
        thirdParty = []
        scriptInsights?.cancel()
        insights = []
        resetSelection()
        links = []
        // As Chrome's Clear empties the recording history too.
        history.history.clear()
        refind(jump: false)
    }

    // MARK: Find

    /// ⌘F: the find bar over the flame chart, its field focused.
    private func openFind() {
        guard !profile.isEmpty, !session.recordingTimeline else { return }
        findShown = true
        findFocus += 1
        refind(jump: false)
    }

    private func closeFind() {
        findShown = false
        findIndex = nil
        findMatchSet = []
        flameFocused = true
    }

    /// The matches for the field's text; `jump`, as typing does, selects
    /// the first and brings it into view.
    private func refind(jump: Bool) {
        guard findShown else {
            findMatches = []
            findMatchSet = []
            findIndex = nil
            return
        }
        let current = findIndex.flatMap { findMatches.indices.contains($0) ? findMatches[$0] : nil }
        findMatches = DeveloperPerformanceFind.matches(findQuery, in: profile.shown)
        findMatchSet = Set(findMatches)
        if jump {
            findIndex = findMatches.isEmpty ? nil : 0
            if let first = findMatches.first { reveal(first) }
        } else {
            // Kept on the entry it was on, if that still matches.
            findIndex = current.flatMap { findMatches.firstIndex(of: $0) }
        }
    }

    /// Return and ⇧Return in the field, and the bar's arrows.
    private func stepFind(backwards: Bool) {
        guard let next = DeveloperPerformanceFind.step(findIndex, count: findMatches.count, backwards: backwards) else {
            return
        }
        findIndex = next
        reveal(findMatches[next])
    }

    /// An entry selected and brought into view: panned to if it's off to
    /// a side (zoomed out to if it's wider than the view), its row
    /// scrolled to if it's above or below.
    private func reveal(_ id: Int) {
        guard profile.shown.indices.contains(id) else { return }
        let event = profile.shown[id]
        select(id)
        if event.duration > window.span * 0.9 {
            show(event.start...event.end)
        } else if event.start < window.lower || event.end > window.upper {
            let middle = (event.start + event.end) / 2
            window = window.panned(by: middle - (window.lower + window.upper) / 2, in: profile.bounds)
        }
        let rowTop = CGFloat(event.row) * Self.rowHeight
        let visible = max(Self.rowHeight, flameSize.height - lanesTop)
        if rowTop < offset || rowTop + Self.rowHeight > offset + visible {
            offset = clampedOffset(rowTop - visible / 2)
        }
    }

    // MARK: Annotations and AI

    /// Performance › Ask AI about an entry: it and its call tree.
    private func askAI(about id: Int) {
        guard profile.events.indices.contains(id) else { return }
        session.aiAssistance.askAboutTraceEvent(profile.events[id], in: profile, key: timelineKey)
    }

    /// An entries link from one Main track entry to another.
    private func link(_ from: Int, to: Int) {
        guard profile.shown.indices.contains(from), profile.shown.indices.contains(to) else { return }
        let a = profile.shown[from], b = profile.shown[to]
        session.linkTimelineEntries(.init(name: a.title, range: a.start...max(a.start, a.end)),
                                    to: .init(name: b.title, range: b.start...max(b.start, b.end)))
    }

    /// The annotations changed: the links found again among the entries,
    /// and the recording's history entry told, for when it's shown again.
    private func annotationsChanged(_ annotations: [DeveloperPerformanceAnnotation]) {
        relink(annotations)
        history.history.update(timelineKey, annotations: annotations)
    }

    private func relink(_ annotations: [DeveloperPerformanceAnnotation]) {
        links = annotations.compactMap { annotation -> (from: Int, to: Int)? in
            guard let link = annotation.link,
                  let from = DeveloperPerformanceAnnotation.find(link.from, in: profile.shown),
                  let to = DeveloperPerformanceAnnotation.find(link.to, in: profile.shown) else { return nil }
            return (from: from.id, to: to.id)
        }
    }

    // MARK: History

    /// A recording from the history menu, shown in place of this one,
    /// with its own annotations.
    private func showRecording(_ entry: DeveloperPerformanceRecordings.Entry) {
        guard !session.recordingTimeline, entry.id != timelineKey else { return }
        history.history.update(timelineKey, annotations: session.timelineAnnotations)
        cleared = nil
        session.loadTimeline(entry.timings, annotations: entry.annotations)
    }

    // MARK: Files

    /// ⌘S: the recording shown, to a trace file.
    private func saveProfile() {
        guard !session.recordingTimeline, !profile.isEmpty else { return }
        DeveloperPerformanceFiles.save(session)
    }

    /// ⌘O: a trace file, shown in place of the recording.
    private func loadProfile() {
        guard !session.recordingTimeline else { return }
        DeveloperPerformanceFiles.load(into: session)
    }

    /// ⌘S and ⌘O from DevTools' keys, which hear them before the browser's
    /// Save Page and Open File (DeveloperToolsKeys).
    private func lendKeys() {
        DeveloperPanelKeys.performance = DeveloperPanelKeys.Performance(
            save: { saveProfile() },
            load: { loadProfile() },
            find: { openFind() })
    }

    private func rebuild() {
        guard timelineKey != cleared else { return }
        let fresh = DeveloperPerformanceProfile(session.timeline)
        profile = fresh
        insights = DeveloperPerformanceInsights.all(fresh, page: session.address)
        loadScriptInsights(fresh)
        thirdParty = DeveloperPerformanceThirdParties.dimmed(fresh, page: session.address)
        window = DeveloperFlameWindow(fresh.bounds)
        breadcrumbs.reset(fresh.bounds)
        resetSelection()
        offset = 0
        relink(session.timelineAnnotations)
        findIndex = nil
        refind(jump: false)
        // Each recording shown joins the session's history, newest first.
        if !session.timeline.isEmpty {
            history.history.add(session.timeline, annotations: session.timelineAnnotations,
                                url: session.address?.absoluteString)
        }
    }

    /// Duplicated and Legacy JavaScript read the page's scripts and their
    /// source maps, which take a moment: their cards join the others once
    /// read, if the recording is still the one shown. A file saved with
    /// its scripts brings its own.
    private func loadScriptInsights(_ fresh: DeveloperPerformanceProfile) {
        scriptInsights?.cancel()
        let key = timelineKey
        let loaded = session.timelineScripts
        scriptInsights = Task {
            var read = loaded
            if read == nil { read = await DeveloperPerformanceInsights.scripts(session, profile: fresh) }
            guard let scripts = read, !Task.isCancelled else { return }
            let found = await Task.detached(priority: .userInitiated) {
                DeveloperPerformanceInsights.javaScriptInsights(fresh, scripts: scripts)
            }.value
            guard !Task.isCancelled, key == timelineKey, cleared != key, !session.recordingTimeline else { return }
            let others = insights.filter { !DeveloperPerformanceInsights.javaScriptKinds.contains($0.kind) }
            insights = DeveloperPerformanceInsights.ranked(others + found)
        }
    }
}

private extension View {
    /// A flame chart tooltip by the pointer, kept inside the chart, `chart`
    /// wide: `width` wide when `fixed`, at most that otherwise.
    func flameTooltip(at pointer: CGPoint, in chart: CGFloat, width: CGFloat = 280, fixed: Bool = false) -> some View {
        font(.system(size: 11))
            .padding(6)
            .frame(width: fixed ? width : nil, alignment: .leading)
            .frame(maxWidth: fixed ? nil : width, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(DeveloperToolsStyle.rule))
            .offset(x: min(pointer.x + 12, max(0, chart - width - 10)), y: pointer.y + 14)
            .allowsHitTesting(false)
    }
}

/// The save and open panels for Performance profiles, for the panel's
/// buttons and keys and for the command menu.
@MainActor
enum DeveloperPerformanceFiles {
    static let includeScriptsKey = "DeveloperPerformanceIncludeScripts"

    /// With Chrome's "Include script content and source maps" under the
    /// file name: the page's scripts and their maps go in the file, so its
    /// JavaScript insights work wherever it's opened.
    static func save(_ session: DeveloperToolsSession) {
        let timings = session.timeline
        guard !timings.isEmpty, !session.recordingTimeline else { return }
        let annotations = session.timelineAnnotations
        let address = session.address?.absoluteString
        let loaded = session.timelineScripts
        let include = NSButton(checkboxWithTitle: "Include script content and source maps", target: nil, action: nil)
        include.state = UserDefaults.standard.bool(forKey: includeScriptsKey) ? .on : .off
        include.sizeToFit()
        // Room around it: a bare checkbox is cut short by the panel.
        let accessory = NSView(frame: include.frame.insetBy(dx: -20, dy: -10).offsetBy(dx: 20, dy: 10))
        include.setFrameOrigin(NSPoint(x: 20, y: 10))
        accessory.addSubview(include)
        DeveloperFilePanel.save(name: DeveloperPerformanceTrace.fileName(), types: [.json], accessory: accessory) { url in
            let including = include.state == .on
            UserDefaults.standard.set(including, forKey: includeScriptsKey)
            Task { @MainActor in
                var scripts = including ? loaded : nil
                if including, scripts == nil {
                    scripts = await DeveloperPerformanceInsights.scripts(session, profile: DeveloperPerformanceProfile(timings))
                }
                attempt {
                    try DeveloperPerformanceTrace.export(timings, url: address, annotations: annotations, scripts: scripts)
                        .write(to: url, options: .atomic)
                }
            }
        }
    }

    static func load(into session: DeveloperToolsSession) {
        guard !session.recordingTimeline else { return }
        DeveloperFilePanel.open(types: [.json]) { url in
            attempt {
                let recording = try DeveloperPerformanceTrace.recording(from: Data(contentsOf: url))
                session.loadTimeline(recording.timings, annotations: recording.annotations, scripts: recording.scripts)
            }
        }
    }

    /// Runs `work`, saying in an alert what went wrong if it throws.
    private static func attempt(_ work: () throws -> Void) {
        do { try work() } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't open or save the profile"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

/// The overview strip's chart: how busy each category kept the page
/// across the recording, stacked as Chrome's CPU chart is, under the
/// recording's time ruler. Redrawn only when the recording changes.
private struct DeveloperPerformanceOverviewChart: View, Equatable {
    let profile: DeveloperPerformanceProfile

    var body: some View {
        Canvas { context, size in
            DeveloperPerformanceRuler.draw(in: &context, window: DeveloperFlameWindow(profile.bounds), size: size, labelY: 7,
                                           spacing: 100)
            let top: CGFloat = 16
            let height = size.height - top - 2
            let buckets = profile.activity(buckets: max(1, Int(size.width / 2)))
            let step = size.width / CGFloat(max(buckets.count, 1))
            for (index, bucket) in buckets.enumerated() {
                var y = size.height - 1
                for category in DeveloperPerformanceCategory.allCases {
                    guard let share = bucket[category], share > 0 else { continue }
                    let bar = CGFloat(share) * height
                    context.fill(Path(CGRect(x: CGFloat(index) * step, y: y - bar, width: step, height: bar)),
                                 with: .color(category.color))
                    y -= bar
                }
            }
        }
    }
}

/// Summary, Bottom-up, Call tree and Event log for the range the flame
/// chart shows, worked out a moment after the range stops changing.
private struct DeveloperPerformanceDetails: View, Equatable {
    /// For the source links, which read through its source maps and open
    /// Sources; not part of the view's equality.
    let session: DeveloperToolsSession
    let profile: DeveloperPerformanceProfile
    let range: ClosedRange<Double>
    let selected: DeveloperPerformanceEvent?
    /// A layout shift chosen in its track, in profile.layoutShifts.
    let shift: Int?
    /// A custom track's entry or an extension marker chosen.
    let custom: DeveloperPerformanceExtensions.Summary?
    let choose: (Int) -> Void
    /// One of a shift's affected nodes, by its page index and place, to Elements.
    let reveal: (Int, Int) -> Void

    @State private var tab = Tab.summary
    @State private var filter = ""
    @State private var minimum = 0.0
    @State private var summary: (categories: [DeveloperPerformanceCategory: Double], idle: Double) = ([:], 0)
    @State private var nodes: [DeveloperPerformanceNode] = []
    /// Bottom-up's rows before the filter, for the heaviest stack.
    @State private var unfiltered: [DeveloperPerformanceNode] = []
    @State private var log: [DeveloperPerformanceEvent] = []
    @State private var grouping = DeveloperPerformanceGrouping.none
    @State private var groupings: [DeveloperPerformanceGrouping] = [.none]
    @State private var matchCase = false
    @State private var regex = false
    @State private var showHeaviestStack = false
    @State private var selectedNode: String?
    /// The Summary stack's ignore-listed frames shown too.
    @State private var showIgnoredFrames = false

    enum Tab: String, CaseIterable, Identifiable {
        case summary = "Summary", bottomUp = "Bottom-up", callTree = "Call tree", eventLog = "Event log"
        var id: String { rawValue }
    }

    private struct SummaryRow: Identifiable {
        let name: String
        let color: Color
        let value: Double
        var id: String { name }
    }

    private struct Work: Equatable {
        let profile: DeveloperPerformanceProfile
        let range: ClosedRange<Double>
        let tab: Tab
        let filter: String
        let minimum: Double
        let grouping: DeveloperPerformanceGrouping
        let matchCase: Bool
        let regex: Bool
    }

    private var textFilter: DeveloperPerformanceTextFilter {
        DeveloperPerformanceTextFilter(text: filter, matchCase: matchCase, regex: regex)
    }

    static func == (a: Self, b: Self) -> Bool {
        a.profile == b.profile && a.range == b.range && a.selected == b.selected && a.shift == b.shift && a.custom == b.custom
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                DeveloperTabBar(Tab.allCases, selection: $tab, title: \.rawValue, scrolls: false)
                Spacer(minLength: 8)
                if tab == .bottomUp || tab == .callTree {
                    Picker("Grouping", selection: $grouping) {
                        ForEach(groupings) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().controlSize(.small).fixedSize()
                    .padding(.trailing, DeveloperToolsStyle.controlSpacing)
                    .accessibilityIdentifier("developer-performance-grouping")
                }
                if tab != .summary {
                    TextField("Filter", text: $filter).developerToolsField().frame(minWidth: 40, maxWidth: 180)
                        .foregroundStyle(textFilter.isValid || tab == .eventLog ? Palette.ink : Color.red)
                }
                if tab == .bottomUp || tab == .callTree {
                    option("Aa", "Match case", isOn: $matchCase)
                        .padding(.leading, DeveloperToolsStyle.controlSpacing)
                    option(".*", "Use regular expression", isOn: $regex)
                }
                if tab == .bottomUp {
                    DeveloperPanelIcon(symbol: "sidebar.right",
                                       title: showHeaviestStack ? "Hide heaviest stack" : "Show heaviest stack",
                                       active: showHeaviestStack) { showHeaviestStack.toggle() }
                        .padding(.leading, DeveloperToolsStyle.controlSpacing)
                        .accessibilityIdentifier("developer-performance-heaviest-stack")
                }
                if tab == .eventLog {
                    Picker("Duration", selection: $minimum) {
                        Text("All").tag(0.0)
                        Text("1 ms").tag(1.0)
                        Text("15 ms").tag(15.0)
                    }
                    .labelsHidden().controlSize(.small).frame(width: 80)
                    .padding(.leading, DeveloperToolsStyle.controlSpacing)
                }
            }
            .padding(.trailing, DeveloperToolsStyle.gutter)
            .background(DeveloperToolsStyle.chrome)
            Divider()
            switch tab {
            case .summary: summaryView
            case .bottomUp, .callTree: treeView
            case .eventLog: logView
            }
        }
        .font(.system(size: 11))
        .task(id: Work(profile: profile, range: range, tab: tab, filter: filter, minimum: minimum, grouping: grouping,
                       matchCase: matchCase, regex: regex)) {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            if tab == .bottomUp || tab == .callTree {
                groupings = profile.groupings
                // A loaded recording may not support the grouping chosen.
                if !groupings.contains(grouping) {
                    grouping = .none
                    return
                }
            }
            switch tab {
            case .summary: summary = profile.summary(in: range)
            case .bottomUp:
                unfiltered = profile.bottomUp(in: range, groupedBy: grouping)
                nodes = textFilter.apply(to: unfiltered)
            case .callTree:
                unfiltered = profile.callTree(in: range, groupedBy: grouping)
                nodes = textFilter.apply(to: unfiltered)
            case .eventLog: log = profile.log(in: range, filter: filter, minimum: minimum)
            }
        }
    }

    /// Chrome's Aa and .* buttons by the filter.
    private func option(_ label: String, _ title: String, isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            Text(label).font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(isOn.wrappedValue ? Palette.ink : .secondary)
                .frame(width: 22, height: 20)
                .background(isOn.wrappedValue ? DeveloperToolsStyle.selected : .clear,
                            in: RoundedRectangle(cornerRadius: DeveloperToolsStyle.controlRadius))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityValue(isOn.wrappedValue ? "On" : "Off")
    }

    private func time(_ value: Double) -> String { DeveloperPerformanceRuler.label(value) }

    // MARK: Summary

    @ViewBuilder private var summaryView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let custom {
                    customSummary(custom)
                } else if let shift, profile.layoutShifts.indices.contains(shift) {
                    shiftSummary(shift)
                } else if let selected {
                    eventSummary(selected)
                } else {
                    rangeSummary
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func eventSummary(_ event: DeveloperPerformanceEvent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            heading(event.category.color, event.title)
            if event.parent == nil, event.duration > DeveloperPerformanceProfile.longTask {
                Label("Long task took \(time(event.duration)).", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(DeveloperPerformanceView.longTaskColor)
            }
            if let interaction = profile.interactions.first(where: { $0.event == event.id }) {
                interactionSummary(interaction)
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                field("Category", event.category.rawValue)
                field("Start", time(event.start))
                field("Duration", time(event.duration))
                field("Self time", time(event.selfTime))
                if let source = event.source {
                    // Chrome's Function row: the script place, through source maps, opening Sources.
                    GridRow {
                        Text("Details").foregroundStyle(.secondary)
                        DeveloperSourceLocationLink(session: session, url: source.url, line: source.line, column: source.column)
                            .accessibilityIdentifier("developer-performance-summary-source")
                    }
                } else if let detail = event.detail {
                    field("Details", detail)
                }
                ForEach(event.data.keys.sorted(), id: \.self) { key in field(key, event.data[key] ?? "") }
            }
            if !event.frames.isEmpty {
                stackTrace(event.frames)
            } else if !event.stack.isEmpty {
                Text("Stack trace").foregroundStyle(.secondary).padding(.top, 4)
                ForEach(Array(event.stack.enumerated()), id: \.offset) { _, frame in
                    Text(frame).font(DeveloperToolsStyle.code).textSelection(.enabled)
                }
            }
        }
    }

    /// The record's stack as Chrome prints it in the Summary: each frame
    /// linking to its place (in the authored file when a source map has
    /// it), the ignore-listed ones behind "Show N more frames".
    @ViewBuilder
    private func stackTrace(_ frames: [ConsoleCallFrame]) -> some View {
        let debugger = session.debugger
        let ignored: (ConsoleCallFrame) -> Bool = { frame in
            guard frame.hasSource else { return false }
            if debugger.isIgnored(frame.url) { return true }
            let link = session.sourceMaps.linked(url: frame.url, line: frame.lineNumber, column: frame.columnNumber)
            return link.url != frame.url && debugger.isIgnored(link.url)
        }
        let filtered = DeveloperIgnoredFrames.filter(frames, isBoundary: { $0.asyncBoundary }, isIgnored: ignored)
        let shown = showIgnoredFrames ? frames : filtered.frames
        Text("Stack trace").foregroundStyle(.secondary).padding(.top, 4)
        ForEach(Array(shown.enumerated()), id: \.offset) { _, frame in
            HStack(spacing: 0) {
                Text(frame.name).font(DeveloperToolsStyle.code).lineLimit(1).textSelection(.enabled)
                if frame.hasSource {
                    Text(" @ ").font(DeveloperToolsStyle.code).foregroundStyle(.secondary)
                    DeveloperSourceLocationLink(session: session, url: frame.url,
                                                line: frame.lineNumber > 0 ? frame.lineNumber : nil,
                                                column: frame.columnNumber > 0 ? frame.columnNumber : nil)
                }
                Spacer(minLength: 0)
            }
            .opacity(showIgnoredFrames && ignored(frame) ? 0.55 : 1)
        }
        if filtered.hidden > 0 {
            Button(DeveloperIgnoredFrames.toggleTitle(hidden: filtered.hidden, showing: showIgnoredFrames)) {
                showIgnoredFrames.toggle()
            }
            .buttonStyle(.plain)
            .underline()
            .foregroundStyle(DeveloperToolsStyle.tint)
            .accessibilityIdentifier("developer-performance-ignored-frames")
        }
    }

    /// Chrome's Summary for an interaction: its whole time, and the three
    /// phases its whiskers draw.
    private func interactionSummary(_ interaction: DeveloperPerformanceProfile.Interaction) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if interaction.duration > DeveloperPerformanceProfile.longInteraction {
                Label("Long interaction took \(time(interaction.duration)).", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(DeveloperPerformanceView.longTaskColor)
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                field("Interaction", interaction.type)
                field("Total duration", time(interaction.duration))
                field("Input delay", time(interaction.inputDelay))
                field("Processing duration", time(interaction.processingDuration))
                field("Presentation delay", time(interaction.presentationDelay))
            }
        }
        .accessibilityIdentifier("developer-performance-interaction-phases")
    }

    /// Chrome's Summary for a layout shift: its score, its cluster's, and
    /// the nodes that moved, each a link to Elements.
    private func shiftSummary(_ index: Int) -> some View {
        let shift = profile.layoutShifts[index]
        let cluster = profile.cluster(of: index)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Rectangle().fill(DeveloperPerformanceView.layoutShiftColor).frame(width: 8, height: 8).rotationEffect(.degrees(45))
                Text("Layout shift").font(.system(size: 13, weight: .semibold))
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                field("Start", time(shift.time))
                field("Score", String(format: "%.4f", shift.score))
                if let cluster {
                    field("Cluster score", String(format: "%.4f", cluster.score))
                    field("Cluster duration", time(cluster.end - cluster.start))
                }
            }
            if !shift.nodes.isEmpty {
                Text("Affected nodes").foregroundStyle(.secondary).padding(.top, 4)
                ForEach(Array(shift.nodes.enumerated()), id: \.offset) { offset, node in
                    if let page = shift.index {
                        Button(node) { reveal(page, offset) }
                            .buttonStyle(.link)
                            .help("Reveal in Elements panel")
                            .accessibilityIdentifier("developer-performance-shift-node")
                    } else {
                        Text(node).font(DeveloperToolsStyle.code).textSelection(.enabled)
                    }
                }
            }
        }
    }

    /// Summary for an entry of a custom track or an extension marker: its
    /// tooltipText, where it is, and its properties, as Chrome lists them.
    private func customSummary(_ item: DeveloperPerformanceExtensions.Summary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            heading(DeveloperPerformanceView.extensionColor(item.color), item.title)
            if let tooltip = item.tooltip { Text(tooltip).textSelection(.enabled) }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                field("Type", item.kind)
                if let track = item.track { field("Track", track) }
                if let group = item.group { field("Track group", group) }
                field("Start", time(item.start))
                if let duration = item.duration { field("Duration", time(duration)) }
                field("Source", item.source)
            }
            if !item.properties.isEmpty {
                Text("Properties").foregroundStyle(.secondary).padding(.top, 4)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    ForEach(Array(item.properties.enumerated()), id: \.offset) { _, property in
                        field(property.key, property.value)
                    }
                }
            }
        }
        .accessibilityIdentifier("developer-performance-extension-summary")
    }

    /// A Summary's title, by its colour's swatch.
    private func heading(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(title).font(.system(size: 13, weight: .semibold)).textSelection(.enabled)
        }
    }

    private func field(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).lineLimit(3)
        }
    }

    private var rangeSummary: some View {
        let total = range.upperBound - range.lowerBound
        let rows = DeveloperPerformanceCategory.allCases.compactMap { category in
            summary.categories[category].map { SummaryRow(name: category.rawValue, color: category.color, value: $0) }
        } + [SummaryRow(name: "Idle", color: Color.secondary.opacity(0.25), value: summary.idle)]
        return VStack(alignment: .leading, spacing: 6) {
            Text("Range: \(time(range.lowerBound)) – \(time(range.upperBound))").foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                ForEach(rows) { row in
                    GridRow {
                        Text(time(row.value)).monospacedDigit().fixedSize().gridColumnAlignment(.trailing)
                        RoundedRectangle(cornerRadius: 2).fill(row.color).frame(width: 10, height: 10)
                        // Names stay whole; the bar gives way in a narrow pane.
                        Text(row.name).fixedSize()
                        GeometryReader { space in
                            RoundedRectangle(cornerRadius: 2).fill(row.color)
                                .frame(width: max(1, space.size.width * CGFloat(total > 0 ? row.value / total : 0)))
                        }
                        .frame(minWidth: 24, maxWidth: 160, minHeight: 8, maxHeight: 8)
                    }
                }
                GridRow {
                    Text(time(total)).monospacedDigit().fontWeight(.semibold).fixedSize()
                    Color.clear.frame(width: 10, height: 10)
                    Text("Total").fontWeight(.semibold).fixedSize()
                    Color.clear.frame(minWidth: 24, maxWidth: 160, minHeight: 8, maxHeight: 8)
                }
            }
        }
    }

    // MARK: Bottom-up and Call tree

    private var treeView: some View {
        let total = max(range.upperBound - range.lowerBound, .leastNonzeroMagnitude)
        return VStack(spacing: 0) {
            columns(["Self time", "Total time"], width: 110)
            if nodes.isEmpty {
                Text("No activity in this range").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tab == .bottomUp && showHeaviestStack {
                HSplitView {
                    treeList(total: total).frame(minWidth: 240)
                    heaviestStack.frame(minWidth: 160, idealWidth: 260)
                }
            } else {
                treeList(total: total)
            }
        }
    }

    /// A table's header: its time columns, `width` wide, then Activity.
    @ViewBuilder private func columns(_ times: [String], width: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(times, id: \.self) { Text($0).frame(width: width, alignment: .trailing) }
            Text("Activity").padding(.leading, 12)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .frame(height: DeveloperToolsStyle.rowHeight)
        .padding(.horizontal, DeveloperToolsStyle.gutter)
        Divider()
    }

    private func treeList(total: Double) -> some View {
        List(selection: $selectedNode) {
            OutlineGroup(nodes, children: \.outline) { node in
                HStack(spacing: 0) {
                    share(node.selfTime, of: total).frame(width: 110, alignment: .trailing)
                    share(node.totalTime, of: total).frame(width: 110, alignment: .trailing)
                    Group {
                        if node.isGroup {
                            Image(systemName: "folder").font(.system(size: 9)).foregroundStyle(.secondary)
                        } else {
                            RoundedRectangle(cornerRadius: 2).fill(node.category.color)
                        }
                    }
                    .frame(width: 9, height: 9).padding(.leading, 12).padding(.trailing, 5)
                    if !node.isGroup, let id = node.event, profile.shown.indices.contains(id),
                       let source = profile.shown[id].source {
                        // As Chrome's rows: the activity, then its script place as a link.
                        Text(profile.shown[id].title).lineLimit(1).textSelection(.enabled)
                        Text(" — ").foregroundStyle(.secondary)
                        DeveloperSourceLocationLink(session: session, url: source.url, line: source.line, column: source.column)
                        Spacer(minLength: 0)
                    } else {
                        Text(node.activity).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                }
                .tag(node.id)
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, DeveloperToolsStyle.rowHeight)
    }

    /// Chrome's Heaviest stack beside Bottom-up: the call path that spent
    /// the most time through the row chosen, root first.
    private var heaviestStack: some View {
        let frames: [DeveloperPerformanceStackFrame]
        if let id = selectedNode, let path = DeveloperPerformanceProfile.path(to: id, in: unfiltered) {
            frames = profile.heaviestStack(through: path, in: range)
        } else {
            frames = []
        }
        return VStack(alignment: .leading, spacing: 0) {
            Text("Heaviest stack").fontWeight(.semibold).foregroundStyle(.secondary)
                .padding(.horizontal, DeveloperToolsStyle.gutter)
                .frame(height: DeveloperToolsStyle.rowHeight)
            Divider()
            if frames.isEmpty {
                Text("Select item for heaviest stack").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(frames) { frame in
                            HStack(spacing: 6) {
                                Text(time(frame.totalTime)).monospacedDigit().foregroundStyle(.secondary)
                                    .frame(width: 64, alignment: .trailing)
                                RoundedRectangle(cornerRadius: 2).fill(frame.category.color).frame(width: 9, height: 9)
                                Text(frame.activity).lineLimit(1).truncationMode(.middle)
                                    .fontWeight(frame.isSelected ? .semibold : .regular)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, DeveloperToolsStyle.gutter)
                            .frame(height: DeveloperToolsStyle.rowHeight)
                            .background(frame.isSelected ? DeveloperToolsStyle.selected : .clear)
                            .help(frame.activity)
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("developer-performance-heaviest-stack-pane")
    }

    private func share(_ value: Double, of total: Double) -> some View {
        HStack(spacing: 6) {
            Text(time(value)).monospacedDigit()
            Text(String(format: "%.1f %%", value / total * 100)).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }

    // MARK: Event log

    private var logView: some View {
        VStack(spacing: 0) {
            columns(["Start time", "Self time", "Total time"], width: 80)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(log) { event in
                        Button { choose(event.id) } label: {
                            HStack(spacing: 0) {
                                Text(time(event.start)).frame(width: 80, alignment: .trailing)
                                Text(time(event.selfTime)).frame(width: 80, alignment: .trailing)
                                Text(time(event.duration)).frame(width: 80, alignment: .trailing)
                                RoundedRectangle(cornerRadius: 2).fill(event.category.color).frame(width: 9, height: 9)
                                    .padding(.leading, 12 + CGFloat(min(event.row, 12)) * 10).padding(.trailing, 5)
                                Text(event.activity).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 0)
                            }
                            .monospacedDigit()
                            .padding(.horizontal, DeveloperToolsStyle.gutter)
                            .frame(height: DeveloperToolsStyle.rowHeight)
                            .background(selected?.id == event.id ? DeveloperToolsStyle.selected : .clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

extension DeveloperPerformanceRuler {
    /// The ruler's gridlines down `size`, each labelled at `labelY`.
    static func draw(in context: inout GraphicsContext, window: DeveloperFlameWindow, size: CGSize, labelY: CGFloat,
                     spacing: Double = 80) {
        let width = Double(size.width)
        for tick in ticks(in: window, width: width, spacing: spacing) {
            let x = CGFloat(window.x(tick, width: width))
            context.fill(Path(CGRect(x: x, y: 0, width: 0.5, height: size.height)), with: .color(DeveloperToolsStyle.rule))
            context.draw(Text(label(tick)).font(.system(size: 9)).foregroundColor(.secondary),
                         at: CGPoint(x: x + 3, y: labelY), anchor: .leading)
        }
    }
}

/// Scroll, pinch and key events for the Performance panel. SwiftUI on
/// macOS 14 has no scroll-wheel or magnify gestures, and ⌘E is the
/// system's Use Selection for Find, so they are taken from the window's
/// event stream while the panel is shown.
@MainActor
final class DeveloperPerformanceInput {
    /// Returns true when it handled the event.
    var scroll: (@MainActor (NSEvent) -> Bool)?
    var key: (@MainActor (NSEvent) -> Bool)?
    private var monitors: [Any] = []

    func start() {
        guard monitors.isEmpty else { return }
        let wheel = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
            MainActor.assumeIsolated { self?.scroll?(event) ?? false } ? nil : event
        }
        let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.key?(event) ?? false } ? nil : event
        }
        monitors = [wheel, keys].compactMap { $0 }
    }

    func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
    }
}
