import SwiftUI

// Every line of Settings, written down once.
//
// Settings › each section draws its groups from this list, and the ⌘F
// "Find a setting" field filters the same list, so a setting can't be on a
// page and missing from the search, or the other way round. Each line says
// which keys it reads and writes (the bench's `settings` verb answers with
// them, see Tests/settings_layout.py). The controls themselves are drawn in
// Settings.swift; what a merged control does to the old keys is here, on
// Preferences, so the switch and the bench write the same thing.

/// A titled group inside a section: a small heading with its icon, a line
/// saying what the group is for, then its rows in one card.
struct SettingsGroup: Identifiable {
    let id: String
    let page: SettingsPanel.Page
    let title: String
    let icon: String
    let blurb: String
}

/// One row of Settings.
struct SettingsItem: Identifiable {
    enum Kind {
        /// A control on the right of the row.
        case control
        /// A control wide enough to go under the words (pictures, long
        /// segmented choices).
        case wide
        /// No control: a feature that is always there, said so plainly.
        /// Only shown by the find field.
        case note
    }

    let id: String
    let group: String
    let icon: String
    let title: String
    /// One short line, under ~90 characters.
    let detail: String
    /// The rest of the story, behind the (i).
    var more: String? = nil
    /// The defaults keys the row reads and writes.
    var keys: [String] = []
    /// Other words someone might type for it.
    var words: [String] = []
    var kind: Kind = .control
    /// The row it hangs under: indented, and only there while that one
    /// makes it count (see SettingsIndex.applies).
    var parent: String? = nil
    /// Only the find field shows it (moved to a menu, or always on).
    var findOnly = false

    var page: SettingsPanel.Page { SettingsIndex.group(group)?.page ?? .general }
    /// Drawn under its parent, indented, when that is the row above it in
    /// the same group; a row whose parent is elsewhere is only hidden.
    var hangs: Bool { parent.flatMap(SettingsIndex.item)?.group == group }
}

enum SettingsIndex {
    // MARK: - groups

    static let groups: [SettingsGroup] = [
        .init(id: "browser", page: .general, title: "Your browser", icon: "globe.desk",
              blurb: "How Search fits in with the rest of your Mac."),
        .init(id: "downloads", page: .general, title: "Downloads", icon: "arrow.down.circle",
              blurb: "Where files go, and when you see them coming in."),

        .init(id: "theme", page: .appearance, title: "Light and dark", icon: "circle.lefthalf.filled",
              blurb: "The look of Search, and of the pages in it."),
        .init(id: "window", page: .appearance, title: "Window", icon: "macwindow",
              blurb: "Where the tabs sit, and how the page fits around them."),
        .init(id: "tablook", page: .appearance, title: "Tabs", icon: "textformat.size",
              blurb: "What each tab shows, and how it feels to press."),
        .init(id: "motion", page: .appearance, title: "Motion", icon: "wind",
              blurb: "How much things move on screen."),

        .init(id: "newtabs", page: .tabs, title: "New tabs", icon: "plus.square",
              blurb: "Where new tabs open, and what's left when the last one closes."),
        .init(id: "memory", page: .tabs, title: "Memory", icon: "moon.zzz",
              blurb: "Tabs you leave alone can rest, so your Mac stays quick."),
        .init(id: "tabbar", page: .tabs, title: "In the tab bar", icon: "number",
              blurb: "What a tab tells you at a glance."),

        .init(id: "search", page: .browsing, title: "Searching", icon: "magnifyingglass",
              blurb: "Where the words you type go when they aren't an address."),
        .init(id: "links", page: .browsing, title: "Links", icon: "link",
              blurb: "What happens to a link from another app."),
        .init(id: "reading", page: .browsing, title: "Reading mode", icon: "doc.plaintext",
              blurb: "⇧⌘R shows a page's article alone, in clean type."),
        .init(id: "video", page: .browsing, title: "Video", icon: "play.rectangle",
              blurb: "Videos that float while you do something else."),
        .init(id: "pages", page: .browsing, title: "Pages", icon: "doc.richtext",
              blurb: "How every page is drawn."),

        .init(id: "arc", page: .spaces, title: "Coming from Arc?", icon: "arrow.down.forward.square",
              blurb: "One click sets Search up the way Arc felt. Change any of it after."),
        .init(id: "spaces", page: .spaces, title: "Spaces and profiles", icon: "rectangle.3.group",
              blurb: "Separate sets of tabs, each signed in its own way."),
        .init(id: "pins", page: .spaces, title: "Pins", icon: "pin",
              blurb: "The sites you live in, always one click away."),
        .init(id: "opening", page: .spaces, title: "Opening and starting", icon: "command",
              blurb: "Arc's ways into a new tab, and into a new day."),

        .init(id: "passwords", page: .passwords, title: "Your passwords", icon: "key",
              blurb: "Kept in the macOS keychain, and filled in for you."),
        .init(id: "apple", page: .passwords, title: "Apple Passwords", icon: "lock.rectangle.stack",
              blurb: "The accounts in your Mac's Passwords app, under the sign-in box."),

        .init(id: "blocking", page: .privacy, title: "Blocking", icon: "shield",
              blurb: "What is stopped before it reaches you."),
        .init(id: "permissions", page: .privacy, title: "Site permissions", icon: "checkmark.shield",
              blurb: "What sites may ask of you, and what you told them."),
        .init(id: "clear", page: .privacy, title: "Clear", icon: "trash",
              blurb: "Take away what Search keeps about where you've been."),

        .init(id: "mouse", page: .keyboard, title: "Mouse and trackpad", icon: "computermouse",
              blurb: "Clicks, swipes and the wheel."),

        .init(id: "updates", page: .about, title: "Updates", icon: "arrow.triangle.2.circlepath",
              blurb: "Search looks for a newer version every hour."),
        .init(id: "developer", page: .about, title: "Developer", icon: "hammer",
              blurb: "For testing Search with scripts."),
    ]

