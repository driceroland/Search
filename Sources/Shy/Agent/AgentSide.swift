import SwiftUI
import WebKit

// What you see of an agent's session (Agent.swift): its folder at the top of
// the column, in every space; its page in the window when you pick one, to
// watch or to use yourself; and the card that hands one of your tabs over.
// The column's own greys and hairlines: the agent's mark and the bar over
// its page are what say whose it is.

/// The Agent folder: the session's pages, its questions for you, and the
/// one button that ends it. Not in any space or profile, so it stays where
/// it is as you go from one to another; not there at all with no session.
struct AgentSection: View {
    @Environment(\.greys) private var greys
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var agent: Agent

    var body: some View {
        if !agent.pages.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                header
                ForEach(agent.pending) { approval in
                    ApprovalRow(agent: agent, approval: approval)
                }
                if !agent.folded {
                    ForEach(agent.pages) { page in
                        AgentRow(browser: browser, prefs: prefs, agent: agent, page: page)
                    }
                }
            }
            .padding(4)
            .background(greys.tile, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: 1)
            )
            .padding(.bottom, 10)
            .transition(.opacity)
        }
    }

    /// Its height as drawn, rounded up, for the column's sums (SideBar.rowsEnd).
    static func height(_ agent: Agent, row: CGFloat) -> CGFloat {
        guard !agent.pages.isEmpty else { return 0 }
        let rows = agent.folded ? 0 : CGFloat(agent.pages.count) * (row + 2)
        return 8 + 30 + rows + agent.pending.reduce(0) { $0 + ($1.picture == nil ? 74 : 170) } + 10 + 4
    }

    private var header: some View {
        HStack(spacing: 7) {
            AgentMark(busy: agent.busy != nil)
            Text("Agent Session")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .help(status)
            Spacer(minLength: 4)
            Door(icon: agent.folded ? "chevron.down" : "chevron.up", help: agent.folded ? "Show pages" : "Fold") {
                withAnimation(Motion.settle) { agent.folded.toggle() }
            }
            Door(icon: "stop.circle", help: "End the session: close every agent page and forget what they hold") {
                withAnimation(Motion.settle) { agent.closeAll() }
            }
        }
        .padding(.leading, 6)
        .frame(height: 30)
    }

    private var status: String {
        let who = agent.client ?? "An agent"
        if let busy = agent.busy { return "\(who) · \(busy.doing)" }
        return agent.pages.count == 1 ? "\(who) · 1 page" : "\(who) · \(agent.pages.count) pages"
    }
}

/// The agent's sign, everywhere it shows: its folder, its rows, its page.
/// It breathes while the agent is acting.
struct AgentMark: View {
    var busy = false
    var size: CGFloat = 12
    @State private var breathing = false

    var body: some View {
        Image(systemName: "cursorarrow.rays")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(Palette.ink)
            .opacity(busy && breathing ? 0.3 : 1)
            .animation(busy ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : .default, value: breathing)
            .onAppear { breathing = busy }
            .onChange(of: busy) { _, now in breathing = now }
    }
}

/// One page of the session: its title, whose sign-in it holds if any, and
/// what the agent is doing to it.
private struct AgentRow: View {
    @Environment(\.greys) private var greys
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    @ObservedObject var agent: Agent
    @ObservedObject var page: Agent.Page
    @State private var hovering = false

    private var shown: Bool { browser.watchingAgent == page.id }

    var body: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: page.handover == nil ? "globe" : "key.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(page.live != nil ? Palette.ink : Palette.muted)
                    .frame(width: 16, height: 16)
            }
            Text(page.title.isEmpty ? (page.address?.host() ?? "Loading…") : page.title)
                .font(.system(size: prefs.sideTitle))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .opacity(page.acting != nil ? 0.6 : 1)
                .help(line ?? "")
            Spacer(minLength: 0)
            if hovering {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 15, height: 15)
                    .background(Palette.ink.opacity(0.07), in: Circle())
                    .contentShape(Circle())
                    .onTapGesture { withAnimation(Motion.settle) { agent.close(page) } }
                    .help("Close this page")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: prefs.sideRow)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(shown ? greys.wash : hovering ? greys.hover : .clear)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { browser.watchAgent(page.id) }
    }

    private var line: String? {
        if let acting = page.acting { return acting.prefix(1).uppercased() + acting.dropFirst() + "…" }
        if let handover = page.handover {
            return handover.over == nil ? "Signed in to \(handover.site)" : "Sign-in removed"
        }
        return nil
    }
}

