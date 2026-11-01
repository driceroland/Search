import AppKit
import NaturalLanguage
import SwiftUI
import Translation
import WebKit

// Translate Page, on this Mac only (idea 131).
//
// A script in Shy's own world — never the page's — reads the page's
// words: text, and the title, alt, placeholder and aria-label attributes,
// in the page, its open shadow roots and every frame, other sites' frames
// included (each frame gets the script of its own, see TranslateRelay).
// Code, fields, editable areas and whatever the page marks translate="no"
// or .notranslate are left alone. The words go to Apple's Translation
// framework, which runs its models on this Mac once a language is
// downloaded; nothing in this path touches the network. What comes back
// is put in the same text nodes and attributes: no element is added or
// removed, so pages that hold on to their nodes (React and the like) keep
// working, and Show Original puts back exactly what was there.
//
// Order: what is on screen first, in slices, each put back as it comes.
// A paragraph's inline text goes as one sentence, its links and bold
// marked with [1], [2]… so each piece goes back to its own node; when the
// translation loses a mark, the pieces go one by one instead. A string
// seen twice is translated once. Each block long enough to tell is
// checked for its own language: an English quote on a French page stays
// as it is, a German one is translated from German. What the page adds
// later (a MutationObserver) follows, until Show Original, the next page,
// or the tab going to sleep.
//
// Off unless switched on in Settings › General, and not there before
// macOS 15. A private tab can translate; nothing it does is remembered.

/// What a tab's translation is doing, for the sign beside its title.
struct TranslationMark: Equatable {
    enum Phase: Equatable {
        case working
        case done
        case failed(String)
    }
    /// The page's language, once known (a minimal identifier: "fr").
    var from: String?
    var to: String
    var phase: Phase

    var failed: Bool { if case .failed = phase { return true } else { return false } }
}

@MainActor
final class PageTranslator {
    /// The switch in Settings. Off unless asked for.
    static let key = "translate.pages"
    /// The languages translated as their pages open (Settings lists them).
    static let alwaysKey = "translate.always"

    /// macOS 15 has the framework's sessions; before, the feature isn't there.
    static var available: Bool {
        if #available(macOS 15, *) { return true }
        return false
    }
    static var enabled: Bool { available && Store.settings.bool(forKey: key) }

    /// Test runs only: a stand-in that marks each string instead of
    /// translating it, to test the page side without a language downloaded.
    static var fake: Bool { Store.testing && ProcessInfo.processInfo.environment["SHY_TRANSLATE_FAKE"] != nil }

    /// The language you read: the Mac's first preferred language.
    nonisolated static var reader: Locale.Language {
        Locale.Language(identifier: Locale.preferredLanguages.first ?? "en")
    }

    /// A language as Shy's menus name it ("French"): in English, as the
    /// rest of the interface is.
    nonisolated static func name(_ code: String) -> String {
        let english = Locale(identifier: "en")
        let language = Locale.Language(identifier: code)
        if language.script != nil, let full = english.localizedString(forIdentifier: code) { return full }
        return english.localizedString(forLanguageCode: language.languageCode?.identifier ?? code) ?? code
    }

    /// How a language is kept and compared: its code, with its script
    /// where it has one of its own (zh-Hans), never its region.
    nonisolated static func code(_ language: Locale.Language) -> String {
        let base = language.languageCode?.identifier ?? language.minimalIdentifier
        if let script = language.script?.identifier, base == "zh" || base == "sr" { return "\(base)-\(script)" }
        return base
    }

    nonisolated static func same(_ a: Locale.Language, _ b: Locale.Language) -> Bool {
        guard a.languageCode == b.languageCode else { return false }
        guard let x = a.script, let y = b.script else { return true }
        return x == y
    }

    // MARK: - starting and stopping