    static func group(_ id: String) -> SettingsGroup? { groups.first { $0.id == id } }
    static func groups(of page: SettingsPanel.Page) -> [SettingsGroup] { groups.filter { $0.page == page } }
    static func items(in group: String) -> [SettingsItem] { items.filter { $0.group == group && !$0.findOnly } }

    // MARK: - rows

    static let items: [SettingsItem] = ([
        // General
        .init(id: "general.default", group: "browser", icon: "link.badge.plus",
              title: "Open links from other apps", detail: "Make Search the browser Mail, Slack and the rest send links to",
              words: ["default browser"]),
        .init(id: "general.import", group: "browser", icon: "square.and.arrow.down.on.square",
              title: "Bring things over", detail: "Bookmarks, history, passwords and extensions from another browser",
              more: "From another browser on this Mac, or from a file it exported. Nothing leaves your Mac.",
              words: ["import", "chrome", "safari", "arc", "migrate"]),
        .init(id: "quit.confirm", group: "browser", icon: "power",
              title: "Confirm before quitting", detail: "Ask before ⌘Q or Quit Search closes the browser",
              keys: ["quit.confirm"], words: ["quit", "cmd q"]),
        .init(id: "downloads.folder", group: "downloads", icon: "folder",
              title: "Save to", detail: "", keys: ["downloads"], words: ["download folder"]),
        .init(id: "downloads.ask", group: "downloads", icon: "questionmark.folder",
              title: "Ask where to save each file", detail: "A save sheet for every download",
              keys: ["downloads.ask"]),
        .init(id: "downloads.button", group: "downloads", icon: "arrow.down.to.line",
              title: "Always show the downloads button", detail: "Off, it shows only while a file comes in",
              keys: ["downloads.button"]),

        // Appearance
        .init(id: "look", group: "theme", icon: "circle.lefthalf.filled",
              title: "Appearance", detail: "Light, dark, or whatever the Mac is doing. Pages follow it too",
              keys: ["look"], words: ["dark mode", "light mode", "theme", "system"], kind: .wide),
        .init(id: "pages.dusk", group: "theme", icon: "moon",
              title: "Darken pages that stay light", detail: "Pages with no dark look of their own are darkened too",
              more: "Sites with a dark look of their own already follow it. ⇧⌘D for the site you're on, ⌥⇧⌘D to pause everywhere.",
              keys: ["pages.dusk"], words: ["dark", "dusk", "night"], parent: "look"),
        .init(id: "tabs.layout", group: "window", icon: "sidebar.left",
              title: "Tabs", detail: "Across the top of the window, or down a side as a column",
              keys: ["sidebar", "sidebar.position"],
              words: ["sidebar", "vertical tabs", "column", "left", "right", "top", "tab bar", "position"], kind: .wide),
        .init(id: "sidebar.hides", group: "window", icon: "sidebar.squares.left",
              title: "Hide the column until the pointer reaches the edge", detail: "The page takes the whole window; ⌘S keeps the tabs out",
              keys: ["sidebar.hides"], words: ["auto hide", "sidebar"], parent: "tabs.layout"),
        .init(id: "layout.cards", group: "window", icon: "rectangle.inset.filled",
              title: "The page as a card", detail: "A little room around the page, with rounded corners",
              more: "Off, the page reaches the window's edges and the column is white with its hairline.",
              keys: ["layout.cards"], words: ["edge to edge", "rounded", "margin"], kind: .wide, parent: "tabs.layout"),
        .init(id: "toolbar.left", group: "window", icon: "arrow.left.arrow.right",
              title: "Back, forward and reload on the left", detail: "Beside the window's buttons, before the tabs",
              keys: ["toolbar.left"], words: ["toolbar", "buttons", "navigation"], parent: "tabs.layout"),
        .init(id: "sidebar.roomy", group: "tablook", icon: "textformat.size.larger",
              title: "Roomier tabs", detail: "Taller rows and larger titles in the column",
              keys: ["sidebar.roomy"], words: ["bigger", "larger", "text size", "accessibility"], parent: "tabs.layout"),
        .init(id: "glyph", group: "tablook", icon: "character",
              title: "Tabs show", detail: "Beside the title, and on a pinned square",
              keys: ["glyph"], words: ["favicon", "icons", "letters"]),
        .init(id: "tabs.reading", group: "tablook", icon: "text.line.first.and.arrowtriangle.forward",
              title: "Show how far you've read", detail: "The tab you're on fills with grey as you scroll down",
              keys: ["tabs.reading"], words: ["progress", "scroll"]),
        .init(id: "tabs.give", group: "tablook", icon: "hand.point.up.left",
              title: "Tabs give when pressed", detail: "A tab sinks a little under the pointer, as in Arc",
              keys: ["tabs.give"], words: ["press", "animation", "bounce"]),
        .init(id: "bookmarks.bar", group: "tablook", icon: "bookmark",
              title: "Show the bookmarks bar", detail: "Your bookmarks in a row above the page",
              keys: ["bookmarks.bar"], words: ["favorites bar"]),
        .init(id: "motion.light", group: "motion", icon: "leaf",
              title: "Reduce animations in Low Power Mode", detail: "Quicker, simpler motion while the Mac saves power",
              more: "In Low Power Mode, or while the Mac runs hot. Pages are left as they are.",
              keys: [Motion.lightKey], words: ["battery", "animations", "motion"]),

        // Tabs
        .init(id: "tabs.newPlace", group: "newtabs", icon: "arrow.right.to.line",
              title: "New tab position", detail: "Where a link or ⌘T's new tab goes in the row",
              more: "After current puts a link beside the tab you're on, and ⌘T's new tab at the end. Pins stay first; a link from a group stays in it.",
              keys: ["tabs.newPlace"], words: ["new tab", "order"]),
        .init(id: "tabs.newAfterLast", group: "newtabs", icon: "plus.rectangle.on.rectangle",
              title: "Leave a new tab when the last tab closes", detail: "Otherwise you land on a pinned tab",
              keys: ["tabs.newAfterLast"], words: ["last tab"]),
        .init(id: "tabs.lazy", group: "newtabs", icon: "hourglass",
              title: "Load background tabs when you go to them", detail: "A link opened behind the page waits until you go to its tab",
              more: "With ⌘-click, the middle button, or a batch of links from another app. ⇧⌘-click still takes you there at once.",
              keys: ["tabs.lazy"], words: ["lazy", "background"]),
        .init(id: "tabs.popupWindows", group: "newtabs", icon: "macwindow.on.rectangle",
              title: "Open sized pop-ups in small windows", detail: "A site asking for a window at its own size gets one, not a tab",
              more: "A call, a sign-in or a chat asking for a window its size gets one, as in Safari. Pop-up blocking still applies.",
              keys: ["tabs.popupWindows"], words: ["popup", "pop-up", "window"]),
        .init(id: "tabs.sleep", group: "memory", icon: "moon.zzz",
              title: "Sleep tabs you aren't using", detail: "A resting tab lets its page go and comes back where you left it",
              more: "Pinned tabs, sound, calls and anything typed stay awake. Right-click a site's card to keep it awake.",
              keys: ["tabs.sleep", SleepPace.key], words: ["memory", "discard", "suspend", "ram"], kind: .wide),
        .init(id: "tabs.close.after", group: "memory", icon: "timer",
              title: "Close tabs you leave alone", detail: "Pinned, named and grouped tabs stay. ⇧⌘T brings one back",
              more: "Counted from when you last left the tab, while Search is quit too. Private tabs, sound, calls and anything typed stay.",
              keys: ["tabs.close.after"], words: ["auto close", "archive", "clean up"]),
        .init(id: "tabs.shortcuts", group: "tabbar", icon: "command",
              title: "Show tab numbers while ⌘ is held", detail: "Which tab each ⌘1–9 selects",
              keys: ["tabs.shortcuts"], words: ["numbers", "shortcut"]),
        .init(id: "tabs.address", group: "tabbar", icon: "lock",
              title: "Show the address on the tab you're on", detail: "Its site in place of its title; the title comes back under the pointer",
              more: "Look-alike names in other alphabets show as they really are, and plain http says Not secure. Off, the tab you're on still says so for those two.",
              keys: ["tabs.address"], words: ["url", "domain", "security", "address bar"]),

        // Browsing
        .init(id: "search.engine", group: "search", icon: "magnifyingglass",
              title: "Search with", detail: "Where words that aren't an address go",
              keys: ["search.engine", "search.custom"], words: ["google", "duckduckgo", "engine", "kagi", "bing"]),
        .init(id: "search.suggest", group: "search", icon: "text.magnifyingglass",
              title: "Suggestions from your search engine", detail: "What you type is sent to your engine as you type",
              more: "Its suggestions show under the address field. Never from a private tab, and never an address.",
              keys: ["search.suggest"], words: ["autocomplete", "suggest"]),
        .init(id: "search.keywords", group: "search", icon: "character.cursor.ibeam",
              title: "Site shortcuts", detail: "A word before your search sends it to that site: \"yt cats\"",
              keys: ["search.keywords"], words: ["keyword", "bang"]),
        .init(id: "links.little", group: "links", icon: "rectangle.on.rectangle",
              title: "Open links from other apps in a small window", detail: "To read and close, or keep with Open in Search (⌘O)",
              keys: ["links.little"], words: ["little arc", "mini window"]),
        .init(id: "reader.twins", group: "reading", icon: "doc.text",
              title: "Read the site's own Markdown", detail: "When a page has a Markdown copy, reading mode shows that",
              more: "Most docs sites publish one. Nothing in it can run: its text is escaped.",
              keys: ["reader.twins"], words: ["markdown", "reader"]),
        .init(id: "reader.follows", group: "reading", icon: "circle.righthalf.filled",
              title: "Reading mode follows light and dark", detail: "In a dark window the article is light on dark",
              more: "A small switch in its corner makes an article light, dark or as the window is, kept for the next one.",
              keys: ["reader.follows"], words: ["reader", "dark"]),
        .init(id: "float.style", group: "video", icon: "pip",
              title: "The floating video", detail: "Search's own window, or macOS's picture in picture",
              more: "Search's window floats a video without a click and keeps its page alive in it. Picture in picture is the one Safari uses, with the system's controls.",
              keys: ["float.style"], words: ["pip", "picture in picture", "mini player"]),
        .init(id: "float.own", group: "video", icon: "pip.exit",
              title: "Float the video on its own", detail: "A playing video comes out when you leave its tab, or Search",
              more: "It goes back into its tab when you return. ⇧⌘P still floats one by hand.",
              keys: ["float.leave", "float.away"], words: ["pip", "picture in picture", "switch apps"], kind: .wide),
        .init(id: "media.click", group: "video", icon: "play.slash",
              title: "Videos wait for a click", detail: "Videos don't start by themselves, even without sound",
              keys: [Preferences.waitsKey], words: ["autoplay", "auto-play"]),
        .init(id: "fullscreen.escapeTwice", group: "video", icon: "escape",
              title: "Press Esc twice to leave full screen", detail: "The first press shows a reminder, as in Arc",
              keys: ["fullscreen.escapeTwice"], words: ["escape", "full screen"]),
        .init(id: "pageZoom", group: "pages", icon: "plus.magnifyingglass",
              title: "Page zoom", detail: "Where every site starts. ⌘+ and ⌘− are kept for each site",
              keys: ["pageZoom"], words: ["zoom", "size", "scale"]),
        .init(id: "pages.120", group: "pages", icon: "speedometer",
              title: "Pages at 120 Hz", detail: "Smoother scrolling on screens that can. On power spares the battery",
              more: "Animations and scrolling in pages at up to 120 frames a second, instead of 60 as in Safari.",
              keys: ["pages.120.mode", "pages.120"], words: ["promotion", "frame rate", "fps", "smooth", "120"]),

        // Spaces & Pins
        .init(id: "arc.setup", group: "arc", icon: "wand.and.stars",
              title: "Set Up Like Arc", detail: "Tabs on the left, spaces, pinned rows and pins that keep their site",
              more: "Also turns on New tab in a floating field. Undo puts back what you had.",
              words: ["arc", "the browser company"]),
        .init(id: "arc.import", group: "arc", icon: "square.and.arrow.down",
              title: "Bring Arc's spaces and pins over", detail: "Your spaces, pinned tabs and folders, read from Arc on this Mac",
              words: ["arc", "import"]),
        .init(id: "spaces", group: "spaces", icon: "square.stack.3d.up",
              title: "Spaces", detail: "Separate sets of tabs, switched with ⌃1–⌃9 or a swipe",
              more: "Each space can be signed in where the others are or start afresh. Mission Control's own ⌃1–⌃9, if you turned them on, take those keys first.",
              keys: ["spaces"], words: ["workspaces", "profiles"]),
        .init(id: "profiles", group: "spaces", icon: "person.2",
              title: "Profiles", detail: "Spaces with their own sign-ins, history and bookmarks",
              more: "In windows of their own. Extensions, passwords and settings are shared.",
              words: ["profile", "accounts", "work", "personal"]),
        .init(id: "pins.keep", group: "pins", icon: "pin.circle",
              title: "Pins keep their site", detail: "Links elsewhere open over the pin, and ⌘W takes it back home",
              more: "As in Arc and Safari: a link from a pin to another site opens in a peek over it, and a pin closed with ⌘W, or left open when Search quits, comes back at the page it was pinned at.",
              keys: ["pins.home", "pins.peek"], words: ["pinned tabs", "go home", "reset pin"]),
        .init(id: "pins.list", group: "pins", icon: "list.bullet.rectangle",
              title: "Pinned rows", detail: "Pins as rows under the squares, and Clear over the rest",
              more: "As in Arc: squares for the sites you live in, rows for pages you keep, and a line over the rest with Clear. Right-click a tab to pin it as a row.",
              keys: ["pins.list"], words: ["arc", "pinned"], parent: "tabs.layout"),
        .init(id: "newtab.floating", group: "opening", icon: "rectangle.and.text.magnifyingglass",
              title: "New tab in a floating field", detail: "⌘T raises the address field over the page, as in Arc",
              more: "Return opens what you typed in a new tab; Escape, ⌘W or a click outside puts it away.",
              keys: ["newtab.floating"], words: ["command bar", "cmd t", "spotlight"]),
        .init(id: "commandbar", group: "opening", icon: "chevron.right.square",
              title: "Address bar commands", detail: "\"settings\" or \"new tab\" alone in the address field goes there",
              keys: ["commandbar"], words: ["commands", "command palette"]),
        .init(id: "start.fresh", group: "opening", icon: "sunrise",
              title: "Start with a fresh window", detail: "Pins, groups and named tabs come back; last time's others don't",
              keys: [Preferences.freshKey], words: ["restore", "session", "startup"]),

        // Passwords
        .init(id: "passwords.open", group: "passwords", icon: "key.viewfinder",
              title: "Your passwords", detail: "In the macOS keychain, shown with Touch ID", words: ["keychain"]),
        .init(id: "passwords.save", group: "passwords", icon: "square.and.arrow.down",
              title: "Offer to save passwords", detail: "Asked once per site, never again for a site you refuse",
              keys: ["passwords.save"], words: ["save password"]),
        .init(id: "passwords.fill", group: "passwords", icon: "rectangle.and.pencil.and.ellipsis",
              title: "Fill in sign-ins", detail: "Click a sign-in box and your accounts for the site hang from it",
              keys: ["passwords.fill"], words: ["autofill", "login"]),
        .init(id: "passkeys", group: "passwords", icon: "person.badge.key",
              title: "Offer passkeys", detail: "Touch ID or an iCloud passkey, on sites that offer one",
              keys: ["passkeys"], words: ["webauthn", "touch id"]),
        .init(id: "passwords.apple", group: "apple", icon: "applelogo",
              title: "Passwords from Apple's Passwords app", detail: "Your Passwords app's accounts under the sign-in box. Unofficial",
              more: "Search talks to the helper Apple made for its Chrome extension, as that extension. Never in private tabs.",
              keys: ["passwords.apple"], words: ["icloud keychain", "apple"]),

        // Privacy
        .init(id: "shield", group: "blocking", icon: "shield.lefthalf.filled",
              title: "Block ads and trackers", detail: "Third parties whose only job is to watch",
              keys: ["shield"], words: ["adblock", "ad blocker", "ads"]),
        .init(id: "sites.keep", group: "blocking", icon: "eye.slash",
              title: "Prevent cross-site tracking", detail: "As in Safari. Private tabs keep it on",
              more: "Off, sites you rarely open keep their sign-ins, and trackers inside other sites can follow you across them again, as in Chrome.",
              keys: ["sites.keep"], words: ["itp", "cookies", "tracking"]),
        .init(id: "privacy.clickIDs", group: "blocking", icon: "scissors",
              title: "Remove click trackers from links", detail: "gclid, fbclid and the like go before the page loads. Private tabs always",
              more: "The IDs an ad network adds to a link so the site can tell whose click it was. Campaign tags (utm_) stay, as in Safari.",
              keys: ["privacy.clickIDs"], words: ["gclid", "fbclid", "click id", "link tracking", "tracking parameters"]),
        .init(id: "privacy.gpc", group: "blocking", icon: "hand.raised",
              title: "Tell sites not to sell or share your data", detail: "Global Privacy Control, with every request. Private tabs always",
              more: "Sends Sec-GPC: 1, which some laws make a site honour.",
              keys: ["privacy.gpc"], words: ["gpc", "do not sell", "do not track", "dnt", "global privacy control"]),
        .init(id: "notifications.ask", group: "permissions", icon: "bell.badge",
              title: "Let sites ask to send notifications", detail: "Only a site you allow reaches your Mac's notifications",
              keys: ["notifications.ask"], words: ["notifications", "alerts", "push"]),
        .init(id: "privacy.forget", group: "permissions", icon: "arrow.uturn.backward.circle",
              title: "Camera, microphone, location and notifications", detail: "What each site was allowed or refused",
              words: ["permissions", "camera", "microphone", "location", "reset"]),
        .init(id: "clear.history", group: "clear", icon: "clock.arrow.circlepath",
              title: "History", detail: "Every address you have been to", words: ["clear history"]),
        .init(id: "clear.cookies", group: "clear", icon: "person.crop.circle.badge.xmark",
              title: "Cookies and sign-ins", detail: "Signs you out of every site", words: ["cookies", "sign out"]),
        .init(id: "clear.cache", group: "clear", icon: "internaldrive",
              title: "Cache", detail: "Only what was fetched to draw pages", words: ["clear cache"]),

        // Keyboard & Mouse
        .init(id: "links.peek", group: "mouse", icon: "eye",
              title: "Peek at a link", detail: "Its page opens in a panel over the one you're reading",
              more: "Escape puts it away; the other button keeps it as a tab.",
              keys: ["links.peek", "links.peekClick"], words: ["preview", "shift click", "peek"]),
        .init(id: "autoscroll", group: "mouse", icon: "arrow.up.and.down.circle",
              title: "Scroll with the middle button", detail: "Click the wheel, then move the mouse to scroll, as on Windows",
              keys: ["autoscroll"], words: ["middle click", "autoscroll", "wheel"]),
        .init(id: "swipe.history", group: "mouse", icon: "hand.draw",
              title: "Hold a swipe to pick from history", detail: "Keep your fingers down after a swipe back to pick a page",
              more: "Swipe back or forward and keep your fingers down: the pages that way appear, and moving up or down picks one.",
              keys: ["swipe.history"], words: ["gesture", "trackpad", "back"]),

        // About
        .init(id: "updates.version", group: "updates", icon: "arrow.down.app",
              title: "Updates", detail: "Checked every hour on its own", words: ["version", "update"]),
        .init(id: "updates.auto", group: "updates", icon: "arrow.triangle.2.circlepath",
              title: "Install updates on its own", detail: "Off, Search tells you and waits for Install",
              keys: [Updater.installKey], words: ["automatic updates"]),
        .init(id: "about.feedback", group: "updates", icon: "envelope",
              title: "Found something wrong?", detail: "Opens a draft with the version already in it", words: ["bug", "feedback", "report"]),
        .init(id: "about.notes", group: "updates", icon: "sparkles",
              title: "What's new", detail: "Every version's notes, newest first", words: ["release notes", "changelog"]),
        .init(id: "bench", group: "developer", icon: "terminal",
              title: "Let a script drive Search", detail: "A local socket for testing; its tabs never take over",
              more: "Its tabs open beside yours with a flask on them. See ./bench.",
              keys: ["bench"], words: ["automation", "script", "developer"]),

        // Moved to a menu, or always on: only the find field says so.
        .init(id: "autocorrect", group: "pages", icon: "textformat.abc.dottedunderline",
              title: "Correct spelling as you type", detail: "Now in Edit › Spelling and Grammar, as in Safari",
              keys: ["autocorrect"], words: ["autocorrect", "spelling", "spell"], findOnly: true),
        .init(id: "note.split", group: "window", icon: "rectangle.split.2x1",
              title: "Split View", detail: "Always there: drag a tab onto a page, or press ⌥⌘N",
              keys: ["splitView"], words: ["split", "side by side"], kind: .note, findOnly: true),
        .init(id: "note.groups", group: "newtabs", icon: "folder",
              title: "Tab groups", detail: "Always there: right-click a tab › Add to New Group",
              keys: ["tabs.groups"], words: ["groups", "folders"], kind: .note, findOnly: true),
        .init(id: "note.panel", group: "links", icon: "sidebar.right",
              title: "Websites in the side panel", detail: "Always there: View › Side Panel, or right-click a tab",
              keys: ["panel.sites"], words: ["side panel", "claude", "chatgpt"], kind: .note, findOnly: true),
        .init(id: "note.translate", group: "pages", icon: "translate",
              title: "Translate pages on this Mac", detail: "Always there: right-click a page › Translate Page",
              keys: ["translate.pages"], words: ["translate", "language"], kind: .note, findOnly: true),
        .init(id: "note.awake", group: "memory", icon: "sun.max",
              title: "Keep selected sites awake", detail: "Always there: Keep This Site Awake, on the site's card",
              keys: ["tabs.keepAwake"], words: ["awake", "sleep"], kind: .note, findOnly: true),
        .init(id: "note.sitesearch", group: "search", icon: "arrow.right.to.line.compact",
              title: "Search a site from the address field", detail: "Always there: type red, then Tab, and search Reddit",
              keys: ["search.sites"], words: ["tab to search", "site search"], kind: .note, findOnly: true),
        .init(id: "note.sharedpins", group: "pins", icon: "pin",
              title: "Pins in every space", detail: "Always there with Spaces: right-click a pin › Keep in Every Space",
              keys: ["pins.shared"], words: ["favorites", "shared pins"], kind: .note, findOnly: true),
        .init(id: "note.pinback", group: "pins", icon: "arrow.uturn.backward",
              title: "A pin's number again goes back", detail: "Always there: press a pin's ⌘ number again to go back",
              keys: ["pins.numberBack"], words: ["cmd 1", "toggle"], kind: .note, findOnly: true),
        .init(id: "note.switcher", group: "mouse", icon: "rectangle.stack",
              title: "Keys in the tab switcher", detail: "Always there: ⌃W, ⌃R, ⌃M and ⌃O while ⌃Tab is up",
              keys: ["switcher.keys"], words: ["ctrl tab", "switcher"], kind: .note, findOnly: true),
        .init(id: "note.links", group: "links", icon: "link",
              title: "Show where links go", detail: "Always there: a link's address at the bottom of the page",
              keys: ["links.show"], words: ["status bar", "hover"], kind: .note, findOnly: true),
        .init(id: "note.flick", group: "video", icon: "hand.raised.fingers.spread",
              title: "Flick the floating video to a corner", detail: "Always there: two fingers send it to the corner they point at",
              keys: ["float.flicks"], words: ["flick", "corner"], kind: .note, findOnly: true),
    ] as [SettingsItem]).filter(offered)

