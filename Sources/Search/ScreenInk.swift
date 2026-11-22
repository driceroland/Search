import AppKit
import SwiftUI

// "Draw on Screen": a presenter's marker. A clear sheet over the whole screen
// Search is on, and a small toolbar at its top centre: Pencil, Eraser, Clear
// All, Capture, Done. Both sit above the recording pill, so the ink shows in
// a screen share. Nothing is kept: Done (or Escape) throws the strokes away.

/// What the pencil does with the mouse.
enum InkTool { case pencil, eraser }

/// The toolbar's state, shared with its view.
@MainActor
final class InkModel: ObservableObject {
    @Published var tool: InkTool = .pencil
}

@MainActor
final class ScreenInk {
    static let shared = ScreenInk()

    private let model = InkModel()
    private var overlay: InkPanel?
    private var toolbar: InkToolbarPanel?

    /// Whether the overlay is up.
    var active: Bool { overlay != nil }

    func toggle() { active ? stop() : start() }

    /// Covers the screen Search is on and shows the toolbar.
    func start() {
        guard !active, !Store.testing else { return }
        let screen = (NSApp.keyWindow ?? NSApp.mainWindow)?.screen ?? NSScreen.main
        guard let screen else { return }
        model.tool = .pencil
        let overlay = InkPanel(frame: screen.frame, model: model)
        let toolbar = InkToolbarPanel(model: model, screen: screen, ink: self)
        self.overlay = overlay
        self.toolbar = toolbar
        overlay.makeKeyAndOrderFront(nil)
        toolbar.orderFrontRegardless()
        RecordingIndicator.shared.refreshMenu()
    }

    /// Closes both, and the strokes go with them.
    func stop() {
        guard active else { return }
        overlay?.orderOut(nil)
        toolbar?.orderOut(nil)
        overlay = nil
        toolbar = nil
        RecordingIndicator.shared.refreshMenu()
    }

    fileprivate func clear() { overlay?.ink.clear() }

    /// A screenshot of the whole screen with the ink on it, to the Desktop,
    /// then shown in Finder. The toolbar steps out of the picture meanwhile.
    fileprivate func capture() {
        guard let toolbar else { return }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Desktop")
        let file = desktop.appendingPathComponent("Search Capture \(format.string(from: Date())).png")
        toolbar.alphaValue = 0
        // A beat for the toolbar to leave the screen before the shot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            task.arguments = ["-x", file.path]
            task.terminationHandler = { _ in
                DispatchQueue.main.async {
                    self?.toolbar?.alphaValue = 1
                    if FileManager.default.fileExists(atPath: file.path) {
                        NSWorkspace.shared.activateFileViewerSelecting([file])
                    }
                }
            }
            do { try task.run() } catch { self?.toolbar?.alphaValue = 1 }
        }
    }
}

// MARK: - the sheet

/// Over everything but the toolbar. It does become key, for Escape.
private final class InkPanel: NSPanel {
    let ink: InkView

    init(frame: NSRect, model: InkModel) {
        ink = InkView(frame: NSRect(origin: .zero, size: frame.size), model: model)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        // Above the pill (which rides at its window's level or the status bar's).
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
        contentView = ink
        initialFirstResponder = ink
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        super.makeKeyAndOrderFront(sender)
        makeFirstResponder(ink)
    }
}

/// The strokes, and the mouse that makes and removes them.
private final class InkView: NSView {
    private let model: InkModel
    private var strokes: [[NSPoint]] = []

    init(frame: NSRect, model: InkModel) {
        self.model = model
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    func clear() { strokes.removeAll(); needsDisplay = true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            MainActor.assumeIsolated { ScreenInk.shared.stop() }
        } else {
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        MainActor.assumeIsolated {
            if model.tool == .pencil { strokes.append([point]); needsDisplay = true } else { erase(at: point) }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        MainActor.assumeIsolated {
            if model.tool == .pencil {
                guard !strokes.isEmpty else { return }
                strokes[strokes.count - 1].append(point)
                needsDisplay = true
            } else {
                erase(at: point)
            }
        }
    }

    /// Takes away every whole stroke that passes within a brush's reach.
    private func erase(at point: NSPoint) {
        let reach: CGFloat = 10
        let before = strokes.count
        strokes.removeAll { stroke in
            if stroke.count == 1 { return hypot(stroke[0].x - point.x, stroke[0].y - point.y) <= reach }
            return zip(stroke, stroke.dropFirst()).contains { distance(from: point, to: $0, $1) <= reach }
        }
        if strokes.count != before { needsDisplay = true }
    }

    /// How far a point is from the segment a–b.
    private func distance(from p: NSPoint, to a: NSPoint, _ b: NSPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let length2 = dx * dx + dy * dy
        guard length2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemRed.setStroke()
        for stroke in strokes {
            let path = NSBezierPath()
            path.lineWidth = 4
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            if stroke.count == 1 {
                // A tap is a dot.
                path.appendOval(in: NSRect(x: stroke[0].x - 2, y: stroke[0].y - 2, width: 4, height: 4))
                NSColor.systemRed.setFill()
                path.fill()
                continue
            }
            // Smooth: curves through the midpoints, the points as controls.
            path.move(to: stroke[0])
            for i in 1..<stroke.count {
                let mid = NSPoint(x: (stroke[i - 1].x + stroke[i].x) / 2, y: (stroke[i - 1].y + stroke[i].y) / 2)
                path.curve(to: mid, controlPoint1: stroke[i - 1], controlPoint2: stroke[i - 1])
            }
            path.line(to: stroke[stroke.count - 1])
            path.stroke()
        }
    }
}

// MARK: - the toolbar

/// Small, draggable by its background, never key; at the top centre.
private final class InkToolbarPanel: NSPanel {
    init(model: InkModel, screen: NSScreen, ink: ScreenInk) {
        let content = NSHostingView(rootView: InkToolbar(model: model, ink: ink))
        let size = content.fittingSize
        let area = screen.visibleFrame
        let origin = NSPoint(x: area.midX - size.width / 2, y: area.maxY - size.height - 12)
        super.init(contentRect: NSRect(origin: origin, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        contentView = content
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct InkToolbar: View {
    @ObservedObject var model: InkModel
    let ink: ScreenInk

    var body: some View {
        HStack(spacing: 4) {
            button("pencil", "Pencil", selected: model.tool == .pencil) { model.tool = .pencil }
            button("eraser", "Eraser", selected: model.tool == .eraser) { model.tool = .eraser }
            button("trash", "Clear All") { ink.clear() }
            button("camera", "Capture") { ink.capture() }
            button("xmark", "Done") { ink.stop() }
        }
        .padding(6)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .fixedSize()
        .padding(8) // room for the shadow
    }

    /// One icon; the selected tool is inked in, as Stop is on the pill.
    private func button(_ symbol: String, _ tip: String, selected: Bool = false,
                        _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(selected ? Palette.ground : Palette.ink)
                .frame(width: 30, height: 26)
                .background(selected ? Palette.ink : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tip)
        .accessibilityLabel(tip)
    }
}
