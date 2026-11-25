import Foundation

/// Performance's Dim 3rd parties, as in Chrome DevTools: the Main track's
/// entries whose script comes from a site other than the page's are drawn
/// greyed. Sites are grouped as Insights' 3rd parties card groups them
/// (DeveloperPerformanceInsights.site). An entry with no script of its own
/// (a layout, a timer firing) is classed as the nearest entry around it
/// that has one, as the work it does belongs to that script.
enum DeveloperPerformanceThirdParties {
    static let key = "developerTools.performance.dimThirdParties"

    /// The page's own site: what the page said its address was, else the
    /// tab's, else its main document's.
    static func firstPartySite(_ profile: DeveloperPerformanceProfile, page: URL? = nil) -> String? {
        let address = profile.pageInfo["url"] ?? page?.absoluteString
            ?? DeveloperPerformanceInsights.mainDocument(profile, page: page)?.url
        return address.flatMap { DeveloperPerformanceInsights.site(of: $0) }
    }

    /// The script an entry ran, if it says.
    static func scriptURL(_ event: DeveloperPerformanceEvent) -> String? {
        let url = event.data["url"] ?? event.data["scriptName"]
        guard let url, !url.isEmpty else { return nil }
        return url
    }

    /// Whether a script from `url` is a 3rd party's to a page of `site`:
    /// nil when the address has no site (an inline script, "about:blank").
    static func isThirdParty(_ url: String, firstParty site: String) -> Bool? {
        guard let other = DeveloperPerformanceInsights.site(of: url) else { return nil }
        return other != site
    }

    /// The ids of the entries to dim: those of 3rd-party scripts, and
    /// those without a script inside one. Empty when the page's site is
    /// unknown, as Chrome dims nothing without it.
    static func dimmed(_ profile: DeveloperPerformanceProfile, page: URL? = nil) -> Set<Int> {
        guard let site = firstPartySite(profile, page: page) else { return [] }
        let events = profile.events
        var classed = [Bool?](repeating: nil, count: events.count)
        var result = Set<Int>()
        // Records are in the order they began, so a parent is classed first.
        for event in events {
            var third: Bool?
            if let url = scriptURL(event) { third = isThirdParty(url, firstParty: site) }
            if third == nil, let parent = event.parent, classed.indices.contains(parent) { third = classed[parent] }
            classed[event.id] = third
            if third == true { result.insert(event.id) }
        }
        return result
    }
}