    /// Rows for a feature this Mac's WebKit doesn't have aren't listed at
    /// all, on the page or in the find field (see Privacy.swift).
    private static func offered(_ item: SettingsItem) -> Bool {
        switch item.id {
        case "privacy.clickIDs": return ClickIDs.possible
        case "privacy.gpc": return PrivacySignal.possible
        default: return true
        }
    }

    static func item(_ id: String) -> SettingsItem? { items.first { $0.id == id } }

    // MARK: - finding

    /// The rows whose words match what was typed, in the order of the
    /// sections. Every word typed has to be found somewhere in the row.
    static func find(_ typed: String) -> [SettingsItem] {
        let words = typed.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        let order = SettingsPanel.Page.allCases
        return items
            .filter { item in
                let group = SettingsIndex.group(item.group)
                let hay = ([item.title, item.detail, item.more ?? "", group?.title ?? "", item.page.title]
                    + item.words + item.keys).joined(separator: " ").lowercased()
                return words.allSatisfy { hay.contains($0) }
            }
            .sorted { (order.firstIndex(of: $0.page) ?? 0, groupOrder($0.group)) < (order.firstIndex(of: $1.page) ?? 0, groupOrder($1.group)) }
    }

    private static func groupOrder(_ id: String) -> Int { groups.firstIndex { $0.id == id } ?? 0 }

