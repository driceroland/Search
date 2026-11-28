import Foundation
import WebKit

/// The floating video as macOS's own picture in picture, for whoever picks
/// it in Settings › General › The floating video (idea 376). Search's own
/// window (Float.swift) stays the default: it floats without a click and
/// keeps the page alive in it. This hands the playing video to WebKit's
/// picture in picture instead, the window Safari uses, with the system's
/// controls, its corners and its place across spaces.
///
/// WebKit wants a user gesture for it. A script the app runs in a page
/// counts as one (WKWebView's evaluateJavaScript is run with the gesture
/// forced), so ⇧⌘P and leaving the tab or the app can ask; a page that
/// refuses anyway says so through `answer`.
enum FloatStyle: String, CaseIterable, Identifiable {
    case search, system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .search: return "Search's window"
        case .system: return "Picture in picture"
        }
    }
}

enum NativePiP {
    /// Whether picture in picture is the choice (Prefs.floatStyle).
    static var chosen: Bool { Store.settings.string(forKey: "float.style") == FloatStyle.system.rawValue }

    /// WebKit lets a page into picture in picture on macOS only with a
    /// preference outside the public framework, off by default there (Safari
    /// turns it on). On only while picture in picture is the choice, so with
    /// Search's window nothing changes for any page; asked for first, as
    /// Web.inspector asks, and a WebKit without it answers "refused".
    static func allow(_ preferences: WKPreferences, on: Bool = chosen) {
        let set = NSSelectorFromString("_setAllowsPictureInPictureMediaPlayback:")
        guard preferences.responds(to: set) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(preferences.method(for: set), to: Setter.self)(preferences, set, on)
    }

    /// Every page there is, after the choice changed.
    @MainActor static func allowEverywhere() {
        for web in Web.pages.allObjects { allow(web.configuration.preferences) }
    }

    /// Tabs currently holding a video in macOS's picture in picture, and an
    /// App Nap activity token while at least one does. While the browser window
    /// sits behind another app and the PiP video is paused (no audio), macOS
    /// App Nap can throttle or suspend the background WebContent process, which
    /// leaves macOS's PiP panel on screen with unresponsive buttons.
    @MainActor private static let activeTabs = NSHashTable<Tab>.weakObjects()
    @MainActor private static var activity: NSObjectProtocol?
    @MainActor private static var sweep: Timer?

    @MainActor static func keepAwake(for tab: Tab, active: Bool) {
        if active {
            activeTabs.add(tab)
        } else {
            activeTabs.remove(tab)
        }
        settleActivity()
    }

    /// The activity held only while a tab still alive is in picture in
    /// picture. A weak table drops a freed tab by itself, with no call here,
    /// so this also runs on a timer while the activity is up.
    @MainActor private static func settleActivity() {
        let needed = !activeTabs.allObjects.isEmpty
        if needed, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep],
                reason: "Picture in Picture"
            )
            sweep = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
                MainActor.assumeIsolated { settleActivity() }
            }
        } else if !needed, let token = activity {
            activity = nil
            sweep?.invalidate()
            sweep = nil
            ProcessInfo.processInfo.endActivity(token)
        }
    }

    /// Whether WebKit currently detects window occlusion for `web`.
    @MainActor static func occlusionDetectionEnabled(_ web: WKWebView) -> Bool {
        let get = NSSelectorFromString("_windowOcclusionDetectionEnabled")
        guard web.responds(to: get) else { return false }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(web.method(for: get), to: Getter.self)(web, get)
    }

    /// Turn WebKit's window occlusion detection off while a page is in macOS's
    /// picture in picture so covering the browser window with another app does
    /// not demote or suspend a paused PiP page's WebContent process.
    @MainActor static func setOcclusionDetection(_ web: WKWebView, enabled: Bool) {
        let set = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        guard web.responds(to: set) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(web.method(for: set), to: Setter.self)(web, set, enabled)
    }

    /// The largest video playing, into picture in picture. `toggle`: one
    /// already there comes back instead. Answers "in", "out", "none" (no
    /// video playing) or "refused".
    static func script(toggle: Bool) -> String {
        // Leaving a tab or the app, only a video somebody watches (see
        // Isolate.real). ⇧⌘P takes any.
        (toggle ? "" : Isolate.real) + """
        (function () {
          var toggle = \(toggle ? "true" : "false");
          var videos = document.querySelectorAll('video');
          for (var i = 0; i < videos.length; i++) {
            var v = videos[i];
            if (v.webkitPresentationMode === 'picture-in-picture') {
              if (!toggle) return 'in';
              try { v.webkitSetPresentationMode('inline'); return 'out'; } catch (e) { return 'refused'; }
            }
          }
          // Paused by WebKit as the page went out of sight counts as
          // playing (see Isolate.watch).
          var unseen = window.__officeFloatUnseen || function () { return false; };
          var only = toggle ? null : window.__officeFloatOnly;
          window.__officeFloatOnly = null;
          var best = null, area = 0;
          for (var j = 0; j < videos.length; j++) {
            var w = videos[j];
            if ((w.paused && !unseen(w)) || w.ended || w.readyState < 2) continue;
            if (only && !only(w)) continue;
            var box = w.getBoundingClientRect();
            if (box.width * box.height >= area) { area = box.width * box.height; best = w; }
          }
          // By hand, a paused video can go too, as in Safari: the largest
          // one with a picture.
          if (!best && toggle) {
            for (var k = 0; k < videos.length; k++) {
              var u = videos[k];
              if (u.readyState < 2) continue;
              var b = u.getBoundingClientRect();
              if (b.width * b.height >= area) { area = b.width * b.height; best = u; }
            }
          }
          if (!best) return 'none';
          if (!best.webkitSupportsPresentationMode || !best.webkitSupportsPresentationMode('picture-in-picture')) return 'refused';
          try { best.webkitSetPresentationMode('picture-in-picture'); return 'in'; } catch (e) { return 'refused'; }
        })();
        """
    }

    /// Back into the page, whatever is in picture in picture there.
    static let off = """
    (function () {
      var videos = document.querySelectorAll('video'), out = false;
      for (var i = 0; i < videos.length; i++) {
        if (videos[i].webkitPresentationMode === 'picture-in-picture') {
          try { videos[i].webkitSetPresentationMode('inline'); out = true; } catch (e) {}
        }
      }
      return out ? 'out' : 'none';
    })();
    """
}
