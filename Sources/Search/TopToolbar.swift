import AppKit
import SwiftUI

/// One reveal state per browser window, separate from sidebar folding.
@MainActor
final class TopToolbarController: ObservableObject {
    @Published private(set) var revealed = false
    @Published private(set) var editing = false
    @Published private(set) var menuTracking = false
    private(set) var currentAnimationDuration = TopToolbarRevealPolicy.animationDuration
    private var pointerInside = false
    private var outsideWindow = false
    private var eligible = false
    private var popup = false
    private var menuDepth = 0
    private var pending: DispatchWorkItem?
    private var animationStart = ProcessInfo.processInfo.systemUptime
    private var animationFrom = 0.0
    private var animationTo = 0.0
    private let captionAnimator = TopToolbarCaptionAnimator()

    var showsWindowControls: Bool {
        TopToolbarPreferences.shared.contains(.windowControls) && revealed && eligible
    }
    func animateCaption(_ bar: NSView, visible: Bool) { captionAnimator.update(bar, visible: visible) }
    func restoreCaption(_ bar: NSView) { captionAnimator.restore(bar) }

    func configure(eligible: Bool, popup: Bool) {
        let changed = self.eligible != eligible || self.popup != popup
        self.eligible = eligible
        self.popup = popup
        guard changed else { return }
        if !eligible { reset() }
        else { reconcile() }
    }

    func pointer(inside: Bool, atEdge: Bool, outsideWindow: Bool = false) {
        pointerInside = inside
        self.outsideWindow = outsideWindow
        guard eligible else { return }
        if inside && (revealed || atEdge) {
            pending?.cancel()
            pending = nil
            // Helium starts the animation immediately; there is no hover dwell.
            setRevealed(true)
        } else { reconcile() }
    }

    func setEditing(_ editing: Bool) {
        guard self.editing != editing else { return }
        self.editing = editing
        if editing && eligible { pending?.cancel(); pending = nil; setRevealed(true) }
        else { reconcile() }
    }
    func setMenuTracking(_ tracking: Bool) {
        guard menuTracking != tracking else { return }
        menuTracking = tracking
        if tracking { pending?.cancel(); pending = nil }
        else { reconcile() }
    }
    func beginMenu() { menuDepth += 1; setMenuTracking(true) }
    func endMenu() {
        guard menuDepth > 0 else { return }
        menuDepth -= 1
        if menuDepth == 0 { setMenuTracking(false) }
    }
    func showNow() {
        guard eligible else { return }
        pending?.cancel()
        pending = nil
        setRevealed(true)
    }
    func reset() {
        pending?.cancel()
        pending = nil
        pointerInside = false
        outsideWindow = false
        editing = false
        menuTracking = false
        menuDepth = 0
        setRevealed(false)
    }
    private func reconcile() {
        guard eligible else { return }
        if TopToolbarRevealPolicy.shouldHold(pointerInside: pointerInside, editing: editing, popup: popup, menuTracking: menuTracking) {
            pending?.cancel()
            pending = nil
        } else if pending == nil && revealed {
            // Like Helium's StartZenCollapseTimer, pointer moves do not restart
            // an already-running exit timer.
            let delay = outsideWindow ? TopToolbarRevealPolicy.cursorExitGrace : TopToolbarRevealPolicy.hideDelay
            let item = DispatchWorkItem { [weak self] in
                guard let self, self.eligible else { return }
                self.pending = nil
                guard !TopToolbarRevealPolicy.shouldHold(pointerInside: self.pointerInside, editing: self.editing, popup: self.popup, menuTracking: self.menuTracking) else { return }
                self.setRevealed(false)
            }
            pending = item
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }
    private func setRevealed(_ shown: Bool) {
        guard revealed != shown else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = currentAnimationDuration > 0 ? (now - animationStart) / currentAnimationDuration : 1
        let current = animationFrom + (animationTo - animationFrom) * TopToolbarRevealPolicy.progress(at: elapsed)
        currentAnimationDuration = Motion.reduced ? 0 : TopToolbarRevealPolicy.duration(current: current, showing: shown)
        animationStart = now
        animationFrom = current
        animationTo = shown ? 1 : 0
        withAnimation(TopToolbarRevealPolicy.animation(duration: currentAnimationDuration)) { revealed = shown }
    }
}

/// Helium fades macOS caption buttons with its reveal ratio; it does not
/// spring-translate them. Apply the same curve to native buttons and grey
/// resting circles, preserving the original frame and hit targets.
@MainActor
private final class TopToolbarCaptionAnimator {
    private weak var bar: NSView?
    private var desired: Bool?
    private var generation = 0
    func restore(_ bar: NSView) {
        guard self.bar === bar, desired != nil else { return }
        generation += 1
        desired = nil
        bar.layer?.removeAnimation(forKey: "opacity")
        bar.alphaValue = 1
    }

