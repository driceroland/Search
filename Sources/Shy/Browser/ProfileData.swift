import SwiftUI
import WebKit

// What a profile keeps on this Mac, for Settings › Profiles & Spaces: the
// sites that left something in its store — cookies, storage, caches — and
// how much history, how many bookmarks and passwords it holds. Read from
// this Mac alone, never from the sites: nothing is fetched or sent. A site's
// data can be removed, or all of it; what is in a cookie is never shown,
// since a sign-in is a value anyone looking over a shoulder could take.

/// One site's data in a profile's store, as WebKit lists it.
struct KeptSite: Identifiable {
    let record: WKWebsiteDataRecord
    var id: String { record.displayName }
    var name: String { record.displayName }

    /// What it keeps, in words, from WebKit's kinds.
    var kinds: String {
        let types = record.dataTypes
        var out: [String] = []
        if types.contains(WKWebsiteDataTypeCookies) { out.append("cookies") }
        if !types.isDisjoint(with: [WKWebsiteDataTypeLocalStorage, WKWebsiteDataTypeSessionStorage,
                                    WKWebsiteDataTypeIndexedDBDatabases, WKWebsiteDataTypeWebSQLDatabases,
                                    WKWebsiteDataTypeFileSystem]) { out.append("storage") }
        if types.contains(WKWebsiteDataTypeServiceWorkerRegistrations) { out.append("a service worker") }
        if !types.isDisjoint(with: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache,
                                    WKWebsiteDataTypeFetchCache, WKWebsiteDataTypeOfflineWebApplicationCache]) { out.append("cache") }
        if out.isEmpty { out.append("other site data") }
        return out.joined(separator: ", ")
    }
}

/// A profile's line on its card, and the list it opens.
struct ProfileData: View {
    let profile: Profile
    @State private var open = false
    @State private var sites: [KeptSite]?
    @State private var counts: (history: Int, bookmarks: Int, passwords: Int)?

    private var store: WKWebsiteDataStore { Profiles.store(profile.id) }

    var body: some View {
        Rule()
        Line("What it keeps", summary) {
            Pill(open ? "Hide" : "Show") {
                open.toggle()
                if open { look() }
            }
        }
        .onAppear { if counts == nil { count(); look() } }
        if open {
            if let sites {
                if sites.isEmpty {
                    Rule()
                    Text("No site has left anything")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.muted)
                        .padding(.horizontal, 14)
                        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                } else {
                    ForEach(sites) { site in
                        Rule()
                        Line(site.name, site.kinds) {
                            Pill("Remove") { remove(site) }
                        }
                    }
                    Rule()
                    Line("All of it", "Signs this profile out of every site and empties its caches. History, bookmarks and passwords stay") {
                        Pill("Remove All…") {
                            Ask.sure("Remove all site data in “\(profile.name)”?",
                                     detail: "Every cookie, sign-in, storage and cache of its \(sites.count) sites is erased from this Mac. History, bookmarks and passwords stay.",
                                     confirm: "Remove All", returnCancels: true) { removeAll() }
                        }
                    }
                }
            } else {
                Rule()
                Ring(size: 12)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            }
        }
    }

    private var summary: String {
        var parts: [String] = []
        if let sites { parts.append(sites.count == 1 ? "1 site" : "\(sites.count) sites") }
        if let counts {
            parts.append(counts.history == 1 ? "1 page in history" : "\(counts.history) pages in history")
            parts.append(counts.bookmarks == 1 ? "1 bookmark" : "\(counts.bookmarks) bookmarks")
            parts.append(counts.passwords == 1 ? "1 password" : "\(counts.passwords) passwords")
        }
        return parts.isEmpty ? "Cookies, storage, history, bookmarks and passwords" : parts.joined(separator: " · ")
    }

    /// History and bookmarks are already in memory; the passwords are a
    /// list of the keychain's, without a single secret read.
    private func count() {
        let id = profile.id
        let history = Profiles.history(id).size
        let bookmarks = Profiles.bookmarks(id).count
        DispatchQueue.global(qos: .userInitiated).async {
            let passwords = Vault.all(in: id).count
            DispatchQueue.main.async { counts = (history, bookmarks, passwords) }
        }
    }

    private func look() {
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            sites = records.map(KeptSite.init).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    private func remove(_ site: KeptSite) {
        store.removeData(ofTypes: site.record.dataTypes, for: [site.record]) { look() }
    }

    /// Every site, signed out — in the spaces of this profile with sign-ins
    /// of their own too, as the button says.
    private func removeAll() {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        for space in Spaces.read() where space.profileID == profile.id && space.sharesSignIns != true {
            Spaces.store(for: space.id).removeData(ofTypes: types, modifiedSince: .distantPast) {}
        }
        store.removeData(ofTypes: types, modifiedSince: .distantPast) { look() }
    }
}
