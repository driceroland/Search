import AppKit
import ObjectiveC
import SwiftUI
import WebKit

/// Applies a device's user agent and pixel ratio to the inspected tab while
/// device mode is on, and gives the tab back exactly what it had afterwards.
@MainActor
final class DeveloperDeviceEmulation {
    private weak var web: WKWebView?
    private var originalAgent: String?
    private var originalScale: CGFloat = 0
    private var active = false

    private static let scaleSetter = NSSelectorFromString("_setOverrideDeviceScaleFactor:")
    private static let scaleGetter = NSSelectorFromString("_overrideDeviceScaleFactor")

    /// WebKit has no protocol command for the device pixel ratio. Search uses
    /// the web view's own override when this WebKit build still has it.
    static var canEmulateScaleFactor: Bool {
        WKWebView.instancesRespond(to: scaleSetter) && WKWebView.instancesRespond(to: scaleGetter)
    }

    func update(web: WKWebView?, agent: String?, scale: Double?) {
        if web !== self.web { restore() }
        guard let web, agent != nil || scale != nil else { restore(); return }
        if !active {
            self.web = web
            originalAgent = web.customUserAgent
            originalScale = Self.scale(of: web)
            active = true
        }
        let wantedAgent = agent ?? originalAgent
        if web.customUserAgent != wantedAgent { web.customUserAgent = wantedAgent }
        let wantedScale = scale.map { CGFloat($0) } ?? originalScale
        if Self.canEmulateScaleFactor, Self.scale(of: web) != wantedScale { Self.setScale(wantedScale, on: web) }
    }

    func restore() {
        defer {
            active = false
            web = nil
        }
        guard active, let web else { return }
        if web.customUserAgent != originalAgent { web.customUserAgent = originalAgent }
        if Self.canEmulateScaleFactor, Self.scale(of: web) != originalScale { Self.setScale(originalScale, on: web) }
    }

    private static func scale(of web: WKWebView) -> CGFloat {
        guard canEmulateScaleFactor, let method = class_getInstanceMethod(WKWebView.self, scaleGetter) else { return 0 }
        typealias Getter = @convention(c) (AnyObject, Selector) -> CGFloat
        return unsafeBitCast(method_getImplementation(method), to: Getter.self)(web, scaleGetter)
    }

    private static func setScale(_ value: CGFloat, on web: WKWebView) {
        guard let method = class_getInstanceMethod(WKWebView.self, scaleSetter) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, CGFloat) -> Void
        unsafeBitCast(method_getImplementation(method), to: Setter.self)(web, scaleSetter, value)
    }
}

private struct DeveloperViewportFocusKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var devToolsFocusOnly: Bool {
        get { self[DeveloperViewportFocusKey.self] }
        set { self[DeveloperViewportFocusKey.self] = newValue }
    }
}

/// The rulers' width along the emulated viewport's top and left.
private let developerRulerThickness: CGFloat = 14
/// The drag handles' width beside the emulated viewport.
private let developerResizeGrip: CGFloat = 8

/// Keeps the site's real layout size separate from its presentation in the dock.
struct DeveloperViewportCanvas<Content: View>: View {
    let web: WKWebView?
    let room: CGSize
    let responsive: Bool
    let dock: DeveloperDockPosition
    @Binding var settings: DeveloperViewportSettings
    @ViewBuilder let content: () -> Content
    @State private var toolbarHeight: CGFloat = 32
    @State private var mediaBarHeight: CGFloat = 0
    @State private var emulation = DeveloperDeviceEmulation()
    /// What a drag on one of the viewport's edges began with.
    @State private var resizing: Resizing?
    @State private var hoveredGrip: DeveloperViewportResize.Edges?

    private struct Resizing: Equatable {
        let start: DeveloperViewportResize.Size
        let scale: CGFloat
        let centred: Bool
        let edges: DeveloperViewportResize.Edges
    }

    private struct EmulationKey: Equatable {
        let web: ObjectIdentifier?
        let agent: String?
        let scale: Double?
    }