    private weak var tab: Tab?
    private weak var web: WKWebView?
    let target: Locale.Language
    private(set) var source: Locale.Language?
    private var task: Task<Void, Never>?
    private var jobs: AsyncStream<WKFrameInfo?>.Continuation?
    /// Every frame given the script, to put back on Show Original.
    private var frames: [WKFrameInfo] = []
    /// One per source language; nil where a language can't be done.
    private var sessions: [String: Translate?] = [:]
    private var leases: [AnyObject] = []
    /// What each string became, by language: a string seen twice is sent once.
    private var cache: [String: String] = [:]
    /// What the last run measured, for the bench.
    private(set) var report: [String: Any] = [:]
    private var done: (([String: Any]) -> Void)?

    private init(tab: Tab, target: Locale.Language) {
        self.tab = tab
        self.web = tab.built
        self.target = target
    }

    /// Translates the tab's page into `target`, and keeps translating what
    /// the page adds until Show Original or the page goes.
    @discardableResult
    static func start(_ tab: Tab, to target: Locale.Language = reader, done: (([String: Any]) -> Void)? = nil) -> PageTranslator? {
        tab.translator?.end(restore: true)
        guard enabled, tab.built != nil else {
            done?(["error": enabled ? "no page" : "off"])
            return nil
        }
        let translator = PageTranslator(tab: tab, target: target)
        translator.done = done
        tab.translator = translator
        tab.translation = TranslationMark(from: nil, to: code(target), phase: .working)
        let (stream, continuation) = AsyncStream<WKFrameInfo?>.makeStream()
        translator.jobs = continuation
        translator.task = Task { @MainActor in
            await translator.run(stream)
        }
        return translator
    }

    /// Show Original (restore), or the page going (no page to restore).
    func end(restore: Bool) {
        task?.cancel()
        jobs?.finish()
        jobs = nil
        for lease in leases { (lease as? Closable)?.close() }
        leases = []
        if let tab, tab.translator === self {
            tab.translator = nil
            if tab.translation?.failed != true { tab.translation = nil }
        }
        if restore, let web {
            let frames = self.frames
            Task { @MainActor in
                for frame in [nil] + frames.map(Optional.some) {
                    _ = try? await web.quietly(PageTranslator.restoreCall, asFunction: true, in: frame)
                }
            }
        }
        finish()
    }

    /// The page, or one of its frames, changed its words.
    func changed(in frame: WKFrameInfo?) { jobs?.yield(frame) }

    /// A frame that loaded while the page is translated, or after.
    func arrived(_ frame: WKFrameInfo) { jobs?.yield(frame) }

    private func finish() {
        if let done {
            self.done = nil
            done(report)
        }
    }

    // MARK: - the run

    private func run(_ stream: AsyncStream<WKFrameInfo?>) async {
        guard let web, let tab else { return }
        let start = Date()
        func ms() -> Int { Int(Date().timeIntervalSince(start) * 1000) }
        report = ["target": PageTranslator.code(target), "units": 0, "parts": 0, "requests": 0, "sent": 0,
                  "cached": 0, "applied": 0, "kept": 0, "chars": 0, "frames": 0, "rounds": 0, "languages": [String: Int]()]
        do {
            let first = try await collect(nil, injecting: true)
            report["collectMs"] = ms()
            let hint = try? await web.quietly("return document.documentElement.lang || ''", asFunction: true) as? String
            let sample = String(first.prefix(400).map(\.plain).joined(separator: "\n").prefix(4000))
            guard let from = PageTranslator.detect(sample, hint: hint) else {
                throw Failure("Shy couldn't tell which language this page is in")
            }
            source = from
            report["source"] = PageTranslator.code(from)
            tab.translation = TranslationMark(from: PageTranslator.code(from), to: PageTranslator.code(target), phase: .working)
            // The page's own language must be there to begin with: this is
            // where the download sheet comes up, or where "can't" is said.
            if !PageTranslator.same(from, target) {
                sessions[PageTranslator.code(from)] = try await session(from: from, main: true)
            }
            try await process(first, in: nil) { self.report["firstSliceMs"] = self.report["firstSliceMs"] ?? ms() }
            // Every frame that said it's there, other sites' included.
            for frame in tab.translateFrames {
                try await frameRound(frame)
            }
            report["fullMs"] = ms()
            if (report["applied"] as? Int ?? 0) == 0, PageTranslator.same(from, target) {
                throw Failure("This page is already in \(PageTranslator.name(PageTranslator.code(target)))")
            }
            tab.translation?.phase = .done
            finish()
            // Then whatever the page adds or changes, frame by frame.
            for await frame in stream {
                if Task.isCancelled { break }
                if let frame { try await frameRound(frame) } else { try await process(collect(nil), in: nil) }
                report["rounds"] = (report["rounds"] as? Int ?? 0) + 1
            }
        } catch is CancellationError {
            // Show Original, or the page went.
        } catch {
            guard tab.translator === self, !Task.isCancelled else { return }
            let message = (error as? Failure)?.message ?? PageTranslator.describe(error, from: source, to: target)
            report["error"] = message
            report["errorDetail"] = "\(error)"
            // The mark first: the sign says why as the run ends.
            tab.failTranslation(TranslationMark(from: source.map(PageTranslator.code), to: PageTranslator.code(target), phase: .failed(message)))
            end(restore: true)
        }
    }

