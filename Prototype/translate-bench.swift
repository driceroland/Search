// How fast Apple's Translation framework is on a page's strings, and how
// often the [1], [2]… marks Translate Page puts between a sentence's parts
// come back intact (Translate.swift falls back to part-by-part otherwise).
// Needs macOS 26 and both languages downloaded (System Settings › General ›
// Language & Region › Translation Languages). Nothing goes to the network.
//   swiftc -parse-as-library -O Prototype/translate-bench.swift -o /tmp/trbench
//   /tmp/trbench strings.json fr en
// strings.json is a JSON array of strings; those holding marks are counted
// for the marks, the rest for speed.
import Foundation
import Translation

@main struct Bench { static func main() async throws {
    let args = CommandLine.arguments
    guard args.count == 4 else { print("usage: trbench strings.json SOURCE TARGET"); exit(2) }
    let strings = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
    let from = Locale.Language(identifier: args[2]), to = Locale.Language(identifier: args[3])
    let status = await LanguageAvailability().status(from: from, to: to)
    print("strings", strings.count, "unique", Set(strings).count, "chars", strings.reduce(0) { $0 + $1.count }, "status", status)
    guard #available(macOS 26, *) else { print("needs macOS 26"); exit(1) }
    guard status == .installed else { print("download \(args[2]) and \(args[3]) first"); exit(1) }
    let session = TranslationSession(installedSource: from, target: to)
    let marks = try NSRegularExpression(pattern: #"\[\d+\]"#)
    func count(_ s: String) -> [String] {
        marks.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { String(s[Range($0.range, in: s)!]) }
    }
    let unique = Array(Set(strings))
    let start = Date()
    var first: TimeInterval?
    var done = 0, marked = 0, intact = 0
    var lost: [(String, String)] = []
    // Slices as Translate Page sends them: a small first one, then 160.
    var index = 0, size = 24
    while index < unique.count {
        let part = Array(unique[index..<min(index + size, unique.count)])
        index += size; size = 160
        let out = try await session.translations(from: part.map { TranslationSession.Request(sourceText: $0) })
        done += out.count
        if first == nil { first = Date().timeIntervalSince(start); print("first slice:", Int(first! * 1000), "ms —", out.prefix(3).map(\.targetText)) }
        for response in out where !count(response.sourceText).isEmpty {
            marked += 1
            if count(response.targetText) == count(response.sourceText) { intact += 1 } else { lost.append((response.sourceText, response.targetText)) }
        }
    }
    let total = Date().timeIntervalSince(start)
    print("all \(done) unique strings:", Int(total * 1000), "ms")
    if marked > 0 {
        print("marks intact, in order: \(intact) of \(marked)")
        for (a, b) in lost.prefix(8) { print("  lost:", a, "→", b) }
    }
}}
