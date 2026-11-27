import Foundation

/// A picture opened in a tab of its own (Open Image in New Tab, or an image's
/// address) sat on the page's white, glaring beside a dark interface. As in
/// Safari and Chrome it gets a neutral dark grey instead; WebKit already
/// centres it and fits it to the window. No setting. Only a document that is
/// itself an image: a page that has pictures in it is left alone. A
/// stylesheet added before the document has a body, so the white is never
/// drawn first.
enum ImageBackdrop {
    /// The grey behind the picture.
    static let colour = "#1c1c1e"

    static let script = """
    (() => {
      try {
        if (!/^image\\//i.test(document.contentType || "")) return;
        const sheet = new CSSStyleSheet();
        sheet.replaceSync("html, body { background: \(colour) !important; }");
        document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
      } catch (_) {}
    })();
    """
}
