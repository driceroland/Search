import NaturalLanguage
import SwiftUI
import Translation
import WebKit

// Translation: the page's words in your language, by the Mac itself.
//
// Apple's Translation framework runs on this Mac — what a page says is never
// sent anywhere to be translated. The first time a pair of languages is
// asked for, macOS offers to download it; that sheet is the system's own,
// which is why the work is started from SwiftUI's translationTask rather
// than from a session made here.
//
// Only text is ever written back, and only where it was read from — a text
// node, an attribute, the title: no markup goes into the page, so a
// translation can't add anything a page could run. The originals are kept,
// and the same key puts them back.
//
// A sentence split among a link and some bold is sent whole, so it is
// translated as the sentence it is, and each part of the answer goes back
// into the node it came from. When the answer can't be divided up again,
// the parts go one by one.
//
// A translated page stays translated: what it adds or changes afterwards —
// a comment thread, the next screenful of a feed — is translated as it comes.

enum Translate {
    /// About a long article's worth. A page with more than this is translated
    /// from the top down to here, and what it adds later counts towards it.
    static let limit = 200_000

    /// How many sentences go to the Mac at once. Small enough that the top of
    /// the page changes while the rest is still on its way.
    static let batch = 60

    /// What the page handed over: each piece of text with its place in the
    /// page's list, the pieces that make one sentence, and the mark that says
    /// which document they came from.
    struct Found {
        let token: String
        let declared: String
        let pieces: [(Int, String)]
        let units: [[Int]]

        init?(_ body: Any?) {
            guard let body = body as? [String: Any],
                  let token = body["token"] as? String,
                  let pieces = body["pieces"] as? [[Any]]
            else { return nil }
            self.token = token
            declared = body["lang"] as? String ?? ""
            self.pieces = pieces.compactMap { piece in
                guard piece.count == 2, let at = piece[0] as? Int, let text = piece[1] as? String else { return nil }
                return (at, text)
            }
            units = (body["units"] as? [[Any]] ?? []).map { $0.compactMap { $0 as? Int } }
            guard !self.pieces.isEmpty else { return nil }
        }
    }

    /// One thing to ask the Mac: a piece on its own, or a sentence of pieces.
    enum Job {
        case piece(Int)
        case sentence([Int])
    }

    /// In the page's order, so the top of it is done first. Each piece once.
    static func jobs(_ found: Found) -> [Job] {
        var starts: [Int: [Int]] = [:]
        var grouped = Set<Int>()
        for unit in found.units where unit.count > 1 {
            starts[unit[0]] = unit
            grouped.formUnion(unit)
        }
        var jobs: [Job] = []
        for (at, _) in found.pieces {
            if let unit = starts[at] { jobs.append(.sentence(unit)) }
            else if !grouped.contains(at) { jobs.append(.piece(at)) }
        }
        return jobs
    }

    /// The language you read: the first one in System Settings › Language & Region.
    static var target: Locale.Language {
        Locale.Language(identifier: Locale.preferredLanguages.first ?? "en")
    }

    /// What the page is written in, by reading it, and by what it says about
    /// itself only when the reading is unsure: plenty of pages declare the
    /// language of the template rather than of the words.
    static func language(of texts: [String], declared: String) -> Locale.Language? {
        var sample = ""
        for text in texts where sample.count < 5_000 { sample += text + "\n" }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        if let guess = recognizer.languageHypotheses(withMaximum: 1).first, guess.value > 0.5 {
            return Locale.Language(identifier: guess.key.rawValue)
        }
        return declared.isEmpty ? nil : Locale.Language(identifier: declared)
    }

    /// "French", in your own language.
    static func name(_ language: Locale.Language) -> String {
        Locale.current.localizedString(forIdentifier: language.minimalIdentifier) ?? language.minimalIdentifier
    }

    /// The same language, for this purpose: English is English, whichever
    /// country's. Chinese in two scripts is not.
    static func same(_ a: Locale.Language, _ b: Locale.Language) -> Bool {
        a.languageCode == b.languageCode && (a.script == nil || b.script == nil || a.script == b.script)
    }

    /// The sentence as one text, each piece inside a marker of its own:
    /// <b0>…</b0><b1>…</b1>. The Mac's translator keeps markers like these
    /// where the words they hold end up — attributes it drops — so the answer
    /// can be divided up again. Nil when a piece already has something that
    /// looks like a marker in it, which would make the answer ambiguous.
    static func marked(_ unit: [Int], _ raw: [Int: String]) -> String? {
        var whole = ""
        for (n, at) in unit.enumerated() {
            let text = raw[at] ?? ""
            guard !text.contains("<b"), !text.contains("</b") else { return nil }
            whole += "<b\(n)>\(text)</b\(n)>"
        }
        return whole
    }

