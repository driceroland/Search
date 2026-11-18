import AppKit
import ObjectiveC
import WebKit

// The bench's `stage` (./demo): a probe's window put where ScreenCaptureKit
// can record it and nobody can see it — ordered in, far off every screen,
// the app shown again without coming forward. Test runs only.
//
// Three things AppKit would otherwise do to such a window, undone for the
// staged window alone, and only while it is staged:
//  - pull a titled window back onto a screen as it comes in
//    (constrainFrameRect:toScreen: leaves it where it was put);
//  - draw it as an inactive app's window, grey lights and all (the app is
//    never made active: that would take the Mac from whoever is using it);
//  - on macOS 26, lay its "this window is being shared" capsule over the
//    traffic lights of a window being recorded (a view of AppKit's own,
//    NSWindowSharingSessionRecipientIndicator, in the window's title bar).
// WebKit, which paints nothing it thinks nobody sees, is told each page is
// seen (as `picture` does).
//
// Tried with Tools/DemoCapture's selftest on a window of its own: off every
// screen, ScreenCaptureKit records it at 60 frames a second, main-thread
// drawing and Core Animation alike.

@MainActor
enum DemoStage {
    private(set) static weak var window: NSWindow?
    private static var looksActive = false
    private static var patched: Set<String> = []
    private static var timer: Timer?
    private static var ticks = 0
    /// Where the window was before, for `stage off`.
    private static var before: NSRect?

    static var staged: Bool { window != nil }

    /// Far off every screen: AppKit's points from the bottom-left of the main screen.
    static let away = NSPoint(x: -30000, y: -30000)

    static func put(_ window: NSWindow, size: NSSize, active: Bool) {
        guard Store.testing else { return }
        before = before ?? window.frame
        self.window = window
        looksActive = active
        patch(window)
        let frame = NSRect(origin: away, size: size)
        window.setFrame(frame, display: true)
        window.orderFront(nil)
        window.setFrame(frame, display: true)
        start()
        tick()
    }

    static func end() {
        timer?.invalidate()
        timer = nil
        looksActive = false
        window = nil
        before = nil
    }

    private static func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Each frame: the capsule hidden as soon as AppKit puts it up; now and
    /// then, every page told it is seen (new tabs, peeks, split panes).
    private static func tick() {
        guard let window, let frame = window.contentView?.superview else { return }
        ticks += 1
        for view in frame.subviews where view !== window.contentView { hideBadge(in: view) }
        if ticks % 15 == 1 { seen(in: frame) }
    }

    private static func hideBadge(in view: NSView) {
        if NSStringFromClass(type(of: view)).contains("SharingSessionRecipientIndicator") {
            if !view.isHidden { view.isHidden = true }
            return
        }
        view.subviews.forEach(hideBadge)
    }

    private static func seen(in view: NSView) {
        if let web = view as? WKWebView {
            let occlusion = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
            if web.responds(to: occlusion) {
                typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
                unsafeBitCast(web.method(for: occlusion), to: Setter.self)(web, occlusion, false)
            }
            return
        }
        view.subviews.forEach(seen)
    }

    /// The overrides, on the window's own class only and answering for the
    /// staged window only: any other window of that class gets AppKit's own.
    private static func patch(_ window: NSWindow) {
        guard let cls = object_getClass(window) else { return }
        let name = NSStringFromClass(cls)
        guard !patched.contains(name) else { return }
        patched.insert(name)
        let constrain = NSSelectorFromString("constrainFrameRect:toScreen:")
        if let method = class_getInstanceMethod(cls, constrain) {
            typealias F = @convention(c) (AnyObject, Selector, NSRect, NSScreen?) -> NSRect
            let original = unsafeBitCast(method_getImplementation(method), to: F.self)
            let block: @convention(block) (AnyObject, NSRect, NSScreen?) -> NSRect = { me, rect, screen in
                MainActor.assumeIsolated { me === DemoStage.window } ? rect : original(me, constrain, rect, screen)
            }
            replace(cls, constrain, method, imp_implementationWithBlock(block))
        }
        for selector in ["_hasActiveAppearance", "_hasActiveAppearanceIgnoringKeyFocus", "hasKeyAppearance", "hasMainAppearance"] {
            let sel = NSSelectorFromString(selector)
            guard let method = class_getInstanceMethod(cls, sel) else { continue }
            typealias F = @convention(c) (AnyObject, Selector) -> Bool
            let original = unsafeBitCast(method_getImplementation(method), to: F.self)
            let block: @convention(block) (AnyObject) -> Bool = { me in
                MainActor.assumeIsolated { DemoStage.looksActive && me === DemoStage.window } ? true : original(me, sel)
            }
            replace(cls, sel, method, imp_implementationWithBlock(block))
        }
    }

    private static func replace(_ cls: AnyClass, _ sel: Selector, _ method: Method, _ imp: IMP) {
        if !class_addMethod(cls, sel, imp, method_getTypeEncoding(method)) {
            if let own = class_getInstanceMethod(cls, sel) { method_setImplementation(own, imp) }
        }
    }

    /// Text typed into whatever has the window's keyboard: a field's or a
    /// text view's editor takes it as typing inserts it, a page as key
    /// events. One character every `every` seconds; `done` after the last.
    static func typeText(_ text: String, in window: NSWindow, every: Double, done: @escaping () -> Void) {
        let characters = Array(text)
        func next(_ index: Int) {
            guard index < characters.count else { done(); return }
            let character = String(characters[index])
            let responder = window.firstResponder
            if let editor = responder as? NSTextView {
                if character == "\n" { editor.doCommand(by: #selector(NSResponder.insertNewline(_:))) }
                else { editor.insertText(character, replacementRange: editor.selectedRange()) }
            } else {
                let view = (responder as? NSView) ?? window.contentView
                let (code, shift) = DemoStage.key(for: characters[index])
                for kind in [NSEvent.EventType.keyDown, .keyUp] {
                    guard let event = NSEvent.keyEvent(
                        with: kind, location: .zero, modifierFlags: shift ? [.shift] : [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, characters: character, charactersIgnoringModifiers: character,
                        isARepeat: false, keyCode: code
                    ) else { continue }
                    if kind == .keyDown { view?.keyDown(with: event) } else { view?.keyUp(with: event) }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + every) { next(index + 1) }
        }
        next(0)
    }

    /// A US keyboard's key for a character, and whether shift is held for it.
    static func key(for character: Character) -> (UInt16, Bool) {
        let plain: [Character: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
            "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
            "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
            "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
            ".": 47, "\t": 48, " ": 49, "`": 50, "\n": 36,
        ]
        let shifted: [Character: Character] = [
            "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
            "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
        ]
        if let code = plain[character] { return (code, false) }
        if let base = shifted[character], let code = plain[base] { return (code, true) }
        let lower = Character(character.lowercased())
        if lower != character, let code = plain[lower] { return (code, true) }
        return (49, false)
    }
}
