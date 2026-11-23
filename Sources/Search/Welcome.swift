import SwiftUI

/// The first time. Four short pages over the window, in the app's own
/// language: what this is, what to bring over, how to hold it, and whether
/// links from other apps should come here — and a fifth, until an email has
/// been given once, offering the iPhone beta and news by email (OptIn.swift).
/// Nothing is asked twice, and every page can be skipped.
///
/// The first page also holds Sync with iCloud and Handoff, on for a new
/// install (SyncDefault.swift): there, before Skip or Continue, so nobody
/// leaves without having seen them. They take effect when the welcome is
/// left, however it is; nothing goes anywhere while it is up.
struct WelcomePanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences

    @State private var page = 0
    // Sync with iCloud and Handoff, as they will be once the welcome is
    // left (SyncDefault.starts).
    @State private var syncs = SyncDefault.startsNow().sync
    @State private var handsOff = SyncDefault.startsNow().handoff
    @State private var forward = true

    // Bringing things over. Nil until one is picked, which means the first:
    // finding them looks through each browser's folders, and as an initial
    // value that ran every time the panel was made, the first window's
    // included, for a page that isn't showing yet.
    @State private var source: ImportSource?
    @State private var wantsPasswords = true
    @State private var wantsHistory = true
    @State private var wantsBookmarks = true
    @State private var bringing = false
    @State private var brought: String?

    // The default browser.
    @State private var isDefault = Links.isDefault
    @State private var asked = false

    private var importsPasswords: Bool { (source ?? ImportSource.installed().first)?.importsPasswords ?? false }

    /// Read once: the email page stays to the end once it is there, for
    /// its thanks.
    @State private var offersEmail = OptIn.offered()
    /// For pictures: the page to open at, and the email page's state.
    var startPage = 0
    var optInStart: OptInForm.Phase = .idle
    var optInEmail = ""
    @State private var began = false

    /// Set Up Like Arc from the welcome: what it turned on, for its line
    /// and Undo. Nothing changes unless it is pressed.
    @State private var arcSaid: String?
    @ObservedObject private var likeArc = LikeArc.shared

    private var pages: Int { offersEmail ? 5 : 4 }

    var body: some View {
        ZStack {
            Palette.ground.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                ZStack {
                    switch page {
                    case 0: welcome
                    case 1: bring
                    case 2: hold
                    case 3: links
                    default: early
                    }
                }
                .frame(maxWidth: 520)
                .id(page)
                .transition(.asymmetric(
                    insertion: .offset(x: forward ? 40 : -40).combined(with: .opacity),
                    removal: .offset(x: forward ? -40 : 40).combined(with: .opacity)
                ))
                Spacer(minLength: 0)
                foot
            }
            .padding(40)
        }
        .animation(Motion.glide, value: page)
        .transition(.opacity)
        .onAppear {
            guard !began else { return }
            began = true
            page = min(startPage, pages - 1)
        }
    }

    // MARK: - the pages

    private var welcome: some View {
        VStack(spacing: 22) {
            Plate(size: 72)
            VStack(spacing: 10) {
                Text("Search")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(Palette.ink)
                Text("A browser with nothing in the way. Four megabytes, the engine already in your Mac, and as little around the page as we could manage.")
                    .font(.system(size: 14.5))
                    .foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 400)
            }
            devices
                .padding(.top, 10)
        }
    }

    /// Sync with iCloud and Handoff, in sight before anything starts.
    private var devices: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 14) {
                Choice("Sync with iCloud", "Open tabs, pins, spaces, bookmarks and a few settings, on your iPhone and other Macs. End-to-end encrypted, in your own iCloud.", on: $syncs, plain: true)
                Rule(inset: 0)
                Choice("Handoff", "The page in front shows up on your iPhone and iPad.", on: $handsOff, plain: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Palette.wash, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text("Nothing starts until you leave this welcome. Both are in Settings › General.")
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.muted)
                .padding(.horizontal, 4)
        }
        .frame(maxWidth: 440)
    }

    private var bring: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading("Bring things over.", "Passwords go into your keychain, bookmarks into the menu, and history means the address field already knows where you go. Nothing in the other browser changes.")

            let sources = ImportSource.installed()
            let unreadable = Chromium.unreadable()
            if sources.isEmpty {
                if unreadable.isEmpty {
                    Text("No other browser found on this Mac — nothing to bring.")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    if sources.count > 1 {
                        Segmented(
                            options: sources.map { ($0, $0.name) },
                            selection: Binding(get: { source ?? sources[0] }, set: { source = $0 })
                        )
                    } else {
                        Text("From \(sources[0].name)")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.muted)
                    }
                    // What can come from it at all; spaces and open tabs
                    // are in the full sheet (File › Bring Things Over…).
                    Text("\((source ?? sources[0]).name) can bring: \((source ?? sources[0]).canBringLine.lowercased())")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.faint)
                    if importsPasswords {
                        Choice("Passwords", "macOS will ask once for that browser's keychain key", on: $wantsPasswords)
                    } else {
                        Text((source ?? sources[0]).passwordsInPasswordsApp
                             ? "\((source ?? sources[0]).name) keeps passwords in the Passwords app: export them there, then bring in the file below."
                             : "Passwords from \((source ?? sources[0]).name) aren't supported yet.")
                            .font(.system(size: 13)).foregroundStyle(Palette.muted)
                    }
                    Choice("Bookmarks", "Folders and all, behind the bookmark button", on: $wantsBookmarks)
                    Choice("History", "The last few thousand places, for finishing addresses", on: $wantsHistory)
                }

                HStack(spacing: 12) {
                    Big(bringing ? "Bringing…" : "Bring them in", filled: true) { bringAll() }
                        .disabled(bringing || brought != nil || !((importsPasswords && wantsPasswords) || wantsHistory || wantsBookmarks))
                    if bringing { Ring(size: 10) }
                    if let brought {
                        Text(brought)
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.muted)
                            .transition(.opacity)
                    }
                }
                .animation(Motion.settle, value: brought)
            }

            if !unreadable.isEmpty {
                Text(unreadable.map(\.message).joined(separator: "\n"))
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Safari, a browser on another Mac, one Search can't read: what
            // it exported, bookmarks, passwords or Safari's own ZIP.
            Pill("From a file another browser exported…") { browser.importFile() }
        }
    }

    private var hold: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading("Two ways to hold it.", "Titles down the side, or across the top. The grey slides to the tab you pick either way, and you can change your mind with ⇧⌘S.")
            HStack(spacing: 12) {
                Way(title: "Sidebar", sidebar: true, glyph: prefs.glyph, chosen: prefs.sidebar) {
                    withAnimation(Motion.glide) { prefs.sidebar = true }
                }
                Way(title: "Tab strip", sidebar: false, glyph: prefs.glyph, chosen: !prefs.sidebar) {
                    withAnimation(Motion.glide) { prefs.sidebar = false }
                }
            }
            HStack(spacing: 12) {
                Text("Tabs wear")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
                Segmented(options: Glyph.allCases.map { ($0, $0.title) }, selection: $prefs.glyph)
            }
            arcCard
        }
    }

    /// Coming from Arc? One button for Arc's way (LikeArc), optional like
    /// everything here: Continue goes on without it.
    private var arcCard: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Coming from Arc?")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Palette.ink)
                Text(arcSaid ?? "Tabs on the left, spaces, pinned rows, and Arc's habits: tabs that close after 12 hours, peek, the floating video.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if arcSaid != nil, likeArc.undoable(prefs) {
                Big("Undo") {
                    withAnimation(Motion.glide) { likeArc.undo(prefs) }
                    arcSaid = nil
                }
            } else if prefs.looksLikeArc {
                Text(arcSaid == nil ? "Set up like Arc" : "")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.faint)
            } else {
                Big("Set Up Like Arc") {
                    arcSaid = LikeArc.said(withAnimation(Motion.glide) { likeArc.setUp(prefs) })
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .animation(Motion.settle, value: arcSaid)
    }

    private var links: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading("Links from other apps.", "A click in Mail, in Slack, in a PDF — macOS sends it to whichever browser is the default. It can be this one.")
            HStack(spacing: 12) {
                if isDefault {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .medium))
                        Text("Search is the default browser")
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink)
                } else {
                    Big("Make Search the default", filled: true) {
                        asked = true
                        Links.becomeDefault { _ in isDefault = Links.isDefault }
                    }
                    if asked, !isDefault {
                        Text("macOS asks in its own dialog")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.faint)
                    }
                }
            }
            .animation(Motion.settle, value: isDefault)

            VStack(alignment: .leading, spacing: 8) {
                Text("A few things worth knowing")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.faint)
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .padding(.top, 6)
                Key("⌘T", "A new tab. Type a place, or words to search.")
                Key("⌘K", "Every open tab, by name.")
                Key("⌘,", "Settings, including passwords and updates. ⌘F there finds any setting.")
                Key("⌃1", "Spaces: separate tabs and sign-ins. Turn them on in Settings › Spaces & Pins, or Set Up Like Arc there.")
                Key("⌥⌘N", "Split a page in two, ⌥-click a tab to put it beside the page, or drag a tab onto a page; ⌃⌘← and ⌃⌘→ go from one page to the other, and ⌥⌘N again puts them apart.")
                Key("⌘O", "Links from other apps open in a small window; ⌘O keeps one as a tab. Settings › Browsing.")
                Key("⌘L", "Suggestions from your search engine as you type — off until you turn them on in Settings › Browsing.")
                Key("⌘", "Held, it can show each tab's number for ⌘1–9. Settings › Tabs.")
                Key("⌘,", "A painted wall behind the blank tab, if you want one — Settings › Themes. Off until you choose.")
                Key("⌘1", "Pressed again on its pin, back to where you were.")
                Key("⇧⌘P", "Float a video in Search's window, or in macOS's picture in picture. Settings › Browsing.")
                Key("⌃-click", "Claude or ChatGPT in a side panel beside the page: right-click a tab › Open in Side Panel, or View › Side Panel.")
                Key("⌘Q", "Search can ask before it quits. Settings › General.")
                Key("⌘,", "Your Apple passwords, under the sign-in field — Settings › Passwords.")
                if PageTranslator.available {
                    Key("⌃-click", "Translate a page into your language, on this Mac — nothing is sent anywhere. Right-click the page › Translate Page.")
                }
                if AI.shipped {
                    Key("⌘,", "AI summaries and questions about a page — off until you turn it on in Settings › AI.")
                }
            }
        }
    }

    /// Light, and skippable like every page: Start browsing goes on
    /// without it (OptIn.swift).
    private var early: some View {
        OptInWelcomePage(start: optInStart, startEmail: optInEmail) { url in
            finish()
            _ = browser.open(url, foreground: true)
        }
    }

    // MARK: - the bottom edge

    private var foot: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                ForEach(0..<pages, id: \.self) { i in
                    Circle()
                        .fill(i == page ? Palette.ink : Palette.faint.opacity(0.6))
                        .frame(width: 6, height: 6)
                }
            }
            Spacer()
            if page > 0 {
                Button("Back") { forward = false; page -= 1 }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
            }
            if page < pages - 1 {
                Button("Skip") { finish() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
            }
            Big(page < pages - 1 ? "Continue" : "Start browsing", filled: true) {
                if page < pages - 1 { forward = true; page += 1 } else { finish() }
            }
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: 520)
    }

    // MARK: - doing

    private func bringAll() {
        guard let source = source ?? ImportSource.installed().first else { return }
        // The profile used most recently, without asking: the sheet in
        // Settings › Passwords is where another is chosen.
        let profile = source.usual
        bringing = true
        var lines: [String] = []
        let group = DispatchGroup()
        if wantsPasswords && source.importsPasswords {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let outcome = Result { try source.read(profile: profile) }
                DispatchQueue.main.async {
                    switch outcome {
                    case .success(let found):
                        let kept = browser.keep(found)
                        ImportRecords.note(source.name, passwords: kept)
                        lines.append("\(kept) passwords" + (found.undecrypted > 0 ? " (\(found.undecrypted) couldn't be decrypted)" : ""))
                    case .failure(Chromium.Trouble.noPassphrase):
                        lines.append("passwords: macOS didn't hand over the key — allow it and try again")
                    case .failure(Mozilla.Trouble.primaryPassword):
                        lines.append("passwords: \(source.name) has a primary password — export them from it and bring in the CSV")
                    case .failure:
                        lines.append("passwords: nothing readable")
                    }
                    group.leave()
                }
            }
        }
        if wantsBookmarks {
            lines.append("\(browser.takeBookmarks(from: source, profile: profile).added) bookmarks")
        }
        if wantsHistory {
            group.enter()
            browser.takePlaces(from: source, profile: profile) { count in
                lines.append("\(count) places")
                group.leave()
            }
        }
        group.notify(queue: .main) {
            bringing = false
            brought = lines.joined(separator: " · ")
            browser.relist()
        }
    }

    private func finish() {
        SyncDefault.welcomeLeft(sync: syncs, handoff: handsOff, prefs: prefs, icloud: ICloudSync.shared)
        prefs.welcomed = true
        withAnimation(Motion.settle) { browser.welcoming = false }
    }

    private func heading(_ title: String, _ line: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Palette.ink)
            Text(line)
                .font(.system(size: 14))
                .foregroundStyle(Palette.muted)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - pieces

    /// The mark alone, at whatever height the page wants — no plate behind
    /// it, the same as everywhere else it's drawn.
    private struct Plate: View {
        let size: CGFloat
        var body: some View {
            Logomark()
                .fill(Palette.ink, style: FillStyle(eoFill: true))
                .aspectRatio(Logomark.canvas.width / Logomark.canvas.height, contentMode: .fit)
                .frame(height: size * 0.56)
        }
    }

    private struct Big: View {
        let title: String
        var filled = false
        let act: () -> Void
        @State private var hovering = false

        init(_ title: String, filled: Bool = false, act: @escaping () -> Void) {
            self.title = title
            self.filled = filled
            self.act = act
        }

        var body: some View {
            Button(action: act) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(filled ? Palette.ground : Palette.ink)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(filled ? Palette.ink : (hovering ? Palette.hover : Palette.wash), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
    }

    private struct Choice: View {
        let title: String
        let detail: String
        @Binding var on: Bool
        /// The line under in the darker grey, for one that must be read.
        var plain = false

        init(_ title: String, _ detail: String, on: Binding<Bool>, plain: Bool = false) {
            self.title = title
            self.detail = detail
            _on = on
            self.plain = plain
        }

        var body: some View {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13.5)).foregroundStyle(Palette.ink)
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(plain ? Palette.muted : Palette.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Switch(on: $on)
            }
        }
    }

    /// One of the two ways, as a small drawing of the window.
    private struct Way: View {
        let title: String
        let sidebar: Bool
        let glyph: Glyph
        let chosen: Bool
        let pick: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: pick) {
                VStack(alignment: .leading, spacing: 10) {
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.ground)
                        if sidebar {
                            HStack(spacing: 0) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 3) { ForEach(0..<3, id: \.self) { _ in Circle().fill(Palette.faint).frame(width: 5, height: 5) } }
                                        .padding(.bottom, 4)
                                    ForEach(0..<4, id: \.self) { i in
                                        HStack(spacing: 3) {
                                            Wear(glyph: glyph, tab: i)
                                            RoundedRectangle(cornerRadius: 3).fill(i == 0 ? Palette.wash : Palette.hover).frame(height: 8)
                                        }
                                    }
                                }
                                .padding(8)
                                .frame(width: 62)
                                Rectangle().fill(Palette.hairline).frame(width: 1)
                                Spacer()
                            }
                        } else {
                            HStack(spacing: 3) {
                                HStack(spacing: 3) { ForEach(0..<3, id: \.self) { _ in Circle().fill(Palette.faint).frame(width: 5, height: 5) } }
                                    .padding(.trailing, 6)
                                ForEach(0..<4, id: \.self) { i in
                                    HStack(spacing: 3) {
                                        Wear(glyph: glyph, tab: i)
                                        RoundedRectangle(cornerRadius: 3).fill(i == 0 ? Palette.wash : Palette.hover).frame(width: 24, height: 8)
                                    }
                                    .padding(.trailing, 3)
                                }
                            }
                            .padding(8)
                        }
                    }
                    .frame(height: 110)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
                    Text(title)
                        .font(.system(size: 13, weight: chosen ? .medium : .regular))
                        .foregroundStyle(chosen ? Palette.ink : Palette.muted)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(chosen ? Palette.wash : (hovering ? Palette.hover : .clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(chosen ? Palette.ink.opacity(0.35) : Palette.hairline, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
            .animation(Motion.settle, value: chosen)
        }
    }

    /// What a tab wears in the two small pictures, as Tabs wear has it: a
    /// letter in a faint square, as Mark draws one, or a patch of colour
    /// where a site's own icon would be. Seen before it is chosen: letters
    /// were taken for icons that hadn't loaded (#1271).
    private struct Wear: View {
        let glyph: Glyph
        let tab: Int

        private static let letters = ["G", "M", "Y", "W"]
        private static let tints: [NSColor] = [.systemRed, .systemBlue, .systemGreen, .systemOrange]

        var body: some View {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(glyph == .icons ? Color(nsColor: Wear.tints[tab]).opacity(0.7) : Palette.ink.opacity(0.06))
                .frame(width: 10, height: 10)
                .overlay {
                    if glyph == .letters {
                        Text(Wear.letters[tab])
                            .font(.system(size: 6.5, weight: .medium))
                            .foregroundStyle(Palette.muted)
                    }
                }
                .animation(Motion.quick, value: glyph)
        }
    }

    private struct Key: View {
        let keys: String
        let what: String
        init(_ keys: String, _ what: String) { self.keys = keys; self.what = what }
        var body: some View {
            HStack(spacing: 10) {
                Text(keys)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .frame(minWidth: 44)
                Text(what).font(.system(size: 13)).foregroundStyle(Palette.muted)
            }
        }
    }
}