    private static let marker = try! NSRegularExpression(pattern: #"<b(\d+)>(.*?)</b\1>"#, options: .dotMatchesLineSeparators)

    /// The translated sentence divided up again, piece by piece — or nil when
    /// it can't be: a marker lost or doubled. Words the translator left
    /// between two markers go with the piece before them.
    static func split(_ text: String, into unit: [Int]) -> [[Any]]? {
        let whole = text as NSString
        var parts = [String?](repeating: nil, count: unit.count)
        var last: Int?
        var lead = ""
        var from = 0
        for match in marker.matches(in: text, range: NSRange(location: 0, length: whole.length)) {
            let between = whole.substring(with: NSRange(location: from, length: match.range.location - from))
            if let last { parts[last]! += between } else { lead += between }
            guard let n = Int(whole.substring(with: match.range(at: 1))), n < unit.count, parts[n] == nil else { return nil }
            parts[n] = (last == nil ? lead : "") + whole.substring(with: match.range(at: 2))
            last = n
            from = match.range.location + match.range.length
        }
        guard let last, parts.allSatisfy({ $0 != nil }) else { return nil }
        parts[last]! += whole.substring(from: from)
        return unit.enumerated().map { [$0.element, parts[$0.offset]!, true] }
    }

    /// Some jobs, translated: [piece, text, exact] for each piece, where
    /// exact means the text already has its own spaces.
    @available(macOS 15, *)
    @MainActor
    static func run(_ jobs: ArraySlice<Job>, _ raw: [Int: String], with session: TranslationSession) async throws -> [[Any]] {
        func alone(_ at: Int) -> TranslationSession.Request {
            .init(sourceText: (raw[at] ?? "").trimmingCharacters(in: .whitespacesAndNewlines), clientIdentifier: "p\(at)")
        }
        var requests: [TranslationSession.Request] = []
        var sentences: [Int: [Int]] = [:]
        for (n, job) in jobs.enumerated() {
            switch job {
            case .piece(let at):
                requests.append(alone(at))
            case .sentence(let unit):
                if let text = marked(unit, raw) {
                    requests.append(.init(sourceText: text, clientIdentifier: "s\(n)"))
                    sentences[n] = unit
                } else {
                    requests += unit.map(alone)
                }
            }
        }
        var pairs: [[Any]] = []
        var again: [TranslationSession.Request] = []
        for answer in try await session.translations(from: requests) {
            guard let id = answer.clientIdentifier, let number = Int(id.dropFirst()) else { continue }
            if id.hasPrefix("p") {
                pairs.append([number, answer.targetText, false])
            } else if let unit = sentences[number] {
                if let divided = split(answer.targetText, into: unit) {
                    pairs += divided
                } else {
                    again += unit.map(alone)
                }
            }
        }
        if !again.isEmpty {
            for answer in try await session.translations(from: again) {
                guard let at = answer.clientIdentifier.flatMap({ Int($0.dropFirst()) }) else { continue }
                pairs.append([at, answer.targetText, false])
            }
        }
        return pairs
    }

    /// In Search's own world (see Web.world), where the page can neither see
    /// it nor reach it. Made once per document; the expression is the object.
    static let script = """
    (function () {
      if (window.__officeTranslate) return window.__officeTranslate;
      // Code, and what isn't text at all, is never read — nor anything that
      // says it isn't to be translated: the page's own notranslate and
      // translate="no" included.
      var skip = /^(SCRIPT|STYLE|NOSCRIPT|TEMPLATE|CODE|PRE|KBD|SAMP|VAR|SVG|MATH|IFRAME|CANVAS|OBJECT)$/;
      // What is typed into a field is yours; what the field says about itself
      // (its placeholder, its title) is the page's.
      var fields = /^(INPUT|TEXTAREA|SELECT)$/;
      // Text split among these is still one sentence.
      var inline = /^(A|ABBR|B|BDI|BDO|CITE|DATA|DEL|DFN|EM|FONT|I|INS|LABEL|MARK|Q|S|SMALL|SPAN|STRONG|SUB|SUP|TIME|U)$/;
      var said = ['placeholder', 'title', 'alt', 'aria-label'];
      var letters = /\\p{L}/u;
      var items = [], originals = [], written = [], nodes = new WeakMap(), sayers = new WeakMap();
      var token = null, limit = 0, total = 0, observer = null, waiting = [], timer = null;

      // A piece is a text node, one attribute of an element, or the title.
      function read(item) {
        return item.node ? item.node.nodeValue : item.el ? (item.el.getAttribute(item.attr) || '') : document.title;
      }
      function write(item, text) {
        if (item.node) item.node.nodeValue = text;
        else if (item.el) item.el.setAttribute(item.attr, text);
        else document.title = text;
      }
      function here(item) { return item.node ? item.node.isConnected : item.el ? item.el.isConnected : true; }
      function refused(el) {
        return skip.test(el.nodeName.toUpperCase()) || el.isContentEditable
          || el.getAttribute('translate') === 'no' || (el.classList && el.classList.contains('notranslate'));
      }
      function kept(el) {
        for (; el; el = el.parentElement) if (refused(el) || fields.test(el.nodeName.toUpperCase())) return true;
        return false;
      }

      function add(item, found) {
        var text = read(item);
        if (total >= limit || !letters.test(text)) return -1;
        var at = items.length;
        items.push(item); originals.push(text); written.push(null);
        total += text.length;
        found.pieces.push([at, text]);
        return at;
      }

      function sayings(el, found) {
        var had = sayers.get(el) || {};
        for (var i = 0; i < said.length; i++) {
          if (had[said[i]] !== undefined || !el.hasAttribute(said[i])) continue;
          var at = add({ el: el, attr: said[i] }, found);
          if (at >= 0) had[said[i]] = at;
        }
        sayers.set(el, had);
      }

      // Everything readable under root, in the page's order. Text that shares
      // a block — a paragraph, a heading, a list item — is one unit.
      function gather(root, found) {
        var unit = null, block;
        function take(node) {
          if (nodes.has(node)) return;
          var at = add({ node: node }, found);
          if (at < 0) return;
          nodes.set(node, at);
          var el = node.parentElement;
          while (el && el !== document.body && inline.test(el.nodeName.toUpperCase())) el = el.parentElement;
          if (!unit || el !== block) { block = el; unit = []; found.units.push(unit); }
          unit.push(at);
        }
        if (root.nodeType === 3) return take(root);
        if (root.nodeType !== 1) return;
        if (fields.test(root.nodeName.toUpperCase())) return sayings(root, found);
        if (refused(root)) return;
        sayings(root, found);
        var walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
          acceptNode: function (node) {
            if (node.nodeType === 3) return NodeFilter.FILTER_ACCEPT;
            if (fields.test(node.nodeName.toUpperCase())) { sayings(node, found); return NodeFilter.FILTER_REJECT; }
            if (refused(node)) return NodeFilter.FILTER_REJECT;
            sayings(node, found);
            return NodeFilter.FILTER_SKIP;
          }
        });
        for (var node = walker.nextNode(); node; node = walker.nextNode()) take(node);
      }

      // What the page adds or changes once it is translated, gathered for a
      // moment and then handed over in one go.
      function watch() {
        observer = new MutationObserver(function (records) {
          for (var r = 0; r < records.length; r++) {
            var record = records[r];
            if (record.type === 'characterData') {
              var node = record.target, at = nodes.get(node);
              if (at === undefined) { waiting.push({ root: node }); continue; }
              // Written here, or put back: nothing new.
              if (node.nodeValue === written[at] || node.nodeValue === originals[at]) continue;
              // The page's own change — a counter, a status line: what it says
              // now is what is translated.
              originals[at] = node.nodeValue; written[at] = null;
              waiting.push({ again: at });
            } else {
              for (var i = 0; i < record.addedNodes.length; i++) waiting.push({ root: record.addedNodes[i] });
            }
          }
          if (waiting.length && !timer) timer = setTimeout(flush, 400);
        });
        observer.observe(document.body || document.documentElement, { childList: true, subtree: true, characterData: true });
      }

      function flush() {
        timer = null;
        var list = waiting, found = { token: token, lang: '', pieces: [], units: [] };
        waiting = [];
        for (var i = 0; i < list.length && total < limit; i++) {
          var next = list[i];
          if (next.again !== undefined) {
            var text = originals[next.again];
            if (!here(items[next.again]) || !letters.test(text)) continue;
            total += text.length;
            found.pieces.push([next.again, text]);
            found.units.push([next.again]);
          } else if (next.root.isConnected && !kept(next.root.parentElement)) {
            gather(next.root, found);
          }
        }
        var relay = window.webkit && window.webkit.messageHandlers.officeTranslate;
        if (found.pieces.length && relay) relay.postMessage(found);
      }

      var self = {
        collect: function (cap) {
          self.restore();
          token = Math.random().toString(36).slice(2);
          limit = cap;
          var found = { token: token, lang: document.documentElement.lang || '', pieces: [], units: [] };
          add({ title: true }, found);
          gather(document.body || document.documentElement, found);
          watch();
          return found;
        },
        // [piece, text, exact]: written as text, where it was read from, with
        // its spaces kept unless it brings its own — and only while it still
        // says what it said when it was read: a page that has changed it
        // since has the last word.
        apply: function (mark, pairs) {
          if (!token || mark !== token) return 0;
          var done = 0;
          for (var i = 0; i < pairs.length; i++) {
            var at = pairs[i][0], item = items[at];
            if (!item || !here(item) || read(item) !== originals[at]) continue;
            var was = originals[at];
            var text = pairs[i][2] ? String(pairs[i][1])
              : was.match(/^\\s*/)[0] + String(pairs[i][1]) + was.match(/\\s*$/)[0];
            write(item, text); written[at] = text; done++;
          }
          return done;
        },
        restore: function () {
          if (observer) { observer.disconnect(); observer = null; }
          if (timer) { clearTimeout(timer); timer = null; }
          for (var i = 0; i < items.length; i++) {
            if (written[i] !== null && here(items[i]) && read(items[i]) === written[i]) write(items[i], originals[i]);
          }
          items = []; originals = []; written = []; waiting = [];
          nodes = new WeakMap(); sayers = new WeakMap();
          token = null; total = 0;
          return true;
        }
      };
      window.__officeTranslate = self;
      return self;
    })()
    """
}

/// A page or a picture, from one language into another. A new one each time
/// it is asked for, so asking again for the same pair still starts the work
/// again.
struct TranslationAsk: Equatable {
    enum Work {
        case page(Translate.Found)
        case image(ImageTranslate.Job)
    }

