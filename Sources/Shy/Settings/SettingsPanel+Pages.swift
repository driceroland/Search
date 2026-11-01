import SwiftUI

// The pages of Settings after General: agents, tabs, passwords, downloads, privacy, about.
extension SettingsPanel {
    /// What may drive Shy from outside it: AI agents, through shy-mcp
    /// (Agent.swift), and what each of its calls may do; and the bench.
    var agents: some View {
        VStack(alignment: .leading, spacing: 18) {
            group("AI agents") {
                Line("Let AI agents browse", "Through MCP, in private pages in the Agent folder you can watch. Never your tabs or passwords") {
                    Switch(on: $prefs.agent)
                }
                if prefs.agent { AgentLines(agent: .shared) }
            }
            if prefs.agent {
                group("What agents may do") {
                    ForEach(Array(Agent.Ability.allCases.enumerated()), id: \.element) { index, ability in
                        if index > 0 { Rule() }
                        Line(ability.title, ability.detail) {
                            Switch(on: Binding(
                                get: { !prefs.agentDenied.contains(ability.rawValue) },
                                set: { on in
                                    if on { prefs.agentDenied.remove(ability.rawValue) } else { prefs.agentDenied.insert(ability.rawValue) }
                                }
                            ))
                        }
                    }
                }
            }
            #if DEBUG
            group("Testing") {
                Line("Let scripts control Shy", "A local socket for ./bench. Its tabs carry a flask and never take focus") {
                    Switch(on: $prefs.bench)
                }
            }
            #endif
        }
    }

    /// Checked when it's saved, not as it's typed into the list: a shortcut
    /// only exists once its address is one it's safe to send words to.
    var draftProblem: String? {
        guard let draft else { return nil }
        return Keyword.problem(word: draft.keyword, template: draft.template, among: prefs.keywords)
    }

    var keywordDetail: String {
        guard let draft else {
            return "Type a word first to search one site: \"yt cats\" searches YouTube"
        }
        if draft.keyword.isEmpty, draft.template.isEmpty {
            return "A word, then the site's search address with %s where the words go"
        }
        return draftProblem ?? "\(draft.keyword.trimmingCharacters(in: .whitespacesAndNewlines)) will search \(draft.name)"
    }

