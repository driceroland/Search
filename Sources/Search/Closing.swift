import Foundation

// Tabs that close themselves, as in Arc.
//
// Everything you open is for now, unless you say it is for keeping. A tab you
// haven't looked at for twelve hours (or a day, a week, a month: Settings ›
// Tabs) closes the way ⌘W would close it: ⇧⌘T and History › Recently Closed
// bring it back while it is recent, and History has its page for good. What
// stays is what you said to keep: a pinned tab, a tab you named, a tab in a
// group. There is no fourth way, and no list of exceptions to learn.
//
// The time counts from when you last left the tab, or let go of it (unpinned,
// ungrouped, unnamed: Tab.letGo), and goes on counting while Search is quit:
// the session file carries both (Session.Entry.touched, .letGo).
// Without that, yesterday's tabs would come back each morning as if just
// looked at, and a browser quit every night would never close a thing.
//
// Nothing is closed from under you. The page on screen stays, and so does one
// busy the way a tab kept awake is (Browser.busy): playing, on a call,
// downloading, asking something, or holding something typed and not sent. A
// private tab stays too: nothing could bring it back. A Split View pair goes
// whole or not at all, since half of one left behind has no reason to be there:
// both halves are asked about anything typed before either closes.
//
// Never, unless chosen.

extension Browser {
    /// How long a tab is left before it closes, nil when tabs never do.
    /// `close.after` in seconds stands in for the chosen time, for the tests.
    var closeAfter: TimeInterval? {
        guard let chosen = prefs.tabLife.interval else { return nil }
        let set = Store.settings.double(forKey: "close.after")
        return set > 0 ? set : chosen
    }

    /// Why a tab stays open however long it is left, nil when nothing keeps
    /// it. The clock is the caller's business, as with `awake(because:)`.
    func stays(because tab: Tab) -> String? {
        if visibleTabIDs.contains(tab.id) { return "on screen" }
        if tab.pin != nil { return "pinned" }
        if tab.name != nil { return "named" }
        if tab.groupID != nil { return "in a group" }
        if tab.shy { return "private" }
        if tab.bench { return "a bench tab" }
        // Holds nothing and costs nothing; closing the last one would close
        // the window.
        if tab.isBlank { return "blank" }
        return busy(tab)
    }

    /// Every tab left alone past its time, in this space's row and the
    /// others'. At launch, and then with each look for tabs to sleep.
    func closeLeftAlone() {
        guard let wait = closeAfter else { return }
        let since = Date().addingTimeInterval(-wait)
        let due = (tabs + parkedTabs).filter { $0.leftSince <= since && stays(because: $0) == nil }
        let going = Set(due.map(\.id))
        let pairs = splits + parked.values.flatMap(\.splits)
        var taken = Set<Tab.ID>()
        for tab in due where !taken.contains(tab.id) {
            // A pair is one: both halves due, or neither goes.
            let pair = pairs.first { $0.contains(tab.id) }
            guard pair?.tabs.allSatisfy(going.contains) ?? true else { continue }
            let together = pair.map { pair in due.filter { pair.contains($0.id) } } ?? [tab]
            taken.formUnion(together.map(\.id))
            retire(together, since: since)
        }
    }

    /// Asks each page whether it holds something typed, as sleeping does,
    /// one after another, and closes them all only when none does. Then it
    /// looks again: you may have gone back to one while they answered.
    private func retire(_ together: [Tab], since: Date, asked: Int = 0) {
        guard asked == together.count else {
            together[asked].unsaved { [weak self] typed in
                guard let self, !typed else { return }
                self.retire(together, since: since, asked: asked + 1)
            }
            return
        }
        guard closeAfter != nil,
              together.allSatisfy({ $0.leftSince <= since && stays(because: $0) == nil }) else { return }
        for tab in together {
            if tabs.contains(where: { $0 === tab }) {
                close(tab)
            } else {
                closeParked(tab)
            }
        }
    }

    /// A tab of a space not on screen: out of its row, and the row written.
    /// It isn't offered to ⇧⌘T, which would reopen it in the space on screen
    /// with that space's sign-ins; History still has it.
    private func closeParked(_ tab: Tab) {
        guard let space = parked.first(where: { $0.value.tabs.contains { $0 === tab } })?.key,
              var row = parked[space] else { return }
        row.tabs.removeAll { $0 === tab }
        row.splits = row.splits.filter { Browser.holds($0, in: row.tabs) }
        if row.active == tab.id {
            row.active = row.tabs.first { $0.pin == nil }?.id ?? row.tabs.first?.id
        }
        tab.close()
        parked[space] = row
        // Now: going to that space reads its file when the row is empty.
        writeSession(now: true, space: space, row: row)
    }
}
