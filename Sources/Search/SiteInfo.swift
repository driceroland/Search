import SwiftUI
import Security

// Site Information: a tab's right-click menu, for the one thing a lock icon
// usually says without a click - whether this connection is actually secure,
// whose certificate it is, who vouched for it, and until when.

extension Browser {
    struct SiteInfo {
        let host: String
        let secure: Bool
        let issuedTo: String?
        let issuedBy: String?
        let expires: Date?
    }

    /// `serverTrust` is the trust WebKit already evaluated once to let the
    /// page through - asked again here, not fetched anew.
    func siteInfo(for tab: Tab) -> SiteInfo? {
        guard let url = tab.address, let host = url.host() else { return nil }
        guard url.scheme == "https", let trust = tab.web.serverTrust else {
            return SiteInfo(host: host, secure: false, issuedTo: nil, issuedBy: nil, expires: nil)
        }
        let secure = SecTrustEvaluateWithError(trust, nil)
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            return SiteInfo(host: host, secure: secure, issuedTo: nil, issuedBy: nil, expires: nil)
        }
        let keys = [kSecOIDX509V1IssuerName, kSecOIDX509V1ValidityNotAfter] as CFArray
        let values = SecCertificateCopyValues(leaf, keys, nil) as? [CFString: Any]
        return SiteInfo(
            host: host,
            secure: secure,
            issuedTo: SecCertificateCopySubjectSummary(leaf) as String?,
            issuedBy: SiteInfoPanel.name(in: values?[kSecOIDX509V1IssuerName]),
            expires: SiteInfoPanel.date(in: values?[kSecOIDX509V1ValidityNotAfter])
        )
    }
}

struct SiteInfoPanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab

    var body: some View {
        Plate("Site Information", width: 420, close: { browser.showingSiteInfo = false }) {
            if let info = browser.siteInfo(for: tab) {
                Card {
                    Line(
                        info.host,
                        info.secure
                            ? "The connection is encrypted, and the certificate checks out"
                            : "The connection is not secure - anything sent could be read on the way"
                    ) {
                        Image(systemName: info.secure ? "lock.fill" : "lock.slash")
                            .font(.system(size: 13))
                            .foregroundStyle(info.secure ? Palette.ink : .red)
                    }
                    if let issuedTo = info.issuedTo {
                        Rule()
                        Line("Issued to", issuedTo) { EmptyView() }
                    }
                    if let issuedBy = info.issuedBy {
                        Rule()
                        Line("Issued by", issuedBy) { EmptyView() }
                    }
                    if let expires = info.expires {
                        Rule()
                        Line("Valid until", SiteInfoPanel.formatted(expires)) { EmptyView() }
                    }
                }
            } else {
                Card { Nothing("Nothing to show for this page.") }
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter
    }()

    fileprivate static func formatted(_ date: Date) -> String { dateFormatter.string(from: date) }

    /// A certificate's name fields (the issuer among them) come back as a
    /// list of labelled parts - the organisation if it gave one, the common
    /// name otherwise.
    fileprivate static func name(in field: Any?) -> String? {
        guard let dict = field as? [CFString: Any],
              let parts = dict[kSecPropertyKeyValue] as? [[CFString: Any]]
        else { return nil }
        for label in ["O", "CN"] {
            if let part = parts.first(where: { ($0[kSecPropertyKeyLabel] as? String) == label }),
               let value = part[kSecPropertyKeyValue] as? String {
                return value
            }
        }
        return nil
    }

    /// A date field comes back as seconds since the reference date, not a
    /// `Date` - the value Security.framework itself uses throughout.
    fileprivate static func date(in field: Any?) -> Date? {
        guard let dict = field as? [CFString: Any],
              let seconds = dict[kSecPropertyKeyValue] as? Double
        else { return nil }
        return Date(timeIntervalSinceReferenceDate: seconds)
    }
}
