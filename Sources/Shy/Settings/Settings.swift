import SwiftUI

/// Everything there is to set. Pages down the left, one page at a time on
/// the right, each a short list of lines with a hairline between them —
/// nothing to scroll through, nothing to hunt for. The same white and
/// hairline as the rest of the app; the same pill for the page you are on
/// as for the tab you are on.
struct SettingsPanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences
    /// The section the tab's address names (shy://settings/privacy),
    /// when Settings is a tab: asked for again, it moves there.
    var asked: String? = nil
    @Environment(\.asTab) private var asTab

    @ObservedObject private var shield = Shield.shared
    @State private var isDefault = Links.isDefault
    /// A site shortcut being written, kept out of Preferences until it's saved.
    @State private var draft: Keyword?
    @State private var page: Page = Page(rawValue: Store.settings.string(forKey: "settings.page") ?? "") ?? .general

    enum Page: String, CaseIterable, Identifiable {
        case general, tabs, profiles, shortcuts, extensions, passwords, downloads, privacy, agents, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: return "General"
            case .tabs: return "Tabs"
            case .profiles: return "Profiles & Spaces"
            case .shortcuts: return "Shortcuts"
            case .extensions: return "Extensions"
            case .passwords: return "Passwords"
            case .downloads: return "Downloads"
            case .privacy: return "Privacy"
            case .agents: return "Agents"
            case .about: return "About"
            }
        }
        var icon: String {
            switch self {
            case .general: return "macwindow"
            case .tabs: return "rectangle.split.3x1"
            case .profiles: return "person.2"
            case .shortcuts: return "keyboard"
            case .extensions: return "puzzlepiece.extension"
            case .passwords: return "key"
            case .downloads: return "arrow.down.circle"
            case .privacy: return "hand.raised"
            case .agents: return "cursorarrow.rays"
            case .about: return "info.circle"
            }
        }
    }

    private static let rail: CGFloat = 196
    private static let width: CGFloat = 700
    private static let height: CGFloat = 540

    var body: some View {
        if asTab { tabbed } else { card }
    }

    /// In a tab of its own (see InternalPages.swift): the sections down the
    /// left, the window's whole height, and the section down the middle of
    /// the rest, as wide as on the card.
    private var tabbed: some View {
        HStack(spacing: 0) {
            pages
            Rectangle().fill(Palette.hairline).frame(width: 1)
            content
                .padding(.top, 26)
                .frame(maxWidth: SettingsPanel.width - SettingsPanel.rail + 60)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { follow(asked) }
        .onChange(of: asked) { _, asked in follow(asked) }
        .onChange(of: page) { _, page in
            Store.settings.set(page.rawValue, forKey: "settings.page")
            browser.settingsMoved(to: page)
        }
    }

    private func follow(_ asked: String?) {
        guard let asked, let wanted = Page(rawValue: asked), wanted != page else { return }
        page = wanted
    }

    private var card: some View {
        HStack(spacing: 0) {
            pages
            Rectangle().fill(Palette.hairline).frame(width: 1)
            content
        }
        .frame(width: SettingsPanel.width, height: SettingsPanel.height)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 34, y: 12)
        .onChange(of: page) { _, page in Store.settings.set(page.rawValue, forKey: "settings.page") }
    }

    // MARK: - the rail

    private var pages: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Settings")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 10)
                .padding(.top, 14)
                .padding(.bottom, 12)
            ForEach(Page.allCases) { item in
                PageRow(page: item, on: page == item) { page = item }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: SettingsPanel.rail, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Palette.wash.opacity(0.45), in: Rectangle())
    }

    private struct PageRow: View {
        let page: Page
        let on: Bool
        let act: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: act) {
                HStack(spacing: 9) {
                    Image(systemName: page.icon)
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 16)
                    Text(page.title)
                        .font(.system(size: 13, weight: on ? .medium : .regular))
                        .lineLimit(1)
                        .fixedSize()
                    Spacer(minLength: 0)
                }
                .foregroundStyle(on ? Palette.ink : (hovering ? Palette.ink.opacity(0.75) : Palette.muted))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(on ? Palette.ground : (hovering ? Palette.hover : .clear))
                        .shadow(color: .black.opacity(on ? 0.06 : 0), radius: 3, y: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
        }
    }

    // MARK: - the page

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(page.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Spacer()
                if !asTab {
                    Door(icon: "xmark", help: "Done   esc") { browser.tuning = false }
                }
            }
            .padding(.bottom, 16)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    switch page {
                    case .general: general
                    case .tabs:
                        tabs
                    case .profiles: ProfilesPage(browser: browser)
                    case .shortcuts: ShortcutsPage(browser: browser, store: .shared, prefs: prefs)
                    case .extensions: ExtensionsPage(browser: browser)
                    case .passwords: passwords
                    case .downloads: downloads
                    case .agents: agents
                    case .privacy: privacy
                    case .about: about
                    }
                }
                .padding(.bottom, 4)
            }
            // A page of its own opens at its top. One scroll view kept for
            // them all opened Tabs as far down as General had been read.
            .id(page)
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - general

    private var general: some View {
        VStack(alignment: .leading, spacing: 18) {
            group("Shy on this Mac") {
                Line(
                    "Default browser",
                    isDefault ? "Links from other apps open in Shy" : "Links from other apps open in another browser"
                ) {
                    if isDefault {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Palette.ink)
                            .frame(width: 24)
                    } else {
                        Pill("Make default", filled: true) {
                            Links.becomeDefault { worked in
                                isDefault = Links.isDefault
                                browser.announce(worked && isDefault ? "Links now open here" : "macOS didn't change it")
                            }
                        }
                    }
                }
                Rule()
                Line("Open links from other apps in a mini window", "Read and close it, or move it into a tab with ⌘O") {
                    Switch(on: $prefs.littleLinks)
                }
                Rule()
                // What another browser exported, now or any time later: the same
                // sheet as File › Bring In a File….
                Line("Import from a file", "Bookmarks (HTML), passwords (CSV) or a Safari export (ZIP)") {
                    Pill("Import…") { browser.importFile() }
                }
                Rule()
                Line("Confirm before quitting with ⌘Q") {
                    Switch(on: $prefs.confirmsQuit)
                }
            }
            group("Search and the address field") {
                // What ⌘T opens to, and the way back after an extension took
                // it. Only there while an extension offers a page; it brings
                // its own hairline.
                HomePageLine()
                Line("Search engine", searchDetail) {
                    Picker("", selection: $prefs.engine) {
                        ForEach(Engine.allCases) { engine in
                            Text(engine.title).tag(engine)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                if prefs.engine == .custom {
                    ZStack(alignment: .leading) {
                        if prefs.customEngine.isEmpty {
                            Text("https://example.com/search?q=%s")
                                .foregroundStyle(Palette.muted.opacity(0.8))
                        }
                        TextField("", text: $prefs.customEngine)
                            .textFieldStyle(.plain)
                            .foregroundStyle(Palette.ink)
                    }
                    .font(.system(size: 12.5))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .padding(.horizontal, 14)
                    .padding(.bottom, 11)
                }
                Rule()
                Line("Search suggestions", suggestDetail) {
                    Switch(on: $prefs.engineSuggests)
                }
                Rule()
                Line("Open new tabs in a floating field", "⌘T shows the address field over the current page, as in Arc") {
                    Switch(on: $prefs.floatingNewTab)
                }
                Rule()
                Line("Site shortcuts", keywordDetail) {
                    if draft == nil {
                        Pill("Add") { draft = Keyword() }
                    } else {
                        HStack(spacing: 6) {
                            Pill("Cancel") { draft = nil }
                            Pill("Save", filled: true) { saveDraft() }
                                .disabled(draftProblem != nil)
                                .opacity(draftProblem == nil ? 1 : 0.4)
                        }
                    }
                }
                if let current = draft {
                    HStack(spacing: 8) {
                        TextField("yt", text: Binding(
                            get: { current.keyword },
                            set: { draft?.keyword = $0 }
                        ))
                        .textFieldStyle(.plain)
                        .frame(width: 50)
                        Text("→").foregroundStyle(Palette.muted)
                        TextField("https://www.youtube.com/results?search_query=%s", text: Binding(
                            get: { current.template },
                            set: { draft?.template = $0 }
                        ))
                        .textFieldStyle(.plain)
                        .onSubmit(saveDraft)
                    }
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
                }
                ForEach(prefs.keywords) { entry in
                    HStack(spacing: 8) {
                        Text(entry.keyword)
                            .frame(width: 50, alignment: .leading)
                        Text("→").foregroundStyle(Palette.muted)
                        Text(entry.template)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            prefs.keywords.removeAll { $0.id == entry.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Palette.faint)
                        }
                        .buttonStyle(.plain)
                    }
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
                }
            }
            group("Appearance") {
                Line("Appearance") {
                    Segmented(options: Look.allCases.map { ($0, $0.title) }, selection: $prefs.look)
                }
                Rule()
                Line("Default page zoom", "⌘+ and ⌘− still set each site's own") {
                    // The number itself takes it back to 100%.
                    Steps(stops: Preferences.zooms, value: $prefs.pageZoom, home: 1) { "\(Int(($0 * 100).rounded()))%" }
                }
            }
            group("Typing and scrolling") {
                Line("Autocorrect spelling in pages") {
                    Switch(on: $prefs.autocorrect)
                }
                Rule()
                Line("Autoscroll with the middle mouse button", "Click the wheel, then move the mouse to scroll") {
                    Switch(on: $prefs.autoScroll)
                }
            }
            group("Reading") {
                Line("Reading mode follows dark mode") {
                    Switch(on: $prefs.readerFollowsLook)
                }
                if PageTranslator.available {
                    Rule()
                    Line("Translate pages", "On this Mac, by macOS. Right-click › Translate Page") {
                        Switch(on: $prefs.translatesPages)
                    }
                    if prefs.translatesPages { TranslateLanguageList(prefs: prefs) }
                }
            }
            group("Video") {
                Line("Picture in picture automatically", prefs.floatWhen.detail) {
                    Picker("", selection: $prefs.floatWhen) {
                        ForEach(FloatWhen.allCases) { when in
                            Text(when.title).tag(when)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                Rule()
                Line("Block autoplay", "Muted videos too. Open tabs follow once reloaded") {
                    Switch(on: $prefs.waitsForPlay)
                }
                Rule()
                Line("Press Esc twice to exit full screen", "The first press only shows a reminder") {
                    Switch(on: $prefs.escapeTwice)
                }
            }
            group("Performance") {
                Line("Pages at 120 Hz", "Smoother scrolling, more battery. On power: only while plugged in") {
                    Segmented(options: FastPages.allCases.map { ($0, $0.title) }, selection: $prefs.fastPages)
                }
                Rule()
                Line("Reduce motion in Low Power Mode") {
                    Switch(on: $prefs.lightMotion)
                }
            }
        }
    }

    /// A named card, so a long page reads as a few things.
    private func group<Content: View>(_ title: String, @ViewBuilder _ content: @escaping () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Caption(title)
            Card(content: content)
        }
    }

    // MARK: - agents

    /// What may drive Shy from outside it: AI agents, through shy-mcp
    /// (Agent.swift), and what each of its calls may do; and the bench.
    private var agents: some View {
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
    private var draftProblem: String? {
        guard let draft else { return nil }
        return Keyword.problem(word: draft.keyword, template: draft.template, among: prefs.keywords)
    }

    private var keywordDetail: String {
        guard let draft else {
            return "Type a word first to search one site: \"yt cats\" searches YouTube"
        }
        if draft.keyword.isEmpty, draft.template.isEmpty {
            return "A word, then the site's search address with %s where the words go"
        }
        return draftProblem ?? "\(draft.keyword.trimmingCharacters(in: .whitespacesAndNewlines)) will search \(draft.name)"
    }

    private func saveDraft() {
        guard let current = draft, draftProblem == nil else { return }
        prefs.keywords.append(Keyword(
            keyword: current.keyword.trimmingCharacters(in: .whitespacesAndNewlines),
            template: current.template.trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        draft = nil
    }

    /// Said plainly: turned on, what you type leaves the Mac as you type it.
    private var suggestDetail: String {
        let name = prefs.engine.name(custom: prefs.customEngine)
        guard EngineSuggest.endpoint(for: prefs.engine) != nil else {
            return "A custom engine has none to offer, so nothing is sent"
        }
        return "Sends what you type to \(name) as you type. Never addresses, never from private tabs"
    }

    private var searchDetail: String? {
        guard prefs.engine == .custom else { return nil }
        guard Engine.accepts(prefs.customEngine) else {
            return "An http or https address with %s for the words. Until then, Google"
        }
        return "Searches go to \(prefs.engine.name(custom: prefs.customEngine))"
    }

    // MARK: - tabs

    private var tabs: some View {
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

    // MARK: - passwords

    /// Says so when a password manager extension has taken the saving over.
    private var savingDetail: String {
        if #available(macOS 15.4, *), let name = Extensions.shared.passwordSavingTakenBy {
            return "\(name) does the saving — it asked Shy not to offer"
        }
        return "Once per site, never again where you say no"
    }

    private var passwords: some View {
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

    // MARK: - downloads

    private var downloads: some View {
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

    // MARK: - privacy

    private var privacy: some View {
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

    // MARK: - about

    private var about: some View {
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

    // MARK: - doing

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

    // MARK: - pieces

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

/// A row of choices in a grey track, one of them lifted out in white. The
/// white slides to the one you pick rather than appearing there.
struct Segmented<Option: Hashable>: View {
    let options: [(Option, String)]
    @Binding var selection: Option
    /// True when the control has the whole width to itself, so the choices
    /// share it evenly instead of each taking only what its word needs.
    var wide = false

    @Namespace private var slide

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { option, title in
                Text(title)
                    .font(.system(size: 11.5, weight: option == selection ? .medium : .regular))
                    .foregroundStyle(option == selection ? Palette.ink : Palette.muted)
                    .lineLimit(1)
                    .fixedSize(horizontal: !wide, vertical: false)
                    .frame(maxWidth: wide ? .infinity : nil)
                    .padding(.horizontal, wide ? 4 : 10)
                    .padding(.vertical, 5)
                    .background {
                        if option == selection {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Palette.ground)
                                .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                                .matchedGeometryEffect(id: "chosen", in: slide)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .onTapGesture {
                        withAnimation(Motion.settle) { selection = option }
                    }
            }
        }
        .padding(2)
        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .animation(Motion.settle, value: selection)
    }
}

/// On or off, in ink rather than in blue.
struct Switch: View {
    @Binding var on: Bool

    var body: some View {
        Capsule()
            .fill(on ? Palette.ink : Palette.faint)
            .frame(width: 30, height: 18)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle()
                    .fill(Palette.ground)
                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                    .padding(2)
            }
            .contentShape(Capsule())
            .onTapGesture { withAnimation(Motion.settle) { on.toggle() } }
            .animation(Motion.settle, value: on)
    }
}

/// A value moved one stop at a time: − and + either side of it, in the same
/// outlined capsule as a pill. Pressing the value itself takes it home.
struct Steps: View {
    let stops: [Double]
    @Binding var value: Double
    let home: Double
    let label: (Double) -> String

    /// The nearest stop either way — a value between stops, from before
    /// there were stops, still moves to a round one.
    private var below: Double? { stops.last { $0 < value - 0.001 } }
    private var above: Double? { stops.first { $0 > value + 0.001 } }

    var body: some View {
        HStack(spacing: 0) {
            Step(icon: "minus", to: below) { value = $0 }
            Button { value = home } label: {
                Text(label(value))
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(Palette.ink)
                    .frame(minWidth: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back to \(label(home))")
            Step(icon: "plus", to: above) { value = $0 }
        }
        .padding(.horizontal, 2)
        .frame(height: 24)
        .background(Palette.ground, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
    }

    private struct Step: View {
        let icon: String
        let to: Double?
        let act: (Double) -> Void
        @State private var hovering = false

        var body: some View {
            Button { if let to { act(to) } } label: {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(to == nil ? Palette.faint : Palette.ink)
                    .frame(width: 20, height: 20)
                    .background(hovering && to != nil ? Palette.hover : .clear, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(to == nil)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
        }
    }
}

/// A small capsule that does one thing. Outlined by default; filled in ink
/// when it is the thing you came here to press.
struct Pill: View {
    let title: String
    var filled = false
    var tint: Color = Palette.ink
    let action: () -> Void

    @State private var hovering = false

    init(_ title: String, filled: Bool = false, tint: Color = Palette.ink, action: @escaping () -> Void) {
        self.title = title
        self.filled = filled
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(filled ? Palette.ground : tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(filled ? Palette.ink : (hovering ? Palette.hover : Palette.ground), in: Capsule())
                .overlay(Capsule().strokeBorder(filled ? .clear : Palette.hairline, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
    }
}

/// Settings › Privacy: the sites allowed to send notifications, each with a
/// way to take it back.
private struct NotificationSites: View {
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
private struct AgentLines: View {
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