    /// A frame's words: the script first, if it hasn't it yet. A frame
    /// that's gone is let go of quietly.
    private func frameRound(_ frame: WKFrameInfo) async throws {
        let units: [Unit]
        do {
            units = try await collect(frame, injecting: true)
        } catch {
            tab?.translateFrames.removeAll { $0 === frame }
            return
        }
        if !frames.contains(where: { $0 === frame }) {
            frames.append(frame)
            report["frames"] = frames.count
        }
        try await process(units, in: frame)
    }

    // MARK: - the page's words

    /// A run of a block's inline text, or one attribute: what the page
    /// script hands over. `parts` go back each to its own node; `fixed`
    /// ones (code, a number, a notranslate name) are only there so the
    /// sentence reads whole, and are never written.
    struct Unit {
        let id: Int
        let parts: [String]
        let gaps: [Bool]
        let fixed: [Bool]
        var plain: String {
            var out = ""
            for (index, part) in parts.enumerated() { out += (index > 0 && gaps[index] ? " " : "") + part }
            return out
        }
    }

    private func collect(_ frame: WKFrameInfo?, injecting: Bool = false) async throws -> [Unit] {
        guard let web else { return [] }
        let call = (injecting ? PageTranslator.script + ";\n" : "") + "return window.__shyTr ? __shyTr.collect() : []"
        let raw = try await web.quietly(call, asFunction: true, in: frame) as? [Any] ?? []
        return raw.compactMap { item in
            guard let row = item as? [Any], row.count == 4, let id = (row[0] as? NSNumber)?.intValue,
                  let parts = row[1] as? [String], let gaps = row[2] as? [Any], let fixed = row[3] as? [Any],
                  gaps.count == parts.count, fixed.count == parts.count, !parts.isEmpty else { return nil }
            return Unit(id: id, parts: parts, gaps: gaps.map { ($0 as? NSNumber)?.boolValue ?? false },
                        fixed: fixed.map { ($0 as? NSNumber)?.boolValue ?? false })
        }
    }

