import SwiftUI

/// Settings › Privacy: the sites allowed to send notifications, each with a
/// way to take it back.
struct NotificationSites: View {
    /// Whose: the profile of the space on screen.
    let profile: UUID
    @ObservedObject private var notifications = SiteNotifications.shared

    var body: some View {
        let sites = SiteNotifications.allowed(in: profile)
        if !sites.isEmpty {
            ForEach(sites, id: \.self) { site in
                Rule()
                Line(URL(string: site).map(SiteCard.site) ?? site, "Can send notifications") {
                    Pill("Remove") { SiteNotifications.forget(site, in: profile) }
                }
            }
        }
    }
}

/// How an agent reaches its pages: a prompt that has the agent set Shy up
/// itself, whichever agent it is, or the MCP server for doing it by hand;
/// and the pages open now.
struct AgentLines: View {
    @ObservedObject var agent: Agent

    /// shy-mcp, beside the app's own binary, wherever the app is: what
    /// any MCP client is told to run, over standard input and output.
    private var helper: String { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/shy-mcp").path }

    /// For pasting into the agent itself, whichever it is: what Shy is,
    /// where its server is, how to add it, and to check it took.
    private var prompt: String {
        """
        Add Shy, my web browser, as an MCP server for yourself.

        Shy's MCP server is a stdio executable with no arguments:
        \(helper)

        Register it under the name "shy" the way you add MCP servers: your own command for it, or your MCP configuration, with that path as the command.

        Then check it connects by listing its tools. With them you can open web pages, read their text, take screenshots, click and type, in private pages of your own that I can watch in Shy's Agent folder and that never touch my tabs or passwords. If I hand you one of my sign-ins, it shows up in shy_list.
        """
    }

    var body: some View {
        Rule()
        Line("Set up an agent", "Paste this prompt into your agent and it adds Shy itself") {
            Pill("Copy Prompt", filled: true) { copy(prompt) }
        }
        Rule()
        Line("MCP server", helper) {
            Pill("Copy Path") { copy(helper) }
        }
        if !agent.pages.isEmpty {
            Rule()
            Line("Open agent pages", agent.pages.count == 1 ? "1 page" : "\(agent.pages.count) pages") {
                Pill("Close All") { agent.closeAll() }
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
