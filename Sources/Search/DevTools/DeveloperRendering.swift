import CoreImage
import SwiftUI
import WebKit

/// Chrome's Rendering drawer (`entrypoints/inspector_main/RenderingOptions.ts`)
/// on WebKit's `Page` domain. The overrides live in the inspected page and
/// WebKit clears them when the inspector disconnects.
@MainActor
final class DeveloperRendering: ObservableObject {
    struct Options: Equatable {
        var paintFlashing = false
        var layerBorders = false
        /// "", "print" or "screen".
        var mediaType = ""
        /// `Page.UserPreferenceValue` names, or `nil` for no emulation.
        var colorScheme: String?
        var reducedMotion: String?
        var contrast: String?
        var javaScriptDisabled = false
        var imagesDisabled = false
        /// Done in the page (DeveloperRenderingPage), as approximations.
        var frameStats = false
        var layoutShifts = false
        var focusedPage = false
        /// Media features emulated by rewriting the page's CSS, by value,
        /// or `nil` for no emulation.
        var forcedColors: String?
        var colorGamut: String?
        var reducedTransparency: String?
        var reducedData: String?

        /// What WebKit's Page domain is asked for. `prefers-contrast: more`
        /// goes to WebKit when it can emulate it; every other contrast is
        /// rewritten in the page.
        fileprivate func payload(nativeContrast: Bool) -> [String: Any] {
            let contrast = nativeContrast && self.contrast == "more" ? self.contrast : nil
            return [
                "paintFlashing": paintFlashing, "layerBorders": layerBorders, "mediaType": mediaType,
                "colorScheme": colorScheme as Any? ?? NSNull(), "reducedMotion": reducedMotion as Any? ?? NSNull(),
                "contrast": contrast as Any? ?? NSNull(), "javaScriptDisabled": javaScriptDisabled,
                "imagesDisabled": imagesDisabled,
            ]
        }

        /// What the page's own script is asked for.
        func pageState(nativeContrast: Bool) -> DeveloperRenderingPage.State {
            var media: [String: String] = [:]
            media["forced-colors"] = forcedColors
            media["color-gamut"] = colorGamut
            media["prefers-reduced-transparency"] = reducedTransparency
            media["prefers-reduced-data"] = reducedData
            if let contrast, !(nativeContrast && contrast == "more") { media["prefers-contrast"] = contrast }
            return DeveloperRenderingPage.State(frameStats: frameStats, layoutShifts: layoutShifts,
                                                focused: focusedPage, media: media)
        }
    }

    struct Support: Equatable {
        var paintRects = false
        var settings = false
        var media = false
        var preferences: Set<String> = []
    }

    /// Chrome's "Emulate vision deficiencies" list.
    enum VisionDeficiency: String, CaseIterable, Identifiable {
        case none = "No emulation"
        case blurredVision = "Blurred vision"
        case reducedContrast = "Reduced contrast"
        case protanopia = "Protanopia (no red)"
        case deuteranopia = "Deuteranopia (no green)"
        case tritanopia = "Tritanopia (no blue)"
        case achromatopsia = "Achromatopsia (no color)"

        var id: Self { self }

        /// Chromium's filters: Machado et al. (2009) matrices at full severity,
        /// a blur, and halved contrast.
        var filters: [CIFilter] {
            func matrix(_ m: [CGFloat]) -> CIFilter? {
                let filter = CIFilter(name: "CIColorMatrix")
                filter?.setValue(CIVector(x: m[0], y: m[1], z: m[2], w: 0), forKey: "inputRVector")
                filter?.setValue(CIVector(x: m[3], y: m[4], z: m[5], w: 0), forKey: "inputGVector")
                filter?.setValue(CIVector(x: m[6], y: m[7], z: m[8], w: 0), forKey: "inputBVector")
                return filter
            }
            switch self {
            case .none: return []
            case .blurredVision:
                let blur = CIFilter(name: "CIGaussianBlur")
                blur?.setValue(2.0, forKey: kCIInputRadiusKey)
                return blur.map { [$0] } ?? []
            case .reducedContrast:
                let controls = CIFilter(name: "CIColorControls")
                controls?.setValue(0.5, forKey: kCIInputContrastKey)
                return controls.map { [$0] } ?? []
            case .achromatopsia:
                return matrix([0.213, 0.715, 0.072, 0.213, 0.715, 0.072, 0.213, 0.715, 0.072]).map { [$0] } ?? []
            case .protanopia:
                return matrix([0.152286, 1.052583, -0.204868, 0.114503, 0.786281, 0.099216,
                               -0.003882, -0.048116, 1.051998]).map { [$0] } ?? []
            case .deuteranopia:
                return matrix([0.367322, 0.860646, -0.227968, 0.280085, 0.672501, 0.047413,
                               -0.011820, 0.042940, 0.968881]).map { [$0] } ?? []
            case .tritanopia:
                return matrix([1.255528, -0.076749, -0.178779, -0.078411, 0.930809, 0.147602,
                               0.004733, 0.691367, 0.303900]).map { [$0] } ?? []
            }
        }
    }

