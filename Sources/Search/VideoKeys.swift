// Space and the arrow keys on a video's own controls, as in Chrome and
// Firefox: once a video with the browser's controls has been clicked, Space
// plays or pauses it and ← → go five seconds back or on (idea 1079).
//
// WebKit's controls take Space only while the video fills the screen; in the
// page the keys reach the page and do nothing, in Safari too. Players a site
// draws itself (YouTube's, Vimeo's) handle their own keys and are left alone:
// only a <video> or <audio> showing the browser's controls, holding the focus,
// and a key the page left unused, with no ⌘, ⌃ or ⌥.
//
// On unless turned off in Settings › Videos. Done in Search's own world, which
// sees the page's events but none of its scripts.

enum VideoKeys {
    /// Settings › Videos › Space and arrow keys control videos.
    @MainActor static var on = false

    /// For a page already up when it is turned off.
    static let off = "window.__searchVideoKeysOff = true;"

    static let script = #"""
    (() => {
      window.__searchVideoKeysOff = false;
      if (window.__searchVideoKeys) return;
      window.__searchVideoKeys = true;
      window.addEventListener('keydown', (e) => {
        if (window.__searchVideoKeysOff || e.defaultPrevented || e.metaKey || e.ctrlKey || e.altKey) return;
        const media = e.target;
        if (!(media instanceof HTMLMediaElement) || !media.controls) return;
        // Filling the screen, WebKit's controls take Space themselves.
        if (document.fullscreenElement || media.webkitDisplayingFullscreen) return;
        if (e.key === ' ' && !e.shiftKey) {
          if (media.paused || media.ended) media.play().catch(() => {}); else media.pause();
        } else if ((e.key === 'ArrowLeft' || e.key === 'ArrowRight') && !e.shiftKey && isFinite(media.duration)) {
          const to = media.currentTime + (e.key === 'ArrowRight' ? 5 : -5);
          media.currentTime = Math.max(0, Math.min(media.duration, to));
        } else return;
        e.preventDefault();
      });
    })();
    """#
}