    /// Whether a dependent row means anything as things are set now. Its
    /// section hides it otherwise; the find field shows it dimmed.
    @MainActor static func applies(_ item: SettingsItem, _ prefs: Preferences) -> Bool {
        switch item.id {
        case "pages.dusk": return prefs.look != .light
        case "sidebar.hides", "layout.cards", "sidebar.roomy", "pins.list": return prefs.sidebar
        case "toolbar.left": return !prefs.sidebar
        default: return true
        }
    }

    /// What a dimmed dependent row says instead of its own line.
    static func needs(_ item: SettingsItem) -> String {
        switch item.id {
        case "pages.dusk": return "Only while Search isn't set to Light"
        case "toolbar.left": return "Only with the tabs across the top"
        default: return "Only with the tabs down a side"
        }
    }
}

// MARK: - merged controls

/// Tabs: across the top, or a column down either side. Reads and writes
/// `sidebar` and `sidebar.position`, as the two switches did.
enum TabsLayout: String, CaseIterable, Identifiable {
    case top, left, right
    var id: String { rawValue }
    var title: String {
        switch self {
        case .top: return "Top"
        case .left: return "Left"
        case .right: return "Right"
        }
    }
}

/// Sleep tabs: Never, or how soon. `tabs.sleep` and `tabs.sleep.pace`.
enum SleepChoice: String, CaseIterable, Identifiable {
    case never, later, normal, sooner
    var id: String { rawValue }
    var title: String { self == .never ? "Never" : pace!.title }
    var pace: SleepPace? { SleepPace(rawValue: rawValue) }
    var detail: String {
        guard let pace else { return "Every tab keeps its page, however long you leave it." }
        return pace.detail.replacingOccurrences(of: ".", with: "") + ", a tab rests and wakes when you go back to it."
    }
}