    @Published private(set) var options = Options()
    @Published private(set) var support: Support?
    @Published private(set) var vision = VisionDeficiency.none
    @Published var problem: String?
    private let page = DeveloperRenderingPage()
    private var queue: Task<Void, Never>?
    private weak var filteredWeb: WKWebView?
    private var originalFilters: [Any]?
    private var originalCoreImage = false

    var active: Bool { options != Options() || vision != .none }

    /// Chrome's words for Emulate a focused page, and what Search's can't do.
    static let focusedPageHelp = "Keep page focused. Commonly used for debugging disappearing elements. "
        + "Partial: `:focus` styles still drop when the window loses focus."

    /// WebKit has no vision deficiency emulation, so the page's layer is filtered.
    func setVision(_ deficiency: VisionDeficiency, in session: DeveloperToolsSession) {
        guard let web = session.web else { return }
        if filteredWeb !== web { detachVision() }
        vision = deficiency
        guard deficiency != .none else { detachVision(); return }
        web.wantsLayer = true
        if filteredWeb == nil {
            filteredWeb = web
            originalFilters = web.layer?.filters
            originalCoreImage = web.layerUsesCoreImageFilters
        }
        web.layerUsesCoreImageFilters = true
        web.layer?.filters = deficiency.filters
    }

    /// Gives the page back its own pixels and takes the page's own script
    /// out. Call when Developer Tools closes.
    func detach() {
        detachVision()
        page.stop()
    }

    private func detachVision() {
        if let web = filteredWeb {
            web.layer?.filters = originalFilters
            web.layerUsesCoreImageFilters = originalCoreImage
        }
        filteredWeb = nil
        originalFilters = nil
        vision = .none
    }

    func prepare(in session: DeveloperToolsSession) {
        guard support == nil else { return }
        enqueue(session) { rendering, session in
            let raw = try await session.evaluateInFrontend(Self.install) as? [String: Any] ?? [:]
            rendering.support = Support(
                paintRects: raw["paintRects"] as? Bool == true, settings: raw["settings"] as? Bool == true,
                media: raw["media"] as? Bool == true, preferences: Set(raw["preferences"] as? [String] ?? []))
        }
    }

    func update(in session: DeveloperToolsSession, _ change: (inout Options) -> Void) {
        var next = options
        change(&next)
        guard next != options else { return }
        options = next
        let nativeContrast = support?.preferences.contains("PrefersContrast") == true
        let state = next.pageState(nativeContrast: nativeContrast)
        if state != page.state { page.apply(state, to: session.web) }
        enqueue(session) { rendering, session in
            _ = try await session.evaluateInFrontend(Self.install)
            _ = try await session.evaluateInFrontend("return await perchRendering.apply(state);",
                                                     ["state": next.payload(nativeContrast: nativeContrast)])
            rendering.problem = nil
        }
    }

    private func enqueue(_ session: DeveloperToolsSession,
                         _ work: @escaping @MainActor (DeveloperRendering, DeveloperToolsSession) async throws -> Void) {
        let previous = queue
        queue = Task { [weak self, weak session] in
            await previous?.value
            guard let self, let session, session.ready else { return }
            do { try await work(self, session) }
            catch is CancellationError {}
            catch { self.problem = error.localizedDescription }
        }
    }

    /// Applies the state to every page target and to targets WebKit adds
    /// later, such as the one a cross-site navigation swaps in.
    static let install = DevToolsResources.script("DeveloperRendering-install.js")
}

struct DeveloperRenderingView: View {
    @ObservedObject var session: DeveloperToolsSession
    @ObservedObject private var rendering: DeveloperRendering

    init(session: DeveloperToolsSession) {
        self.session = session
        rendering = session.rendering
    }

    private static let unsupported = "Not available in WebKit."
    private static let layoutShiftsHelp = "Highlights areas of the page (blue) that were shifted. Approximate: "
        + "Search flashes where the moved elements are now, from the page’s layout-shift entries or, where WebKit "
        + "has none, its own estimate."
    private static let frameStatsHelp = "Plots frame throughput and dropped frames. Approximate: Search counts "
        + "the page’s animation frames, not the compositor’s."
    private static let rewrittenHelp = "Approximate: Search rewrites the page’s media queries and wraps "
        + "`matchMedia`. Cross-origin style sheets are left as they are."