    var body: some View {
        let buffer: CGFloat = 8
        let zoom = web?.pageZoom ?? 1
        let ruler: CGFloat = responsive && settings.showRulers ? developerRulerThickness : 0
        let bar: CGFloat = responsive && settings.showMediaQueries ? mediaBarHeight : 0
        let free = CGSize(width: max(0, room.width - buffer * 2 - ruler),
                          height: max(0, room.height - toolbarHeight - bar - ruler - buffer * 2))
        let fit = settings.presentation(in: free, pageZoom: zoom)
        let layout = responsive ? fit.layout : room
        let display = responsive ? fit.displayed : room
        let overflows = responsive && (display.width > free.width + 0.5 || display.height > free.height + 0.5)
        let fixed = settings.zoom != .fit
        // Points on screen for each CSS pixel of the emulated viewport.
        let points = fit.scale * zoom
        let key = EmulationKey(web: web.map(ObjectIdentifier.init),
                               agent: responsive ? settings.userAgent : nil,
                               scale: responsive ? settings.deviceScaleFactor : nil)
        VStack(spacing: 0) {
            if responsive {
                DeveloperViewportToolbar(settings: $settings, scale: fit.scale)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { toolbarHeight = $0 }
                if settings.showMediaQueries, let web {
                    DeveloperMediaQueryBar(web: web, scale: points, width: settings.width, offset: 0) {
                        settings.resize(width: $0)
                    }
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { mediaBarHeight = $0 }
                }
            }
            let stage = content()
                .environment(\.devToolsFocusOnly, responsive)
                .frame(width: layout.width, height: layout.height)
                .scaleEffect(responsive ? fit.scale : 1)
                .frame(width: display.width, height: display.height)
                .clipped()
                .overlay {
                    if responsive {
                        Rectangle().strokeBorder(DeveloperToolsStyle.rule)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if responsive, resizing != nil {
                        Text("\(settings.width) × \(settings.height)")
                            .font(.system(size: 11).monospacedDigit())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.regularMaterial, in: Capsule())
                            .padding(6)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .overlay {
                    if responsive {
                        // A preview past the room at a fixed zoom starts at the
                        // left, and its right edge then follows the pointer.
                        grips(display: display, points: points, centred: !(fixed && overflows))
                    }
                }
            let framed = withRulers(stage, display: display, points: points, thickness: ruler)
            // A fixed zoom larger than the room scrolls, as Chrome's does.
            if fixed, responsive {
                ScrollView([.horizontal, .vertical]) {
                    framed
                        .padding(buffer)
                        .frame(minWidth: room.width, minHeight: max(0, room.height - toolbarHeight - bar), alignment: .top)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DeveloperToolsStyle.raised)
            } else if responsive {
                // As Chrome's device mode: centred across, at the top.
                framed
                    .padding(.top, buffer)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background(DeveloperToolsStyle.raised)
            } else {
                framed
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: room.width, height: room.height)
        .clipped()
        .overlay {
            if let web {
                DeveloperViewportIndicator(web: web, responsive: responsive, dock: dock)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: key, initial: true) { _, key in
            emulation.update(web: web, agent: key.agent, scale: key.scale)
        }
        .onChange(of: responsive) { _, on in if !on { resizing = nil } }
        .onDisappear { emulation.restore() }
    }

    @ViewBuilder
    private func withRulers<Stage: View>(_ stage: Stage, display: CGSize, points: CGFloat, thickness: CGFloat) -> some View {
        if thickness > 0 {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    DeveloperToolsStyle.chrome.frame(width: thickness, height: thickness)
                    DeveloperViewportRulerView(vertical: false, length: settings.width, scale: points)
                        .frame(width: display.width, height: thickness)
                }
                HStack(spacing: 0) {
                    DeveloperViewportRulerView(vertical: true, length: settings.height, scale: points)
                        .frame(width: thickness, height: display.height)
                    stage
                }
            }
            // Centred on the viewport, not on viewport and ruler together.
            .offset(x: -thickness / 2)
        } else {
            stage
        }
    }

    /// The handles on the right edge, the bottom edge and the corner, as
    /// Chrome's device mode has them, just outside the viewport.
    private func grips(display: CGSize, points: CGFloat, centred: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            grip(.right, points: points, centred: centred)
                .frame(width: developerResizeGrip, height: display.height)
                .offset(x: display.width)
            grip(.bottom, points: points, centred: centred)
                .frame(width: display.width, height: developerResizeGrip)
                .offset(y: display.height)
            grip(.corner, points: points, centred: centred)
                .frame(width: developerResizeGrip, height: developerResizeGrip)
                .offset(x: display.width, y: display.height)
        }
        .frame(width: display.width, height: display.height, alignment: .topLeading)
    }

    private func grip(_ edges: DeveloperViewportResize.Edges, points: CGFloat, centred: Bool) -> some View {
        let lit: Bool = resizing?.edges == edges || hoveredGrip == edges
        let title: String
        let cursor: NSCursor
        switch edges {
        case .right: title = "Resize width"; cursor = .resizeLeftRight
        case .bottom: title = "Resize height"; cursor = .resizeUpDown
        default: title = "Resize width and height"; cursor = .crosshair
        }
        return Rectangle()
            .fill(lit ? DeveloperToolsStyle.selected : DeveloperToolsStyle.raised)
            .overlay { gripMark(edges, lit: lit) }
            .contentShape(Rectangle())
            .onHover { (over: Bool) in
                if over {
                    hoveredGrip = edges
                    cursor.push()
                } else {
                    if hoveredGrip == edges { hoveredGrip = nil }
                    NSCursor.pop()
                }
            }
            .gesture(resizeGesture(edges, points: points, centred: centred))
            .help(title)
            .accessibilityElement()
            .accessibilityLabel(title)
            .accessibilityValue("\(settings.width) × \(settings.height)")
            .accessibilityAdjustableAction { direction in
                let step = direction == .increment ? 10 : -10
                settings.resize(width: edges.contains(.right) ? settings.width + step : nil,
                                height: edges.contains(.bottom) ? settings.height + step : nil)
            }
    }

    /// The little bar drawn on a side grip; the corner has none.
    @ViewBuilder
    private func gripMark(_ edges: DeveloperViewportResize.Edges, lit: Bool) -> some View {
        if edges != .corner {
            let across: Bool = edges == .right
            Capsule().fill(Color.secondary.opacity(lit ? 0.8 : 0.45))
                .frame(width: across ? 2 : 18, height: across ? 18 : 2)
        }
    }

    private func resizeGesture(_ edges: DeveloperViewportResize.Edges, points: CGFloat,
                               centred: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { (value: DragGesture.Value) in
                if resizing == nil {
                    resizing = Resizing(start: .init(width: settings.width, height: settings.height),
                                        scale: points, centred: centred, edges: edges)
                }
                guard let resizing else { return }
                let size: DeveloperViewportResize.Size = DeveloperViewportResize.size(
                    from: resizing.start, translation: value.translation,
                    scale: resizing.scale, edges: edges, centred: resizing.centred)
                guard !settings.isResponsive || size.width != settings.width || size.height != settings.height
                else { return }
                settings.resize(width: edges.contains(.right) ? size.width : nil,
                                height: edges.contains(.bottom) ? size.height : nil)
            }
            .onEnded { _ in resizing = nil }
    }
}

/// A ruler along the emulated viewport, in CSS pixels, as Chrome's "Show rulers".
private struct DeveloperViewportRulerView: View {
    let vertical: Bool
    let length: Int
    /// Points for each CSS pixel.
    let scale: CGFloat

