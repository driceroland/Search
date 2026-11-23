import AppKit
import ObjectiveC

// Scroll bars that fade away when nothing is scrolling, even with System
// Settings › Appearance › Show scroll bars set to Always, or Automatically
// with a mouse plugged in.
//
// Off unless turned on in Settings › Appearance › Window. WebKit draws a
// page's scroll bars in the style AppKit prefers, and asks again when AppKit
// says the style has changed: answered "overlay" for Search alone, pages get
// the Mac's own thin bars, over the page instead of beside it, that come up
// as it scrolls and fade out once it stops. The same goes for Search's own
// lists. Off, the Mac's answer is given as it always was.

@MainActor
enum Scrollbars {
    /// Settings › Appearance › Window › Hide scroll bars until you scroll.
    static var fade = false {
        didSet {
            guard fade != oldValue else { return }
            overlay = fade
            if fade { install() }
            // WebKit hears this and tells every page's process (see
            // WebProcessPool's scroller style observer); a page already up
            // changes at once.
            NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        }
    }

    private static var installed = false
    /// `fade`, for AppKit to read from whichever thread asks.
    nonisolated(unsafe) private static var overlay = false

    /// Once, the first time it is turned on: AppKit's answer, looked at first.
    private static func install() {
        guard !installed else { return }
        let pick = #selector(getter: NSScroller.preferredScrollerStyle)
        guard let method = class_getClassMethod(NSScroller.self, pick) else { return }
        installed = true
        typealias Style = @convention(c) (AnyClass, Selector) -> Int
        let original = unsafeBitCast(method_getImplementation(method), to: Style.self)
        let block: @convention(block) (AnyClass) -> Int = { cls in
            overlay ? NSScroller.Style.overlay.rawValue : original(cls, pick)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }
}