    func update(_ bar: NSView, visible: Bool) {
        guard self.bar !== bar || desired != visible else { return }
        self.bar = bar
        desired = visible
        generation += 1
        let ticket = generation
        let value = bar.isHidden ? 0 : min(1, max(0, Double(bar.layer?.presentation()?.opacity ?? Swift.Float(bar.alphaValue))))
        Fold.reset(bar, hidden: false)
        bar.alphaValue = value
        let duration = Motion.reduced ? 0 : TopToolbarRevealPolicy.duration(current: value, showing: visible)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0, 0, 1)
            bar.animator().alphaValue = visible ? 1 : 0
        } completionHandler: { [weak self, weak bar] in
            guard let self, let bar, self.generation == ticket else { return }
            bar.isHidden = !visible
        }
    }
}

enum TopToolbarPointerPolicy {
    static func hit(point: CGPoint, size: CGSize, revealed: Bool) -> (inside: Bool, atEdge: Bool) {
        let withinWidth = point.x >= 0 && point.x < size.width
        let atEdge = withinWidth && point.y >= 0 && point.y < TopToolbarRevealPolicy.triggerHeight
        let height = revealed ? TopToolbarRevealPolicy.height + TopToolbarRevealPolicy.hoverLeeway : TopToolbarRevealPolicy.triggerHeight
        return (withinWidth && point.y >= 0 && point.y <= min(height, size.height), atEdge)
    }
}

/// Watches the window's top edge without swallowing page or toolbar events.
private struct TopToolbarPointer: NSViewRepresentable {
    let controller: TopToolbarController
    func makeNSView(context: Context) -> Tracking { Tracking() }
    func updateNSView(_ view: Tracking, context: Context) { view.controller = controller }
    static func dismantleNSView(_ view: Tracking, coordinator: ()) {
        let controller = view.controller
        DispatchQueue.main.async { controller?.pointer(inside: false, atEdge: false) }
    }

    final class Tracking: NSView {
        weak var controller: TopToolbarController?
        private var area: NSTrackingArea?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(area)
            self.area = area
        }
        override func mouseEntered(with event: NSEvent) { moved(event) }
        override func mouseMoved(with event: NSEvent) { moved(event) }
        override func mouseExited(with event: NSEvent) { controller?.pointer(inside: false, atEdge: false, outsideWindow: true) }
        private func moved(_ event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            let hit = TopToolbarPointerPolicy.hit(point: point, size: bounds.size, revealed: controller?.revealed == true)
            controller?.pointer(inside: hit.inside, atEdge: hit.atEdge)
        }
    }
}