/// Float the video on its own: `float.leave` and `float.away`.
enum FloatOwn: String, CaseIterable, Identifiable {
    case never, tabs, tabsOrApps
    var id: String { rawValue }
    var title: String {
        switch self {
        case .never: return "Never"
        case .tabs: return "Switching tabs"
        case .tabsOrApps: return "Tabs or apps"
        }
    }
}

/// Peek at a link: Off, or the click that does it. `links.peek` and
/// `links.peekClick`.
enum PeekChoice: String, CaseIterable, Identifiable {
    case off, shift, optionShift, optionCommand
    var id: String { rawValue }
    var title: String { self == .off ? "Off" : click!.title }
    var click: PeekClick? { PeekClick(rawValue: rawValue) }
}

extension Preferences {
    var tabsLayout: TabsLayout {
        get { !sidebar ? .top : (sidePosition == .right ? .right : .left) }
        set {
            if newValue == .top {
                sidebar = false
            } else {
                sidePosition = newValue == .right ? .right : .left
                sidebar = true
            }
        }
    }

    var sleepChoice: SleepChoice {
        get { sleepsTabs ? (SleepChoice(rawValue: sleepPace.rawValue) ?? .normal) : .never }
        set {
            if let pace = newValue.pace { sleepPace = pace; sleepsTabs = true } else { sleepsTabs = false }
        }
    }