/// A click, typing or form on a page with your sign-in in it, waiting for
/// your yes.
private struct ApprovalRow: View {
    @ObservedObject var agent: Agent
    let approval: Agent.Approval

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Allow on \(approval.site)?")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Palette.ink)
            Text(approval.what)
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            // The spot a click at a point would land on, marked.
            if let picture = approval.picture {
                Image(nsImage: picture)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .overlay { Circle().strokeBorder(Palette.ink, lineWidth: 1.5).frame(width: 14, height: 14) }
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
            }
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Pill("Deny") { agent.answer(approval, false) }
                Pill("Allow", filled: true) { agent.answer(approval, true) }
            }
        }
        .padding(8)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
    }
}

/// An agent's page in the window, over yours, as usable as any page: a bar
/// over it says whose it is, what it holds and what the agent is doing, and
/// shows the steps taken on it.
struct AgentStage: View {
    @ObservedObject var browser: Browser
    @ObservedObject var agent: Agent
    var corner: CGFloat = 0
    @State private var showingSteps = false

    var body: some View {
        if let page = agent.page(browser.watchingAgent) {
            Watched(browser: browser, agent: agent, page: page, corner: corner, showingSteps: $showingSteps)
                .onDisappear { agent.reroom() }
        }
    }

    private struct Watched: View {
        @ObservedObject var browser: Browser
        @ObservedObject var agent: Agent
        @ObservedObject var page: Agent.Page
        let corner: CGFloat
        @Binding var showingSteps: Bool

        var body: some View {
            VStack(spacing: 0) {
                bar
                Rectangle().fill(Palette.hairline).frame(height: 1)
                ZStack(alignment: .topTrailing) {
                    WebStage(page: page.web)
                        .overlay(alignment: .topLeading) {
                            if let at = page.cursor { AgentCursor(presses: page.presses).offset(x: at.x, y: at.y) }
                        }
                        .animation(Motion.glide, value: page.cursor)
                    if showingSteps { steps }
                }
            }
            .background(Palette.ground)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        }

        private var bar: some View {
            HStack(spacing: 8) {
                AgentMark(busy: page.acting != nil)
                Text(says)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .help(detail)
                if let acting = page.acting {
                    Text(acting)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 8)
                if let handover = page.live {
                    Pill("Take Back Sign-In") { agent.end(page, "you took it back") }
                        .help("Ends at \(handover.ends.formatted(date: .omitted, time: .shortened)) on its own")
                }
                Pill(showingSteps ? "Hide Steps" : "Steps (\(page.steps.count))") { showingSteps.toggle() }
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(Palette.wash)
        }

        private var says: String {
            guard let handover = page.handover else { return "Not signed in" }
            if handover.over != nil { return "Sign-in to \(handover.site) removed" }
            let how = handover.acts ? (handover.asks ? "asks first" : "acts") : "read only"
            return "\(handover.site) · \(how) · until \(handover.ends.formatted(date: .omitted, time: .shortened))"
        }

        /// The bar's words said in full, on hover.
        private var detail: String {
            guard let handover = page.handover else { return "An agent page, not signed in as you" }
            if let over = handover.over { return "Your sign-in to \(handover.site) was removed: \(over)" }
            let how = handover.acts ? (handover.asks ? "asks before each click" : "can click and type") : "read only"
            return "Signed in to \(handover.site) as you, \(how), until \(handover.ends.formatted(date: .omitted, time: .shortened))"
        }

        private var steps: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(page.steps.reversed()) { step in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(step.at.formatted(date: .omitted, time: .standard))
                                .font(.system(size: 10.5).monospacedDigit())
                                .foregroundStyle(Palette.muted)
                            Text(step.what)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Palette.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(12)
            }
            .frame(width: 340)
            .frame(maxHeight: 360)
            .background(Palette.ground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
            .padding(10)
        }
    }
}

/// The agent's pointer over its page: an arrow where it last pointed, and a
/// ring that opens out each time it presses. Never in the way of yours.
private struct AgentCursor: View {
    let presses: Int
    @State private var ring = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Circle()
                .strokeBorder(Palette.ink.opacity(ring ? 0 : 0.5), lineWidth: 2)
                .frame(width: ring ? 34 : 6, height: ring ? 34 : 6)
                .offset(x: ring ? -17 : -3, y: ring ? -17 : -3)
            Image(systemName: "cursorarrow")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(Palette.ink)
                .shadow(color: Palette.ground, radius: 0, x: 1, y: 1)
                .shadow(color: Palette.ground, radius: 0, x: -1, y: -1)
                .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                .offset(x: -3, y: -2)
        }
        .allowsHitTesting(false)
        .onChange(of: presses) { _, _ in
            ring = false
            withAnimation(.easeOut(duration: 0.45)) { ring = true }
        }
    }
}