    var body: some View {
        Canvas { context, size in
            let across = vertical ? size.width : size.height
            let ink = Color.secondary
            for tick in DeveloperViewportRuler.ticks(length: length, scale: scale) {
                let at = (CGFloat(tick.position) * scale).rounded() + 0.5
                let long: CGFloat
                switch tick.kind {
                case .major: long = across
                case .medium: long = across * 0.5
                case .minor: long = across * 0.25
                }
                var path = Path()
                if vertical {
                    path.move(to: CGPoint(x: size.width - long, y: at))
                    path.addLine(to: CGPoint(x: size.width, y: at))
                } else {
                    path.move(to: CGPoint(x: at, y: size.height - long))
                    path.addLine(to: CGPoint(x: at, y: size.height))
                }
                context.stroke(path, with: .color(ink.opacity(tick.kind == .minor ? 0.45 : 0.7)), lineWidth: 1)
                guard tick.kind == .major, tick.position > 0 else { continue }
                let label = context.resolve(Text("\(tick.position)").font(.system(size: 8).monospacedDigit())
                    .foregroundColor(ink))
                if vertical {
                    var turned = context
                    turned.translateBy(x: 1, y: at + 2)
                    turned.rotate(by: .degrees(90))
                    turned.draw(label, at: .zero, anchor: .bottomLeading)
                } else {
                    context.draw(label, at: CGPoint(x: at + 2, y: 0), anchor: .topLeading)
                }
            }
        }
        .background(DeveloperToolsStyle.chrome)
        .accessibilityHidden(true)
    }
}

/// Chrome's "Show media queries": a bar for each width breakpoint in the
/// page's style sheets, max-width in blue, ranges in green and min-width in
/// orange, mirrored about the viewport's middle. Clicking one sets the
/// viewport to its width.
private struct DeveloperMediaQueryBar: View {
    let web: WKWebView
    /// Points for each CSS pixel.
    let scale: CGFloat
    let width: Int
    /// How far right of the bar's middle the viewport's middle is.
    let offset: CGFloat
    let choose: (Int) -> Void
    @State private var queries: [DeveloperMediaQuery] = []
    @State private var loaded = false