    /// Away alone (never seen from the switches, but possible) reads as the
    /// nearest choice that includes it.
    var floatOwn: FloatOwn {
        get { floatsAway ? .tabsOrApps : (floatsOnLeave ? .tabs : .never) }
        set {
            floatsOnLeave = newValue != .never
            floatsAway = newValue == .tabsOrApps
        }
    }

    var pinsKeepSite: Bool {
        get { pinsGoHome || pinsPeek }
        set { pinsGoHome = newValue; pinsPeek = newValue }
    }

    var peekChoice: PeekChoice {
        get { peeksLinks ? (PeekChoice(rawValue: peekClick.rawValue) ?? .shift) : .off }
        set {
            if let click = newValue.click { peekClick = click; peeksLinks = true } else { peeksLinks = false }
        }
    }

    /// Set Up Like Arc: what it turns on, and what was there before, so
    /// Undo can put it back.
    struct ArcSetup {
        var layout: TabsLayout
        var spaces: Bool
        var rows: Bool
        var keep: (home: Bool, peek: Bool)
        var floating: Bool
    }

    var arcSnapshot: ArcSetup {
        ArcSetup(layout: tabsLayout, spaces: usesSpaces, rows: listsPins, keep: (pinsGoHome, pinsPeek), floating: floatingNewTab)
    }