    /// Units in slices — a small one first, for what is on screen — each
    /// sorted by language, translated and put back before the next.
    private func process(_ units: [Unit], in frame: WKFrameInfo?, first: (() -> Void)? = nil) async throws {
        guard !units.isEmpty, let web else { return }
        report["units"] = (report["units"] as? Int ?? 0) + units.count
        report["parts"] = (report["parts"] as? Int ?? 0) + units.reduce(0) { $0 + $1.parts.count }
        report["chars"] = (report["chars"] as? Int ?? 0) + units.reduce(0) { $0 + $1.plain.count }
        var index = 0
        var size = 24
        while index < units.count {
            try Task.checkCancellation()
            var slice: [Unit] = []
            var chars = 0
            while index < units.count, slice.count < size, chars < (size > 24 ? 12000 : 3000) {
                slice.append(units[index]); chars += units[index].plain.count; index += 1
            }
            // The first slice small, for what is on screen; then fewer,
            // bigger trips to the page.
            size = 160
            let page = source.map(PageTranslator.code) ?? PageTranslator.code(target)
            let texts = slice.map(\.plain)
            let languages = await Task.detached(priority: .userInitiated) {
                PageTranslator.languages(of: texts, page: page)
            }.value
            try Task.checkCancellation()
            var out: [Int: [String]?] = [:]
            var counts = report["languages"] as? [String: Int] ?? [:]
            for language in Set(languages) {
                let group = slice.indices.filter { languages[$0] == language }.map { slice[$0] }
                counts[language, default: 0] += group.count
                guard let translate = try await translator(for: language) else {
                    for unit in group { out[unit.id] = .some(nil) }
                    report["kept"] = (report["kept"] as? Int ?? 0) + group.count
                    continue
                }
                let done = try await translateUnits(group, language: language, with: translate)
                for (unit, parts) in zip(group, done) { out[unit.id] = .some(parts) }
            }
            report["languages"] = counts
            let pairs: [[Any]] = slice.map { unit in
                [NSNumber(value: unit.id), (out[unit.id] ?? nil).map { $0 as Any } ?? NSNull()]
            }
            let applied = try await web.quietly("return window.__shyTr ? __shyTr.apply(pairs) : 0",
                                              asFunction: true, arguments: ["pairs": pairs], in: frame)
            report["applied"] = (report["applied"] as? Int ?? 0) + ((applied as? NSNumber)?.intValue ?? 0)
            first?()
        }
    }

    /// The session for a source language: nil for the reader's own and for
    /// one this Mac can't do. A language other than the page's own is only
    /// used when it is already on the Mac: no download sheet for a quote.
    private func translator(for code: String) async throws -> Translate? {
        let language = Locale.Language(identifier: code)
        if PageTranslator.same(language, target) { return nil }
        if let known = sessions[code] { return known }
        let made = try? await session(from: language, main: false)
        sessions[code] = .some(made)
        return made
    }

    /// Translates each unit: a run of several parts as one sentence with
    /// marks between its parts, put back in pieces; one whose marks don't
    /// come back intact, part by part.
    private func translateUnits(_ units: [Unit], language: String, with translate: Translate) async throws -> [[String]] {
        var wanted: [String] = []
        var joined: [Int: String] = [:]
        for (index, unit) in units.enumerated() {
            if unit.parts.count > 1, let line = PageTranslator.joined(unit.parts, gaps: unit.gaps) {
                joined[index] = line
                wanted.append(line)
            } else {
                for (part, fixed) in zip(unit.parts, unit.fixed) where !fixed { wanted.append(part) }
            }
        }
        var got = try await strings(wanted, language: language, with: translate)
        var results: [[String]?] = Array(repeating: nil, count: units.count)
        var again: [Int] = []
        for (index, unit) in units.enumerated() {
            if let line = joined[index] {
                if let back = got[line], let pieces = PageTranslator.split(back, count: unit.parts.count),
                   zip(pieces, zip(unit.parts, unit.fixed)).allSatisfy({ piece, part in part.1 || !PageTranslator.letters(part.0) || !piece.isEmpty }) {
                    results[index] = pieces
                } else {
                    again.append(index)
                }
            }
        }
        // Marks lost: the pieces one by one, still once each.
        if !again.isEmpty {
            report["unjoined"] = (report["unjoined"] as? Int ?? 0) + again.count
            let pieces = again.flatMap { index in zip(units[index].parts, units[index].fixed).filter { !$0.1 }.map(\.0) }
            got.merge(try await strings(pieces, language: language, with: translate)) { $1 }
        }
        for (index, unit) in units.enumerated() where results[index] == nil {
            results[index] = zip(unit.parts, unit.fixed).map { part, fixed in fixed ? part : (got[part] ?? part) }
        }
        return results.map { $0 ?? [] }
    }