    var body: some View {
        let rows = [DeveloperMediaQuery.Kind.max, .range, .min]
            .map { kind in queries.filter { $0.kind == kind } }
            .filter { !$0.isEmpty }
        VStack(spacing: 1) {
            if loaded, rows.isEmpty {
                Text("No width media queries in the style sheets this page can read")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .frame(height: 14)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GeometryReader { space in
                    let middle = space.size.width / 2 + offset
                    ZStack(alignment: .topLeading) {
                        ForEach(row, id: \.self) { query in
                            segments(query, middle: middle, room: space.size.width)
                        }
                    }
                }
                .frame(height: 12)
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity)
        .background(DeveloperToolsStyle.chrome)
        .overlay(alignment: .bottom) { DeveloperToolsStyle.rule.frame(height: 1) }
        .onReceive(web.publisher(for: \.isLoading)) { loading in
            if !loading { Task { await load() } }
        }
        // Style sheets come and go as the page runs; Chrome follows them too.
        .task(id: web.url) {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func segments(_ query: DeveloperMediaQuery, middle: CGFloat, room: CGFloat) -> some View {
        let lower: CGFloat = query.kind == .max ? 0 : CGFloat(query.min ?? 0) * scale / 2
        let upper: CGFloat = query.kind == .min ? room : CGFloat(query.max ?? 0) * scale / 2
        let length: CGFloat = max(1, upper - lower)
        return ForEach([-1.0, 1.0], id: \.self) { (side: Double) in
            let start: CGFloat = side < 0 ? middle - upper : middle + lower
            segment(query, leading: side < 0, length: length).offset(x: start)
        }
    }

    /// One of a query's two mirrored bars, `length` points long.
    private func segment(_ query: DeveloperMediaQuery, leading: Bool, length: CGFloat) -> some View {
        let color: Color
        switch query.kind {
        case .max: color = .blue
        case .range: color = .green
        case .min: color = .orange
        }
        let matches: Bool = (query.min.map { width >= $0 } ?? true) && (query.max.map { width <= $0 } ?? true)
        let labelled: Bool = query.kind != .min && length >= 34
        return Button { choose(query.width) } label: {
            Rectangle().fill(color.opacity(matches ? 0.75 : 0.35))
                .overlay(alignment: leading ? .leading : .trailing) {
                    if labelled {
                        Text("\(query.width)px").font(.system(size: 8).monospacedDigit())
                            .foregroundStyle(.white).padding(.horizontal, 2).lineLimit(1)
                    }
                }
                .frame(width: length, height: 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("@media (" + query.title + ")")
        .accessibilityLabel("Media query " + query.title)
        .accessibilityHidden(!leading)
    }

    private func load() async {
        let result = try? await web.callAsyncJavaScript(DeveloperMediaQuery.script, arguments: [:], in: nil,
                                                        contentWorld: Web.world)
        let found = DeveloperMediaQuery.parse(result as? [String] ?? [])
        if found != queries { queries = found }
        loaded = true
    }
}

/// The device toolbar's throttling menu. Chrome's presets pair a network
/// profile with a CPU slowdown; WebKit can hold back a page's requests but
/// can't slow its CPU, so each brings its network half.
enum DeveloperViewportThrottling: String, CaseIterable, Identifiable {
    case none = "No throttling"
    case midTier = "Mid-tier mobile"
    case lowEnd = "Low-end mobile"
    case offline = "Offline"

    var id: Self { self }

    var condition: DeveloperToolsSession.NetworkCondition {
        switch self {
        case .none: .unrestricted
        case .midTier: .fast4G
        case .lowEnd: .slow4G
        case .offline: .offline
        }
    }

    /// The preset a network condition belongs to, if any.
    init?(_ condition: DeveloperToolsSession.NetworkCondition) {
        guard let match = Self.allCases.first(where: { $0.condition == condition }) else { return nil }
        self = match
    }

    var detail: String {
        switch self {
        case .none: "No throttling"
        case .midTier: "Fast 4G network. Chrome also slows the CPU 4×, which WebKit can’t."
        case .lowEnd: "Slow 4G network. Chrome also slows the CPU 6×, which WebKit can’t."
        case .offline: "Every request fails"
        }
    }
}

/// A device toolbar menu's title and its chevron.
private func viewportMenuLabel(_ text: String) -> some View {
    HStack(spacing: 3) {
        Text(text).lineLimit(1)
        Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold)).foregroundStyle(.secondary)
    }
    .padding(.horizontal, 5)
    .frame(height: DeveloperToolsStyle.controlHeight)
    .contentShape(Rectangle())
}

private extension View {
    /// A device toolbar menu: borderless, no indicator, its own size.
    func viewportMenu() -> some View {
        menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }
}

private struct DeveloperViewportThrottle: View {
    @ObservedObject private var tools = DeveloperTools.shared

    var body: some View {
        if let session = tools.session {
            ThrottleMenu(session: session)
        }
    }

    private struct ThrottleMenu: View {
        @ObservedObject var session: DeveloperToolsSession

        var body: some View {
            let current: DeveloperViewportThrottling? = DeveloperViewportThrottling(session.throttle)
            let title: String = current?.rawValue ?? session.throttle.rawValue
            Menu {
                items(current)
            } label: {
                viewportMenuLabel(title).foregroundStyle(session.throttle == .unrestricted ? Palette.ink : Color.orange)
            }
            .viewportMenu()
            .disabled(!session.requestInterception)
            .accessibilityLabel("Throttling")
            .accessibilityValue(title)
            .help(current?.detail ?? session.throttle.detail)
        }

        @ViewBuilder
        private func items(_ current: DeveloperViewportThrottling?) -> some View {
            ForEach(DeveloperViewportThrottling.allCases) { (preset: DeveloperViewportThrottling) in
                Button { session.setNetwork(preset.condition) } label: {
                    if current == preset { Label(preset.rawValue, systemImage: "checkmark") } else { Text(preset.rawValue) }
                }
                .help(preset.detail)
            }
            if !session.requestInterception {
                Divider()
                Text("WebKit hasn’t given this page’s requests to Developer Tools yet.")
            }
        }
    }
}

private struct DeveloperViewportToolbar: View {
    @Binding var settings: DeveloperViewportSettings
    let scale: CGFloat
    @ObservedObject private var shell = DeveloperToolsShell.shared
    @State private var devices = DeveloperDevices.shown

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DeveloperToolsStyle.controlSpacing) {
                device
                dimensions
                zoom
                if settings.showDevicePixelRatio { scaleFactor }
                if settings.showDeviceType { deviceType }
                DeveloperViewportThrottle()
                rotate
                more
            }.fixedSize(horizontal: true, vertical: false)
            VStack(spacing: 4) {
                HStack(spacing: DeveloperToolsStyle.controlSpacing) {
                    device
                    zoom
                    DeveloperViewportThrottle()
                    rotate
                    more
                }
                HStack(spacing: DeveloperToolsStyle.controlSpacing) {
                    dimensions
                    if settings.showDevicePixelRatio { scaleFactor }
                    if settings.showDeviceType { deviceType }
                }
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, DeveloperToolsStyle.gutter)
        .frame(maxWidth: .infinity, alignment: .center)
        .font(.system(size: 11))
        .controlSize(.small)
        .background(DeveloperToolsStyle.chrome)
        .overlay(alignment: .bottom) { DeveloperToolsStyle.rule.frame(height: 1) }
        // Edit… opens Settings › Devices, as in Chrome; what it changed is
        // read back when Settings closes.
        .onChange(of: shell.settingsShown) { _, shown in
            guard !shown else { return }
            devices = DeveloperDevices.shown
            if let current = settings.device, DeveloperDevices.device(id: current.id) == nil { settings.select(nil) }
        }
    }

    private var device: some View {
        Menu {
            Button { settings.select(nil) } label: { check("Responsive", settings.isResponsive) }
            Divider()
            ForEach(devices) { device in
                Button { settings.select(device) } label: { check(device.title, settings.device?.id == device.id) }
            }
            Divider()
            Button("Edit…") { shell.showSettings(.devices) }
        } label: {
            viewportMenuLabel("Dimensions: " + (settings.device?.title ?? "Responsive"))
        }
        .viewportMenu()
        .accessibilityLabel("Device")
        .accessibilityValue(settings.device?.title ?? "Responsive")
        .help("Emulated device")
    }

    @ViewBuilder
    private func check(_ title: String, _ on: Bool) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    private var dimensions: some View {
        HStack(spacing: 4) {
            field("Width", value: Binding(get: { settings.width }, set: { settings.set(width: $0) }))
            Text("×").foregroundStyle(.secondary).accessibilityHidden(true)
            field("Height", value: Binding(get: { settings.height }, set: { settings.set(height: $0) }))
        }
        .disabled(!settings.isResponsive)
        .fixedSize()
    }

    private func field(_ label: String, value: Binding<Int>) -> some View {
        TextField(label, value: value, format: .number.grouping(.never))
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .font(.system(size: 11).monospacedDigit())
            .developerToolsField()
            .frame(width: 50)
            // As in Chrome DevTools: Up and Down step a pixel, ten with Shift.
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                guard settings.isResponsive else { return .ignored }
                value.wrappedValue = DeveloperViewportSettings.stepped(value.wrappedValue, up: press.key == .upArrow,
                                                                       shift: press.modifiers.contains(.shift))
                return .handled
            }
            .accessibilityLabel("Viewport " + label.lowercased())
            .help(label + " in CSS pixels. Up and Down change it by 1, with Shift by 10.")
    }

