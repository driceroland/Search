import Foundation

/// `document.fonts.ready` as Chrome has it. WebKit holds the promise until
/// the whole document has loaded, so a page that waits for its fonts before
/// showing itself (a common way to avoid a flash of fallback text) also
/// waits for every image and video below the fold. Chrome resolves it once
/// the fonts the page has asked for are in. This resolves it then too, and
/// never later than WebKit would.
///
/// On cure.no, which hides itself until its fonts are ready, a reload shows
/// the page at about 0.25 s instead of 0.65 s: its fonts are in at 0.13 s,
/// its last off-screen video at 0.65 s.
enum EarlyFonts {
    static let script = #"""
    (() => {
      const fonts = document.fonts;
      if (!fonts) return;
      const proto = Object.getPrototypeOf(fonts);
      const native = Object.getOwnPropertyDescriptor(proto, 'ready');
      if (!native || !native.get || !native.configurable) return;
      let early = null;
      const settled = () => new Promise(resolve => {
        const check = () => {
          // A style pass first, so fonts the first layout needs have
          // started loading and show in status.
          document.documentElement.getBoundingClientRect();
          if (fonts.status === 'loaded') resolve(fonts);
          else fonts.addEventListener('loadingdone', () => setTimeout(check), {once: true});
        };
        if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', () => setTimeout(check), {once: true});
        else setTimeout(check);
      });
      Object.defineProperty(proto, 'ready', {
        configurable: true,
        enumerable: native.enumerable,
        get() {
          const late = native.get.call(this);
          if (this !== fonts) return late;
          early ??= Promise.race([late, settled()]);
          return early;
        }
      });
    })();
    """#
}