struct TopToolbarLayer: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var prefs = TopToolbarPreferences.shared
    @ObservedObject private var controller: TopToolbarController
    let immersed: Bool

    init(browser: Browser, immersed: Bool) {
        self.browser = browser
        self.immersed = immersed
        _controller = ObservedObject(wrappedValue: browser.topToolbar)
    }
    private var eligible: Bool {
        TopToolbarRevealPolicy.eligible(compact: browser.prefs.iconSidebar, fullscreen: browser.fullScreen,
                                        immersed: immersed, enabled: prefs.enabled, hasItems: !prefs.items.isEmpty)
    }
    private var popup: Bool {
        if browser.bookmarksOpen || browser.makingSpace { return true }
        if #available(macOS 15.4, *), Extensions.shared.menuOpen || ExtensionPopup.shared.isUp { return true }
        return false
    }

    var body: some View {
        ZStack(alignment: .top) {
            if eligible {
                TopToolbarPointer(controller: controller)
                if controller.revealed {
                    TopToolbar(browser: browser)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(1)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .onAppear { configure() }
        .onChange(of: eligible) { _, _ in configure() }
        .onChange(of: popup) { _, _ in configure() }
        .task(id: controller.revealed) {
            guard controller.revealed else { return }
            while !Task.isCancelled && controller.revealed {
                // Extension action popups are AppKit objects, not published
                // SwiftUI state. Check only while the toolbar is out.
                configure()
                do { try await Task.sleep(nanoseconds: 150_000_000) }
                catch { break }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            if browser.window?.isKeyWindow == true && controller.revealed { controller.beginMenu() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in controller.endMenu() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in controller.reset() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            if (note.object as? NSWindow) === browser.window && !popup { controller.reset() }
        }
        .onDisappear { controller.reset() }
    }
    private func configure() { controller.configure(eligible: eligible, popup: popup) }
}

struct TopToolbarViewFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
private struct ToolbarIntrinsicWidth: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
private struct TopToolbarFrame: ViewModifier {
    let key: String
    func body(content: Content) -> some View {
        content.background {
            if Store.testing {
                GeometryReader { geo in Color.clear.preference(key: TopToolbarViewFrames.self, value: [key: geo.frame(in: .named("top-toolbar"))]) }
            }
        }
    }
}

struct TopToolbar: View {
    @ObservedObject var browser: Browser
    @State private var measuredToolsWidth: CGFloat = 0
    @ObservedObject private var prefs = TopToolbarPreferences.shared
    @ObservedObject private var controller: TopToolbarController
    init(browser: Browser) {
        self.browser = browser
        _controller = ObservedObject(wrappedValue: browser.topToolbar)
    }
    private var leading: [TopToolbarItem] { [.sidebar, .back, .forward, .reload].filter(prefs.contains) }
    private var trailing: [TopToolbarItem] {
        [.spaces, .extensions, .bookmarks, .history, .downloads, .settings, .tools].filter(prefs.contains)
    }

    private var leadingWidth: CGFloat { (prefs.contains(.windowControls) ? 90 : 0) + CGFloat(leading.count) * 32 }

    var body: some View {
        GeometryReader { geometry in
            let desired = measuredToolsWidth > 0 ? measuredToolsWidth : max(0, CGFloat(trailing.count) * 30 - 4)
            let widths = TopToolbarLayoutPolicy.widths(total: geometry.size.width, leading: leadingWidth,
                                                       trailing: desired, hasAddress: prefs.contains(.address))
            HStack(spacing: 6) {
                if prefs.contains(.windowControls) { Color.clear.frame(width: 84).allowsHitTesting(false) }
                ForEach(leading) { item in control(item) }
                if prefs.contains(.address) {
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Palette.muted)
                        if let tab = browser.active {
                            TopToolbarAddressField(browser: browser, tab: tab, controller: controller)
                                .frame(maxWidth: .infinity, minHeight: 22, maxHeight: 22)
                        } else { Text("Search or type a URL").font(.system(size: 12)).foregroundStyle(Palette.muted).frame(maxWidth: .infinity) }
                    }
                    .padding(.horizontal, 10).frame(width: widths.address, height: 30)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 9))
                    .modifier(TopToolbarFrame(key: "address"))
                } else { Spacer(minLength: 0) }
                if !trailing.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 4) { ForEach(trailing) { item in control(item) } }
                            .fixedSize(horizontal: true, vertical: false)
                            .background(GeometryReader { geo in Color.clear.preference(key: ToolbarIntrinsicWidth.self, value: geo.size.width) })
                    }
                    .scrollIndicators(.hidden)
                    .frame(width: widths.trailing, height: 30)
                    .modifier(TopToolbarFrame(key: "tools"))
                }
            }
            .padding(.horizontal, 10)
            .frame(width: geometry.size.width, height: TopToolbarRevealPolicy.height)
        }
        .frame(height: TopToolbarRevealPolicy.height)
        .coordinateSpace(name: "top-toolbar")
        .onPreferenceChange(ToolbarIntrinsicWidth.self) { width in
            if abs(measuredToolsWidth - width) > 0.5 { measuredToolsWidth = width }
        }
        .background(Palette.ground)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
        .background { DragStrip(reserved: 0) }
        .contextMenu { TopToolbarCustomizationMenu() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Top hover toolbar")
    }

    @ViewBuilder private func control(_ item: TopToolbarItem) -> some View {
        switch item {
        case .windowControls, .address: EmptyView()
        case .sidebar:
            Door(icon: "sidebar.left", help: "Show or hide sidebar   ⌘S") { browser.toggleFold() }
        case .spaces:
            if browser.prefs.usesSpaces { SpaceDot(browser: browser) }
            else { Door(icon: "square.stack", help: "Spaces settings") { browser.tuning = true } }
        case .extensions:
            ExtensionSlot(edge: .bottom, compact: false, alwaysShow: true)
        case .bookmarks:
            BookmarkDoor(browser: browser, arrowEdge: .top, isTopToolbar: true)
        case .history:
            Door(icon: "clock", help: "History") { browser.recalling.toggle() }
        case .downloads:
            Door(icon: "arrow.down.circle", help: "Downloads") { browser.hoarding.toggle() }
        case .settings:
            Door(icon: "gearshape", help: "Settings   ⌘,") { browser.tuning.toggle() }
        case .back:
            if let tab = browser.active { Navigation(browser: browser, tab: tab, forward: false) }
            else { Door(icon: "chevron.left") {}.disabled(true).opacity(0.3) }
        case .forward:
            if let tab = browser.active { Navigation(browser: browser, tab: tab, forward: true) }
            else { Door(icon: "chevron.right") {}.disabled(true).opacity(0.3) }
        case .reload:
            if let tab = browser.active { Reload(browser: browser, tab: tab) }
            else { Door(icon: "arrow.clockwise") {}.disabled(true).opacity(0.3) }
        case .tools:
            Menu {
                Button("Address / Search   ⌘L") { browser.edit() }
                Button("Bookmarks") { browser.bookmarking = true }
                Button("History") { browser.recalling = true }
                Button("Downloads") { browser.hoarding = true }
                Button("Settings") { browser.tuning = true }
                Divider()
                TopToolbarCustomizationMenu()
                SidebarFooterCustomizationMenu()
                SidebarDetailsMenu()
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 14))
                    .foregroundStyle(Palette.muted).frame(width: 26, height: 26)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Top toolbar tools").accessibilityLabel("Top toolbar tools")
        }
    }
    private struct Navigation: View {
        let browser: Browser
        @ObservedObject var tab: Tab
        let forward: Bool
        private var enabled: Bool { forward ? tab.canGoForward : tab.canGoBack }
        var body: some View {
            Door(icon: forward ? "chevron.right" : "chevron.left", help: forward ? "Forward" : "Back") {
                if forward { browser.forward() } else { browser.back() }
            }.disabled(!enabled).opacity(enabled ? 1 : 0.3)
        }
    }
    private struct Reload: View {
        let browser: Browser
        @ObservedObject var tab: Tab
        var body: some View {
            Door(icon: tab.loading ? "xmark" : "arrow.clockwise", help: tab.loading ? "Stop" : "Reload") {
                if tab.loading { tab.stop() } else { browser.reload() }
            }.disabled(tab.isBlank).opacity(tab.isBlank ? 0.3 : 1)
        }
    }
}

