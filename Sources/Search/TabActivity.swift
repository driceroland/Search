import SwiftUI

struct TabActivity: View {
    @ObservedObject var browser: Browser
    @State private var rows: [Entry] = []
    @State private var refreshID = UUID()

    private struct Entry: Identifiable {
        let id: Tab.ID
        let title: String
        var reason = "Checking…"
    }

    var body: some View {
        Plate("Tab Activity", close: { browser.activityShowing = false }) {
            ScrollView {
                Card {
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.title).lineLimit(1)
                            Text(row.reason).font(.system(size: 12)).foregroundStyle(Palette.muted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        if row.id != rows.last?.id { Rule() }
                    }
                }
            }
            .frame(maxHeight: 340)
        } foot: {
            HStack {
                Text("This window and its Spaces. Snapshot only.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
                Spacer()
                Button("Refresh", action: refresh)
            }
        }
        .onAppear(perform: refresh)
        .onDisappear { refreshID = UUID() }
        .onChange(of: browser.prefs.showsTabActivity) { _, on in
            if !on { browser.activityShowing = false }
        }
    }

    private func refresh() {
        let request = UUID()
        refreshID = request
        let tabs = browser.tabs + browser.parkedTabs
        rows = tabs.map { Entry(id: $0.id, title: $0.label.isEmpty ? "New Tab" : $0.label) }
        for tab in tabs {
            browser.activityReason(for: tab) { [weak tab] reason in
                guard refreshID == request, let tab, let index = rows.firstIndex(where: { $0.id == tab.id }) else { return }
                rows[index].reason = reason
            }
        }
    }
}

extension Browser {
    /// Reuses sleep's checks, without creating a page or changing its idle time.
    func activityReason(for tab: Tab, done: @escaping (String) -> Void) {
        if tab.asleep { return done("Sleeping") }
        guard let web = tab.built else { return done("Not loaded") }
        if let reason = awake(because: tab) { return done(reason) }
        guard prefs.sleepsTabs else { return done("Automatic sleeping is off") }
        let address = tab.address
        tab.unsavedState { [weak self, weak tab, weak web] typed in
            guard let self, let tab, let web, tab.built === web, tab.address == address,
                  (self.tabs + self.parkedTabs).contains(where: { $0 === tab }) else {
                return done("Changed — refresh")
            }
            if tab.asleep { return done("Sleeping") }
            if let reason = self.awake(because: tab) { return done(reason) }
            guard self.prefs.sleepsTabs else { return done("Automatic sleeping is off") }
            guard let typed else { return done("Form state unavailable") }
            done(typed ? "Holding unsaved input" : Date().timeIntervalSince(tab.touched) < Browser.sleepAfter
                 ? "Waiting for sleep delay" : "Eligible to sleep")
        }
    }
}