    var looksLikeArc: Bool {
        tabsLayout == .left && usesSpaces && listsPins && pinsGoHome && pinsPeek && floatingNewTab
    }

    /// Turns Arc's way on and says what changed.
    @discardableResult
    func setUpLikeArc() -> [String] {
        var changed: [String] = []
        if tabsLayout != .left { tabsLayout = .left; changed.append("tabs on the left") }
        if !usesSpaces { usesSpaces = true; changed.append("Spaces") }
        if !listsPins { listsPins = true; changed.append("pinned rows") }
        if !(pinsGoHome && pinsPeek) { pinsKeepSite = true; changed.append("pins keep their site") }
        if !floatingNewTab { floatingNewTab = true; changed.append("the floating new tab") }
        return changed
    }

    func restore(_ before: ArcSetup) {
        tabsLayout = before.layout
        usesSpaces = before.spaces
        listsPins = before.rows
        pinsGoHome = before.keep.home
        pinsPeek = before.keep.peek
        floatingNewTab = before.floating
    }
}

// MARK: - for the bench

extension SettingsIndex {
    /// The merged controls as Settings shows them, and the switches whose
    /// defaults changed: what Tests/settings_layout.py reads back.
    @MainActor static func values(_ prefs: Preferences) -> [String: Any] {
        [
            "tabs.layout": prefs.tabsLayout.rawValue,
            "tabs.sleep": prefs.sleepChoice.rawValue,
            "float.own": prefs.floatOwn.rawValue,
            "pins.keep": prefs.pinsKeepSite,
            "pins.home": prefs.pinsGoHome,
            "pins.peek": prefs.pinsPeek,
            "links.peek": prefs.peekChoice.rawValue,
            "pages.120": prefs.fastPages.rawValue,
            "swipe.history": prefs.holdsHistory,
            "tabs.address": prefs.showsAddress,
            "links.show": prefs.showsLinks,
            "float.flicks": prefs.floatFlicks,
            "arc": prefs.looksLikeArc,
            "always": [
                "splitView": prefs.splitView, "tabs.groups": prefs.usesTabGroups,
                "panel.sites": prefs.sitesInPanel, "translate": PageTranslator.enabled,
                "tabs.keepAwake": prefs.keepsSitesAwake, "search.sites": prefs.searchesSites,
                "pins.shared": prefs.sharesPins, "pins.numberBack": prefs.pinNumberGoesBack,
                "switcher.keys": prefs.switcherKeys,
            ],
        ]
    }

