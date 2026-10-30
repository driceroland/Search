import AppKit
import SwiftUI

/// A tracking view below the tab's controls: it never takes a click or first
/// responder, unlike a popover that opens as soon as the pointer arrives.
struct TabHoverDetails: ViewModifier {
    let browser: Browser
    @ObservedObject var tab: Tab
    @ObservedObject private var details = SidebarDetailsPreferences.shared

    func body(content: Content) -> some View {
        content.background {
            TabHoverAnchor(browser: browser, tab: tab,
                           previews: details.showsPreviews, memory: details.showsMemory)
        }
    }
}

private struct TabHoverAnchor: NSViewRepresentable {
    let browser: Browser
    let tab: Tab
    let previews: Bool
    let memory: Bool

    func makeNSView(context: Context) -> TabHoverTrackingView { TabHoverTrackingView() }
    func updateNSView(_ view: TabHoverTrackingView, context: Context) {
        view.browser = browser
        view.tab = tab
        view.previews = previews
        view.memory = memory
        view.invalidateIfNeeded()
    }
    static func dismantleNSView(_ view: TabHoverTrackingView, coordinator: ()) { view.dismiss() }
}

@MainActor
private final class TabHoverTrackingView: NSView {
    weak var browser: Browser?
    weak var tab: Tab?
    var previews = false
    var memory = false
    private var tracking: NSTrackingArea?
    private var state = TabHoverRequestState()
    private var reveal: DispatchWorkItem?
    private var card: TabHoverCardModel?
    private var panel: TabHoverPanel?
    private var eventMonitor: Any?
    private static weak var showing: TabHoverTrackingView?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { dismiss() }
    }
    override func mouseEntered(with event: NSEvent) {
        guard previews || memory, let browser, let tab, !tab.isBlank,
              browser.editingTab == nil, browser.editingPin == nil else { return }
        dismiss()
        let request = state.begin(tabID: tab.id, address: tab.address)
        let work = DispatchWorkItem { [weak self, weak browser, weak tab] in
            guard let self, let browser, let tab, self.accepts(request, browser: browser, tab: tab),
                  self.window?.isKeyWindow == true else { return }
            self.present(tab: tab, browser: browser, request: request)
        }
        reveal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
    override func mouseExited(with event: NSEvent) { dismiss() }

    func invalidateIfNeeded() {
        guard let request = state.current else { return }
        guard previews || memory, let browser, let tab,
              accepts(request, browser: browser, tab: tab), browser.editingTab == nil, browser.editingPin == nil else {
            dismiss()
            return
        }
        if TabHoverRequestState.presentationChanged(shownPreviews: card?.previews, shownMemory: card?.memory, previews: previews, memory: memory) { dismiss() }
    }

    private func accepts(_ request: TabHoverRequestState.Request, browser: Browser, tab: Tab) -> Bool {
        state.accepts(request, tabID: tab.id, address: tab.address, stillPresent: browser.tabs.contains { $0 === tab })
    }

    private func present(tab: Tab, browser: Browser, request: TabHoverRequestState.Request) {
        Self.showing?.dismiss()
        Self.showing = self
        let model = TabHoverCardModel(tab: tab, previews: previews, memory: memory)
        card = model
        let height: CGFloat = (previews ? 164 : 0) + (memory ? 100 : 0) + 76
        let panel = TabHoverPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: height),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        panel.appearance = window?.effectiveAppearance
        panel.contentView = NSHostingView(rootView: TabHoverCard(model: model))
        let anchor = window?.convertToScreen(convert(bounds, to: nil)) ?? .zero
        let screen = window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1100, height: 800)
        let onRight = browser.prefs.sidebar && browser.prefs.sidePosition == .right
        var origin = NSPoint(x: onRight ? anchor.minX - 288 : anchor.maxX + 8, y: anchor.maxY - height)
        origin.x = min(screen.maxX - 288, max(screen.minX + 8, origin.x))
        origin.y = min(screen.maxY - height - 8, max(screen.minY + 8, origin.y))
        panel.setFrameOrigin(origin)
        if let window { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
        self.panel = panel
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown]) { [weak self] event in
            self?.dismiss()
            return event
        }
        if previews {
            // Tab.preview uses saved sleep pictures or an already-built view.
            // No global preview cache, especially for private tabs.
            tab.preview(width: 264) { [weak self, weak tab, weak browser, weak model] image in
                guard let self, let tab, let browser, let model,
                      self.accepts(request, browser: browser, tab: tab) else { return }
                model.image = image
            }
        }
    }

    func dismiss() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        reveal?.cancel()
        reveal = nil
        state.cancel()
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            panel.contentView = nil
        }
        panel = nil
        card = nil
        if Self.showing === self { Self.showing = nil }
    }
}