    let id = UUID()
    let tab: UUID
    let work: Work
    let source: Locale.Language
    let target: Locale.Language

    var isPage: Bool { if case .page = work { true } else { false } }

    static func == (a: TranslationAsk, b: TranslationAsk) -> Bool { a.id == b.id }
}

/// What a translated page adds later, from Search's own world: only its
/// script can post here, and only the page's main frame is heard.
final class TranslateRelay: NSObject, WKScriptMessageHandler {
    static let name = "officeTranslate"

    weak var tab: Tab?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let found = Translate.Found(message.body) else { return }
        MainActor.assumeIsolated {
            guard let tab, tab.translated, message.webView === tab.built else { return }
            tab.onMoreToTranslate?(tab, found)
        }
    }
}

extension Tab {
    /// The page's text, as its pieces, from Search's own world.
    @MainActor
    func collectForTranslation() async -> Translate.Found? {
        guard let web = built else { return nil }
        let answer = try? await web.callAsyncJavaScript(
            "return (\(Translate.script)).collect(limit)",
            arguments: ["limit": Translate.limit], contentWorld: Web.world
        )
        return Translate.Found(answer)
    }

    /// Passed as arguments, never spliced into the script: a translation is
    /// only ever a string.
    @MainActor
    func applyTranslation(token: String, _ pairs: [[Any]]) async {
        guard let web = built, !pairs.isEmpty else { return }
        _ = try? await web.callAsyncJavaScript(
            "return (\(Translate.script)).apply(token, pairs)",
            arguments: ["token": token, "pairs": pairs], contentWorld: Web.world
        )
    }