    /// Each string translated once: from the cache, or in one request with
    /// the others not seen yet.
    private func strings(_ texts: [String], language: String, with translate: Translate) async throws -> [String: String] {
        var out: [String: String] = [:]
        var missing: [String] = []
        var seen = Set<String>()
        for text in texts {
            if let known = cache[language + "\u{1}" + text] {
                out[text] = known
                report["cached"] = (report["cached"] as? Int ?? 0) + 1
            } else if seen.insert(text).inserted {
                missing.append(text)
            } else {
                report["cached"] = (report["cached"] as? Int ?? 0) + 1
            }
        }
        guard !missing.isEmpty else { return out }
        report["requests"] = (report["requests"] as? Int ?? 0) + 1
        report["sent"] = (report["sent"] as? Int ?? 0) + missing.count
        let back = try await translate(missing)
        for (text, translated) in zip(missing, back) {
            cache[language + "\u{1}" + text] = translated
            out[text] = translated
        }
        return out
    }

    // MARK: - marks between a sentence's parts

    nonisolated static func mark(_ index: Int) -> String { "[\(index)]" }
    nonisolated private static let marks = try! NSRegularExpression(pattern: #"\[\d+\]"#)

    nonisolated static func letters(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }

    /// The parts as one sentence, a mark before each but the first; nil when
    /// the text has something that looks like a mark already.
    nonisolated static func joined(_ parts: [String], gaps: [Bool]) -> String? {
        var out = ""
        for (index, part) in parts.enumerated() {
            let range = NSRange(part.startIndex..., in: part)
            if marks.firstMatch(in: part, range: range) != nil { return nil }
            if index > 0 { out += (gaps[index] ? " " : "") + mark(index) }
            out += part
        }
        return out
    }

    /// A translated sentence cut back into `count` pieces at its marks: each
    /// mark once and in order, and no other, or nil.
    nonisolated static func split(_ text: String, count: Int) -> [String]? {
        let range = NSRange(text.startIndex..., in: text)
        let found = marks.matches(in: text, range: range)
        guard found.count == count - 1 else { return nil }
        var pieces: [String] = []
        var rest = text[...]
        for index in 1..<count {
            guard let at = rest.range(of: mark(index)) else { return nil }
            pieces.append(String(rest[..<at.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines))
            rest = rest[at.upperBound...]
        }
        pieces.append(String(rest).trimmingCharacters(in: .whitespacesAndNewlines))
        return pieces
    }

    // MARK: - which language

    /// The page's language, from its words; the page's own lang attribute
    /// when the words don't say clearly.
    nonisolated static func detect(_ text: String, hint: String?) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let best = recognizer.languageHypotheses(withMaximum: 1).first
        if let best, best.key != .undetermined, best.value >= 0.5 || hint?.isEmpty != false {
            return Locale.Language(identifier: best.key.rawValue)
        }
        if let hint, !hint.isEmpty { return Locale.Language(identifier: hint) }
        return nil
    }

    /// Each block's own language where it is long enough to tell and says
    /// so clearly; the page's otherwise.
    nonisolated static func languages(of texts: [String], page: String) -> [String] {
        let recognizer = NLLanguageRecognizer()
        return texts.map { text in
            guard text.count >= 40 else { return page }
            recognizer.reset()
            recognizer.processString(text)
            guard let best = recognizer.languageHypotheses(withMaximum: 1).first,
                  best.key != .undetermined, best.value >= 0.8 else { return page }
            return code(Locale.Language(identifier: best.key.rawValue))
        }
    }

    // MARK: - the translator

    typealias Translate = ([String]) async throws -> [String]

    /// A way to translate strings from one language into the target.
    /// macOS 26 opens a session with no view when the language is on the
    /// Mac already. Otherwise (macOS 15, or a language still to download)
    /// the session comes from SwiftUI's translationTask, in a 1×1 view in
    /// the tab's window, which is where the system's download sheet shows.
    private func session(from: Locale.Language, main: Bool) async throws -> Translate? {
        if PageTranslator.fake {
            let tag = "[\(PageTranslator.code(from))→\(PageTranslator.code(target))] "
            return { strings in strings.map { tag + $0 } }
        }
        guard #available(macOS 15, *) else { throw Failure("Translate Page needs macOS 15 or later") }
        let status = await LanguageAvailability().status(from: from, to: target)
        if main { report["availability"] = "\(status)" }
        switch status {
        case .unsupported:
            if main {
                throw Failure("\(PageTranslator.name(PageTranslator.code(from))) to \(PageTranslator.name(PageTranslator.code(target))) can't be translated on this Mac")
            }
            return nil
        case .installed:
            if #available(macOS 26, *) {
                let session = TranslationSession(installedSource: from, target: target)
                return { strings in try await PageTranslator.translate(strings, with: session) }
            }
        default:
            // To download: only for the page's own language, which you asked for.
            if !main { return nil }
        }
        guard let content = web?.window?.contentView else { throw Failure("Translate Page needs the tab in a window") }
        let lease = try await SessionLease.open(from: from, to: target, in: content)
        leases.append(lease)
        let session: TranslationSession = lease.session
        return { strings in try await PageTranslator.translate(strings, with: session) }
    }

