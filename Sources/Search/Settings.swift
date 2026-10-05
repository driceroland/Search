import SwiftUI

/// Everything there is to set. Pages down the left, one page at a time on
/// the right, each a short list of lines with a hairline between them —
/// nothing to scroll through, nothing to hunt for. The same white and
/// hairline as the rest of the app; the same pill for the page you are on
/// as for the tab you are on.
struct SettingsPanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences

    @Bindable private var localization = Localization.shared
    @ObservedObject private var updater = Updater.shared
    @ObservedObject private var shield = Shield.shared
    @State private var isDefault = Links.isDefault
    /// A site shortcut being written, kept out of Preferences until it's saved.
    @State private var draft: Keyword?
    @State private var page: Page = Page(rawValue: Store.settings.string(forKey: "settings.page") ?? "") ?? .general

    enum Page: String, CaseIterable, Identifiable {
        case general, tabs, shortcuts, extensions, passwords, downloads, privacy, ai, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: return L("General")
            case .tabs: return L("Tabs")
            case .shortcuts: return L("Shortcuts")
            case .extensions: return L("Extensions")
            case .passwords: return L("Passwords")
            case .downloads: return L("Downloads")
            case .privacy: return L("Privacy")
            case .ai: return L("AI")
            case .about: return L("About")
            }
        }
        var icon: String {
            switch self {
            case .general: return "macwindow"
            case .tabs: return "rectangle.split.3x1"
            case .shortcuts: return "keyboard"
            case .extensions: return "puzzlepiece.extension"
            case .passwords: return "key"
            case .downloads: return "arrow.down.circle"
            case .privacy: return "hand.raised"
            case .ai: return "sparkles"
            case .about: return "info.circle"
            }
        }
    }

    private static let rail: CGFloat = 182
    private static let width: CGFloat = 680
    private static let height: CGFloat = 500

    var body: some View {
        HStack(spacing: 0) {
            pages
            Rectangle().fill(Palette.hairline).frame(width: 1)
            content
        }
        .frame(maxWidth: SettingsPanel.width, maxHeight: SettingsPanel.height)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 34, y: 12)
        .padding(16)
        .onChange(of: page) { _, page in Store.settings.set(page.rawValue, forKey: "settings.page") }
    }

    // MARK: - the rail

    private var pages: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L("Settings"))
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
                Door(icon: "xmark", help: L("Done   esc")) { browser.tuning = false }
            }
            .padding(.bottom, 16)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    switch page {
                    case .general: general
                    case .tabs:
                        tabs
                        if !prefs.sidebar { toolbar }
                    case .shortcuts: ShortcutsPage(browser: browser, store: .shared)
                    case .extensions: ExtensionsPage(browser: browser)
                    case .passwords: passwords
                    case .downloads: downloads
                    case .privacy: privacy
                    case .ai: AISettings(browser: browser, prefs: prefs)
                    case .about: about
                    }
                }
                .padding(.bottom, 4)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - general

    private var general: some View {
        Card {
            Line(L("Interface language"), L("Choose the language used in menus and settings"), detailColor: Palette.ink.opacity(0.72)) {
                Picker(L("Interface language"), selection: $localization.language) {
                    ForEach(InterfaceLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            Rule()
            Line(L("Show floating navigation"), L("Glass controls and address at the top, even when the sidebar is hidden"), detailColor: Palette.ink.opacity(0.72)) {
                Toggle(L("Show floating navigation"), isOn: $prefs.floatingNavigation)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityLabel(L("Show floating navigation"))
            }
            Rule()
            Line(
                L("Open links from other apps"),
                isDefault ? L("Search is the default browser on this Mac") : L("Mail, Slack and the rest still send links elsewhere")
            ) {
                if isDefault {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .frame(width: 24)
                } else {
                    Pill(L("Make default"), filled: true) {
                        Links.becomeDefault { worked in
                            isDefault = Links.isDefault
                            browser.announce(worked && isDefault ? L("Links now open here") : L("macOS didn't change it"))
                        }
                    }
                }
            }
            Rule()
            // Coming from another browser, now or any time later: the same
            // sheet as File › Bring Things Over… and the Welcome's.
            Line(L("Bring things over"), L("Bookmarks, history, passwords and extensions from another browser on this Mac, or from a file it exported")) {
                Pill(L("Bring Things Over…")) {
                    browser.tuning = false
                    browser.bringingIn = ""
                }
            }
            Rule()
            Line(L("Search with"), searchDetail) {
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
            Line(L("Site shortcuts"), keywordDetail) {
                if draft == nil {
                    Pill(L("Add")) { draft = Keyword() }
                } else {
                    HStack(spacing: 6) {
                        Pill(L("Cancel")) { draft = nil }
                        Pill(L("Save"), filled: true) { saveDraft() }
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
            Rule()
            Line(L("Appearance"), L("Light, dark, or whatever the Mac is doing — pages follow it too")) {
                Segmented(options: Look.allCases.map { ($0, $0.title) }, selection: $prefs.look)
            }
            Rule()
            Line(L("Page zoom"), L("Where every site starts. ⌘+ and ⌘− are still remembered for each site.")) {
                // The number itself takes it back to 100%.
                Steps(stops: Preferences.zooms, value: $prefs.pageZoom, home: 1) { "\(Int(($0 * 100).rounded()))%" }
            }
            Rule()
            Line(L("Correct spelling as you type"), L("macOS's autocorrect inside pages — the one that capitalises for you")) {
                Switch(on: $prefs.autocorrect)
            }
            Rule()
            Line(L("Peek at a link with a shift-click"), L("Its page opens in a panel over the one you're reading. Escape puts it away; the other button keeps it as a tab")) {
                Switch(on: $prefs.peeksLinks)
            }
            Rule()
            Line(L("Open links from other apps in a small window"), L("To read and close, or keep with Open in Search (⌘O)")) {
                Switch(on: $prefs.littleLinks)
            }
            Rule()
            Line(L("Address bar commands"), L("A word like \"settings\" or \"new tab\", typed alone in the address field, goes there instead of searching for it")) {
                Switch(on: $prefs.commandBar)
            }
            Rule()
            Line(L("Show where links go"), L("Point at a link and its address shows at the bottom of the page")) {
                Switch(on: $prefs.showsLinks)
            }
            Rule()
            Line(L("Scroll with the middle button"), L("Click the wheel on a page, then move the mouse up or down to scroll, as on Windows. Click again to stop")) {
                Switch(on: $prefs.autoScroll)
            }
            Rule()
            Line(L("Pages at 120 Hz"), L("Animations and scrolling in pages at up to 120 frames a second on a screen that can, instead of 60 as in Safari. Uses more battery. Open tabs follow when reloaded")) {
                Switch(on: $prefs.fastPages)
            }
            Rule()
            Line(L("Hold a swipe to pick from history"), L("Swipe back or forward and keep your fingers down: the pages that way appear, and moving up or down picks one to go to")) {
                Switch(on: $prefs.holdsHistory)
            }
            Rule()
            Line(L("Flick the floating video to a corner"), L("Two fingers on it send it to the corner or edge they point at, instead of pushing it along; a strong swipe at the side of the screen it is against tucks it in there, a sliver left to bring it back by. Dragging still puts it anywhere")) {
                Switch(on: $prefs.floatFlicks)
            }
            Rule()
            Line(L("Videos wait for a click"), L("Videos don't start by themselves, even without sound; they play when you press play. Tabs already open follow once closed and opened again, or after they've slept")) {
                Switch(on: $prefs.waitsForPlay)
            }
            Rule()
            Line(L("Float the video when you switch tabs"), L("A video playing on YouTube and the like comes out into its floating window when you go to another tab, and back when you return. ⇧⌘P still floats one by hand")) {
                Switch(on: $prefs.floatsOnLeave)
            }
            Rule()
            Line(L("Float the video when you switch apps"), L("A video playing on the site you're on comes out into its floating window as another app comes to the front, and goes back into its tab when you return")) {
                Switch(on: $prefs.floatsAway)
            }
            Rule()
            Line(L("Let a script drive Search"), L("A local socket for testing. Its tabs open beside yours with a flask on them and never take over — see ./bench")) {
                Switch(on: $prefs.bench)
            }
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
            return L("A word before your search goes straight to that site, whatever engine you've picked — \"yt cats\" to YouTube")
        }
        if draft.keyword.isEmpty, draft.template.isEmpty {
            return L("A word, then the site's search address with %s where the words go")
        }
        return draftProblem ?? L("\(draft.keyword.trimmingCharacters(in: .whitespacesAndNewlines)) will search \(draft.name)")
    }

    private func saveDraft() {
        guard let current = draft, draftProblem == nil else { return }
        prefs.keywords.append(Keyword(
            keyword: current.keyword.trimmingCharacters(in: .whitespacesAndNewlines),
            template: current.template.trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        draft = nil
    }

    private var searchDetail: String {
        guard prefs.engine == .custom else { return L("Where words that aren't an address go") }
        guard Engine.accepts(prefs.customEngine) else {
            return L("An http or https address with %s where the words go. Until then, Google")
        }
        return L("Words go to \(prefs.engine.name(custom: prefs.customEngine))")
    }

    // MARK: - tabs

    /// Where back, forward and reload sit with the tabs across the top. With
    /// the sidebar they are already beside the window's buttons: nothing to
    /// move, and the line isn't shown.
    private var toolbar: some View {
        Card {
            Line(L("Back, forward and reload on the left"), L("Beside the window's buttons, before the tabs")) {
                Switch(on: $prefs.navigationLeft)
            }
        }
    }

    private var tabs: some View {
        Card {
            Line(L("Tabs in a sidebar"), L("Down the \(prefs.sidePosition.title) instead of across the top. Pull its edge to make it wider; double-click the edge to reset.")) {
                Switch(on: Binding(
                    get: { prefs.sidebar },
                    set: { on in withAnimation(Motion.glide) { prefs.sidebar = on } }
                ))
            }
            if prefs.sidebar {
                Rule()
                Line(L("Sidebar position"), L("Tabs down the \(prefs.sidePosition.title) edge of the window")) {
                    Segmented(options: SidebarPosition.allCases.map { ($0, $0.title) }, selection: $prefs.sidePosition)
                }
                Rule()
                Line(L("Hide the sidebar until the pointer reaches the edge"), L("The page takes the whole window; push against its \(prefs.sidePosition.title) edge for the tabs. ⌘S keeps them out.")) {
                    Switch(on: $prefs.sideHides)
                }
            }
            Rule()
            Line(L("Tabs show"), L("Beside the title, and on a pinned square")) {
                Segmented(options: Glyph.allCases.map { ($0, $0.title) }, selection: $prefs.glyph)
            }
            Rule()
            Line(L("Show the bookmarks bar"), L("Your bookmarks in a row above the page, folders opening as menus. It folds away with the tabs")) {
                Switch(on: $prefs.bookmarksBar)
            }
            Rule()
            Line(L("Show how far you've read"), L("The tab you're on fills with grey as you scroll down the page")) {
                Switch(on: $prefs.showsReading)
            }
            Rule()
            Line(L("Sleep tabs you aren't using"), L("After half an hour away they come back where you left them. Pinned tabs, sound, calls and anything typed stay awake.")) {
                Switch(on: $prefs.sleepsTabs)
            }
            Rule()
            Line(L("Load background tabs when you go to them"), L("A link opened behind the page, with ⌘-click or the middle button, or a batch of links from another app, waits until you go to its tab. ⇧⌘-click still takes you there at once.")) {
                Switch(on: $prefs.lazyTabs)
            }
            Rule()
            Line(L("Search a site from the address field"), L("Type the start of a site's name, like red or yout, then Tab, and what you type next searches that site. Sites you visit that offer a search join the list.")) {
                Switch(on: $prefs.searchesSites)
            }
            Rule()
            Line(L("Start with a fresh window"), L("Each time Search opens, your pinned tabs are there and last time's other tabs aren't.")) {
                Switch(on: $prefs.startsFresh)
            }
            Rule()
            Line(L("Spaces"), L("Separate sets of tabs, signed in where the others are or starting afresh, switched with ⌃1–⌃9, two fingers sideways over the column, or the space's icon. Mission Control's own ⌃1–⌃9, if you turned them on, take those keys first.")) {
                Switch(on: $prefs.usesSpaces)
            }
            Rule()
            Line(L("Tab groups"), L("Named sections in the sidebar. Right-click a tab to start a group; click its heading to hide or show its tabs.")) {
                Switch(on: $prefs.usesTabGroups)
            }
            if prefs.sidebar {
                Rule()
                Line(L("Pinned rows"), L("As in Arc: pins as squares for the sites you live in, pins as rows under them for pages you keep, and a line over the rest with Clear. Right-click a tab to pin it as a row.")) {
                    Switch(on: $prefs.listsPins)
                }
            }
            Rule()
            Line(L("Split View"), L("Show two tabs side by side. Drag a tab onto a page to pair them.")) {
                Switch(on: $prefs.splitView)
            }
        }
    }

    // MARK: - passwords

    /// Says so when a password manager extension has taken the saving over.
    private var savingDetail: String {
        if #available(macOS 15.4, *), let name = Extensions.shared.passwordSavingTakenBy {
            return L("\(name) does the saving — it asked Search not to offer")
        }
        return L("Asked once per site, never again for a site you refuse")
    }

    private var passwords: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                Line(L("Your passwords"), L("In the macOS keychain, shown with Touch ID")) {
                    Pill(L("Open…")) {
                        browser.tuning = false
                        browser.managing = true
                    }
                }
                Rule()
                Line(L("Offer to save passwords"), savingDetail) {
                    Switch(on: $prefs.savesPasswords)
                }
                Rule()
                Line(L("Fill in sign-ins"), L("Click a sign-in box and the accounts kept for the site hang from it")) {
                    Switch(on: $prefs.fillsPasswords)
                }
                Rule()
                Line(
                    L("Offer passkeys"),
                    !prefs.passkeysPossible
                        ? L("Needs an Apple entitlement this build doesn't have — off keeps sites to the password")
                        : Passkeys.access == .denied
                        ? L("macOS was told no — System Settings › Privacy & Security › Passkeys Access for Web Browsers")
                        : L("Touch ID or an iCloud passkey, on sites that offer one")
                ) {
                    Switch(on: $prefs.passkeys)
                }
                if !Vault.never.isEmpty {
                    Rule()
                    Line(L("Sites never asked"), L("\(Vault.never.count) sites told to stop offering")) {
                        Pill(L("Forget")) {
                            Vault.never = []
                            browser.announce(L("Every site can ask again"))
                        }
                    }
                }
            }
            Card {
                Line(L("Bring yours in"), L("From another browser on this Mac — nothing leaves it")) {
                    Pill(L("Import…")) {
                        browser.tuning = false
                        browser.bringingIn = ""
                    }
                }
            }
        }
    }

    // MARK: - downloads

    private var downloads: some View {
        Card {
            Line(L("Save to"), prefs.downloads.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                Pill(L("Change…")) { chooseFolder() }
            }
            Rule()
            Line(L("Ask where to save each file")) {
                Switch(on: $prefs.asksWhereToSave)
            }
            Rule()
            Line(L("Always show the downloads button"), L("Beside the other buttons, even with nothing downloading. Off, it shows only while a file comes in")) {
                Switch(on: $prefs.alwaysShowsDownloads)
            }
        }
    }

    // MARK: - privacy

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                Line(L("Block ads and trackers"), shield.trouble ?? L("Third parties whose only job is to watch")) {
                    Switch(on: $prefs.shielded)
                }
                if let trouble = shield.trouble {
                    Rule()
                    Line(trouble, L("Nothing is being blocked until this clears — try again, or restart Search")) {
                        Pill(L("Try again")) { shield.compile() }
                    }
                }
                if let host = browser.hereHost, prefs.shielded, shield.trouble == nil {
                    Rule()
                    Line(L("Block on \(host)"), L("Turn off here if the site breaks — the page reloads")) {
                        Switch(on: Binding(
                            get: { !Shield.shared.isPaused(on: host) },
                            set: { on in
                                Shield.shared.pause(host, !on)
                                browser.reload()
                            }
                        ))
                    }
                }
                Rule()
                Line(L("Prevent cross-site tracking"), L("As in Safari. Off, sites you rarely open keep their sign-ins, and trackers inside other sites can follow you across them again, as in Chrome. Private tabs keep it on")) {
                    Switch(on: Binding(get: { !prefs.keepsSignIns }, set: { prefs.keepsSignIns = !$0 }))
                }
                Rule()
                Line(L("Camera, microphone, location and notifications"), L("What each site was allowed or refused, and the sites whose videos don't float")) {
                    Pill(L("Forget choices")) { browser.forgetCaptureChoices() }
                }
                Rule()
                Line(L("Let sites ask to send notifications"), L("A site asks on a card over its page, and only one you allow reaches your Mac's notifications. Private tabs are never asked")) {
                    Switch(on: $prefs.siteNotifications)
                }
                NotificationSites()
            }
            Card {
                Line(L("History"), L("Every address you have been to")) {
                    Pill(L("Clear")) { browser.clearHistory() }
                }
                Rule()
                Line(L("Cookies and sign-ins"), L("Signs you out of every site")) {
                    Pill(L("Sign out of everything")) { browser.clearSites() }
                }
                Rule()
                Line(L("Cache"), L("Only what was fetched to draw pages")) {
                    Pill(L("Clear")) { browser.clearCache() }
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
                    Text("Search")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Text(L("by Office Commun · version \(Updater.version)"))
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                }
            }
            .padding(.bottom, 2)

            Card {
                if Store.localProfile != nil {
                    Line(L("Local version"), L("Updates are integrated from the source project, preserving your custom interface.")) { EmptyView() }
                } else {
                Line(versionTitle, versionDetail) { versionControl }
                Rule()
                Line(L("Install updates on its own"), L("Off, Search still looks every hour and tells you, and installs only when you press Install")) {
                    Switch(on: $prefs.installsUpdates)
                }
                }
                Rule()
                Line(L("Found something wrong?"), L("Opens a draft with the version already in it")) {
                    Pill(L("Send Feedback")) { Links.writeFeedback() }
                }
                Rule()
                Line(L("What's new"), L("Every version's notes, newest first")) {
                    Pill(L("What's New…")) { browser.notesShowing = true }
                }
            }

            Card {
                Shortcut("⌘L", L("Address"))
                Rule()
                Shortcut("⌘K", L("Switch tab"))
                Rule()
                Shortcut("⌘T  ⌘W  ⇧⌘T", L("New, close, reopen tab"))
                Rule()
                Shortcut("⇧⌘V", L("Paste and go"))
                Rule()
                Shortcut("⇧⌘C", L("Copy address"))
                Rule()
                Shortcut("⌃⇥  ⌘1–9", L("Next tab, a tab by its place"))
                Rule()
                Shortcut("⇧⌘S", L("Tabs in a sidebar"))
                Rule()
                Shortcut("⌘S", L("Fold the sidebar away"))
                Rule()
                Shortcut("⇧⌘R", L("Reading mode"))
                Rule()
                Shortcut("⇧⌘H", L("Hide something on this site"))
                Rule()
                Shortcut("⇧⌘P", L("Float the video"))
                Rule()
                Shortcut("⇧⌘⌫", L("Clear browsing data"))
            }
        }
    }

    /// The version line follows the newer build from found to fetched to
    /// in place; with none, it is simply this one.
    private var versionTitle: String {
        switch updater.stage {
        case .none: return L("Updates")
        case .fetching(let next): return L("Search \(next.version) is downloading…")
        case .ready(let next): return L("Search \(next.version) is ready")
        case .offered(let next), .waiting(let next): return L("Search \(next.version) is out")
        }
    }

    private var versionDetail: String {
        switch updater.stage {
        case .none:
            return updater.lastChecked.map { L("Checked \($0.formatted(.relative(presentation: .named))) — every hour on its own") }
                ?? L("Checked every hour on its own")
        case .fetching(let next):
            return next.notes ?? L("Quietly, in the background — nothing you have set is touched")
        case .ready(let next):
            return next.notes ?? L("It's there the next time you open Search")
        case .offered(let next):
            return next.notes ?? L("Open the disk image, the same as the first time")
        case .waiting(let next):
            return next.notes ?? L("Checked and put in place when you press Install")
        }
    }

    @ViewBuilder
    private var versionControl: some View {
        switch updater.stage {
        case .none:
            Pill(updater.checking ? L("Checking…") : L("Check now")) {
                updater.check { found in
                    if found == nil { browser.announce(L("This is the latest one")) }
                }
            }
            .disabled(updater.checking)
        case .fetching:
            Ring(size: 12)
        case .ready:
            Pill(L("Relaunch now"), filled: true) { updater.relaunch() }
        case .offered:
            Pill(updater.fetchingDisk ? L("Downloading…") : L("Download"), filled: true) { updater.openDisk() }
                .disabled(updater.fetchingDisk)
        case .waiting:
            Pill(L("Install"), filled: true) { updater.install() }
        }
    }

    // MARK: - doing

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = prefs.downloads
        panel.prompt = L("Use this folder")
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
            .help(L("Back to \(label(home))"))
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
    @ObservedObject private var notifications = SiteNotifications.shared

    var body: some View {
        let sites = SiteNotifications.allowed
        if !sites.isEmpty {
            ForEach(sites, id: \.self) { site in
                Rule()
                Line(URL(string: site).map(SiteCard.site) ?? site, L("Can send notifications")) {
                    Pill(L("Remove")) { SiteNotifications.forget(site) }
                }
            }
        }
    }
}