    /// A merged control moved as Settings moves it. False for an id or a
    /// value it doesn't know.
    @MainActor static func apply(_ id: String, _ value: Any, to prefs: Preferences) -> Bool {
        switch id {
        case "tabs.layout":
            guard let layout = (value as? String).flatMap(TabsLayout.init) else { return false }
            prefs.tabsLayout = layout
        case "tabs.sleep":
            guard let choice = (value as? String).flatMap(SleepChoice.init) else { return false }
            prefs.sleepChoice = choice
        case "float.own":
            guard let choice = (value as? String).flatMap(FloatOwn.init) else { return false }
            prefs.floatOwn = choice
        case "pins.keep":
            guard let on = value as? Bool else { return false }
            prefs.pinsKeepSite = on
        case "links.peek":
            guard let choice = (value as? String).flatMap(PeekChoice.init) else { return false }
            prefs.peekChoice = choice
        case "arc.setup":
            prefs.setUpLikeArc()
        default:
            return false
        }
        return true
    }

    static func describe(_ item: SettingsItem) -> [String: Any] {
        ["id": item.id, "page": item.page.rawValue, "group": item.group,
         "groupTitle": group(item.group)?.title ?? "", "title": item.title, "detail": item.detail,
         "keys": item.keys, "findOnly": item.findOnly, "note": item.kind == .note,
         "parent": item.parent ?? ""]
    }
}