    @available(macOS 15, *)
    private static func translate(_ strings: [String], with session: TranslationSession) async throws -> [String] {
        let requests = strings.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
        var out = strings
        for response in try await session.translations(from: requests) {
            if let index = response.clientIdentifier.flatMap(Int.init), out.indices.contains(index) { out[index] = response.targetText }
        }
        return out
    }

    /// What went wrong, said quietly in the sign's menu.
    private static func describe(_ error: Error, from: Locale.Language?, to: Locale.Language) -> String {
        let language = from.map { name(code($0)) } ?? "this page's language"
        if #available(macOS 15, *), let error = error as? TranslationError {
            switch error {
            case .unsupportedLanguagePairing, .unsupportedSourceLanguage, .unsupportedTargetLanguage:
                return "\(language) to \(name(code(to))) can't be translated on this Mac"
            case .unableToIdentifyLanguage:
                return "Shy couldn't tell which language this page is in"
            default:
                break
            }
        }
        return "\(language) wasn't translated. The language may still need to be downloaded, in System Settings › General › Language & Region › Translation Languages"
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    // MARK: - the page side

    static let restoreCall = "return window.__shyTr ? __shyTr.restore() : 0"

    /// The script each frame gets once, in Shy's world. Only text node
    /// values and four attributes are ever written, and each original is
    /// kept beside it.
    static let script = Scripts.load("translate")

    /// For every frame but the top, while the switch is on: "I'm here", so
    /// a frame of another site can be given the script too. Nothing else.
    static let announce = """
    if (window !== window.top) try { webkit.messageHandlers.officeTranslate.postMessage({ frame: 1 }); } catch (e) {}
    """
}

// MARK: - the session's view, before macOS 26 or for a download

@MainActor
private protocol Closable: AnyObject { func close() }

/// A 1×1 clear view in the tab's window whose translationTask hands out a
/// session, and holds it open until closed.
@available(macOS 15, *)
@MainActor
private final class SessionLease: Closable {
    private(set) var session: TranslationSession!
    private var host: NSView?
    private var hold: CheckedContinuation<Void, Never>?
    private var closed = false

    static func open(from: Locale.Language, to: Locale.Language, in content: NSView) async throws -> SessionLease {
        let lease = SessionLease()
        let session: TranslationSession = await withCheckedContinuation { got in
            var given = false
            let view = NSHostingView(rootView: SessionHost(configuration: .init(source: from, target: to)) { session in
                guard !given else { return }
                given = true
                got.resume(returning: session)
                await withCheckedContinuation { (hold: CheckedContinuation<Void, Never>) in
                    if lease.closed { hold.resume() } else { lease.hold = hold }
                }
            })
            view.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
            view.alphaValue = 0.01
            content.addSubview(view)
            lease.host = view
        }
        lease.session = session
        return lease
    }

