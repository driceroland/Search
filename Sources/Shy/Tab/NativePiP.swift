import WebKit

/// A playing video, into macOS's own picture in picture: the window Safari
/// uses, with the system's controls, its corners and its place across
/// spaces. Shy has no player of its own.
///
/// WebKit wants a user gesture for it. A script the app runs in a page
/// counts as one (WKWebView's evaluateJavaScript is run with the gesture
/// forced), so ⇧⌘P and leaving the tab or the app can ask; a page that
/// refuses anyway says so through `answer`.
enum NativePiP {
    /// WebKit lets a page into picture in picture on macOS only with a
    /// preference outside the public framework, off by default there (Safari
    /// turns it on). Asked for first, as Web.inspector asks, and a WebKit
    /// without it answers "refused".
    static func allow(_ preferences: WKPreferences) {
        let set = NSSelectorFromString("_setAllowsPictureInPictureMediaPlayback:")
        guard preferences.responds(to: set) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(preferences.method(for: set), to: Setter.self)(preferences, set, true)
    }

    /// The largest video playing, into picture in picture. `toggle`: one
    /// already there comes back instead. Answers "in", "out", "none" (no
    /// video playing) or "refused".
    static func script(toggle: Bool) -> String {
        """
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
          var best = null, area = 0;
          for (var j = 0; j < videos.length; j++) {
            var w = videos[j];
            if (w.paused || w.ended || w.readyState < 2) continue;
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
    static let off = Scripts.load("native-pip-off")
}

/// Sites with a player worth following into picture in picture.
///
/// Anywhere else, a playing video is as likely to be a background as a film,
/// and the difference isn't something a script can tell from the outside. So
/// the list is of places people go to watch, and the shortcut covers the rest.
enum Players {
    /// A host suffix, and for a few shops that also stream, the path that
    /// separates the film from the product page.
    private static let known: [(host: String, path: String?)] = [
        ("youtube.com", nil), ("youtu.be", nil), ("netflix.com", nil),
        ("primevideo.com", nil), ("amazon.com", "/gp/video"), ("amazon.fr", "/gp/video"),
        ("amazon.co.uk", "/gp/video"), ("amazon.de", "/gp/video"),
        ("disneyplus.com", nil), ("tv.apple.com", nil), ("twitch.tv", nil),
        ("vimeo.com", nil), ("dailymotion.com", nil), ("max.com", nil), ("hbomax.com", nil),
        ("canalplus.com", nil), ("mycanal.fr", nil), ("arte.tv", nil), ("france.tv", nil),
        ("tf1.fr", nil), ("6play.fr", nil), ("crunchyroll.com", nil), ("plex.tv", nil),
        ("peacocktv.com", nil), ("hulu.com", nil), ("paramountplus.com", nil),
        ("molotov.tv", nil), ("ocs.fr", nil), ("mubi.com", nil), ("criterionchannel.com", nil),
        ("ted.com", nil), ("nebula.tv", nil), ("curiositystream.com", nil),
    ]

    /// Hosts a test run's bench counts as players' (see `player` in
    /// Bench.swift). Empty everywhere else.
    static var benchHosts: Set<String> = []

    static func knows(_ url: URL?) -> Bool {
        guard let url, let host = url.host()?.lowercased() else { return false }
        if benchHosts.contains(host) { return true }
        let path = url.path().lowercased()
        return known.contains { entry in
            guard host == entry.host || host.hasSuffix("." + entry.host) else { return false }
            guard let needle = entry.path else { return true }
            return path.hasPrefix(needle)
        }
    }
}

/// Sites whose videos never float out on their own: the site card's Don't
/// Picture in Picture Here (#267). Only switching tabs or apps is held back; ⇧⌘P
/// still sends one by hand. Kept by host, as a site's sound is, and
/// forgotten with the other site choices (Browser.forgetCaptureChoices).
enum Grounded {
    static let prefix = "nofloat."

    static func holds(_ host: String, in profile: UUID) -> Bool {
        Store.settings.bool(forKey: SiteMemory.key(prefix, host, profile))
    }

    /// Off keeps nothing, as Autoplay's does.
    static func set(_ on: Bool, for host: String, in profile: UUID) {
        if on {
            Store.settings.set(true, forKey: SiteMemory.key(prefix, host, profile))
        } else {
            Store.settings.removeObject(forKey: SiteMemory.key(prefix, host, profile))
        }
    }
}
