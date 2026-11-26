import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

@MainActor
enum TidyTitles {
    nonisolated static var available: Bool {
        if faking { return true }
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return SystemLanguageModel.default.isAvailable }
        #endif
        return false
    }

    nonisolated(unsafe) static var faking = false
    static var fake: (String) async -> String = { madeUp($0) }
    nonisolated static func madeUp(_ title: String) -> String {
        "Short title: Tidy " + title.split(separator: " ").prefix(3).joined(separator: " ")
    }

    nonisolated static let shortEnough = 24
    nonisolated static let longest = 48
    static let most = 400

    static func saw(_ tab: Tab) {
        guard Shared.prefs.tidiesTitles, wanted(tab) else { return }
        let id = tab.id
        settling.removeValue(forKey: id)?.cancel()
        if let kept = made[key(tab)] { return wear(kept, on: tab) }
        settling[id] = Task { [weak tab] in
            try? await Task.sleep(nanoseconds: faking ? 10_000_000 : 1_000_000_000)
            guard !Task.isCancelled else { return }
            settling[id] = nil
            guard let tab else { return }
            queue(tab)
        }
    }

    static func turned(_ on: Bool) {
        guard on else { return forget() }
        Browsers.all.flatMap { $0.tabs + $0.parkedTabs }.forEach(saw)
    }

    static func closed(_ tab: Tab) {
        settling.removeValue(forKey: tab.id)?.cancel()
        waiting.removeAll { $0.tab == nil || $0.tab === tab }
    }

    static func forget() {
        settling.values.forEach { $0.cancel() }
        settling = [:]
        worker?.cancel()
        worker = nil
        waiting = []
        made = [:]
        order = []
        Browsers.all.flatMap { $0.tabs + $0.parkedTabs }.forEach { $0.tidy = nil }
    }

    private static func wanted(_ tab: Tab) -> Bool {
        guard (tab.name ?? "").isEmpty, tab.page == nil else { return false }
        if tab.atPinnedPage, !(tab.pinTitle ?? "").isEmpty { return false }
        if tab.popup, !(tab.address?.host() ?? "").isEmpty { return false }
        return plain(tab.title).count > shortEnough
    }

    private static func key(_ tab: Tab) -> String {
        (tab.pageAddress?.host() ?? "") + "\u{1}" + plain(tab.title)
    }

    nonisolated static func plain(_ title: String) -> String {
        var rest = title[...]
        while true {
            rest = rest.drop(while: \.isWhitespace)
            guard let first = rest.first else { break }
            if "•●*".contains(first) {
                rest = rest.dropFirst()
                continue
            }
            guard first == "(" || first == "[",
                  let end = rest.firstIndex(of: first == "(" ? ")" : "]") else { break }
            let inside = rest[rest.index(after: rest.startIndex)..<end]
            guard !inside.isEmpty, inside.allSatisfy({ $0.isNumber || ",.+".contains($0) }) else { break }
            rest = rest[rest.index(after: end)...]
        }
        return rest.isEmpty ? title : String(rest)
    }

    private static func wear(_ answer: String, on tab: Tab) {
        guard !answer.isEmpty else {
            if tab.tidy != nil { tab.tidy = nil }
            return
        }
        let of = plain(tab.title)
        if let tidy = tab.tidy, tidy.of == of, tidy.text == answer { return }
        tab.tidy = Tab.Tidied(of: of, text: answer, quiet: tab.asleep)
    }

    private struct Waiting { weak var tab: Tab? }
    private static var settling: [Tab.ID: Task<Void, Never>] = [:]
    private static var waiting: [Waiting] = []
    private static var worker: Task<Void, Never>?
    private static var made: [String: String] = [:]
    private static var order: [String] = []

    private static func queue(_ tab: Tab) {
        if !waiting.contains(where: { $0.tab === tab }) { waiting.append(Waiting(tab: tab)) }
        work()
    }

    private static func work() {
        guard worker == nil else { return }
        worker = Task {
            while !waiting.isEmpty {
                guard let tab = waiting.removeFirst().tab, Shared.prefs.tidiesTitles, wanted(tab) else { continue }
                let title = tab.title, key = key(tab)
                if let kept = made[key] {
                    wear(kept, on: tab)
                    continue
                }
                let answer = await ask(title: title, address: tab.pageAddress)
                guard !Task.isCancelled else { return }
                guard let answer else { continue }
                if !tab.shy { keep(answer, for: key) }
                if wanted(tab), plain(tab.title) == plain(title) { wear(answer, on: tab) }
            }
            worker = nil
        }
    }

    private static func keep(_ answer: String, for key: String) {
        if made.updateValue(answer, forKey: key) == nil { order.append(key) }
        if order.count > most { made[order.removeFirst()] = nil }
    }

    private static let instructions = """
        You shorten the titles of browser tabs. You are given a web page's title and \
        where the page is. Answer with a short title, at most five words, that says what \
        the page is. Leave out the site's name, counts of unread items, separators like \
        "|" or "·", and words like "Home" or "Welcome", unless nothing else tells the page \
        apart. Keep the language the title is written in. Answer with the short title \
        alone, without quotes and without a full stop.
        Title: Pull Request #1502 · Custom engine suggestions · driceroland/Search · GitHub
        Short title: Custom engine suggestions PR
        Title: (3) Inbox - someone@example.com - Example Mail
        Short title: Inbox
        Title: How to bake sourdough bread at home: a beginner's guide | The Kitchen Blog
        Short title: Sourdough bread guide
        """

    private static func ask(title: String, address: URL?) async -> String? {
        if faking {
            let answer = await fake(title)
            return clean(answer, from: title)
        }
        #if canImport(FoundationModels)
        guard #available(macOS 26, *), SystemLanguageModel.default.isAvailable else { return nil }
        let line = title.split(whereSeparator: \.isNewline).joined(separator: " ")
        let at = place(of: address)
        let prompt = "Title: \(line.prefix(300))\n" + (at.isEmpty ? "" : "Where: \(at)\n") + "Short title:"
        #if compiler(>=6.4)
        let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 24)
        #else
        let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: 24)
        #endif
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        let session = LanguageModelSession(model: model, instructions: instructions)
        guard let answer = try? await session.respond(to: prompt, options: options) else { return nil }
        return clean(answer.content, from: title)
        #else
        return nil
        #endif
    }

    nonisolated static func place(of address: URL?) -> String {
        guard let address, let scheme = address.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = address.host(), !host.isEmpty else { return "" }
        return host + String(address.path().prefix(80))
    }

    nonisolated static func clean(_ answer: String, from title: String) -> String {
        var text = answer.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        if text.hasPrefix("Short title:") { text.removeFirst("Short title:".count) }
        text = text.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'“”‘’«»*")))
        while let last = text.last, ".。".contains(last) { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespaces)
        if text.count > longest {
            let cut = text.prefix(longest)
            text = (cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)) + "…"
        }
        return text.count * 4 <= title.count * 3 ? text : ""
    }
}