/// Right-click › Hand Over to Agent…: what would be copied, said plainly,
/// and how far the agent may go with it. Read-only and asking are where it
/// starts; nothing is copied until Hand Over is pressed.
struct HandoverCard: View {
    @ObservedObject var browser: Browser
    let tab: Tab

    @State private var found: (url: URL, cookies: [HTTPCookie], storage: Agent.Storage)?
    @State private var acts = false
    @State private var asks = true
    @State private var minutes = 30
    @State private var trouble: String?

    private var host: String { found?.url.host() ?? tab.address?.host() ?? "this site" }
    private var site: String { Vault.registrable(host) }

    var body: some View {
        Plate("Hand over to the agent", width: 420, close: { browser.handingOver = nil }) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    AgentMark(size: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(host)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                        Text(copied)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.muted)
                    }
                }
                Card {
                    Line("Access") {
                        Segmented(options: [(false, "Read only"), (true, "Read and act")], selection: $acts)
                    }
                    if acts {
                        Rule()
                        Line("Ask before each action") {
                            Switch(on: $asks)
                        }
                    }
                    Rule()
                    Line("For") {
                        Picker("", selection: $minutes) {
                            Text("15 minutes").tag(15)
                            Text("30 minutes").tag(30)
                            Text("1 hour").tag(60)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                }
                Text("Removed when time is up, when it leaves \(site), or when you take it back.")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if let trouble {
                    Text(trouble)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.unsafe)
                }
            }
        } foot: {
            HStack {
                Spacer()
                Pill("Cancel") { browser.handingOver = nil }
                Pill("Hand Over", filled: true) { handOver() }
                    .disabled(found == nil)
                    .opacity(found == nil ? 0.4 : 1)
            }
        }
        .onAppear {
            Agent.offer(tab) { url, cookies, storage in found = (url, cookies, storage) }
        }
    }

    /// What would be copied, in a few words: only this site's sign-in.
    private var copied: String {
        guard let found else { return "Looking…" }
        let count = found.cookies.count, stored = found.storage.count
        var kept: [String] = []
        if count > 0 { kept.append("\(count) cookie\(count == 1 ? "" : "s")") }
        if stored > 0 { kept.append("\(stored) stored item\(stored == 1 ? "" : "s")") }
        return kept.isEmpty ? "No sign-in to copy — the agent arrives signed out" : "Your sign-in: " + kept.joined(separator: " · ")
    }

    private func handOver() {
        guard let found else { return }
        if let why = Agent.shared.handOver(found.url, cookies: found.cookies, storage: found.storage, acts: acts, asks: acts && asks, minutes: minutes) {
            trouble = why
            return
        }
        browser.handingOver = nil
        browser.announce("Handed over \(host) to the agent")
    }
}
