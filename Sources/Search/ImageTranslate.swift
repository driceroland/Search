import AppKit
import ImageIO
import NaturalLanguage
import Translation
import UniformTypeIdentifiers
import Vision
import WebKit

// A picture's words in your language: right-click, Translate Image.
//
// All of it on this Mac. Vision reads the text in the picture — the same
// reading Live Text does — and the Translation framework translates it, as it
// does pages (see Translate.swift). Each block of text is then painted over
// with the colour around it and written again, in the colour it was in, at
// the size that fits where it was. The page gets the new picture in place of
// the old, from Search's own world; the old one is kept, and Show Original
// Image puts it back.
//
// The picture itself is fetched again from where the page got it: with the
// site's cookies only when it comes from the page's own site, and never into
// the cache from a private tab. One the Mac can't fetch — a blob: the page
// made — is taken from the screen instead, as it is drawn.

enum ImageTranslate {
    /// A block of text found in the picture: its lines' words, and where they
    /// sit, in pixels, from the bottom left as Core Graphics counts.
    struct Block {
        var box: CGRect
        var lines: Int
        var lineHeight: CGFloat
        var text: String
        var centered: Bool
    }

    /// A picture to translate, and how to find its place in the page again.
    struct Job {
        let frame: WKFrameInfo?
        let mark: String
        let image: CGImage
        let type: UTType
        let blocks: [Block]
    }

    /// Bigger than this on its longer side, a picture is read and painted at
    /// this size: past it, text is legible anyway and the result gets heavy.
    static let largest = 4_096

    // MARK: - reading