    private var zoom: some View {
        Menu {
            Button {
                settings.zoom = .fit
            } label: {
                check("Fit to window (" + percent(scale) + ")", settings.zoom == .fit)
            }
            Divider()
            ForEach(DeveloperViewportSettings.Zoom.presets, id: \.self) { value in
                Button { settings.zoom = .fixed(value) } label: {
                    check(percent(CGFloat(value)), settings.zoom == .fixed(value))
                }
            }
        } label: {
            viewportMenuLabel(percent(scale))
        }
        .viewportMenu()
        .accessibilityLabel("Zoom")
        .accessibilityValue(percent(scale))
        .help("Zoom. The preview scale never changes the page's CSS viewport.")
    }

    private func percent(_ value: CGFloat) -> String {
        Double(value).formatted(.percent.precision(.fractionLength(0)))
    }

    private var scaleFactor: some View {
        let supported = DeveloperDeviceEmulation.canEmulateScaleFactor
        let current = settings.deviceScaleFactor
        let text = "DPR: " + (supported ? (current.map(Self.ratio) ?? "Default") : "Default")
        return Menu {
            if supported {
                let defaultRatio = settings.responsiveType == .mobile ? DeveloperDevices.responsiveMobileScaleFactor : nil
                Button { settings.responsiveScaleFactor = nil } label: {
                    check(defaultRatio.map { "Default: " + Self.ratio($0) } ?? "Default", settings.responsiveScaleFactor == nil)
                }
                ForEach([1.0, 2.0, 3.0], id: \.self) { value in
                    Button { settings.responsiveScaleFactor = value } label: {
                        check(Self.ratio(value), settings.responsiveScaleFactor == value)
                    }
                }
            } else {
                Text("This version of WebKit can’t emulate the device pixel ratio.")
            }
        } label: {
            viewportMenuLabel(text).foregroundStyle(supported ? .primary : .secondary)
        }
        .viewportMenu()
        .disabled(supported && !settings.isResponsive)
        .accessibilityLabel("Device pixel ratio")
        .accessibilityValue(text)
        .help(supported ? "Device pixel ratio (window.devicePixelRatio)"
              : "WebKit can’t emulate the device pixel ratio in this version.")
    }