    func saveDraft() {
        guard let current = draft, draftProblem == nil else { return }
        prefs.keywords.append(Keyword(
            keyword: current.keyword.trimmingCharacters(in: .whitespacesAndNewlines),
            template: current.template.trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        draft = nil
    }

    /// Said plainly: turned on, what you type leaves the Mac as you type it.
    var suggestDetail: String {
        let name = prefs.engine.name(custom: prefs.customEngine)
        guard EngineSuggest.endpoint(for: prefs.engine) != nil else {
            return "A custom engine has none to offer, so nothing is sent"
        }
        return "Sends what you type to \(name) as you type. Never addresses, never from private tabs"
    }

    var searchDetail: String? {
        guard prefs.engine == .custom else { return nil }
        guard Engine.accepts(prefs.customEngine) else {
            return "An http or https address with %s for the words. Until then, Google"
        }
        return "Searches go to \(prefs.engine.name(custom: prefs.customEngine))"
    }

    var tabs: some View {
        VStack(alignment: .leading, spacing: 18) {
            group("Sidebar") {
                Line("Sidebar position", "Drag its edge to resize, double-click to reset") {
                    Segmented(options: SidebarPosition.allCases.map { ($0, $0.title) }, selection: $prefs.sidePosition)
                }
                Rule()
                Line("Show the hidden sidebar at the edge", "Folded with ⌘S, it comes out when the pointer meets the edge. Off, only ⌘S shows it") {
                    Switch(on: $prefs.sidePeeks)
                }
                Rule()
                Line("Show the page as a card", "Rounded corners and a small margin") {
                    Switch(on: Binding(
                        get: { prefs.cards },
                        set: { on in withAnimation(Motion.glide) { prefs.cards = on } }
                    ))
                }
                Rule()
                Line("Larger tabs") {
                    Switch(on: Binding(
                        get: { prefs.roomyTabs },
                        set: { on in withAnimation(Motion.glide) { prefs.roomyTabs = on } }
                    ))
                }
                Rule()
                Line("Clear keeps tabs playing sound", "Clear always keeps the tab you're on") {
                    Switch(on: $prefs.clearKeepsPlaying)
                }
                Rule()
                Line("Show the site instead of the title on the current tab", "Hover to see the title. Look-alike and insecure sites are flagged either way") {
                    Switch(on: Binding(
                        get: { prefs.showsAddress },
                        set: { on in withAnimation(Motion.glide) { prefs.showsAddress = on } }
                    ))
                }
            }
            group("Opening tabs") {
                Line("Where new tabs open", "After current: links open next to their tab, ⌘T at the bottom") {
                    Picker("New tab position", selection: $prefs.newTabPlace) {
                        Text("After current").tag(NewTabPlace.next)
                        Text("Top").tag(NewTabPlace.top)
                        Text("Bottom").tag(NewTabPlace.end)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                Rule()
                Line("Load background tabs only when you open them", "Links opened with ⌘-click, the middle button or from other apps") {
                    Switch(on: $prefs.lazyTabs)
                }
                Rule()
                Line("Open sized pop-ups as windows", "When a site asks for a window of its own size. Blocking still applies") {
                    Switch(on: $prefs.popupWindows)
                }
                Rule()
                Line("Start with only pinned tabs", "Pins, folders and named tabs stay. Last session's other tabs don't") {
                    Switch(on: $prefs.startsFresh)
                }
            }
            group("Idle tabs") {
                Line("Put idle tabs to sleep", prefs.sleepPace.detail) {
                    Picker("", selection: $prefs.sleepPace) {
                        ForEach(SleepPace.allCases) { pace in
                            Text(pace.title).tag(pace)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                Rule()
                Line("Close idle tabs", "Pinned, foldered and named tabs stay. ⇧⌘T brings one back") {
                    Picker("", selection: $prefs.tabLife) {
                        ForEach(TabLife.allCases) { life in
                            Text(life.title).tag(life)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }
        }
    }

    /// Says so when a password manager extension has taken the saving over.
    private var savingDetail: String {
        if #available(macOS 15.4, *), let name = Extensions.shared.passwordSavingTakenBy {
            return "\(name) does the saving — it asked Shy not to offer"
        }
        return "Once per site, never again where you say no"
    }

    var passwords: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                Line("Saved passwords", "Kept in the macOS keychain, opened with Touch ID") {
                    Pill("Open…") { browser.lead(to: InternalPage(.passwords)) }
                }
                Rule()
                Line("Offer to save passwords", savingDetail) {
                    Switch(on: $prefs.savesPasswords)
                }
                Rule()
                Line("Autofill sign-ins") {
                    Switch(on: $prefs.fillsPasswords)
                }
                Rule()
                Line(
                    "Offer passkeys",
                    !prefs.passkeysPossible
                        ? "Needs an Apple entitlement this build doesn't have — off keeps sites to the password"
                        : Passkeys.access == .denied
                        ? "macOS was told no — System Settings › Privacy & Security › Passkeys Access for Web Browsers"
                        : "Touch ID or iCloud Keychain, where sites support them"
                ) {
                    Switch(on: $prefs.passkeys)
                }
                if !Vault.never(in: browser.profileID).isEmpty {
                    Rule()
                    Line("Sites you told never to save", Vault.never(in: browser.profileID).count == 1 ? "1 site" : "\(Vault.never(in: browser.profileID).count) sites") {
                        Pill("Forget") {
                            Vault.setNever([], in: browser.profileID)
                            browser.announce("Every site can ask again")
                        }
                    }
                }
            }
            Card {
                Line("Import passwords", "From another browser on this Mac") {
                    Pill("Import…") { browser.importFile() }
                }
            }
        }
    }

    var downloads: some View {
        Card {
            Line("Save to", prefs.downloads.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                Pill("Change…") { chooseFolder() }
            }
            Rule()
            Line("Ask where to save each download") {
                Switch(on: $prefs.asksWhereToSave)
            }
            Rule()
            Line("Always show the downloads button", "Otherwise only while something downloads") {
                Switch(on: $prefs.alwaysShowsDownloads)
            }
        }
    }

    var privacy: some View {
        VStack(alignment: .leading, spacing: 18) {
            group("Tracking") {
                Line("Block ads and trackers", shield.trouble) {
                    Switch(on: $prefs.shielded)
                }
                if let trouble = shield.trouble {
                    Rule()
                    Line(trouble, "Nothing is being blocked until this clears — try again, or restart Shy") {
                        Pill("Try again") { shield.compile() }
                    }
                }
                // Not from a private tab: its site would be written down.
                if let host = browser.hereHost, prefs.shielded, shield.trouble == nil, browser.active?.shy != true {
                    Rule()
                    Line("Block on \(host)", "Turn off if the site breaks. The page reloads") {
                        Switch(on: Binding(
                            get: { !Shield.shared.isPaused(on: host, in: browser.active?.profile ?? browser.profileID) },
                            set: { on in
                                Shield.shared.pause(host, !on, in: browser.active?.profile ?? browser.profileID)
                                browser.reload()
                            }
                        ))
                    }
                }
                Rule()
                Line("Prevent cross-site tracking", "As in Safari. Off, rarely visited sites stay signed in, but trackers can follow you") {
                    Switch(on: Binding(get: { !prefs.keepsSignIns }, set: { prefs.keepsSignIns = !$0 }))
                }
            }
            group("Site permissions") {
                Line("Camera, microphone, location and notifications", "Forget what each site was allowed or refused") {
                    Pill("Reset") { browser.forgetCaptureChoices() }
                }
                Rule()
                Line("Let sites ask to send notifications", "Private tabs never ask") {
                    Switch(on: $prefs.siteNotifications)
                }
                NotificationSites(profile: browser.profileID)
                PopupSiteList(prefs: prefs, profile: browser.profileID)
            }
            group("Clear browsing data") {
                Line("History") {
                    Pill("Clear") { browser.clearHistory() }
                }
                Rule()
                Line("Cookies and sign-ins", "Signs you out of every site") {
                    Pill("Sign out of everything") { browser.clearSites() }
                }
                Rule()
                Line("Cache", "Copies of pages kept to load them faster") {
                    Pill("Clear") { browser.clearCache() }
                }
            }
        }
    }

    var about: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Logomark()
                    .fill(Palette.ink, style: FillStyle(eoFill: true))
                    .aspectRatio(Logomark.canvas.width / Logomark.canvas.height, contentMode: .fit)
                    .frame(height: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Shy")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Text("version \(Version.number), build \(Version.build) · a fork of Search by Office Commun")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                }
            }
            .padding(.bottom, 2)

            Card {
                Line("Updates", "Shy never checks for updates. Install new versions yourself") {
                    EmptyView()
                }
                Rule()
                Line("Report a problem", "Opens a GitHub issue with your version filled in") {
                    Pill("Send Feedback") { Links.writeFeedback() }
                }
            }

            Card {
                Shortcut("⌘L", "Address")
                Rule()
                Shortcut("⌘K", "Switch tab")
                Rule()
                Shortcut("⌘T  ⌘W  ⇧⌘T", "New, close, reopen tab")
                Rule()
                Shortcut("⇧⌘V", "Paste and go")
                Rule()
                Shortcut("⇧⌘C  ⌥⇧⌘C", "Copy address, a clean link")
                Rule()
                Shortcut("⌃⇥  ⌘1–9", "Next tab, a tab by its place")
                Rule()
                Shortcut("⌘S", "Fold the sidebar away")
                Rule()
                Shortcut("⇧⌘R", "Reading mode")
                Rule()
                Shortcut("⇧⌘H", "Hide something on this site")
                Rule()
                Shortcut("⇧⌘P", "Float the video")
                Rule()
                Shortcut("⇧⌘⌫", "Clear browsing data")
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = prefs.downloads
        panel.prompt = "Use this folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        prefs.downloads = url
    }

    /// A keystroke and what it does.
    private struct Shortcut: View {
        let keys: String
        let does: String
        init(_ keys: String, _ does: String) { self.keys = keys; self.does = does }

        var body: some View {
            HStack {
                Text(does)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink)
                Spacer()
                Text(keys)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
    }
}
