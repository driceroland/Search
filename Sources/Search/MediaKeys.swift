import WebKit

// A paused tab gives the media keys back (#512).
//
// As soon as a page plays sound, WebKit makes the app the Mac's Now Playing
// app: the play/pause keys, and a tap on AirPods, come here. It keeps that
// after the video is paused, for good, so a tab paused and forgotten took the
// keys from Spotify or Music until they played something again. WebKit has no
// setting for it, and muting the page as a whole doesn't change it (measured
// with the bench's `nowplaying`): what it goes by is the element's own
// `muted`. A muted element is never the Now Playing one, and with none left
// the Mac hands the keys back to the app before.
//
// So once a tab that played sound has been quiet for ten seconds, a script in
// Search's world mutes the media there that is paused, remembers which, and
// unmutes those when one of them plays again. Ten seconds, so the play/pause
// key pressed twice still resumes the video. The page reads the real value
// and hears the change, as it would any other; a page that muted something
// itself is never touched, and one that unmutes what Search muted keeps its
// answer, Search forgetting that element. While something plays, the keys are
// WebKit's to give, and stay here.
//
// Only what has played is muted: a player that never made a sound, or one on
// a page the tab has moved on to, was never the Now Playing one. Out of reach
// are a player kept inside a shadow root and one never put in the page (new
// Audio()): those keep the keys as before.
//
// What it costs: a site that saves its player's mute when it changes (Plyr
// does) saves it while Search holds it, and a tab closed then leaves the next
// visit's player muted. And a page that mutes what Search already holds can't
// be told from no change at all, so Search unmutes it when it plays.
//
// One timer a tab, started when its sound stops and gone once it has run, the
// sound starts again, or the page goes (see Tab.heard).

final class MediaKeys: NSObject, WKScriptMessageHandler {
    static let name = "officeMedia"

    /// How long a tab that played sound has to be quiet.
    static let wait: TimeInterval = 10

    /// The frames below the page's own that have played something: looked
    /// in too, an embedded player being a player. The newest few.
    private(set) var frames: [WKFrameInfo] = []

    /// Every frame, in Search's world: the page never sees it, and it sees
    /// the page's media and their events as they are.
    static let watch = """
    (function () {
      if (window.__officeMedia) return;
      // Played here at some point: only these were ever the Now Playing one.
      // Held: muted here, to be unmuted when they play.
      var played = new WeakSet(), held = new WeakSet(), watched = new WeakSet(), told = false;
      function plays(e) {
        // Only the element's own play counts: a page's synthetic 'play'
        // event neither marks it as played nor unmutes what Search holds.
        if (!e.isTrusted) return;
        var el = e.target;
        played.add(el);
        if (held.has(el)) { held.delete(el); el.muted = false; }
      }
      function changed(e) {
        // Unmuted by the page, or its controls, while held: theirs wins.
        if (held.has(e.target) && !e.target.muted) held.delete(e.target);
      }
      window.__officeMedia = function () {
        document.querySelectorAll('audio, video').forEach(function (el) {
          if (!el.paused || el.muted || held.has(el) || !played.has(el)) return;
          held.add(el);
          // Its own ears too: taken out of the page, or the page's listeners
          // wiped by document.open(), it still hears its play.
          if (!watched.has(el)) {
            watched.add(el);
            el.addEventListener('play', plays, true);
            el.addEventListener('volumechange', changed, true);
          }
          el.muted = true;
        });
      };
      document.addEventListener('play', function (e) {
        if (!e.isTrusted) return;
        plays(e);
        // A frame below the page says once that it plays, to be looked in.
        if (!told && window.top !== window) {
          told = true;
          var relay = window.webkit && webkit.messageHandlers && webkit.messageHandlers.officeMedia;
          if (relay) relay.postMessage('plays');
        }
      }, true);
      document.addEventListener('volumechange', changed, true);
    })();
    """

    /// What the timer runs, in the page and in each frame that played.
    static let hush = "window.__officeMedia && window.__officeMedia(); 0"

    weak var tab: Tab?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let frame = message.frameInfo
        guard !frame.isMainFrame else { return }
        MainActor.assumeIsolated {
            // This tab's page only: a controller can be shared.
            guard let web = tab?.built, web === message.webView else { return }
            // Each frame's document says it once.
            frames.append(frame)
            if frames.count > 8 { frames.removeFirst(frames.count - 8) }
        }
    }

    /// The page went: its frames with it.
    func forget() { frames = [] }
}
