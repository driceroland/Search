import WebKit

/// The page-side part of ⌘F. A count and the range selected by Next always
/// come from the same list, built in Shy's own world (`Web.world`), which
/// the page cannot see into: not the word looked for, not the list, and none
/// of the functions it is built with — a page that swaps `Range`,
/// `getSelection` or `RegExp` for its own swaps them in its world only.
@MainActor
final class PageFind {
    struct Result: Equatable {
        let count: Int?
        /// One-based, as shown in the find bar.
        let index: Int?
        /// More matches than `count` may follow: the list stops at
        /// `PageFind.limit` until Next goes past its end.
        let more: Bool
        let found: Bool
        let nativeFallback: Bool
        let wholeWordsAvailable: Bool
        let available: Bool
        let stale: Bool
    }

    /// Matches measured at a time. Each one is a range whose boxes are asked
    /// for, which is what costs on a long page; a letter typed into a book
    /// would otherwise measure every "e" in it before the count came back.
    /// Safari stops counting at the same number.
    static let limit = 1000

    private var newestGeneration: UInt64 = 0

    /// `steps` is how far to move: on a new search, from the first match
    /// (0 lands on it); otherwise from the current one, negative for back.
    func update(
        on web: WKWebView,
        query: String,
        matchCase: Bool,
        wholeWords: Bool,
        steps: Int,
        generation: UInt64
    ) async -> Result {
        guard generation >= newestGeneration else { return Self.staleResult }
        newestGeneration = max(newestGeneration, generation)
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return await clear(on: web, generation: generation)
        }

        do {
            let value = try await evaluate(
                on: web,
                arguments: [
                    "query": query,
                    "matchCase": matchCase,
                    "wholeWords": wholeWords,
                    "steps": steps,
                    "limit": Self.limit,
                    "generation": NSNumber(value: generation),
                ]
            )
            guard generation >= newestGeneration else { return Self.staleResult }
            guard let result = value as? [String: Any], let status = result["status"] as? String else {
                return Self.unavailableResult
            }

            if status == "stale" { return Self.staleResult }
            if status == "pdf" {
                guard !wholeWords else {
                    return Result(
                        count: nil, index: nil, more: false, found: false, nativeFallback: true,
                        wholeWordsAvailable: false, available: true, stale: false
                    )
                }
                let found = await nativeFind(
                    query, on: web, matchCase: matchCase, forward: steps >= 0
                )
                guard generation >= newestGeneration else { return Self.staleResult }
                return Result(
                    count: nil, index: nil, more: false, found: found, nativeFallback: true,
                    wholeWordsAvailable: false, available: true, stale: false
                )
            }

            guard status == "ok",
                  let count = result["count"] as? Int,
                  let index = result["index"] as? Int else {
                return Self.unavailableResult
            }
            return Result(
                count: count,
                index: index == 0 ? nil : index,
                more: result["more"] as? Bool ?? false,
                found: count > 0,
                nativeFallback: false,
                wholeWordsAvailable: true,
                available: true,
                stale: false
            )
        } catch {
            guard generation >= newestGeneration else { return Self.staleResult }
            return Self.unavailableResult
        }
    }

    func clear(on web: WKWebView, generation: UInt64) async -> Result {
        newestGeneration = max(newestGeneration, generation)
        do {
            _ = try await evaluate(
                on: web,
                arguments: [
                    "query": "",
                    "matchCase": false,
                    "wholeWords": false,
                    "steps": 0,
                    "limit": Self.limit,
                    "generation": NSNumber(value: generation),
                ]
            )
        } catch {
            // A page may have gone away between the clear and WebKit's reply.
        }
        return generation >= newestGeneration ? Self.emptyResult : Self.staleResult
    }

    private func evaluate(on web: WKWebView, arguments: [String: Any]) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            web.quietly(Self.script, asFunction: true, arguments: arguments) { result in
                continuation.resume(with: result.map { $0 ?? NSNull() })
            }
        }
    }

    private func nativeFind(
        _ query: String,
        on web: WKWebView,
        matchCase: Bool,
        forward: Bool
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let configuration = WKFindConfiguration()
            configuration.backwards = !forward
            configuration.caseSensitive = matchCase
            configuration.wraps = true
            web.find(query, configuration: configuration) { result in
                continuation.resume(returning: result.matchFound)
            }
        }
    }

    private static let emptyResult = Result(
        count: 0, index: nil, more: false, found: false, nativeFallback: false,
        wholeWordsAvailable: true, available: true, stale: false
    )
    private static let unavailableResult = Result(
        count: nil, index: nil, more: false, found: false, nativeFallback: false,
        wholeWordsAvailable: true, available: false, stale: false
    )
    private static let staleResult = Result(
        count: nil, index: nil, more: false, found: false, nativeFallback: false,
        wholeWordsAvailable: true, available: false, stale: true
    )

    /// `callAsyncJavaScript` supplies these names as arguments; the query is
    /// never interpolated into source. State and ranges live only in Shy's
    /// isolated content world, so the page's nodes stay untouched. The matches
    /// are painted with `CSS.highlights` and one adopted style sheet, which the
    /// page can read back, but not the list the count comes from.
    ///
    /// The page's text is read once and kept, as runs of text with a map back
    /// to the nodes, until a mutation, a changed field or another frame says
    /// it is out of date: typing one more letter only runs the search again
    /// over the kept text, and measures the first `limit` matches.
    private static let script = Scripts.load("page-find")
}
