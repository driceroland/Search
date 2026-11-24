import WebKit

/// An image's true size, for Lighthouse's image audits and Performance's
/// Improve image delivery. WebKit gives an image it decodes smaller than
/// its file (one shown at 40×40 on a 1.75× screen from a 1200×1200 file)
/// a naturalWidth of that decoded size, 70, where Chrome reports the file's
/// 1200. WebKit shares that scaled decode with any image of the same URL,
/// so the probe asks for the file under a URL of its own, which WebKit
/// decodes whole and so tells the real size.
enum DeveloperImageNaturalSize {
    /// Each src's size, by loading it again off the document; at most
    /// 300, each given 1.5 s.
    static let script = """
        const out = {};
        await Promise.all(srcs.slice(0, 300).map((src) => new Promise((resolve) => {
            const probe = new Image();
            probe.onload = () => { if (probe.naturalWidth) out[src] = [probe.naturalWidth, probe.naturalHeight]; resolve(); };
            probe.onerror = () => resolve();
            setTimeout(resolve, 1500);
            probe.src = src + (src.includes("?") ? "&" : "?") + "perch-natural-size=" + Math.random().toString(36).slice(2);
        })));
        return out;
        """

    /// The images whose reported size is no bigger than they are shown at
    /// this pixel ratio: the ones WebKit may have scaled down.
    static func suspects(_ images: [[String: Any]], ratio: Double) -> [String] {
        var seen: Set<String> = []
        return images.compactMap { image in
            guard let src = image["src"] as? String, !src.isEmpty, !src.hasPrefix("data:"),
                  let nw = number(image["nw"]), let nh = number(image["nh"]), nw > 0, nh > 0,
                  let dw = number(image["dw"]), let dh = number(image["dh"]), dw > 0, dh > 0,
                  nw <= (dw * ratio).rounded(.up) + 1, nh <= (dh * ratio).rounded(.up) + 1,
                  seen.insert(src).inserted else { return nil }
            return src
        }
    }

    /// The images with each size the probe found larger put in its place.
    static func corrected(_ images: [[String: Any]], sizes: [String: (Double, Double)]) -> [[String: Any]] {
        images.map { image in
            guard let src = image["src"] as? String, let size = sizes[src],
                  let nw = number(image["nw"]), let nh = number(image["nh"]),
                  size.0 * size.1 > nw * nh else { return image }
            var image = image
            image["nw"] = size.0
            image["nh"] = size.1
            return image
        }
    }

    /// Probes the suspects in the page and returns the images corrected.
    @MainActor
    static func correct(_ images: [[String: Any]], ratio: Double, in web: WKWebView) async -> [[String: Any]] {
        let srcs = suspects(images, ratio: ratio)
        guard !srcs.isEmpty,
              let found = try? await web.callAsyncJavaScript(script, arguments: ["srcs": srcs], in: nil, contentWorld: .defaultClient)
                as? [String: Any] else { return images }
        var sizes: [String: (Double, Double)] = [:]
        for (src, value) in found {
            guard let pair = value as? [Any], pair.count == 2, let w = number(pair[0]), let h = number(pair[1]) else { continue }
            sizes[src] = (w, h)
        }
        return corrected(images, sizes: sizes)
    }

    private static func number(_ value: Any?) -> Double? { DeveloperProtocolValue.number(value) }
}