    /// The text in the picture, a block at a time, top first.
    static func read(_ image: CGImage) async -> [Block] {
        await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            try? VNImageRequestHandler(cgImage: image).perform([request])
            let width = CGFloat(image.width), height = CGFloat(image.height)
            let lines: [(String, CGRect)] = (request.results ?? []).compactMap { observation in
                guard let best = observation.topCandidates(1).first, best.confidence > 0.3,
                      best.string.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) })
                else { return nil }
                let box = observation.boundingBox
                return (best.string, CGRect(x: box.minX * width, y: box.minY * height,
                                            width: box.width * width, height: box.height * height))
            }
            return group(lines, width: width)
        }.value
    }

    /// Lines that sit one under the other, the same size and overlapping, are
    /// one paragraph: translated together, so a sentence broken across lines
    /// is still one sentence.
    static func group(_ lines: [(String, CGRect)], width: CGFloat) -> [Block] {
        var blocks: [(texts: [String], boxes: [CGRect])] = []
        for (text, box) in lines.sorted(by: { $0.1.maxY > $1.1.maxY }) {
            if let at = blocks.lastIndex(where: { block in
                let last = block.boxes.last!
                let gap = last.minY - box.maxY
                let ratio = box.height / last.height
                return gap > -box.height * 0.3 && gap < last.height * 0.8
                    && ratio > 0.7 && ratio < 1.4
                    && box.minX < last.maxX && box.maxX > last.minX
            }) {
                blocks[at].texts.append(text)
                blocks[at].boxes.append(box)
            } else {
                blocks.append(([text], [box]))
            }
        }
        return blocks.map { texts, boxes in
            let union = boxes.dropFirst().reduce(boxes[0]) { $0.union($1) }
            // Centred when the lines' middles agree better than their starts —
            // or, for a line on its own, when it sits across the middle of
            // the picture, as a title or a sign does.
            let lefts = boxes.map(\.minX), middles = boxes.map(\.midX)
            let centered = boxes.count > 1
                ? spread(middles) < spread(lefts) * 0.5
                : abs(union.midX - width / 2) < width * 0.06
            return Block(box: union, lines: boxes.count, lineHeight: boxes.map(\.height).reduce(0, +) / CGFloat(boxes.count),
                         text: joined(texts), centered: centered)
        }
    }

    private static func spread(_ values: [CGFloat]) -> CGFloat {
        (values.max() ?? 0) - (values.min() ?? 0)
    }

    /// Lines as one text: with spaces where the language uses them, a word
    /// hyphenated across two lines made whole again.
    static func joined(_ lines: [String]) -> String {
        var whole = ""
        for line in lines {
            guard let first = line.unicodeScalars.first, let last = whole.unicodeScalars.last else { whole = line; continue }
            let wide = { (s: Unicode.Scalar) in s.properties.isIdeographic || (0x3040...0x30FF).contains(s.value) || (0xAC00...0xD7AF).contains(s.value) }
            if whole.hasSuffix("-"), CharacterSet.lowercaseLetters.contains(first) {
                whole.removeLast()
            } else if !(wide(last) && wide(first)) {
                whole += " "
            }
            whole += line
        }
        return whole
    }

    // MARK: - painting

    /// The picture again, each block covered and written anew. Nil when
    /// there is nowhere to draw.
    static func paint(_ image: CGImage, _ blocks: [Block], _ texts: [String?]) -> CGImage? {
        let width = image.width, height = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let row = context.bytesPerRow
        let bytes = data.bindMemory(to: UInt8.self, capacity: row * height)
        func pixel(_ x: Int, _ y: Int) -> SIMD3<Double> {
            let x = min(max(x, 0), width - 1), y = min(max(y, 0), height - 1)
            let at = (height - 1 - y) * row + x * 4
            return SIMD3(Double(bytes[at]), Double(bytes[at + 1]), Double(bytes[at + 2])) / 255
        }

        // Every colour is read before anything is painted: blocks that touch
        // would otherwise read each other's paint.
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let plans: [(Block, String, Look, CGRect)] = zip(blocks, texts).compactMap { block, text in
            guard let text, !text.isEmpty else { return nil }
            let pad = block.lineHeight * 0.18
            let box = block.box.insetBy(dx: -pad, dy: -pad).intersection(bounds).integral
            let around = ring(around: box, pixel)
            let ground = median(around)
            // Even enough behind the text that more of it can be painted.
            let even = around.allSatisfy { color in let d = color - ground; return (d * d).sum() < 0.01 }
            let (ink, weight) = ink(in: block.box, on: ground, pixel)
            return (block, text, Look(ground: color(ground), ink: color(ink), weight: weight, even: even), box)
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        for (block, text, look, box) in plans {
            let room = self.room(for: box, block, look, in: bounds)
            let (attributes, used) = fit(text, in: room, like: block, look)
            // The ground under what was there, and under what is written now.
            let left = block.centered ? room.midX - used.width / 2 : room.minX
            let written = CGRect(x: left, y: room.midY - used.height / 2, width: used.width, height: used.height)
            let cover = box.union(written.insetBy(dx: -block.lineHeight * 0.15, dy: 0)).intersection(bounds)
            look.ground.setFill()
            NSBezierPath(roundedRect: cover, xRadius: block.lineHeight * 0.12, yRadius: block.lineHeight * 0.12).fill()
            let at = CGRect(x: room.minX, y: room.minY + (room.height - used.height) / 2, width: room.width, height: used.height)
            (text as NSString).draw(with: at, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    /// How a block of text looks: what is behind it, its colour, how heavy.
    struct Look {
        let ground: NSColor
        let ink: NSColor
        let weight: NSFont.Weight
        let even: Bool
    }

    /// Where the translation may go. The original's place — or, for a line
    /// on its own over an even ground, wider, so that a translation longer
    /// than the original can stay one line, as a title or a label is.
    private static func room(for box: CGRect, _ block: Block, _ look: Look, in bounds: CGRect) -> CGRect {
        let inner = box.insetBy(dx: block.lineHeight * 0.1, dy: 0)
        guard block.lines == 1, look.even else { return inner }
        let margin = block.lineHeight * 0.4
        let widest = block.centered
            ? 2 * min(inner.midX - bounds.minX, bounds.maxX - inner.midX) - 2 * margin
            : bounds.maxX - inner.minX - margin
        let width = max(inner.width, min(widest, inner.width * 2.5))
        return CGRect(x: block.centered ? inner.midX - width / 2 : inner.minX, y: inner.minY, width: width, height: inner.height)
    }

    /// The pixels just outside a box: what is behind the text.
    private static func ring(around box: CGRect, _ pixel: (Int, Int) -> SIMD3<Double>) -> [SIMD3<Double>] {
        let left = Int(box.minX) - 2, right = Int(box.maxX) + 1, bottom = Int(box.minY) - 2, top = Int(box.maxY) + 1
        let step = max(1, Int(max(box.width, box.height)) / 120)
        var out: [SIMD3<Double>] = []
        for x in stride(from: left, through: right, by: step) { out += [pixel(x, bottom), pixel(x, top)] }
        for y in stride(from: bottom, through: top, by: step) { out += [pixel(left, y), pixel(right, y)] }
        return out
    }

    private static func median(_ colors: [SIMD3<Double>]) -> SIMD3<Double> {
        guard !colors.isEmpty else { return SIMD3(1, 1, 1) }
        func middle(_ channel: KeyPath<SIMD3<Double>, Double>) -> Double {
            let sorted = colors.map { $0[keyPath: channel] }.sorted()
            return sorted[sorted.count / 2]
        }
        return SIMD3(middle(\.x), middle(\.y), middle(\.z))
    }

    /// The text's own colour: the pixels in the box least like the ground.
    /// Too close to the ground to read, black or white instead, whichever
    /// stands out. And how heavy it is, from how much of the box the letters
    /// cover: about a quarter for regular text, a third and more for bold,
    /// in Latin letters and in Chinese alike.
    private static func ink(in box: CGRect, on ground: SIMD3<Double>, _ pixel: (Int, Int) -> SIMD3<Double>) -> (SIMD3<Double>, NSFont.Weight) {
        let step = max(1, Int(max(box.width, box.height)) / 200)
        var samples: [(Double, SIMD3<Double>)] = []
        for x in stride(from: Int(box.minX), to: Int(box.maxX), by: step) {
            for y in stride(from: Int(box.minY), to: Int(box.maxY), by: step) {
                let color = pixel(x, y)
                let distance = color - ground
                samples.append(((distance * distance).sum(), color))
            }
        }
        let covered = Double(samples.filter { $0.0 > 0.08 }.count) / Double(max(samples.count, 1))
        let weight: NSFont.Weight = covered < 0.29 ? .regular : covered < 0.38 ? .semibold : .bold
        samples.sort { $0.0 > $1.0 }
        let far = samples.prefix(max(1, samples.count / 10))
        if let strongest = far.first?.0, strongest > 0.04 {
            return (far.map(\.1).reduce(SIMD3(0, 0, 0), +) / Double(far.count), weight)
        }
        let light = 0.2126 * ground.x + 0.7152 * ground.y + 0.0722 * ground.z
        return (light > 0.5 ? SIMD3(0, 0, 0) : SIMD3(1, 1, 1), weight)
    }

    private static func color(_ c: SIMD3<Double>) -> NSColor {
        NSColor(srgbRed: c.x, green: c.y, blue: c.z, alpha: 1)
    }

    /// The translation at the largest size that fits its room: starting
    /// from the original's own size and stepping down until every line does.
    private static func fit(_ text: String, in room: CGRect, like block: Block, _ look: Look) -> ([NSAttributedString.Key: Any], CGRect) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.alignment = block.centered ? .center : .natural
        var size = block.lineHeight * 0.82
        while true {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size, weight: look.weight), .foregroundColor: look.ink, .paragraphStyle: style,
            ]
            let used = (text as NSString).boundingRect(
                with: CGSize(width: room.width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes
            )
            if used.height <= room.height * 1.05 || size <= 6 { return (attributes, used) }
            size *= 0.92
        }
    }

    /// PNG, unless the picture was a photograph to begin with.
    static func encode(_ image: CGImage, like type: UTType) -> (Data, String)? {
        let photo = type.conforms(to: .jpeg) || type.conforms(to: .heic)
        let out = photo ? UTType.jpeg : UTType.png
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, out.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, photo ? [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary : nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (data as Data, out.preferredMIMEType ?? "image/png")
    }

    // MARK: - fetching

    /// The picture's bytes, from where the page got them.
    @MainActor
    static func fetch(_ url: URL, for tab: Tab) async -> Data? {
        if url.scheme == "data" { return try? Data(contentsOf: url) }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        if let page = tab.address { request.setValue(page.absoluteString, forHTTPHeaderField: "Referer") }
        if let agent = tab.built?.value(forKey: "userAgent") as? String { request.setValue(agent, forHTTPHeaderField: "User-Agent") }
        // The site's own cookies, for a picture on the site's own domain — as
        // the page's own request carried them. None for another site's.
        if let host = url.host(), let page = tab.address?.host(), Vault.registrable(host) == Vault.registrable(page) {
            let cookies = await tab.store.httpCookieStore.allCookies().filter { matches($0, url) }
            for (name, value) in HTTPCookie.requestHeaderFields(with: cookies) { request.setValue(value, forHTTPHeaderField: name) }
        }
        let configuration: URLSessionConfiguration = tab.shy ? .ephemeral : .default
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              data.count < 40_000_000
        else { return nil }
        return data
    }

    private static func matches(_ cookie: HTTPCookie, _ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        if let expires = cookie.expiresDate, expires < Date() { return false }
        if cookie.isSecure, url.scheme != "https" { return false }
        let domain = cookie.domain.lowercased()
        let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        guard host == bare || host.hasSuffix("." + bare) else { return false }
        let path = url.path().isEmpty ? "/" : url.path()
        return path.hasPrefix(cookie.path)
    }

    /// Bytes as a picture, no larger than `largest`.
    static func picture(_ data: Data) -> (CGImage, UTType)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source).flatMap({ UTType($0 as String) })
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: largest,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return (image, type)
    }

    // MARK: - the page

    /// In Search's own world, in the picture's frame: which picture was
    /// right-clicked, the translated one put in its place, the original put
    /// back. The page sees a picture change and nothing else.
    static let script = """
    (function () {
      if (window.__officeImageText) return window.__officeImageText;
      var picked = new Map(), kept = window.__officeImageKept || (window.__officeImageKept = new WeakMap());
      var canvases = window.__officeImageCanvases || (window.__officeImageCanvases = new WeakMap());
      function put(el, name, value) { if (value === null) el.removeAttribute(name); else el.setAttribute(name, value); }
      var self = {
        // The picture just right-clicked, held under a mark until its
        // translation is ready: by then another may have been.
        pick: function () {
          var el = window.__officeImageLast;
          if (!el || !el.isConnected) return null;
          var mark = Math.random().toString(36).slice(2);
          picked.set(mark, el);
          var r = el.getBoundingClientRect();
          return { mark: mark, rect: [r.left, r.top, r.width, r.height] };
        },
        forget: function (mark) { picked.delete(mark); return true; },
        // As a source of the density it replaces, so it takes the same room:
        // a 2x picture swapped for a plain src would draw twice the size.
        // A page whose policy refuses data: pictures gets the original back,
        // and the translation drawn on a canvas in its place — pixels from
        // bytes, which no policy about addresses applies to.
        show: function (mark, data, pixels) {
          var el = picked.get(mark);
          picked.delete(mark);
          if (!el || !el.isConnected) return false;
          if (!kept.has(el)) {
            var picture = el.parentElement && el.parentElement.nodeName === 'PICTURE' ? el.parentElement : null;
            kept.set(el, {
              src: el.getAttribute('src'), srcset: el.getAttribute('srcset'), sizes: el.getAttribute('sizes'),
              sources: picture ? Array.prototype.map.call(picture.querySelectorAll('source'), function (s) { return [s, s.getAttribute('srcset')]; }) : []
            });
          }
          var was = kept.get(el);
          if (was.canvas) return draw(el, was, data);
          var density = el.naturalWidth ? pixels / el.naturalWidth : 1;
          was.sources.forEach(function (s) { s[0].removeAttribute('srcset'); });
          el.removeAttribute('sizes');
          el.setAttribute('srcset', data + ' ' + density + 'x');
          el.setAttribute('src', data);
          // A new src always ends in load or error; the timer is for a
          // page that stops either from arriving.
          return new Promise(function (resolve) {
            var timer = setTimeout(settled, 5000);
            function settled() {
              clearTimeout(timer);
              el.removeEventListener('load', settled); el.removeEventListener('error', settled);
              if (el.currentSrc === data && el.naturalWidth > 0) return resolve('image');
              back(el, was);
              resolve(draw(el, was, data));
            }
            el.addEventListener('load', settled); el.addEventListener('error', settled);
          });
        },
        restore: function () {
          var el = window.__officeImageLast, was = el && kept.get(el);
          if (!was) return false;
          if (was.canvas) { canvases.delete(was.canvas); was.canvas.remove(); el.style.display = was.display; }
          else back(el, was);
          kept.delete(el);
          return true;
        }
      };
      function back(el, was) {
        put(el, 'srcset', was.srcset); put(el, 'sizes', was.sizes); put(el, 'src', was.src);
        was.sources.forEach(function (s) { put(s[0], 'srcset', s[1]); });
      }
      function draw(el, was, data) {
        var comma = data.indexOf(','), raw = atob(data.slice(comma + 1)), bytes = new Uint8Array(raw.length);
        for (var i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
        return createImageBitmap(new Blob([bytes], { type: data.slice(5, data.indexOf(';')) })).then(function (bitmap) {
          var canvas = was.canvas || document.createElement('canvas');
          if (!was.canvas) {
            var r = el.getBoundingClientRect();
            canvas.className = el.className;
            canvas.style.width = r.width + 'px';
            canvas.style.height = r.height + 'px';
            canvas.setAttribute('role', 'img');
            if (el.alt) canvas.setAttribute('aria-label', el.alt);
            el.after(canvas);
            was.display = el.style.display;
            el.style.display = 'none';
            was.canvas = canvas;
            canvases.set(canvas, el);
          }
          canvas.width = bitmap.width; canvas.height = bitmap.height;
          canvas.getContext('2d').drawImage(bitmap, 0, 0);
          return 'canvas';
        }, function () { return false; });
      }
      window.__officeImageText = self;
      return self;
    })()
    """
}