struct TidyGlint: ViewModifier {
    let tidy: String?

    @State private var sweeps = 0
    @State private var glowing = false

    private static let colours: [Color] = [
        Color(red: 1.00, green: 0.62, blue: 0.04),
        Color(red: 1.00, green: 0.22, blue: 0.37),
        Color(red: 0.75, green: 0.35, blue: 0.95),
        Color(red: 0.04, green: 0.52, blue: 1.00),
        Color(red: 0.39, green: 0.82, blue: 1.00),
    ]

    func body(content: Content) -> some View {
        content
            .overlay {
                if glowing {
                    let run = sweeps
                    TidySweep(colours: Self.colours) {
                        if sweeps == run { glowing = false }
                    }
                    .mask(content)
                    .id(run)
                    .allowsHitTesting(false)
                }
            }
            .onChange(of: tidy) { _, now in
                guard now != nil, !Motion.reduced else { return }
                sweeps += 1
                glowing = true
            }
    }
}

private struct TidySweep: View {
    let colours: [Color]
    let done: () -> Void

    @State private var at: CGFloat = 0

    var body: some View {
        LinearGradient(colors: colours, startPoint: .leading, endPoint: .trailing)
            .mask {
                GeometryReader { box in
                    let band = max(box.size.width * 0.7, 40)
                    LinearGradient(colors: [.clear, .white, .white, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: band)
                        .offset(x: -band + at * (box.size.width + band))
                }
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9)) { at = 1 } completion: { done() }
            }
    }
}
