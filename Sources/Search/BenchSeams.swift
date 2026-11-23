import AppKit
import ObjectiveC

/// The bench's `seam`, test runs only: a hidden probe's browser window told
/// it is in full screen, or in or out of sight, without AppKit moving it or
/// showing it. A hidden window never enters full screen and is never in
/// view, so the code that asks (the key monitor's Escape, idea 582; the
/// floating video waiting for the window to be out of sight, idea 470) is
/// reached only this way. The window's own class answers `styleMask` and
/// `occlusionState` as told, for that one window, and counts what reaches
/// it; every other window, and that one once let go, is answered as before.
/// (A subclass swapped in for the window's own broke SwiftUI's KVO on it.)
@MainActor
enum BenchSeams {
    /// Full screen as told, or AppKit's own (nil).
    nonisolated(unsafe) static var fullScreen: Bool?
    /// In sight as told, or AppKit's own (nil).
    nonisolated(unsafe) static var visible: Bool?
    /// Escape presses that went on to the window itself (sendEvent), where
    /// AppKit would take a window out of full screen on one.
    nonisolated(unsafe) static var escapes = 0
    /// Asks to leave or enter full screen, kept from AppKit while faked.
    nonisolated(unsafe) static var toggles = 0
    nonisolated(unsafe) private static weak var target: NSWindow?
    private static var installed: Set<ObjectIdentifier> = []

    static func fake(_ window: NSWindow) {
        target = window
        guard var cls: AnyClass = object_getClass(window) else { return }
        // KVO's class stands in front of the window's own.
        if NSStringFromClass(cls).hasPrefix("NSKVONotifying_"), let own = class_getSuperclass(cls) { cls = own }
        guard installed.insert(ObjectIdentifier(cls)).inserted else { return }

        typealias Getter = @convention(c) (AnyObject, Selector) -> UInt
        typealias Send = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        /// The class's own method put in place of what it had, or inherited.
        func override(_ sel: Selector, _ types: String, _ make: (IMP) -> Any) {
            guard let method = class_getInstanceMethod(cls, sel) else { return }
            let old = method_getImplementation(method)
            let imp = imp_implementationWithBlock(make(old))
            if !class_addMethod(cls, sel, imp, types) { method_setImplementation(method, imp) }
        }
        override(#selector(getter: NSWindow.styleMask), "Q@:") { old in
            { (me: AnyObject) -> UInt in
                var mask = NSWindow.StyleMask(rawValue: unsafeBitCast(old, to: Getter.self)(me, #selector(getter: NSWindow.styleMask)))
                if me === BenchSeams.target, let on = BenchSeams.fullScreen {
                    if on { mask.insert(.fullScreen) } else { mask.remove(.fullScreen) }
                }
                return mask.rawValue
            } as @convention(block) (AnyObject) -> UInt
        }
        override(#selector(getter: NSWindow.occlusionState), "Q@:") { old in
            { (me: AnyObject) -> UInt in
                var state = NSWindow.OcclusionState(rawValue: unsafeBitCast(old, to: Getter.self)(me, #selector(getter: NSWindow.occlusionState)))
                if me === BenchSeams.target, let on = BenchSeams.visible {
                    if on { state.insert(.visible) } else { state.remove(.visible) }
                }
                return state.rawValue
            } as @convention(block) (AnyObject) -> UInt
        }
        override(#selector(NSWindow.sendEvent(_:)), "v@:@") { old in
            { (me: AnyObject, event: NSEvent) in
                if me === BenchSeams.target, event.type == .keyDown, event.keyCode == 53 { BenchSeams.escapes += 1 }
                unsafeBitCast(old, to: Send.self)(me, #selector(NSWindow.sendEvent(_:)), event)
            } as @convention(block) (AnyObject, NSEvent) -> Void
        }
        // Never a real full screen from a probe told it is in one: it would
        // show the window.
        override(#selector(NSWindow.toggleFullScreen(_:)), "v@:@") { old in
            { (me: AnyObject, sender: AnyObject?) in
                if me === BenchSeams.target, BenchSeams.fullScreen != nil { BenchSeams.toggles += 1; return }
                unsafeBitCast(old, to: Send.self)(me, #selector(NSWindow.toggleFullScreen(_:)), sender)
            } as @convention(block) (AnyObject, AnyObject?) -> Void
        }
    }

    /// The window answered by AppKit again.
    static func restore(_ window: NSWindow) {
        if target === window { target = nil }
    }
}