    private static func ratio(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...3)))
    }

    private var deviceType: some View {
        Menu {
            ForEach(DeveloperEmulatedDevice.DeviceType.allCases) { type in
                Button { settings.responsiveType = type } label: { check(type.rawValue, settings.responsiveType == type) }
            }
        } label: {
            viewportMenuLabel(settings.device?.type.rawValue ?? settings.responsiveType.rawValue)
        }
        .viewportMenu()
        .disabled(!settings.isResponsive)
        .accessibilityLabel("Device type")
        .help("Device type. Mobile sends a mobile user agent.")
    }

    private var rotate: some View {
        DeveloperPanelIcon(symbol: "rotate.right", title: "Rotate") { settings.rotate() }
    }

    /// Chrome's device toolbar ⋮ menu. Its "Show device frame" is left out:
    /// none of the devices here has a frame to show, which is when Chrome
    /// leaves it out too.
    private var more: some View {
        Menu {
            Button(settings.showMediaQueries ? "Hide media queries" : "Show media queries") {
                settings.showMediaQueries.toggle()
            }
            Button(settings.showRulers ? "Hide rulers" : "Show rulers") { settings.showRulers.toggle() }
            Button(settings.showDevicePixelRatio ? "Remove device pixel ratio" : "Add device pixel ratio") {
                settings.showDevicePixelRatio.toggle()
            }
            Button(settings.showDeviceType ? "Remove device type" : "Add device type") {
                settings.showDeviceType.toggle()
            }
            Divider()
            Button("Capture screenshot") { capture(fullSize: false) }
                .disabled(captureTarget == nil)
            Button("Capture full size screenshot") { capture(fullSize: true) }
                .disabled(captureTarget == nil)
            Divider()
            Button("Reset to defaults") { settings.reset() }
            Divider()
            Section("User agent") {
                Text(settings.userAgent ?? "Search’s own user agent")
            }
            Section("Touch") {
                Text(settings.touch ? "Approximate: Search turns presses and drags into touch events. "
                     + "Reload pages that look for touch as they load." : "No touch emulation")
            }
            if !DeveloperDeviceEmulation.canEmulateScaleFactor {
                Section("Device pixel ratio") {
                    Text("WebKit can’t emulate the device pixel ratio in this version.")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .rotationEffect(.degrees(90))
                .foregroundStyle(.secondary)
                .frame(width: DeveloperToolsStyle.controlHeight, height: DeveloperToolsStyle.controlHeight)
                .contentShape(Rectangle())
        }
        .viewportMenu()
        .accessibilityLabel("More options")
        .help("More options")
    }

    /// The window showing the inspected tab. In device mode its screenshots
    /// are of the emulated viewport, as Chrome's are.
    private var captureTarget: Browser? {
        guard let tab = DeveloperTools.shared.session?.tab else { return nil }
        return Browsers.all.first { $0.active === tab }
    }

    private func capture(fullSize: Bool) {
        guard let browser = captureTarget else { return }
        if fullSize { browser.captureFullSizeScreenshot() } else { browser.captureScreenshot() }
    }
}