    func close() {
        closed = true
        hold?.resume()
        hold = nil
        host?.removeFromSuperview()
        host = nil
    }
}

@available(macOS 15, *)
private struct SessionHost: View {
    let configuration: TranslationSession.Configuration
    let work: (TranslationSession) async -> Void

    var body: some View {
        Color.clear.frame(width: 1, height: 1)
            .translationTask(configuration) { session in await work(session) }
    }
}

// MARK: - the frames and the page's changes

/// Frames saying they're there, and pages saying their words changed.
final class TranslateRelay: NSObject, WKScriptMessageHandler {
    static let name = "officeTranslate"
    weak var tab: Tab?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let said = message.body as? [String: Any] else { return }
        let frame = message.frameInfo
        MainActor.assumeIsolated {
            guard let tab, let web = tab.built, web === message.webView else { return }
            if said["frame"] != nil, !frame.isMainFrame {
                tab.translateFrames.append(frame)
                if tab.translateFrames.count > 64 { tab.translateFrames.removeFirst() }
                tab.translator?.arrived(frame)
            } else if said["dirty"] != nil {
                tab.translator?.changed(in: frame.isMainFrame ? nil : frame)
            }
        }
    }
}

// MARK: - the tab

extension Tab {
    /// Translate Page, or Show Original, as the page's menu and the sign do.
    func toggleTranslation() {
        if let translator, translation?.failed != true {
            translator.end(restore: true)
        } else {
            PageTranslator.start(self)
        }
    }

    /// The page went: nothing to put back. A tab going to sleep translated
    /// is translated again when it wakes on the same page.
    func translationGone(sleeping: Bool) {
        if sleeping, let translator, let url = pageAddress {
            translateOnWake = (url, PageTranslator.code(translator.target))
        }
        translator?.end(restore: false)
        translation = nil
        translateFrames = []
    }

    func failTranslation(_ mark: TranslationMark) {
        translation = mark
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            if self?.translation == mark { self?.translation = nil }
        }
    }

    /// Whether the page's language is one translated as it opens: always
    /// (Settings), or in this private tab only.
    func alwaysTranslates(_ code: String) -> Bool {
        shy ? translateLanguages.contains(code) || Shared.prefs.translateAlways.contains(code)
            : Shared.prefs.translateAlways.contains(code)
    }

    /// Always Translate <language>, on or off. A private tab keeps it to
    /// itself, written nowhere.
    func setAlwaysTranslates(_ code: String, _ on: Bool) {
        if shy {
            if on { translateLanguages.insert(code) } else { translateLanguages.remove(code) }
        } else {
            if on { Shared.prefs.translateAlways.insert(code) } else { Shared.prefs.translateAlways.remove(code) }
        }
    }

    /// A page has come in: translated if it's in a language you always
    /// translate, or if it's the one this tab had translated as it slept.
    func translateIfWanted() {
        guard PageTranslator.enabled, translator == nil, let web = built, let url = pageAddress,
              ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else { return }
        if let wake = translateOnWake {
            translateOnWake = nil
            if wake.url == url {
                PageTranslator.start(self, to: Locale.Language(identifier: wake.to))
                return
            }
        }
        let wanted = shy ? Shared.prefs.translateAlways.union(translateLanguages) : Shared.prefs.translateAlways
        guard !wanted.isEmpty else { return }
        web.quietly(
            "return [document.documentElement.lang || '', document.body ? document.body.innerText.slice(0, 3000) : '']",
            asFunction: true
        ) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, self.translator == nil, self.built === web,
                      let pair = (try? result.get()) as? [String], pair.count == 2,
                      let language = PageTranslator.detect(pair[1], hint: pair[0]),
                      !PageTranslator.same(language, PageTranslator.reader),
                      wanted.contains(PageTranslator.code(language)) else { return }
                PageTranslator.start(self)
            }
        }
    }
}

