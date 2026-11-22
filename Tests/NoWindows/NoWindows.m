#import "NoWindows.h"
#import <AppKit/AppKit.h>
#import <objc/runtime.h>

// The unit tests must never show anything on the person's screen. Many make
// real windows — Browser, its panels, popovers, sheets — and order them in;
// rather than ask every test to remember, every NSWindow of the test process
// is made fully transparent in the window server from the moment it exists.
//
// The window is otherwise untouched: it is on screen as far as AppKit knows
// (isVisible, frames, key and main status as before, and not occluded, see
// below), so the tests' geometry and focus checks keep working. Only its
// alpha changes, and -alphaValue answers 0 whatever the code set: AppKit
// itself sends -alphaValue on to the window server (on a deferred window's
// first ordering in, on becoming key), so answering the code with its own
// value would show the window.

static void (*NoWindowsRealSetAlpha)(id, SEL, CGFloat);

/// The window made fully transparent.
static void NoWindowsHide(NSWindow *window) {
    if (window.alphaValue != 0) NoWindowsRealSetAlpha(window, @selector(setAlphaValue:), 0);
}

/// Puts `block` in place of the implementation of `selector` on NSWindow,
/// handing it the original.
static void NoWindowsReplace(SEL selector, id (^make)(IMP original)) {
    Method method = class_getInstanceMethod([NSWindow class], selector);
    NSCAssert(method, @"NSWindow has no %@", NSStringFromSelector(selector));
    IMP original = method_getImplementation(method);
    method_setImplementation(method, imp_implementationWithBlock(make(original)));
}

// XCTest is looked up at run time, so plain `swift build` (which builds this
// target too) needs no XCTest to compile it.
@interface NoWindowsObserver : NSObject
@end

@implementation NoWindowsObserver
- (void)testBundleWillStart:(NSBundle *)testBundle {
    // Never the active app: the tests can't take focus from the person.
    [[NSApplication sharedApplication] setActivationPolicy:NSApplicationActivationPolicyProhibited];
}
@end

void NoWindowsInstall(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class window = [NSWindow class];
        NoWindowsRealSetAlpha = (void *)method_getImplementation(
            class_getInstanceMethod(window, @selector(setAlphaValue:)));

        // Whatever alpha the code asks for, a fade in included.
        NoWindowsReplace(@selector(setAlphaValue:), ^id(IMP original) {
            return ^(NSWindow *self, CGFloat alpha) {
                NoWindowsRealSetAlpha(self, @selector(setAlphaValue:), 0);
            };
        });

        // To the window server a transparent window is occluded, so WebKit
        // and the code that minds what's out of sight (a video floating
        // when its window can't be seen) would take it as hidden. It is on a
        // screen as far as the process can tell: so seen.
        NoWindowsReplace(@selector(occlusionState), ^id(IMP original) {
            return ^NSWindowOcclusionState(NSWindow *self) {
                NSWindowOcclusionState state = ((NSWindowOcclusionState (*)(id, SEL))original)(
                    self, @selector(occlusionState));
                if (!self.isVisible || self.isMiniaturized) return state;
                // Only where it would be seen: a window off every screen
                // stays occluded, as it always was.
                for (NSScreen *screen in NSScreen.screens) {
                    if (NSIntersectsRect(screen.frame, self.frame)) return state | NSWindowOcclusionStateVisible;
                }
                return state;
            };
        });

        // Transparent from birth, whichever way the window is made.
        NoWindowsReplace(@selector(initWithContentRect:styleMask:backing:defer:), ^id(IMP original) {
            return ^id(NSWindow *self, NSRect rect, NSWindowStyleMask style, NSBackingStoreType backing, BOOL defer) {
                NSWindow *made = ((id (*)(id, SEL, NSRect, NSWindowStyleMask, NSBackingStoreType, BOOL))original)(
                    self, @selector(initWithContentRect:styleMask:backing:defer:), rect, style, backing, defer);
                if (made) NoWindowsHide(made);
                return made;
            };
        });
        NoWindowsReplace(@selector(initWithContentRect:styleMask:backing:defer:screen:), ^id(IMP original) {
            return ^id(NSWindow *self, NSRect rect, NSWindowStyleMask style, NSBackingStoreType backing, BOOL defer, NSScreen *screen) {
                NSWindow *made = ((id (*)(id, SEL, NSRect, NSWindowStyleMask, NSBackingStoreType, BOOL, NSScreen *))original)(
                    self, @selector(initWithContentRect:styleMask:backing:defer:screen:), rect, style, backing, defer, screen);
                if (made) NoWindowsHide(made);
                return made;
            };
        });
        NoWindowsReplace(@selector(initWithCoder:), ^id(IMP original) {
            return ^id(NSWindow *self, NSCoder *coder) {
                NSWindow *made = ((id (*)(id, SEL, NSCoder *))original)(self, @selector(initWithCoder:), coder);
                if (made) NoWindowsHide(made);
                return made;
            };
        });

        // And again on every way in.
        NoWindowsReplace(@selector(orderWindow:relativeTo:), ^id(IMP original) {
            return ^(NSWindow *self, NSWindowOrderingMode mode, NSInteger other) {
                if (mode != NSWindowOut) NoWindowsHide(self);
                ((void (*)(id, SEL, NSWindowOrderingMode, NSInteger))original)(
                    self, @selector(orderWindow:relativeTo:), mode, other);
            };
        });
        SEL senders[] = { @selector(orderFront:), @selector(orderBack:), @selector(makeKeyAndOrderFront:) };
        for (size_t i = 0; i < sizeof senders / sizeof *senders; i++) {
            SEL selector = senders[i];
            NoWindowsReplace(selector, ^id(IMP original) {
                return ^(NSWindow *self, id sender) {
                    NoWindowsHide(self);
                    ((void (*)(id, SEL, id))original)(self, selector, sender);
                };
            });
        }
        NoWindowsReplace(@selector(orderFrontRegardless), ^id(IMP original) {
            return ^(NSWindow *self) {
                NoWindowsHide(self);
                ((void (*)(id, SEL))original)(self, @selector(orderFrontRegardless));
            };
        });
        NoWindowsReplace(@selector(setIsVisible:), ^id(IMP original) {
            return ^(NSWindow *self, BOOL visible) {
                if (visible) NoWindowsHide(self);
                ((void (*)(id, SEL, BOOL))original)(self, @selector(setIsVisible:), visible);
            };
        });
        NoWindowsReplace(@selector(addChildWindow:ordered:), ^id(IMP original) {
            return ^(NSWindow *self, NSWindow *child, NSWindowOrderingMode mode) {
                NoWindowsHide(child);
                ((void (*)(id, SEL, NSWindow *, NSWindowOrderingMode))original)(
                    self, @selector(addChildWindow:ordered:), child, mode);
            };
        });

        Protocol *observation = objc_getProtocol("XCTestObservation");
        id center = [NSClassFromString(@"XCTestObservationCenter") valueForKey:@"sharedTestObservationCenter"];
        if (observation && center) {
            class_addProtocol([NoWindowsObserver class], observation);
            static NoWindowsObserver *observer;
            observer = [NoWindowsObserver new];
            [center performSelector:@selector(addTestObserver:) withObject:observer];
        }
    });
}

@interface NoWindowsLoader : NSObject
@end

@implementation NoWindowsLoader
// When the test bundle is loaded, before any test class is looked at.
+ (void)load { NoWindowsInstall(); }
@end