extension Browser {
    /// Translate Image, from the picture's own menu.
    @MainActor
    func translateImage(at url: URL, in tab: Tab, frame: WKFrameInfo?) {
        guard #available(macOS 15, *) else { return announce("Translation needs macOS 15 or later") }
        guard let web = tab.built else { return }
        Task { @MainActor [weak self, weak tab] in
            guard let self, let tab else { return }
            guard let picked = try? await web.callAsyncJavaScript(
                "return (\(ImageTranslate.script)).pick()", in: frame, contentWorld: Web.world
            ) as? [String: Any], let mark = picked["mark"] as? String else { return }
            @MainActor func forget() { web.callAsyncJavaScript("return (\(ImageTranslate.script)).forget(mark)", arguments: ["mark": mark], in: frame, in: Web.world) { _ in } }

            announce("Reading the image…")
            var loaded = await ImageTranslate.fetch(url, for: tab).flatMap(ImageTranslate.picture)
            if loaded == nil, frame?.isMainFrame ?? true, let rect = picked["rect"] as? [Double], rect.count == 4 {
                loaded = await snapshot(of: rect, in: web).map { ($0, UTType.png) }
            }
            guard let (image, type) = loaded else {
                forget()
                return announce("Couldn't load that image")
            }
            let blocks = await ImageTranslate.read(image)
            guard !blocks.isEmpty else {
                forget()
                return announce("No text found in this image")
            }
            let target = Translate.target
            guard let source = Translate.language(of: blocks.map(\.text), declared: "") else {
                forget()
                return announce("Couldn't tell what language this image is in")
            }
            guard !Translate.same(source, target) else {
                forget()
                return announce("The text in this image is already in \(Translate.name(target))")
            }
            guard await LanguageAvailability().status(from: source, to: target) != .unsupported else {
                forget()
                return announce("This Mac can't translate \(Translate.name(source)) into \(Translate.name(target))")
            }
            let job = ImageTranslate.Job(frame: frame, mark: mark, image: image, type: type, blocks: blocks)
            translating = TranslationAsk(tab: tab.id, work: .image(job), source: source, target: target)
        }
    }

