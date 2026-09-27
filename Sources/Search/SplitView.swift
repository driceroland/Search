import AppKit
import Combine
import SwiftUI

/// The page area. A pair keeps both tabs' existing WebViews in place, so
/// switching focus or moving the divider never rebuilds a page.
struct BrowserStage: View {
    @ObservedObject var browser: Browser
    var onMousePaneFocus: (Tab) -> Void = { _ in }
    @ObservedObject private var drag = TabDrag.shared
    @StateObject private var immersion = TabImmersionWatch()

    private let dividerWidth: CGFloat = 12

    var body: some View {
        GeometryReader { geometry in
            let _ = immersion.revision
            let size = geometry.size
            let split = browser.activeSplit
            let left = split.flatMap { tab($0.left) }
            let right = split.flatMap { tab($0.right) }
            let immersive = split.flatMap { pair in
                [pair.left, pair.right].compactMap(tab).first(where: \.immersed)
            }

            ZStack {
                if let split, let left, let right {
                    splitPages(split, left: left, right: right, immersive: immersive, size: size)
                } else if let active = browser.active {
                    pane(active, side: nil, split: false, width: size.width)
                        .id(active.id)
                } else {
                    Palette.ground
                }

                if let preview = drag.preview, preview.browserID == ObjectIdentifier(browser) {
                    SplitDropPreview(preview: preview, tabs: browser.tabs)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.ground)
            .coordinateSpace(name: "browser-stage")
            .animation(Motion.quick, value: drag.preview)
        }
        .onAppear { immersion.watch(browser.tabs) }
        .onChange(of: browser.tabs.map(\.id)) { _, _ in immersion.watch(browser.tabs) }
    }

    private func splitPages(
        _ split: TabSplit,
        left: Tab,
        right: Tab,
        immersive: Tab?,
        size: CGSize
    ) -> some View {
        let available = max(0, size.width - dividerWidth)
        let leftWidth = available * CGFloat(split.fraction)
        let rightWidth = available - leftWidth

        return HStack(spacing: 0) {
            pane(left, side: "Left", split: true,
                 width: immersive == nil ? leftWidth : (immersive?.id == left.id ? size.width : 0))
                .frame(width: immersive == nil ? leftWidth : (immersive?.id == left.id ? size.width : 0))
                .id(left.id)

            if immersive == nil {
                SplitDivider(browser: browser, split: split, stageWidth: size.width)
                    .frame(width: dividerWidth)
            }

            pane(right, side: "Right", split: true,
                 width: immersive == nil ? rightWidth : (immersive?.id == right.id ? size.width : 0))
                .frame(width: immersive == nil ? rightWidth : (immersive?.id == right.id ? size.width : 0))
                .id(right.id)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .overlay {
            PaneClickFocus(tabs: [left, right], onFocus: onMousePaneFocus)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func pane(_ tab: Tab, side: String?, split: Bool, width: CGFloat) -> some View {
        SplitPane(browser: browser, tab: tab, side: side, split: split,
                  width: width, onMousePaneFocus: onMousePaneFocus)
    }

    private func tab(_ id: Tab.ID) -> Tab? {
        browser.tabs.first { $0.id == id }
    }
}

/// Blank-to-page transitions, title and accessibility state belong to the
/// tab itself; observing it keeps each pane current without changing focus.
private struct SplitPane: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    let side: String?
    let split: Bool
    let width: CGFloat
    let onMousePaneFocus: (Tab) -> Void

    var body: some View {
        ZStack {
            if tab.isBlank {
                Palette.ground
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if split, browser.activeID != tab.id { onMousePaneFocus(tab) }
                    }
            } else {
                Page(tab: tab)
            }

            if browser.fieldShowing && browser.activeID == tab.id && browser.activeSplit != nil {
                Omnibox(browser: browser, over: !tab.isBlank)
                    .transition(.scale(scale: 0.97).combined(with: .opacity))
            }
        }
        .overlay {
            if browser.prefs.showsLinks, browser.activeID == tab.id {
                LinkBubble(status: browser.linkStatus)
            }
        }
        .overlay(alignment: .topTrailing) {
            if browser.finding, browser.activeID == tab.id {
                FindBar(browser: browser, availableWidth: width)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .clipped()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .topLeading) {
            if let asked = browser.suggesting, asked.tab == tab.id {
                AccountList(browser: browser, asked: asked)
                    .transition(.opacity)
            }
        }
        .overlay {
            if split {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(browser.activeID == tab.id ? 0.9 : 0), lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .background(Palette.ground)
        .background {
            if browser.prefs.splitView {
                SplitDropZone(browser: browser, tab: tab, kind: .stage)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(side.map { "\($0) pane, \(tab.label.isEmpty ? "New Tab" : tab.label)" } ?? tab.label)
        .accessibilityHint(split && browser.activeID != tab.id ? "Click to focus this pane" : "")
        .accessibilityAction(named: "Focus pane") {
            if split { onMousePaneFocus(tab) }
        }
        .clipped()
        .animation(Motion.quick, value: browser.suggesting)
    }
}

private struct SplitDropPreview: View {
    let preview: TabDrag.Preview
    let tabs: [Tab]

    private var target: Tab? { tabs.first { $0.id == preview.targetID } }

    var body: some View {
        HStack(spacing: 2) {
            half(title: preview.side == .left ? "Tab" : target?.label ?? "Page", proposed: preview.side == .left)
            half(title: preview.side == .right ? "Tab" : target?.label ?? "Page", proposed: preview.side == .right)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.ground.opacity(0.12))
    }

    private func half(title: String, proposed: Bool) -> some View {
        ZStack {
            Rectangle().fill(proposed ? Color.accentColor.opacity(0.11) : Palette.ground.opacity(0.42))
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(proposed ? Color.accentColor.opacity(0.7) : Palette.ink.opacity(0.12), lineWidth: proposed ? 2 : 1)
                .padding(6)
            Text(title.isEmpty ? "New Tab" : title)
                .font(.system(size: 13, weight: proposed ? .medium : .regular))
                .foregroundStyle(Palette.ink.opacity(proposed ? 0.78 : 0.48))
                .lineLimit(1)
                .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SplitDivider: View {
    @ObservedObject var browser: Browser
    let split: TabSplit
    let stageWidth: CGFloat

    @State private var dragging = false
    @State private var hovering = false
    @State private var grabOffset: CGFloat = 0
    @FocusState private var focused: Bool

    private let width: CGFloat = 12
    private let step = 0.05

    var body: some View {
        handle
            .gesture(resizeGesture)
            .focusable()
            .focused($focused)
            .onMoveCommand { direction in
                switch direction {
                case .left: adjust(-step)
                case .right: adjust(step)
                default: break
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Split view divider")
            .accessibilityValue("Left pane \(Int((split.fraction * 100).rounded())) percent")
            .accessibilityHint("Use the left and right arrow keys to resize the panes")
            .accessibilityAddTraits(.isButton)
            .accessibilityAdjustableAction { direction in
                adjust(direction == .increment ? step : -step)
            }
            .help("Drag to resize the panes")
    }

    private var handle: some View {
        Rectangle()
            .fill(Palette.ground.opacity(0.001))
            .overlay {
                Capsule()
                    .fill(dragging || hovering || focused ? Color.accentColor.opacity(0.9) : Palette.ink.opacity(0.18))
                    .frame(width: dragging || hovering || focused ? 2 : 1)
                    .padding(.vertical, 6)
            }
            .contentShape(Rectangle())
            .onHover { over in
                guard hovering != over else { return }
                hovering = over
                if over { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .onDisappear {
                if hovering { NSCursor.pop(); hovering = false }
            }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("browser-stage"))
            .onChanged { value in
                if !dragging {
                    let available = max(stageWidth - width, 1)
                    let center = available * CGFloat(split.fraction) + width / 2
                    grabOffset = value.startLocation.x - center
                    focused = true
                }
                dragging = true
                let available = max(stageWidth - width, 1)
                let center = value.location.x - grabOffset
                browser.setSplitFraction(split.id, fraction: Double((center - width / 2) / available))
            }
            .onEnded { _ in dragging = false; grabOffset = 0 }
    }

    private func adjust(_ amount: Double) {
        browser.setSplitFraction(split.id, fraction: split.fraction + amount)
    }
}

/// Observes AppKit's real hit target, leaving the click itself for WebKit.
/// Dialogs, find controls and the address field live outside the WKWebView and
/// therefore cannot change which pane owns the keyboard.
private struct PaneClickFocus: NSViewRepresentable {
    let tabs: [Tab]
    let onFocus: (Tab) -> Void

    func makeNSView(context: Context) -> ClickObserverView {
        let view = ClickObserverView()
        view.tabs = tabs
        view.onFocus = onFocus
        return view
    }

    func updateNSView(_ view: ClickObserverView, context: Context) {
        view.tabs = tabs
        view.onFocus = onFocus
    }

    static func dismantleNSView(_ view: ClickObserverView, coordinator: ()) {
        view.removeMonitor()
    }

    final class ClickObserverView: NSView {
        var tabs: [Tab] = []
        var onFocus: ((Tab) -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      let content = window.contentView
                else { return event }
                let contentPoint = content.convert(event.locationInWindow, from: nil)
                guard let hit = content.hitTest(contentPoint) else { return event }
                guard let tab = self.tabs.first(where: { tab in
                    guard let web = tab.built, web.window === window else { return false }
                    return hit === web || hit.isDescendant(of: web)
                }), let onFocus = self.onFocus else { return event }
                DispatchQueue.main.async { onFocus(tab) }
                return event
            }
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { removeMonitor() }
    }
}

/// A split stage holds two `Tab` reference objects. Watching their fullscreen
/// state directly is necessary because changes to either tab do not publish
/// through the Browser's tabs array.
@MainActor
private final class TabImmersionWatch: ObservableObject {
    @Published private(set) var revision = 0
    private var ids: [Tab.ID] = []
    private var subscriptions = Set<AnyCancellable>()

    func watch(_ tabs: [Tab]) {
        let next = tabs.map(\.id)
        guard next != ids else { return }
        ids = next
        subscriptions.removeAll()
        for tab in tabs {
            tab.$immersed
                .dropFirst()
                .sink { [weak self] _ in
                    DispatchQueue.main.async { self?.revision &+= 1 }
                }
                .store(in: &subscriptions)
        }
    }
}