    /// The page's own words again, and nothing more followed.
    func untranslate() {
        translated = false
        built?.evaluateInSearch("window.__officeTranslate && window.__officeTranslate.restore()")
    }
}

extension Browser {
    /// ⇧⌘L. The page in your language, and back again.
    @MainActor
    func toggleTranslation() {
        guard let tab = active, !tab.isBlank else { return }
        // Turned off, it only ever puts a page back.
        guard prefs.translates || tab.translated else { return }
        if tab.translated || (translating?.tab == tab.id && translating?.isPage == true) {
            if translating?.tab == tab.id, translating?.isPage == true { translating = nil }
            tab.untranslate()
            return
        }
        guard #available(macOS 15, *) else {
            announce("Translation needs macOS 15 or later")
            return
        }
        Task { @MainActor [weak self, weak tab] in
            guard let self, let tab else { return }
            guard let found = await tab.collectForTranslation() else {
                return announce("Nothing to translate on this page")
            }
            let target = Translate.target
            guard let source = Translate.language(of: found.pieces.map(\.1), declared: found.declared) else {
                return announce("Couldn't tell what language this page is in")
            }
            guard !Translate.same(source, target) else {
                tab.untranslate()
                return announce("This page is already in \(Translate.name(target))")
            }
            guard await LanguageAvailability().status(from: source, to: target) != .unsupported else {
                tab.untranslate()
                return announce("This Mac can't translate \(Translate.name(source)) into \(Translate.name(target))")
            }
            guard tab.id == activeID else { return tab.untranslate() }
            translating = TranslationAsk(tab: tab.id, work: .page(found), source: source, target: target)
        }
    }

    /// The page, sentence by sentence, top first, until it is done or no
    /// longer wanted: turned off, or the tab gone somewhere else — or the
    /// picture, whole. Then, for as long as this session lasts, what
    /// translated pages in the same language add afterwards.
    @available(macOS 15, *)
    @MainActor
    func translate(_ ask: TranslationAsk, with session: TranslationSession) async {
        guard let tab = tabs.first(where: { $0.id == ask.tab }) else { return }
        let (feed, into) = AsyncStream<(UUID, Translate.Found)>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let mine = UUID()
        translationFeed = (mine, into)
        defer { if translationFeed?.owner == mine { translationFeed = nil } }

        let address = tab.address
        switch ask.work {
        case .image(let job):
            await translate(job, on: tab, with: session)
            if translating == ask { translating = nil }
        case .page(let found):
            guard await translate(found, ask, on: tab, address: address, with: session) else { return }
        }

        // A new request replaces this session, and ends this wait with it.
        for await (id, found) in feed {
            guard let tab = tabs.first(where: { $0.id == id }), tab.translated,
                  let from = tab.translatedFrom, Translate.same(from, ask.source)
            else { continue }
            try? await pass(found, on: tab, with: session) { !tab.translated } landed: {}
        }
    }

    /// The page's first pass. False when it went no further.
    @available(macOS 15, *)
    @MainActor
    private func translate(
        _ found: Translate.Found, _ ask: TranslationAsk, on tab: Tab, address: URL?, with session: TranslationSession
    ) async -> Bool {
        announce("Translating from \(Translate.name(ask.source))…")
        do {
            try await pass(found, on: tab, with: session) { [weak self] in
                self?.translating != ask || tab.address != address
            } landed: {
                tab.translated = true
                tab.translatedFrom = ask.source
            }
        } catch {
            guard translating == ask else { return false }
            translating = nil
            if !tab.translated { tab.untranslate() }
            // Nothing had changed yet: the download was turned down, or the
            // pair isn't there after all. Some of it had: the rest is left.
            announce(tab.translated ? "Couldn't translate the rest of this page" : "Couldn't translate this page")
            return false
        }
        guard translating == ask else { return false }
        translating = nil
        return true
    }

    @available(macOS 15, *)
    @MainActor
    private func pass(
        _ found: Translate.Found, on tab: Tab, with session: TranslationSession,
        stop: () -> Bool, landed: () -> Void
    ) async throws {
        let raw = Dictionary(found.pieces, uniquingKeysWith: { first, _ in first })
        let jobs = Translate.jobs(found)
        var at = 0
        while at < jobs.count {
            let end = min(at + Translate.batch, jobs.count)
            let pairs = try await Translate.run(jobs[at..<end], raw, with: session)
            guard !stop() else { return }
            await tab.applyTranslation(token: found.token, pairs)
            landed()
            at = end
        }
    }
}