// MARK: - the sign and its menu

/// The sign beside a tab's title while its page is translated: the size
/// of the other marks there, and gone with the page or Show Original.
struct TranslateSign: View {
    @ObservedObject var tab: Tab
    var colour: Color = Palette.muted
    /// Drawn open, for a picture of it (tests).
    var shown = false

    @State private var showing = false
    @State private var hovering = false

    var body: some View {
        if let mark = tab.translation {
            let lit = hovering || showing || shown
            Button { showing.toggle() } label: {
                Image(systemName: mark.failed ? "exclamationmark.bubble" : "translate")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(lit ? Palette.ink : colour.opacity(mark.phase == .working ? 0.4 : 0.75))
                    .frame(width: 17, height: 15)
                    .background(Palette.ink.opacity(lit ? 0.07 : 0),
                                in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(TranslateMenu.heading(mark))
            .accessibilityLabel(TranslateMenu.heading(mark))
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                TranslateMenu(tab: tab) { showing = false }
            }
            .animation(Motion.quick, value: hovering)
            .transition(.scale(scale: 0.5).combined(with: .opacity))
        }
    }
}

/// What the sign offers: Show Original, and Always Translate the page's
/// language (in a private tab, for that tab only).
struct TranslateMenu: View {
    @ObservedObject var tab: Tab
    @ObservedObject var prefs = Shared.prefs
    let done: () -> Void

    static func heading(_ mark: TranslationMark) -> String {
        let from = mark.from.map(PageTranslator.name)
        switch mark.phase {
        case .working: return from.map { "Translating from \($0)…" } ?? "Translating…"
        case .done: return from.map { "Translated from \($0)" } ?? "Translated"
        case .failed(let message): return message
        }
    }

    var body: some View {
        let mark = tab.translation ?? TranslationMark(from: nil, to: "en", phase: .done)
        VStack(alignment: .leading, spacing: 0) {
            Text(TranslateMenu.heading(mark))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.top, 11)
                .padding(.bottom, mark.failed ? 11 : 3)
            if !mark.failed {
                VStack(spacing: 1) {
                    Item(symbol: "arrow.uturn.backward", title: "Show Original") {
                        tab.translator?.end(restore: true)
                        done()
                    }
                    if let from = mark.from {
                        let on = tab.alwaysTranslates(from)
                        Item(symbol: on ? "checkmark" : "circle.dashed",
                             title: tab.shy ? "Translate \(PageTranslator.name(from)) in This Tab" : "Always Translate \(PageTranslator.name(from))") {
                            tab.setAlwaysTranslates(from, !on)
                        }
                        .help(tab.shy ? "Only until this private tab closes" : "Settings › General lists the languages always translated")
                    }
                }
                .padding(6)
                Divider().overlay(Palette.hairline)
                Text("Translated on this Mac. Nothing is sent anywhere.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.faint)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
        }
        .frame(width: 270, alignment: .leading)
        .popoverGround()
    }

    private struct Item: View {
        let symbol: String
        let title: String
        let act: () -> Void
        @State private var hovering = false

        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(Palette.muted).frame(width: 14)
                Text(title).font(.system(size: 12.5)).foregroundStyle(Palette.ink).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Palette.wash : .clear))
            .contentShape(Rectangle())
            .onTapGesture(perform: act)
            .onHover { hovering = $0 }
        }
    }
}

/// Settings › General, under the switch: the languages translated as their
/// pages open, each with a way to stop.
struct TranslateLanguageList: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        ForEach(prefs.translateAlways.sorted(), id: \.self) { code in
            Rule()
            Line("Always translate \(PageTranslator.name(code))", "Pages in \(PageTranslator.name(code)) are translated as they open") {
                Pill("Remove") { prefs.translateAlways.remove(code) }
            }
        }
    }
}
