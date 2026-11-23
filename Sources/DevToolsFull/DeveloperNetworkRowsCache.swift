import Foundation

/// The Network list's filtered and sorted rows and its timing ruler, kept
/// between body passes. The panel's body runs on every session publish
/// (console messages included) and every half-second poll; this rebuilds
/// only when the requests, the filter options, the extras or the page
/// change. Array `==` is O(1) while the session keeps the same storage,
/// so the unchanged case costs a few comparisons.
final class DeveloperNetworkRowsCache {
    typealias Request = DeveloperToolsSession.Request

    /// What the visible rows depend on besides the requests and extras.
    struct Filters: Equatable {
        var query: String
        var invert: Bool
        var hideDataURLs: Bool
        var hideExtensionURLs: Bool
        var blockedOnly: Bool
        var thirdPartyOnly: Bool
        var kinds: Set<DeveloperRequestKind>
        var sort: DeveloperNetworkListColumn?
        var ascending: Bool
        var waterfallSort: DeveloperNetworkWaterfallSort

        init(_ options: DeveloperNetworkView.Options) {
            query = options.query
            invert = options.invert
            hideDataURLs = options.hideDataURLs
            hideExtensionURLs = options.hideExtensionURLs
            blockedOnly = options.blockedOnly
            thirdPartyOnly = options.thirdPartyOnly
            kinds = options.kinds
            sort = options.sort
            ascending = options.ascending
            waterfallSort = options.waterfallSort
        }
    }

    /// A request's URL, parsed once: its scheme and its site.
    private struct Parsed {
        let url: String
        let scheme: String
        let site: String
    }

    private var parsed: [String: Parsed] = [:]

    private var shownKey: (requests: [Request], filters: Filters, extras: Int, page: String)?
    private var shownValue: [Request] = []

    private var rowsKey: (shown: Int, window: ClosedRange<Double>?)?
    private var rowsValue: [Request] = []
    /// Bumped whenever `rowsValue` is rebuilt, for the selection lookup.
    private var rowsGeneration = 0
    private var shownGeneration = 0

    private var timingKey: (requests: [Request], marks: [Double])?
    private var timingValue = DeveloperNetworkTiming([])

    private var selectionKey: (rows: Int, id: String)?
    private var selectionValue: Request?

    /// The requests the filters let through, sorted as the list is.
    func shown(_ requests: [Request], options: DeveloperNetworkView.Options,
               extras: [String: DeveloperNetworkTools.Extra], extrasRevision: Int,
               page: String) -> [Request] {
        let filters = Filters(options)
        if let key = shownKey, key.extras == extrasRevision, key.page == page,
           key.filters == filters, key.requests == requests {
            return shownValue
        }
        shownValue = compute(requests, filters: filters, extras: extras, page: page)
        shownKey = (requests, filters, extrasRevision, page)
        shownGeneration &+= 1
        prune(requests)
        return shownValue
    }

    /// The shown requests within the span chosen on the overview.
    func rows(_ shown: [Request], window: ClosedRange<Double>?) -> [Request] {
        if let key = rowsKey, key.shown == shownGeneration, key.window == window { return rowsValue }
        rowsValue = window.map { window in shown.filter { DeveloperNetworkTiming.overlaps($0, window) } } ?? shown
        rowsKey = (shownGeneration, window)
        rowsGeneration &+= 1
        return rowsValue
    }

    /// The whole recording's ruler.
    func timing(_ requests: [Request], marks: [Double]) -> DeveloperNetworkTiming {
        if let key = timingKey, key.marks == marks, key.requests == requests { return timingValue }
        timingValue = DeveloperNetworkTiming(requests, marks: marks)
        timingKey = (requests, marks)
        return timingValue
    }

    /// The chosen request among the rows last returned by `rows`.
    func selected(_ id: String?, in rows: [Request]) -> Request? {
        guard let id else { return nil }
        if let key = selectionKey, key.rows == rowsGeneration, key.id == id { return selectionValue }
        selectionValue = rows.first { $0.id == id }
        selectionKey = (rowsGeneration, id)
        return selectionValue
    }

    private func compute(_ requests: [Request], filters: Filters,
                         extras: [String: DeveloperNetworkTools.Extra], page: String) -> [Request] {
        let filter = DeveloperNetworkFilter(filters.query, invert: filters.invert)
        let pageSite = filters.thirdPartyOnly ? Self.site(page) : ""
        let rows = requests.filter { row in
            if !filters.kinds.isEmpty && !filters.kinds.contains(DeveloperRequestKind(row)) { return false }
            let needsURL = filters.hideDataURLs || filters.hideExtensionURLs || filters.thirdPartyOnly
            if needsURL {
                let url = parse(row)
                if filters.hideDataURLs && (url.scheme == "data" || url.scheme == "blob") { return false }
                if filters.hideExtensionURLs && url.scheme.contains("extension") { return false }
                if filters.thirdPartyOnly && url.site == pageSite { return false }
            }
            if filters.blockedOnly && extras[row.id]?.blocked != true && row.failure == nil { return false }
            return filter.isEmpty || filter.matches(row, extra: extras[row.id])
        }
        guard let sort = filters.sort else { return rows }
        return DeveloperNetworkListColumn.sort(rows, by: sort, ascending: filters.ascending, extras: extras,
                                               waterfall: filters.waterfallSort)
    }

    private func parse(_ row: Request) -> Parsed {
        if let known = parsed[row.id], known.url == row.url { return known }
        let scheme = URL(string: row.url)?.scheme?.lowercased() ?? row.url.prefix { $0 != ":" }.lowercased()
        let entry = Parsed(url: row.url, scheme: scheme, site: Self.site(row.url))
        parsed[row.id] = entry
        return entry
    }

    /// Forgets parsed URLs of requests no longer recorded.
    private func prune(_ requests: [Request]) {
        guard parsed.count > max(64, requests.count * 2) else { return }
        let live = Set(requests.map(\.id))
        parsed = parsed.filter { live.contains($0.key) }
    }

    /// The registrable part of a host, approximated by its last two labels.
    static func site(_ url: String) -> String {
        let host = URLComponents(string: url)?.host ?? ""
        return host.split(separator: ".").suffix(2).joined(separator: ".")
    }
}