/// A compact independent editor; it uses Search's destination policy without
/// making the page-centred omnibox edit at the same time.
private struct TopToolbarAddressField: NSViewRepresentable {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    let controller: TopToolbarController
    func makeCoordinator() -> Coordinator { Coordinator(browser: browser, controller: controller) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12.5)
        field.textColor = Palette.NS.ink
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.lineBreakMode = .byTruncatingMiddle
        field.delegate = context.coordinator
        field.identifier = NSUserInterfaceItemIdentifier("top-toolbar-address")
        field.setAccessibilityLabel("Search or enter a URL")
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.browser = browser
        if let editingID = coordinator.editingTabID, editingID != browser.activeID {
            DispatchQueue.main.async {
                if coordinator.editingTabID == editingID { coordinator.finish() }
            }
        }
        field.placeholderString = "Search \(browser.prefs.engine.name(custom: browser.prefs.customEngine)) or type a URL"
        if !controller.editing { field.stringValue = TopToolbarAddressPolicy.display(tab.address) }
    }
    static func dismantleNSView(_ view: NSTextField, coordinator: Coordinator) {
        let controller = coordinator.controller
        DispatchQueue.main.async { controller.setEditing(false) }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var browser: Browser
        let controller: TopToolbarController
        private(set) var editingTabID: Tab.ID?
        func beginEditing() { editingTabID = browser.activeID; controller.setEditing(true) }
        init(browser: Browser, controller: TopToolbarController) { self.browser = browser; self.controller = controller }
        func controlTextDidBeginEditing(_ note: Notification) {
            beginEditing()
            if let field = note.object as? NSTextField, let editor = field.currentEditor() as? NSTextView {
                editor.selectedTextAttributes = [.backgroundColor: NSColor(Palette.ink.opacity(0.12)), .foregroundColor: Palette.NS.ink]
                editor.selectAll(nil)
            }
        }
        func controlTextDidEndEditing(_ note: Notification) { editingTabID = nil; controller.setEditing(false) }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            if command == #selector(NSResponder.insertNewline(_:)) {
                guard TopToolbarAddressPolicy.canSubmit(editingTabID: editingTabID, activeTabID: browser.activeID) else { finish(); return true }
                guard let url = browser.destination(for: textView.string) else { NSSound.beep(); return true }
                browser.cancelTabEdit()
                (browser.active ?? browser.tabs.first)?.go(to: url)
                finish()
                return true
            }
            if command == #selector(NSResponder.cancelOperation(_:)) { finish(); return true }
            return false
        }
        func finish() {
            editingTabID = nil
            controller.setEditing(false)
            if let view = browser.active?.built { browser.window?.makeFirstResponder(view) }
            else { browser.window?.makeFirstResponder(nil) }
        }
    }
}

