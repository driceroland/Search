import SwiftUI

/// The first time. Four short pages over the window, in the app's own
/// language: what this is, what to bring over, how to hold it, and whether
/// links from other apps should come here. Nothing is asked twice, and every
/// page can be skipped.
struct WelcomePanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs: Preferences

    @State private var page = 0
    @State private var forward = true

    // Bringing things over. Nil until one is picked, which means the first:
    // finding them looks through each browser's folders, and as an initial
    // value that ran every time the panel was made, the first window's
    // included, for a page that isn't showing yet.
    @State private var source: ImportSource?
    @State private var wantsHistory = true
    @State private var wantsBookmarks = true
    @State private var bringing = false
    @State private var brought: String?

    // The default browser.
    @State private var isDefault = Links.isDefault
    @State private var asked = false


    /// For pictures: the page to open at.
    var startPage = 0
    @State private var began = false

    private let pages = 4

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
                    default: links
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
                Text("A browser with nothing in the way. Search uses the engine built into your Mac and keeps the interface around the page simple.")
                    .font(.system(size: 14.5))
                    .foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 400)
            }
        }
    }

    private var bring: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading("Bring things over.", "Bookmarks go into the menu, and history means the address field already knows where you go. Nothing in the other browser changes.")

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
                    Choice("Bookmarks", "Folders and all, behind the bookmark button", on: $wantsBookmarks)
                    Choice("History", "The last few thousand places, for finishing addresses", on: $wantsHistory)
                }

                HStack(spacing: 12) {
                    Big(bringing ? "Bringing…" : "Bring them in", filled: true) { bringAll() }
                        .disabled(bringing || brought != nil || !(wantsHistory || wantsBookmarks))
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
            heading("Tabs in the sidebar.", "Choose what appears next to each tab title.")
            HStack(spacing: 12) {
                Text("Tabs wear")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
                Segmented(options: Glyph.allCases.map { ($0, $0.title) }, selection: $prefs.glyph)
            }
        }
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
                Key("⌘,", "Settings. ⌘F there finds any setting.")
                Key("⌥⌘N", "Split a page in two, ⌥-click a tab to put it beside the page, or drag a tab onto a page; ⌃⌘← and ⌃⌘→ go from one page to the other, and ⌥⌘N again puts them apart.")
                Key("⌘O", "Links from other apps can open in a small window; ⌘O keeps one as a tab. Settings › Browsing.")
                Key("⌘L", "Search engine suggestions are on by default. Turn them off in Settings › Browsing.")
                Key("⌘", "Held, it can show each tab's number for ⌘1–9. Settings › Tabs.")
                Key("⌘,", "Choose a colour, gradient or image for the window and new tabs in Settings › Appearance › Theme.")
                Key("⌘1", "Pressed again on its pin, back to where you were.")
                Key("⇧⌘P", "Float a video in Search's window, or in macOS's picture in picture. Settings › Browsing.")
                Key("⌃-click", "Claude or ChatGPT in a side panel beside the page: right-click a tab › Open in Side Panel, or View › Side Panel.")
                Key("⌘Q", "Search can ask before it quits. Settings › General.")
                Key("⌘,", "Your card in Contacts under a box for your name, email or address — Settings › General.")
                if PageTranslator.available {
                    Key("⌃-click", "Translate a page into your language, on this Mac — nothing is sent anywhere. Right-click the page › Translate Page.")
                }
                if AI.shipped {
                    Key("⌘,", "AI summaries and questions about a page — off until you turn it on in Settings › AI.")
                }
            }
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
        // The profile used most recently, without asking: the full sheet
        // (File › Bring Things Over…) is where another is chosen.
        let profile = source.usual
        bringing = true
        var lines: [String] = []
        let group = DispatchGroup()
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
        }
    }

    private func finish() {
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

        init(_ title: String, _ detail: String, on: Binding<Bool>) {
            self.title = title
            self.detail = detail
            _on = on
        }

        var body: some View {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13.5)).foregroundStyle(Palette.ink)
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(Palette.faint)
                }
                Spacer()
                Switch(on: $on)
            }
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
