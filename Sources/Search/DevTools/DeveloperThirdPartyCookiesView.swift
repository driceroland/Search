import SwiftUI

/// The Privacy and security panel's Third-party cookies report: each
/// third-party site whose requests carried cookies or whose responses set
/// them, with its status under WebKit's tracking prevention, the cookies'
/// names and a link to its requests in Network. Grouping is
/// DeveloperThirdPartyCookies (DeveloperNetworkCookies.swift).
struct DeveloperThirdPartyCookiesView: View {
    @ObservedObject var session: DeveloperToolsSession
    @ObservedObject var tools: DeveloperNetworkTools
    let showInNetwork: (String) -> Void

    private var sites: [DeveloperThirdPartyCookies.Site] {
        let requests = session.requests.map { request in
            let extra = tools.extras[request.id]
            return DeveloperThirdPartyCookies.Request(id: request.id, url: request.url, sent: extra?.cookies ?? [],
                                                      set: extra?.setCookies ?? [])
        }
        return DeveloperThirdPartyCookies.report(requests, page: session.address)
    }

    var body: some View {
        let sites = sites
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Privacy").foregroundStyle(.secondary)
                    Text("Third-party cookies").font(.system(size: 14, weight: .semibold))
                }
                Text("Search blocks third-party cookies: WebKit’s tracking prevention keeps sites other than the page’s from "
                     + "reading or setting cookies, unless the page is granted storage access.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                if sites.isEmpty {
                    Text("No third-party cookies have been sent or set since DevTools opened. Reload the page to see them all.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(sites) { site in row(site) }
                    Text(DeveloperThirdPartyCookies.summary(sites)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
        .task {
            // Network's columns are read only while something asks for them.
            while !Task.isCancelled {
                await tools.poll()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func row(_ site: DeveloperThirdPartyCookies.Site) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: site.status == .blocked ? "nosign" : "checkmark.circle")
                .foregroundStyle(site.status == .blocked ? Palette.unsafe : Color.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: DeveloperToolsStyle.gutter) {
                    Text(site.site).fontWeight(.semibold).textSelection(.enabled)
                    Text(site.status.rawValue).foregroundStyle(.secondary)
                }
                Text(site.cookies.prefix(20).joined(separator: ", ") + (site.cookies.count > 20 ? ", …" : ""))
                    .font(DeveloperToolsStyle.code)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .help(site.cookies.joined(separator: ", "))
                Text(counts(site)).foregroundStyle(.secondary)
                Button(site.requests.count == 1 ? "View 1 request in Network panel"
                       : "View \(site.requests.count) requests in Network panel") {
                    showInNetwork(site.networkFilter)
                }
                .buttonStyle(.link)
            }
        }
    }

    private func counts(_ site: DeveloperThirdPartyCookies.Site) -> String {
        var parts: [String] = []
        if site.sent > 0 { parts.append(site.sent == 1 ? "1 cookie sent" : "\(site.sent) cookies sent") }
        if site.set > 0 {
            let verb = site.status == .blocked ? "blocked" : "set"
            parts.append(site.set == 1 ? "1 cookie " + verb : "\(site.set) cookies " + verb)
        }
        return parts.joined(separator: " · ")
    }
}