/// Invokes the same native editor delegate in an isolated test window only.
@MainActor
enum TopToolbarNativeTestInput {
    static func submit(_ text: String, in window: NSWindow) -> Bool {
        guard Store.testing else { return false }
        func fields(_ view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
        }
        guard let root = window.contentView,
              let field = fields(root).first(where: { $0.identifier?.rawValue == "top-toolbar-address" }),
              let coordinator = field.delegate as? TopToolbarAddressField.Coordinator else { return false }
        let editor = NSTextView()
        editor.string = text
        coordinator.beginEditing()
        return coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    }
}

/// Weak registration keeps temporary hover controls from stranding popup
/// actions when their views are removed; the surviving sidebar is the fallback.
@MainActor
final class ToolbarAnchorRegistry {
    private final class Entry {
        weak var view: NSView?
        init(_ view: NSView) { self.view = view }
    }
    private var entries: [String: [Entry]] = [:]
    func register(_ view: NSView, for id: String) {
        entries[id] = (entries[id] ?? []).filter { $0.view != nil && $0.view !== view } + [Entry(view)]
    }
    func remove(_ view: NSView, for id: String) {
        entries[id] = (entries[id] ?? []).filter { $0.view != nil && $0.view !== view }
        if entries[id]?.isEmpty == true { entries[id] = nil }
    }
    func latest(for id: String) -> NSView? {
        entries[id] = entries[id]?.filter { $0.view != nil }
        return entries[id]?.last?.view
    }
    func attached(for id: String) -> NSView? {
        entries[id]?.reversed().compactMap(\.view).first { $0.window != nil }
    }
}

enum ToolbarPopupOwnership {
    static func presents(owner: UUID?, candidate: UUID, defaultOwner: Bool) -> Bool {
        owner.map { $0 == candidate } ?? defaultOwner
    }
}

enum TopToolbarAddressPolicy {
    static func canSubmit(editingTabID: UUID?, activeTabID: UUID?) -> Bool {
        editingTabID != nil && editingTabID == activeTabID
    }
    static func display(_ url: URL?) -> String {
        guard let url, url.absoluteString != "about:blank" else { return "" }
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "" }
        parts.user = nil
        parts.password = nil
        return parts.url.map(Address.editable) ?? ""
    }
}

struct TopToolbarCustomizationMenu: View {
    @ObservedObject private var prefs = TopToolbarPreferences.shared
    var body: some View {
        Menu("Top hover toolbar") {
            Toggle("Reveal at the top edge", isOn: $prefs.enabled)
            Divider()
            Button("Show Everything") { prefs.showAll() }
            Button("Hide Everything") { prefs.hideAll() }
            Divider()
            ForEach(TopToolbarItem.allCases) { item in Toggle(item.title, isOn: prefs.binding(for: item)) }
        }
    }
}

struct TopToolbarSettingsButton: View {
    @State private var open = false
    var body: some View {
        Button("Customize…") { open = true }.popover(isPresented: $open) { Picker() }
    }
    private struct Picker: View {
        @ObservedObject private var prefs = TopToolbarPreferences.shared
        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text("Top hover toolbar").font(.system(size: 13, weight: .semibold))
                Toggle("Reveal at the top edge", isOn: $prefs.enabled)
                HStack { Button("Show everything") { prefs.showAll() }; Button("Hide everything") { prefs.hideAll() } }
                ForEach(TopToolbarItem.allCases) { item in Toggle(item.title, isOn: prefs.binding(for: item)).toggleStyle(.checkbox) }
                Text("Independent of the sidebar bottom buttons. Hover the top edge in favicon-only mode. The strip stays open while editing or using a menu.")
                    .font(.system(size: 10)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }.padding(18).frame(width: 320)
        }
    }
}