    var body: some View {
        let support = rendering.support ?? .init()
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                option("Paint flashing",
                       "Highlights areas of the page (green) that need to be repainted. May not be suitable for people prone to photosensitive epilepsy.",
                       on: rendering.options.paintFlashing, available: support.paintRects) { $0.paintFlashing = $1 }
                option("Layout shift regions", Self.layoutShiftsHelp,
                       on: rendering.options.layoutShifts, available: true) { $0.layoutShifts = $1 }
                option("Layer borders", "Shows layer borders (orange/olive) and tiles (cyan)",
                       on: rendering.options.layerBorders, available: support.settings) { $0.layerBorders = $1 }
                option("Frame rendering stats", Self.frameStatsHelp,
                       on: rendering.options.frameStats, available: true) { $0.frameStats = $1 }
                unavailable("Scrolling performance issues",
                            "Highlights elements (teal) that can slow down scrolling. " + Self.unsupported)
                unavailable("Highlight ads", "Highlights elements (red) detected to be ads. " + Self.unsupported)
                unavailable("Disable local fonts", "Disables `local()` sources in `@font-face` rules. " + Self.unsupported)
                option("Emulate a focused page", DeveloperRendering.focusedPageHelp,
                       on: rendering.options.focusedPage, available: true) { $0.focusedPage = $1 }
                unavailable("Enable automatic dark mode",
                            "Enables automatic dark mode and sets `prefers-color-scheme` to `dark`. " + Self.unsupported)
                Divider()
                preference("prefers-color-scheme", "PrefersColorScheme", value: rendering.options.colorScheme,
                           support: support, choices: [("Light", "light"), ("Dark", "dark")]) { $0.colorScheme = $1 }
                menu("Emulate CSS media type", "Forces media type for testing `print` and `screen` styles",
                     value: rendering.options.mediaType, available: support.media,
                     choices: [("", "No emulation"), ("print", "print"), ("screen", "screen")]) { $0.mediaType = $1 }
                rewritten("forced-colors", value: rendering.options.forcedColors,
                          values: ["active", "none"]) { $0.forcedColors = $1 }
                rewritten("prefers-contrast", value: rendering.options.contrast,
                          values: ["more", "less", "custom", "no-preference"],
                          note: support.preferences.contains("PrefersContrast")
                              ? "WebKit emulates `more`; Search rewrites the page’s media queries for the rest."
                              : nil) { $0.contrast = $1 }
                preference("prefers-reduced-motion", "PrefersReducedMotion", value: rendering.options.reducedMotion,
                           support: support, choices: [("Reduce", "reduce")]) { $0.reducedMotion = $1 }
                rewritten("prefers-reduced-data", value: rendering.options.reducedData,
                          values: ["reduce"]) { $0.reducedData = $1 }
                rewritten("prefers-reduced-transparency", value: rendering.options.reducedTransparency,
                          values: ["reduce", "no-preference"]) { $0.reducedTransparency = $1 }
                rewritten("color-gamut", value: rendering.options.colorGamut,
                          values: ["srgb", "p3", "rec2020"]) { $0.colorGamut = $1 }
                vision
                unavailable("Emulate OS text scale", "Forces OS text scale emulation. " + Self.unsupported)
                unavailable("Disable AVIF image format", Self.unsupported)
                unavailable("Disable JPEG XL image format", Self.unsupported)
                unavailable("Disable WebP image format", Self.unsupported)
                Divider()
                Text("Page settings").fontWeight(.semibold)
                option("Disable JavaScript", "Stops scripts in the inspected tab. Reload to stop scripts already running.",
                       on: rendering.options.javaScriptDisabled, available: support.settings) { $0.javaScriptDisabled = $1 }
                option("Disable images", "Stops loading images. Reload to apply to images already shown.",
                       on: rendering.options.imagesDisabled, available: support.settings) { $0.imagesDisabled = $1 }
                if rendering.active {
                    Text("These overrides apply to the inspected tab until Developer Tools closes.")
                        .foregroundStyle(.secondary)
                }
                if let problem = rendering.problem {
                    Text(problem).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(DeveloperToolsStyle.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { rendering.prepare(in: session) }
    }

    private var vision: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Emulate vision deficiencies")
            Text("Forces vision deficiency emulation. Search filters the page’s pixels, as Chrome does.")
                .foregroundStyle(.secondary)
            Picker("Emulate vision deficiencies", selection: Binding(get: { rendering.vision }, set: { value in
                rendering.setVision(value, in: session)
            })) {
                ForEach(DeveloperRendering.VisionDeficiency.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    private func option(_ title: String, _ detail: String, on: Bool, available: Bool,
                        set: @escaping (inout DeveloperRendering.Options, Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { on }, set: { value in rendering.update(in: session) { set(&$0, value) } })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(available ? detail : Self.unsupported).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.developerCheckbox)
        .disabled(!available)
    }

    private func unavailable(_ title: String, _ detail: String) -> some View {
        Toggle(isOn: .constant(false)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.developerCheckbox)
        .disabled(true)
        .accessibilityHint(Self.unsupported)
    }

    private func menu(_ title: String, _ detail: String, value: String, available: Bool,
                      choices: [(String, String)],
                      set: @escaping (inout DeveloperRendering.Options, String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
            Text(available ? detail : Self.unsupported).foregroundStyle(.secondary)
            Picker(title, selection: Binding(get: { value }, set: { new in
                rendering.update(in: session) { set(&$0, new) }
            })) {
                ForEach(choices, id: \.0) { choice in Text(choice.1).tag(choice.0) }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(!available)
        }
    }

    /// A media feature emulated in the page rather than by WebKit.
    private func rewritten(_ feature: String, value: String?, values: [String], note: String? = nil,
                           set: @escaping (inout DeveloperRendering.Options, String?) -> Void) -> some View {
        menu("Emulate CSS media feature " + feature,
             "Forces CSS `\(feature)` media feature. " + (note.map { $0 + " " } ?? "") + Self.rewrittenHelp,
             value: value ?? "", available: true,
             choices: [("", "No emulation")] + values.map { ($0, feature + ": " + $0) }) { options, new in
            set(&options, new.isEmpty ? nil : new)
        }
    }

    private func preference(_ feature: String, _ name: String, value: String?, support: DeveloperRendering.Support,
                            choices: [(String, String)], note: String? = nil,
                            set: @escaping (inout DeveloperRendering.Options, String?) -> Void) -> some View {
        menu("Emulate CSS media feature " + feature,
             "Forces CSS `\(feature)` media feature" + (note.map { ". " + $0 } ?? ""),
             value: value ?? "", available: support.preferences.contains(name),
             choices: [("", "No emulation")] + choices.map { ($0.0, feature + ": " + $0.1) }) { options, new in
            set(&options, new.isEmpty ? nil : new)
        }
    }
}

/// Elements › Styles' "Toggle common rendering emulations" (the paintbrush),
/// as in Chrome: prefers-color-scheme light or dark and the print media
/// type, the same state as the Rendering drawer's, so a change in either
/// shows in both.
struct DeveloperRenderingShortcuts: View {
    @ObservedObject var session: DeveloperToolsSession
    @ObservedObject private var rendering: DeveloperRendering

    init(session: DeveloperToolsSession) {
        self.session = session
        rendering = session.rendering
    }

    private var active: Bool {
        rendering.options.colorScheme != nil || rendering.options.mediaType == "print"
    }

    var body: some View {
        Menu {
            scheme("prefers-color-scheme: light", "Light")
            scheme("prefers-color-scheme: dark", "Dark")
            Toggle("print", isOn: Binding(get: { rendering.options.mediaType == "print" }, set: { on in
                rendering.update(in: session) { $0.mediaType = on ? "print" : "" }
            }))
            .disabled(rendering.support.map { !$0.media } ?? false)
        } label: {
            Image(systemName: "paintbrush").font(.system(size: 10, weight: .medium))
                .foregroundStyle(active ? DeveloperToolsStyle.tint : .secondary)
                .frame(width: DeveloperToolsStyle.controlHeight, height: DeveloperToolsStyle.controlHeight)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Toggle common rendering emulations")
        .accessibilityLabel("Toggle common rendering emulations")
        .onAppear { rendering.prepare(in: session) }
    }

    /// One of the colour schemes, by its `Page.UserPreferenceValue` name;
    /// checked again, it goes back to no emulation.
    private func scheme(_ title: String, _ value: String) -> some View {
        Toggle(title, isOn: Binding(get: { rendering.options.colorScheme == value }, set: { on in
            rendering.update(in: session) { $0.colorScheme = on ? value : nil }
        }))
        .disabled(rendering.support.map { !$0.preferences.contains("PrefersColorScheme") } ?? false)
    }
}

/// Elements › Styles › :hov's "Emulate a focused page", where Chrome puts
/// it: the same option as the Rendering drawer's, so a change in either
/// shows in both.
struct DeveloperFocusedPageToggle: View {
    @ObservedObject var session: DeveloperToolsSession
    @ObservedObject private var rendering: DeveloperRendering

    init(session: DeveloperToolsSession) {
        self.session = session
        rendering = session.rendering
    }

    var body: some View {
        Toggle("Emulate a focused page", isOn: Binding(get: { rendering.options.focusedPage }, set: { on in
            rendering.update(in: session) { $0.focusedPage = on }
        }))
        .toggleStyle(.developerCheckbox)
        .help(DeveloperRendering.focusedPageHelp)
    }
}
