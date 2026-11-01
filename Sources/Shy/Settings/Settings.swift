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

    @ObservedObject var shield = Shield.shared
    @State var isDefault = Links.isDefault
    /// A site shortcut being written, kept out of Preferences until it's saved.
    @State var draft: Keyword?
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
}