private final class TabHoverPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class TabHoverCardModel: ObservableObject {
    let tab: Tab
    let previews: Bool
    let memory: Bool
    @Published var image: NSImage?
    init(tab: Tab, previews: Bool, memory: Bool) {
        self.tab = tab
        self.previews = previews
        self.memory = memory
    }
}

private struct TabHoverCard: View {
    @ObservedObject var model: TabHoverCardModel
    @ObservedObject private var monitor = TabMemoryMonitor.shared
    private var tab: Tab { model.tab }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tab.label).font(.system(size: 12, weight: .semibold)).lineLimit(2)
            Text(tab.shy ? "Private tab" : (tab.address?.host() ?? "New tab"))
                .font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(1)
            if model.previews {
                Group {
                    if let image = model.image {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        ZStack {
                            Palette.wash
                            Image(systemName: tab.asleep ? "moon.zzz" : "photo")
                                .font(.system(size: 24)).foregroundStyle(Palette.muted)
                        }
                    }
                }
                .frame(width: 256, height: 156).clipped()
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            if model.memory {
                let reading = monitor.reading(for: tab)
                Divider()
                if tab.asleep {
                    Text("Sleeping").font(.system(size: 11, weight: .medium))
                    if let saved = reading.estimatedSavingsBytes {
                        Text("≈ \(SidebarMemoryText.bytes(saved)) saved").font(.system(size: 11))
                        Text("Estimate from this renderer before sleep; not measured system RAM freed.")
                            .font(.system(size: 9)).foregroundStyle(Palette.muted)
                    } else {
                        Text("RAM savings not measured").font(.system(size: 10)).foregroundStyle(Palette.muted)
                    }
                } else if reading.isSharedProcess {
                    Text("Shared WebKit process").font(.system(size: 11))
                    Text("RAM cannot be attributed to this tab alone.").font(.system(size: 9)).foregroundStyle(Palette.muted)
                } else {
                    Text("RAM: \(SidebarMemoryText.bytes(reading.bytes))").font(.system(size: 11))
                }
            }
        }
        .padding(12).frame(width: 280, alignment: .leading)
        .foregroundStyle(Palette.ink)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.hairline, lineWidth: 1))
    }
}

struct SidebarDetailsMenu: View {
    @ObservedObject private var details = SidebarDetailsPreferences.shared
    var body: some View {
        Toggle("Show Tab Previews", isOn: $details.showsPreviews)
        Toggle("Show RAM in Tab Previews", isOn: $details.showsMemory)
    }
}

/// One shared, throttled request even when several browser windows own a view.
@MainActor
private enum SidebarMemoryRefresh {
    static var last: Date = .distantPast
    static var pending = false
    static func update() async {
        guard !pending, Date().timeIntervalSince(last) >= 2 else { return }
        pending = true
        defer { pending = false; last = Date() }
        await TabMemoryMonitor.shared.refresh(tabs: Browsers.all.flatMap { $0.tabs + $0.parkedTabs })
    }
}

struct SidebarMemoryPolling: ViewModifier {
    @ObservedObject private var details = SidebarDetailsPreferences.shared
    func body(content: Content) -> some View {
        content.task(id: details.showsMemory) {
            guard details.showsMemory else { return }
            while !Task.isCancelled && details.showsMemory {
                await SidebarMemoryRefresh.update()
                do { try await Task.sleep(nanoseconds: 3_000_000_000) }
                catch { break }
            }
        }
    }
}
