import WebKit

enum GmailRendering {
    private static let styleID = "search-gmail-rendering"

    // WebKit paints an opaque black rectangle around Gmail's scaled, clipped
    // Gemini graphic. A compositing layer preserves its transparent surround.
    static let script = #"""
    (() => {
      if (location.protocol !== "https:" || location.hostname !== "mail.google.com") return;

      const install = () => {
        if (!document.documentElement || document.getElementById("\#(styleID)")) return;
        const style = document.createElement("style");
        style.id = "\#(styleID)";
        style.textContent = "#gb .HFMVod { transform: translateZ(0); }";
        (document.head || document.documentElement).appendChild(style);
      };

      if (!document.documentElement) {
        document.addEventListener("DOMContentLoaded", install, { once: true });
      } else {
        install();
      }
    })();
    """#

    @MainActor static let userScript = WKUserScript(
        source: script,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true,
        in: Web.world
    )
}