    /// Show Original Image: the picture just right-clicked, as the page had it.
    @MainActor
    func restoreImage(in tab: Tab, frame: WKFrameInfo?) {
        tab.built?.callAsyncJavaScript("return (\(ImageTranslate.script)).restore()", in: frame, in: Web.world) { _ in }
    }

    /// Translated and painted, then handed to the page.
    @available(macOS 15, *)
    @MainActor
    func translate(_ job: ImageTranslate.Job, on tab: Tab, with session: TranslationSession) async {
        announce("Translating the image…")
        let requests = job.blocks.enumerated().map {
            TranslationSession.Request(sourceText: $0.element.text, clientIdentifier: String($0.offset))
        }
        guard let answers = try? await session.translations(from: requests) else {
            return announce("Couldn't translate this image")
        }
        var texts = [String?](repeating: nil, count: job.blocks.count)
        for answer in answers {
            if let at = answer.clientIdentifier.flatMap(Int.init), at < texts.count { texts[at] = answer.targetText }
        }
        let image = job.image, blocks = job.blocks
        guard let (data, mime) = await Task.detached(priority: .userInitiated, operation: {
            ImageTranslate.paint(image, blocks, texts).flatMap { ImageTranslate.encode($0, like: job.type) }
        }).value, let web = tab.built else {
            return announce("Couldn't translate this image")
        }
        let shown = try? await web.callAsyncJavaScript(
            "return await (\(ImageTranslate.script)).show(mark, data, pixels)",
            arguments: ["mark": job.mark, "data": "data:\(mime);base64,\(data.base64EncodedString())", "pixels": image.width],
            in: job.frame, contentWorld: Web.world
        )
        announce(shown is String ? "Image translated" : "The image went away before it was translated")
    }

    /// What the page shows of a picture, when its bytes can't be had any
    /// other way. CSS pixels at the page's zoom.
    @MainActor
    private func snapshot(of rect: [Double], in web: WKWebView) async -> CGImage? {
        let zoom = web.pageZoom
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: rect[0] * zoom, y: rect[1] * zoom, width: rect[2] * zoom, height: rect[3] * zoom)
        guard configuration.rect.width >= 8, configuration.rect.height >= 8,
              let shot = try? await web.takeSnapshot(configuration: configuration)
        else { return nil }
        return shot.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