/// View › Translate Page, only while Settings has translation on. Its own
/// view, so the menu follows the switch as it is flipped.
struct TranslateCommand: View {
    let browser: Browser
    @ObservedObject var prefs: Preferences

    var body: some View {
        if prefs.translates, #available(macOS 15, *) {
            Button("Translate Page") { browser.toggleTranslation() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
        }
    }
}

/// Where the Mac is asked, over the whole window: a translation's download
/// sheet needs a view to hang from. Before macOS 15, nothing.
struct Translating: ViewModifier {
    @ObservedObject var browser: Browser

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.modifier(TranslationTask(browser: browser))
        } else {
            content
        }
    }
}

@available(macOS 15, *)
private struct TranslationTask: ViewModifier {
    @ObservedObject var browser: Browser
    @State private var configuration: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .translationTask(configuration) { session in
                guard let ask = browser.translating else { return }
                await browser.translate(ask, with: session)
            }
            .onChange(of: browser.translating) { _, ask in
                guard let ask else { return }
                // The same pair again is the same configuration, which SwiftUI
                // wouldn't run twice: invalidated, it does.
                if var same = configuration, same.source == ask.source, same.target == ask.target {
                    same.invalidate()
                    configuration = same
                } else {
                    configuration = TranslationSession.Configuration(source: ask.source, target: ask.target)
                }
            }
    }
}
