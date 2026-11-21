import SwiftUI

// A blank tab's grid: the sites of the bookmark folder called Home, each a
// tile with its saved title. Off unless Settings › Tabs turns it on; nothing
// is drawn without such a folder.
struct HomeGrid: View {
    let browser: Browser
    @ObservedObject private var typing: FieldState
    @ObservedObject private var prefs: Preferences

    init(browser: Browser) {
        self.browser = browser
        typing = browser.typing
        prefs = browser.prefs
    }

    var body: some View {
        let sites = browser.bookmarks.homeSites
        if prefs.homeGrid, browser.active?.isBlank == true, typing.typed.isEmpty, !sites.isEmpty {
            // The field's own width and row height, hung just under it: the
            // field is centred, lifted 30, and 50 tall.
            GeometryReader { page in
                let width = min(Metrics.fieldWidth, max(0, page.size.width - 28))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(sites) { site in
                        Button { site.address.map(browser.openBookmark) } label: {
                            Text(site.label)
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.muted)
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .frame(maxWidth: .infinity, minHeight: 50, maxHeight: 50)
                                .background(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.hairline))
                                .contentShape(RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: width)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, page.size.height / 2 - 30 + 25 + 10)
            }
        }
    }
}
