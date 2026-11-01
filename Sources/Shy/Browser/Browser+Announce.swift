import SwiftUI
import WebKit
import Combine

// Saying so: the line at the foot of the window, and what was closed.
extension Browser {
    /// ⌘⇧C. The address, in the clipboard, and a line that says as much.
    func copyAddress() {
        guard let url = active?.address else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        announce("Address copied")
    }

    /// ⌥⇧⌘C. The address without its tracking parameters (CleanLink).
    func copyCleanLink() {
        guard let url = active?.address else { return }
        CleanLink.copy(url)
        announce("Clean link copied")
    }

    /// For pasting into notes and messages that read Markdown: a title that
    /// links, not a bare address to explain in your own words.
    func copyMarkdownLink() {
        guard let tab = active, let url = tab.address else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Browser.markdownLink(tab.label, url), forType: .string)
        announce("Link copied")
    }

    /// A page as a Markdown link, its title the text. A backslash first, so
    /// the ones added next aren't doubled; then both brackets, either of
    /// which would end or break the link's text.
    static func markdownLink(_ title: String, _ url: URL) -> String {
        let text = title
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        return "[\(text)](\(url.absoluteString))"
    }

    func announce(_ text: String, file: URL? = nil) {
        announcement = text
        announcedFile = file
        hush?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.announcement = nil
            self?.announcedFile = nil
        }
        hush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (file == nil ? 1.7 : 4), execute: work)
    }

    /// The ones closed in the profile on screen, the only ones offered back:
    /// an address from one profile — a sign-in link, a document — reopened
    /// in another would be taken there with that one's sign-ins.
    var closedHere: [Ghost] { ghosts.filter { $0.profile == profileID } }

    /// A deleted profile's closed tabs, gone with it.
    func forgetGhosts(of profile: UUID) { ghosts.removeAll { $0.profile == profile } }

    struct Ghost: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        let title: String
        let index: Int
        /// When it was closed, to weigh against a window closed since.
        var at = Date()
        /// The other page of the pair it was in, and whether it was on that
        /// page's left: ⇧⌘T puts it back beside it, while that page is alone.
        var partner: Tab.ID? = nil
        var onLeft = false
        /// The tab it was, so a pair closed together finds its other half
        /// again when both come back (see reopen(batch:)).
        var was: Tab.ID? = nil
        /// The Clear it went with: one ⇧⌘T brings back the whole of it.
        var batch: UUID? = nil
        /// Of a Clear's tabs, the one you were on, which comes back in front.
        var front = false
        /// The profile it was signed in as: it comes back only there, never
        /// with another's sign-ins (see closedHere).
        var profile = Profile.personalID

        var label: String { title.isEmpty ? Address.pretty(url) : title }
    }

    /// What handOff decided, in a test run, for the bench.
    static var handedOff: [String] = []
}
