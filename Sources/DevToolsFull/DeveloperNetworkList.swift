import Foundation

/// The request list's keyboard, as in Chrome DevTools: once a row has been
/// clicked the list has the keys, and the arrows, Page Up and Page Down,
/// Home and End move the selection, the request's tabs following it.
enum DeveloperNetworkKeyboard {
    enum Move: Equatable {
        case up, down, pageUp, pageDown, home, end
    }

    /// The row a move lands on in a list of `count` rows, from the chosen
    /// one at `index` (nil when none is chosen); `page` rows make a page.
    /// Nil when there is nothing to choose.
    static func index(after move: Move, from index: Int?, count: Int, page: Int) -> Int? {
        guard count > 0 else { return nil }
        let page = max(1, page)
        let last = count - 1
        guard let index, index >= 0, index <= last else {
            // Nothing chosen yet: the keys start at the end they point to.
            switch move {
            case .up, .pageUp, .end: return last
            case .down, .pageDown, .home: return 0
            }
        }
        switch move {
        case .up: return max(0, index - 1)
        case .down: return min(last, index + 1)
        case .pageUp: return max(0, index - page)
        case .pageDown: return min(last, index + page)
        case .home: return 0
        case .end: return last
        }
    }
}

/// Which requests led to a request and which it led to, matched by
/// address as WebKit reports initiators: the chain the Initiator tab draws
/// and the rows Shift-hover tints in the list.
enum DeveloperNetworkInitiators {
    /// How far up an initiator chain is followed.
    static let depth = 10

    /// The addresses that led to `request`, the first page first.
    static func ancestors(of request: DeveloperToolsSession.Request, initiator: String? = nil,
                          in all: [DeveloperToolsSession.Request]) -> [String] {
        let parents = parentsByURL(all)
        var ancestors: [String] = []
        var next = initiator ?? request.initiatorURL
        while let url = next, ancestors.count < depth, !ancestors.contains(url), url != request.url {
            ancestors.insert(url, at: 0)
            next = parents[url] ?? nil
        }
        return ancestors
    }

    /// As Chrome's Initiator tab draws it: the requests that led here, this
    /// one, then the requests it started.
    static func chain(for request: DeveloperToolsSession.Request, initiator: String? = nil,
                      in all: [DeveloperToolsSession.Request]) -> [(url: String, depth: Int, current: Bool)] {
        let ancestors = ancestors(of: request, initiator: initiator, in: all)
        var chain = ancestors.enumerated().map { (url: $1, depth: $0, current: false) }
        chain.append((url: request.url, depth: ancestors.count, current: true))
        let children = all.filter { $0.initiatorURL == request.url && $0.id != request.id }.prefix(100)
        chain += children.map { (url: $0.url, depth: ancestors.count + 1, current: false) }
        return chain
    }

    /// Shift-hover in Chrome's list: the requests on `request`'s initiator
    /// chain (green), and every request it led to, directly or through
    /// others (red). The request itself is in neither.
    static func graph(for request: DeveloperToolsSession.Request,
                      in all: [DeveloperToolsSession.Request]) -> (initiators: Set<String>, initiated: Set<String>) {
        let parents = parentsByURL(all)
        let up = Set(ancestors(of: request, in: all))
        var initiators = Set<String>()
        var initiated = Set<String>()
        for other in all where other.id != request.id {
            if up.contains(other.url) { initiators.insert(other.id) }
            // Up from the other request: does its chain pass through this one?
            var next = other.initiatorURL
            var seen = Set<String>()
            while let url = next, seen.count < depth, seen.insert(url).inserted {
                if url == request.url {
                    initiated.insert(other.id)
                    break
                }
                next = parents[url] ?? nil
            }
        }
        initiated.subtract(initiators)
        return (initiators, initiated)
    }

    /// Each address's initiator, from the first request made to it.
    private static func parentsByURL(_ all: [DeveloperToolsSession.Request]) -> [String: String?] {
        var parents: [String: String?] = [:]
        for request in all where parents[request.url] == nil {
            parents[request.url] = .some(request.initiatorURL)
        }
        return parents
    }
}
