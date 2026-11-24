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

/// A heading and its rows within a settings page.
struct SettingsGroup: Identifiable {
    let id: String
    let page: SettingsPanel.Page
    let title: String
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
    let title: String
    /// A short explanation used for help and search.
    let detail: String
    /// Extra help for the row.
    var more: String? = nil
    /// The defaults keys the row reads and writes.
    var keys: [String] = []
    /// Other words someone might type for it.
    var words: [String] = []
    var kind: Kind = .control
    /// The row that makes this one count. It stands at the same level as
    /// every other row, and is only there while that one makes it count
    /// (see SettingsIndex.applies).
    var parent: String? = nil
    /// Only the find field shows it (moved to a menu, or always on).
    var findOnly = false

    var page: SettingsPanel.Page { SettingsIndex.group(group)?.page ?? .general }
}

enum SettingsIndex {
    // MARK: - groups

    static let groups: [SettingsGroup] = [
        .init(id: "browser", page: .general, title: "Browser"),
        .init(id: "downloads", page: .general, title: "Downloads"),
        .init(id: "forms", page: .general, title: "Autofill"),

        .init(id: "theme", page: .appearance, title: "Light and dark"),
        .init(id: "window", page: .appearance, title: "Window"),
        .init(id: "tablook", page: .appearance, title: "Tabs"),
        .init(id: "themes", page: .appearance, title: "Theme"),
        .init(id: "motion", page: .appearance, title: "Motion"),

        .init(id: "newtabs", page: .tabs, title: "New tabs"),
        .init(id: "memory", page: .tabs, title: "Memory"),
        .init(id: "tabbar", page: .tabs, title: "Tab bar"),

        .init(id: "search", page: .browsing, title: "Search"),
        .init(id: "links", page: .browsing, title: "Links"),
        .init(id: "reading", page: .browsing, title: "Reading mode"),
        .init(id: "video", page: .browsing, title: "Video"),
        .init(id: "pages", page: .browsing, title: "Pages"),

        .init(id: "arc", page: .pins, title: "Arc"),
        .init(id: "pins", page: .pins, title: "Pins"),
        .init(id: "opening", page: .pins, title: "Startup and shortcuts"),

        .init(id: "blocking", page: .privacy, title: "Blocking"),
        .init(id: "permissions", page: .privacy, title: "Site permissions"),
        .init(id: "clear", page: .privacy, title: "Clear"),

        .init(id: "mouse", page: .keyboard, title: "Mouse and trackpad"),
        .init(id: "anywhere", page: .keyboard, title: "From any app"),

        .init(id: "developer", page: .about, title: "Developer"),

        // Drawn by ExtensionsPage itself; here so the find field reaches it.
        .init(id: "extensions", page: .extensions, title: "Installed"),
    ]

    static func group(_ id: String) -> SettingsGroup? { groups.first { $0.id == id } }
    static func groups(of page: SettingsPanel.Page) -> [SettingsGroup] { groups.filter { $0.page == page } }
    static func items(in group: String) -> [SettingsItem] { items.filter { $0.group == group && !$0.findOnly } }

    // MARK: - rows

    static let items: [SettingsItem] = ([
        // General
        .init(id: "general.default", group: "browser",
              title: "Default browser", detail: "Open links from other apps in Search.",
              words: ["default browser"]),
        .init(id: "mail.webmail", group: "browser",
              title: "Open email links in", detail: "Choose your mail app or a webmail provider.",
              more: "Email (mailto:) links clicked in a page open the webmail's new message in a tab beside it, with the address, subject and text filled in. From a private tab too, in an ordinary tab, where you're signed in. Links from other apps use this choice when Search is the default email app.",
              keys: ["mail.webmail"], words: ["email", "mailto", "gmail", "mail", "outlook", "fastmail", "proton", "webmail", "compose"]),
        .init(id: "mail.default", group: "browser",
              title: "Default email app", detail: "So links from other apps open your webmail too",
              more: "macOS asks you to confirm. Pick another app in Mail › Settings › General › Default email reader to undo it.",
              words: ["email", "mailto", "gmail", "mail", "default email", "handler"], parent: "mail.webmail"),
        .init(id: "general.import", group: "browser",
              title: "Import browser data", detail: "Bookmarks, history, passwords and extensions from another browser",
              more: "From another browser on this Mac, or from a file it exported. Nothing leaves your Mac.",
              words: ["bring things over", "import", "chrome", "safari", "arc", "migrate"]),
        .init(id: "quit.confirm", group: "browser",
              title: "Confirm before quitting", detail: "Ask before ⌘Q or Quit Search closes the browser",
              keys: ["quit.confirm"], words: ["quit", "cmd q"]),
        .init(id: "downloads.folder", group: "downloads",
              title: "Download folder", detail: "", keys: ["downloads"], words: ["save to"]),
        .init(id: "downloads.ask", group: "downloads",
              title: "Ask where to save files", detail: "Choose a location for each download.",
              keys: ["downloads.ask"]),
        .init(id: "downloads.button", group: "downloads",
              title: "Always show Downloads button", detail: "Keep the button visible between downloads.",
              keys: ["downloads.button"]),
        .init(id: "downloads.open", group: "downloads",
              title: "Open Downloads in", detail: "From its button, ⇧⌘J and History › Downloads",
              more: "In a tab, as the side panel's card floating by the downloads button, or in the side panel beside the page.",
              keys: ["downloads.open"], words: ["downloads window", "popover", "side panel"]),

        // Themes
        .init(id: "home.theme", group: "themes",
              title: "Theme", detail: "Choose a colour, gradient or image for the new tab and window.",
              more: "Set the new tab intensity and window colour separately. Images stay on your Mac.",
              keys: ["browser.theme", "home.theme", "home.theme.image", "home.tuning"],
              words: ["themes", "wallpaper", "background", "gradient", "colour", "color", "new tab", "image", "arc", "browser colour", "window colour", "tint", "strength", "intensity", "full", "theme", "home background"],
              kind: .wide),

        // Appearance
        .init(id: "look", group: "theme",
              title: "Appearance", detail: "Light, dark, or whatever the Mac is doing. Pages follow it too",
              keys: ["look"], words: ["dark mode", "light mode", "theme", "system"], kind: .wide),
        .init(id: "pages.dusk", group: "theme",
              title: "Darken light websites", detail: "Pages with no dark look of their own are darkened too",
              more: "Sites with a dark look of their own already follow it. ⇧⌘D for the site you're on, ⌥⇧⌘D to pause everywhere.",
              keys: ["pages.dusk"], words: ["dark", "dusk", "night"], parent: "look"),
        .init(id: "inspector.chrome", group: "theme",
              title: "Chrome colors in Web Inspector",
              detail: "A flat tab strip, and DevTools' colors for the row and the code",
              more: "Off, the inspector is left as it comes. The panels and the tools stay Web Inspector's.",
              keys: ["inspector.chrome"], words: ["devtools", "inspect", "console", "chrome"]),
        .init(id: "inspector.dark", group: "theme",
              title: "Always use dark Web Inspector", detail: "The tools stay dark while Search is light",
              more: "Off, it follows Appearance. Chrome's colors, when they're on, follow this too.",
              keys: ["inspector.dark"], words: ["devtools", "inspect", "console", "dark"], parent: "look"),
        .init(id: "tabs.layout", group: "window",
              title: "Sidebar layout", detail: "Down the left or right side, or as icons only",
              more: "Icons only is a narrow column of each tab's icon, the title in a tooltip. Nothing grows under the pointer.",
              keys: ["sidebar.position", "sidebar.icons"],
              words: ["sidebar", "vertical tabs", "column", "left", "right", "top", "tab bar", "position",
                      "icons only", "compact", "collapsed", "narrow", "favicons"], kind: .wide),
        .init(id: "sidebar.hides", group: "window",
              title: "Auto-hide sidebar", detail: "The page takes the whole window; ⌘S keeps the tabs out",
              keys: ["sidebar.hides"], words: ["hide the column", "auto hide", "sidebar"], parent: "tabs.layout"),
        .init(id: "sidebar.slides", group: "window",
              title: "Animate sidebar", detail: "A gentler slide when ⌘S or the window's edge brings the column out or puts it away",
              more: "With Reduce Motion on in System Settings › Accessibility › Display, the column fades in and out instead. With Reduce animations on, it comes and goes at once.",
              keys: [Motion.slidesKey], words: ["animation", "animate", "smooth", "slide", "sidebar", "arc"], parent: "tabs.layout"),
        .init(id: "sidebar.foldIcons", group: "window",
              title: "⌘S collapses sidebar to icons", detail: "The tabs stay in sight as a narrow column of icons; ⌘S again brings the titles back",
              more: "Off, ⌘S hides the column and the page takes the whole window.",
              keys: ["sidebar.foldIcons"], words: ["collapse", "collapsed", "compact", "narrow", "hide sidebar", "icons only", "favicons"],
              parent: "tabs.layout"),
        .init(id: "layout.cards", group: "window",
              title: "Page layout", detail: "A little room around the page, with rounded corners",
              more: "Off, the page reaches the window's edges and the column is white with its hairline.",
              keys: ["layout.cards"], words: ["edge to edge", "rounded", "margin"], kind: .wide, parent: "tabs.layout"),
        .init(id: "layout.cardsFullScreen", group: "window",
              title: "Use page cards in full screen", detail: "Off, the page goes edge to edge when the window fills the screen",
              keys: ["layout.cardsFullScreen"], words: ["full screen", "fullscreen", "card", "margin", "rounded", "zen", "arc"],
              parent: "layout.cards"),
        .init(id: "address.shown", group: "window",
              title: "Always show address bar", detail: "The page's full address, to type in",
              keys: ["address.shown"], words: ["address bar", "url", "location", "url bar", "omnibox", "full address"]),
        .init(id: "tabs.liquid", group: "tablook",
              title: "Liquid Glass tab", detail: "The tab you're on under a pane of Liquid Glass that glides, stretches and settles",
              more: "It bends the tabs it passes over. Pinned tabs and split pages keep their grey. Under Reduce Motion it goes straight to the tab you pick.",
              keys: ["tabs.liquid"], words: ["liquid glass", "liquid", "glass", "active tab", "selected tab", "animation", "wobble"]),
        .init(id: "sidebar.doorsUp", group: "tablook",
              title: "Buttons at the top", detail: "Bookmarks, extensions and downloads beside back, forward and reload, when they fit",
              keys: ["sidebar.doorsUp"], words: ["minimal", "toolbar", "footer", "bottom", "icons", "clean"], parent: "tabs.layout"),
        .init(id: "sidebar.foldButton", group: "tablook",
              title: "Sidebar button", detail: "Beside the window's buttons, to hide the sidebar as ⌘S does",
              more: "With the sidebar hidden, ⌘S or the pointer at the window's edge brings it back; the button then keeps it out.",
              keys: ["sidebar.foldButton"], words: ["hide sidebar", "collapse", "toggle", "fold", "traffic lights", "safari", "arc"], parent: "tabs.layout"),
        .init(id: "sidebar.narrowIcons", group: "tablook",
              title: "Narrow to icons", detail: "Pulled narrower than 200 points, the sidebar becomes a strip of site icons and its buttons",
              more: "The strip keeps the window's colour and shows letters or icons as the tabs do. Back, forward and reload stay on their keys. Pull its edge back out, or press ⌘S, for titles again.",
              keys: ["sidebar.narrowIcons"], words: ["collapse", "collapsed", "compact", "narrow", "thin", "strip", "icons only", "auto"], parent: "tabs.layout"),
        .init(id: "sidebar.player", group: "tablook",
              title: "Sidebar media controls", detail: "At the foot of the sidebar, to pause it, play it again or go to it",
              more: "A tab playing sound while you're on another one shows above the sidebar's foot.",
              keys: ["sidebar.player"], words: ["media", "music", "now playing", "pause", "player", "sound", "audio"], parent: "tabs.layout"),
        .init(id: "glyph", group: "tablook",
              title: "Tabs show", detail: "A letter or the site's icon",
              more: "Beside the title, and on a pinned square.",
              keys: ["glyph"], words: ["favicon", "icons", "letters"]),
        .init(id: "tabs.highContrast", group: "tablook",
              title: "High-contrast tab titles", detail: "Tab titles in black or white, instead of soft grey",
              keys: ["tabs.highContrast"], words: ["contrast", "accessibility", "bold", "readable", "black", "white"]),
        .init(id: "tabs.reading", group: "tablook",
              title: "Show reading progress", detail: "The tab you're on fills with grey as you scroll down",
              keys: ["tabs.reading"], words: ["how far", "progress", "scroll"]),
        .init(id: "tabs.give", group: "tablook",
              title: "Animate tab clicks", detail: "A tab sinks a little under the pointer, as in Arc",
              keys: ["tabs.give"], words: ["pressed", "animation", "bounce"]),
        .init(id: "bookmarks.bar", group: "tablook",
              title: "Show the bookmarks bar", detail: "Your bookmarks in a row above the page",
              keys: ["bookmarks.bar"], words: ["favorites bar"]),
        .init(id: "motion.light", group: "motion",
              title: "Simplify motion in Low Power Mode", detail: "Simpler motion while saving power or running hot; idle tabs sleep sooner in Low Power Mode",
              more: "In Low Power Mode, or while the Mac runs hot. Pages are left as they are.",
              keys: [Motion.lightKey], words: ["battery", "animations", "motion"]),
        .init(id: "motion.instant", group: "motion",
              title: "Reduce animations", detail: "Switching tabs and panels happens at once, without sliding or fading",
              more: "For Search alone, whatever Reduce Motion in System Settings says. The tab ⌘1–⌘9 picks is lit at once, and the page shows at once.",
              keys: [Motion.instantKey], words: ["animations", "motion", "instant", "faster", "reduce motion", "transitions"]),

        // Tabs
        .init(id: "tabs.newPlace", group: "newtabs",
              title: "New tab position", detail: "Where a link or ⌘T's new tab goes in the row",
              more: "After current puts a link you ⌘-click right after its page; ⌘T's new tab and a page a link opens in front go at the end. Pins stay first; a link from a group stays in it.",
              keys: ["tabs.newPlace"], words: ["new tab", "order"]),
        .init(id: "tabs.frontBeside", group: "newtabs",
              title: "Open foreground links next to their tab", detail: "A link that opens a new tab lands right after the tab it came from",
              more: "In the order you click them, as ⌘-clicks do, while you go back and forth between the page and the tabs it opened. Going to any other tab starts again right after the page.",
              keys: ["tabs.frontBeside"], words: ["target blank", "new tab", "order", "next to", "opener", "link"], parent: "tabs.newPlace"),
        .init(id: "tabs.newAfterLast", group: "newtabs",
              title: "Keep an empty tab open", detail: "Otherwise you land on a pinned tab",
              keys: ["tabs.newAfterLast"], words: ["last tab"]),
        .init(id: "tabs.closeGoesBack", group: "newtabs",
              title: "Return to the previous tab on close", detail: "Otherwise you land on the tab beside it",
              more: "The tab you viewed last, as ⌃Tab would take you. The other half of a Split View stays first.",
              keys: ["tabs.closeGoesBack"], words: ["close", "previous tab", "recent"]),
        .init(id: "tabs.swipeBackCloses", group: "newtabs",
              title: "Swipe back closes linked tabs", detail: "Back to the tab you were on, as Safari and Arc do",
              more: "On the page a link opened in a new tab, with nothing before it, a swipe back shows a cross and closes the tab, then goes to the tab you viewed last. Pages you clicked through in the tab go back as usual first. Only the swipe: a mouse's back button does nothing there, as before.",
              keys: ["tabs.swipeBackCloses"], words: ["swipe", "back", "close", "target blank", "new tab", "opener", "gesture", "link"]),
        .init(id: "home.grid", group: "newtabs",
              title: "Show Home bookmarks on new tabs", detail: "The sites of your bookmark folder called Home, under the address field",
              more: "Make a folder called Home in Bookmarks and put sites in it: a blank tab shows up to 16 of them as tiles with their names, in the order you keep them.",
              keys: ["home.grid"], words: ["home", "home page", "start page", "new tab", "speed dial", "favorites"]),
        .init(id: "tabs.undoReopens", group: "newtabs",
              title: "⌘Z reopens a closed tab", detail: "Right after closing it, as ⇧⌘T would bring it back",
              more: "Only while closing it is the last thing you did: type or click anything else and ⌘Z undoes as before. A page that uses ⌘Z itself, such as a document or a drawing, keeps it.",
              keys: ["tabs.undoReopens"], words: ["undo", "reopen", "closed tab", "cmd z", "restore"]),
        .init(id: "tabs.switcherBehindFirst", group: "newtabs",
              title: "⌃Tab selects background links", detail: "Otherwise a quick ⌃Tab goes back to the tab you were on before",
              more: "A link you ⌘-click, middle-click or open with Open Link in New Tab comes right after the page in the ⌃Tab switcher, the newest first. Off, it comes after the tab you were on before.",
              keys: ["tabs.switcherBehindFirst"], words: ["ctrl tab", "switcher", "background", "recent", "new tab"]),
        .init(id: "tabs.switcherLeavesOutPins", group: "newtabs",
              title: "Skip pins in the ⌃Tab switcher", detail: "Otherwise pinned tabs appear alongside regular tabs",
              more: "When on, pinned tabs stay in their places and do not appear in the ⌃Tab switcher grid. Off, the switcher includes pinned tabs that are awake or in front.",
              keys: ["tabs.switcherLeavesOutPins"], words: ["ctrl tab", "switcher", "pins", "pinned", "exclude"]),
        .init(id: "tabs.lazy", group: "newtabs",
              title: "Defer background tab loading", detail: "A link opened behind the page waits until you go to its tab",
              more: "With ⌘-click, the middle button, or a batch of links from another app. ⇧⌘-click still takes you there at once.",
              keys: ["tabs.lazy"], words: ["lazy", "background"]),
        .init(id: "tabs.popupWindows", group: "newtabs",
              title: "Open sized pop-ups in small windows", detail: "A site asking for a window at its own size gets one, not a tab",
              more: "A call, a sign-in or a chat asking for a window its size gets one, as in Safari. Pop-up blocking still applies.",
              keys: ["tabs.popupWindows"], words: ["popup", "pop-up", "window"]),
        .init(id: "tabs.sleep", group: "memory",
              title: "Sleep inactive tabs", detail: "A resting tab lets its page go and comes back where you left it",
              more: "Pinned tabs, sound, calls and anything typed stay awake. Right-click a site's card to keep it awake.",
              keys: ["tabs.sleep", SleepPace.key], words: ["memory", "discard", "suspend", "ram"], kind: .wide),
        .init(id: "tabs.sleep.dim", group: "memory",
              title: "Dim sleeping tabs", detail: "A resting tab's title and icon fade until you go to it",
              keys: ["tabs.sleep.dim"], words: ["sleep", "dim", "fade", "inactive", "suspend"]),
        .init(id: "tabs.close.after", group: "memory",
              title: "Close inactive tabs", detail: "Pinned, named and grouped tabs stay. ⇧⌘T brings one back",
              more: "Counted from when you last left the tab, while Search is quit too. Private tabs, sound, calls and anything typed stay.",
              keys: ["tabs.close.after"], words: ["auto close", "archive", "clean up"]),
        .init(id: "tabs.shortcuts", group: "tabbar",
              title: "Show tab numbers with ⌘", detail: "Which tab each ⌘1–9 selects",
              keys: ["tabs.shortcuts"], words: ["numbers", "shortcut"]),
        .init(id: "tabs.address", group: "tabbar",
              title: "Show the active tab’s site", detail: "Its site in place of its title; the title comes back under the pointer",
              more: "Look-alike names in other alphabets show as they really are, and plain http says Not secure. Off, the tab you're on still says so for those two.",
              keys: ["tabs.address"], words: ["url", "domain", "security", "address bar"]),

        // Browsing
        .init(id: "search.engine", group: "search",
              title: "Search engine", detail: "Where words that aren't an address go",
              keys: ["search.engine", "search.custom"], words: ["search with", "google", "duckduckgo", "engine", "kagi", "bing"]),
        .init(id: "search.shift", group: "search",
              title: "Shift-Return search engine", detail: "Off: Shift-Return does what Return does",
              more: "A second engine one key away: Return asks your default, Shift-Return asks this one, with exactly what you typed.",
              keys: ["search.shift", "search.shiftCustom"], words: ["shift enter", "second engine", "alternate", "google", "perplexity"]),
        .init(id: "search.suggest", group: "search",
              title: "Search engine suggestions", detail: "What you type is sent to your engine as you type",
              more: "Its suggestions show under the address field. Never from a private tab, and never an address.",
              keys: ["search.suggest"], words: ["autocomplete", "suggest"]),
        .init(id: "search.keywords", group: "search",
              title: "Site shortcuts", detail: "A word before your search sends it to that site: \"yt cats\"",
              keys: ["search.keywords"], words: ["keyword", "bang"]),
        .init(id: "links.little", group: "links",
              title: "Open external links in a small window", detail: "To read and close, or keep with Open in Search (⌘O); a tab's menu opens one too",
              keys: ["links.little"], words: ["little arc", "mini window", "open in small window"]),
        .init(id: "links.little.tabs", group: "links",
              title: "Reuse open tabs", detail: "A link to a page already open in a tab goes to that tab, not a small window",
              keys: ["links.little.tabs"], words: ["switch to tab", "already open", "duplicate"], parent: "links.little"),
        .init(id: "reader.twins", group: "reading",
              title: "Prefer Markdown in Reading Mode", detail: "When a page has a Markdown copy, reading mode shows that",
              more: "⇧⌘R shows a page's article alone, in clean type. Most docs sites publish a Markdown copy; nothing in it can run, its text is escaped.",
              keys: ["reader.twins"], words: ["markdown", "reader"]),
        .init(id: "reader.follows", group: "reading",
              title: "Match Reading Mode to Appearance", detail: "In a dark window the article is light on dark",
              more: "A small switch in its corner makes an article light, dark or as the window is, kept for the next one.",
              keys: ["reader.follows"], words: ["reader", "dark"]),
        .init(id: "float.style", group: "video",
              title: "Floating video style", detail: "Search's own window, or macOS's picture in picture",
              more: "Search's window floats a video without a click and keeps its page alive in it. Picture in picture is the one Safari uses, with the system's controls.",
              keys: ["float.style"], words: ["pip", "picture in picture", "mini player"]),
        .init(id: "float.own", group: "video",
              title: "Float video automatically", detail: "A playing video comes out when you leave its tab, or Search",
              more: "It goes back into its tab when you return, and stays put while its window is still in view on another screen. ⇧⌘P still floats one by hand.",
              keys: ["float.leave", "float.away"], words: ["pip", "picture in picture", "switch apps"], kind: .wide),
        .init(id: "float.minimize", group: "video",
              title: "Minimize the floating video", detail: "A button tucks the floating video small. The same button brings it back",
              keys: ["float.minimize"], words: ["minimize", "pip", "collapse", "small"]),
        .init(id: "media.click", group: "video",
              title: "Require a click to play video", detail: "Videos don't start by themselves, even without sound",
              keys: [Preferences.waitsKey], words: ["autoplay", "auto-play"]),
        .init(id: "fullscreen.escapeTwice", group: "video",
              title: "Press Esc twice to exit full screen", detail: "The first press shows a reminder, as in Arc",
              keys: ["fullscreen.escapeTwice"], words: ["escape", "full screen"]),
        .init(id: "fullscreen.keepsWindow", group: "video",
              title: "Keep browser available in full screen", detail: "Its tabs stay in reach on its own desktop while a video plays on another",
              keys: ["fullscreen.keepsWindow"], words: ["full screen", "desktop", "space", "video"]),
        .init(id: "translate.target", group: "pages",
              title: "Translation language", detail: "Pages are translated on this Mac",
              keys: ["translate.target"], words: ["translate", "language"]),
        .init(id: "pageZoom", group: "pages",
              title: "Page zoom", detail: "Where every site starts. ⌘+ and ⌘− are kept for each site",
              keys: ["pageZoom"], words: ["zoom", "size", "scale"]),
        .init(id: "pages.capture", group: "pages",
              title: "Capture pages", detail: "Capture… in the View menu copies an area, an element or the whole page",
              more: "Drag across an area, click an element, or choose Whole Page; Esc cancels. The picture is copied and saved as a PNG in your downloads folder, and goes nowhere else.",
              keys: ["pages.capture"], words: ["screenshot", "capture", "snapshot", "picture", "png", "arc"]),
        .init(id: "sites.styles", group: "pages",
              title: "Your own style for a site", detail: "Edit Site Style… in the View menu puts CSS of yours on the site you're on",
              more: "Applied as you type, to every page of that site, as Arc's Boosts. CSS only: Search never runs script you write in a page. Off, every style is kept but none is worn.",
              keys: ["sites.styles"], words: ["boost", "boosts", "css", "style", "stylesheet", "customize", "custom css", "arc", "theme"]),
        .init(id: "pages.120", group: "pages",
              title: "Pages at 120 Hz", detail: "Smoother scrolling on screens that can. On power spares the battery",
              more: "Animations and scrolling in pages at up to 120 frames a second, instead of 60 as in Safari.",
              keys: ["pages.120.mode", "pages.120"], words: ["promotion", "frame rate", "fps", "smooth", "120"]),

        // Pins
        .init(id: "arc.setup", group: "arc",
              title: "Set Up Like Arc", detail: "Tabs on the left, pinned rows and pins that keep their site",
              more: "Also turns on New tab in a floating field. Undo puts back what you had.",
              words: ["arc", "the browser company"]),
        .init(id: "arc.import", group: "arc",
              title: "Bring Arc's pins over", detail: "Your favourites, pinned tabs and folders, read from Arc on this Mac",
              words: ["arc", "import"]),
        .init(id: "pins.keep", group: "pins",
              title: "Pins keep their site", detail: "Links elsewhere open over the pin, and ⌘W takes it back home",
              more: "As in Arc and Safari: a link from a pin to another site opens in a peek over it, and a pin closed with ⌘W, or left open when Search quits, comes back at the page it was pinned at.",
              keys: ["pins.home", "pins.peek"], words: ["pinned tabs", "go home", "reset pin"]),
        .init(id: "pins.list", group: "pins",
              title: "Pinned rows", detail: "Pins as rows under the squares, and Clear over the rest",
              more: "As in Arc: squares for the sites you live in, rows for pages you keep, and a line over the rest with Clear. Right-click a tab to pin it as a row.",
              keys: ["pins.list"], words: ["arc", "pinned"], parent: "tabs.layout"),
        .init(id: "pins.folders", group: "pins",
              title: "Folders in pinned rows", detail: "Pinned rows in folders, folders in folders, as in Arc",
              more: "Right-click a pinned row and choose New Folder, or drag a row onto a folder. A folder folds with a click and holds up to three levels. Bringing Arc over keeps its folders as folders here.",
              keys: ["pins.folders"],
              words: ["arc", "folder", "folders", "nested", "subfolder", "pinned folder", "pinned tabs", "organise", "organize"],
              parent: "pins.list"),
        .init(id: "pins.commandNewTab", group: "pins",
              title: "⌘-click on a pin opens a new tab",
              detail: "Opens a tab at the pin's site, or moves a wandered page to loose tabs",
              more: "As in Arc: ⌘-clicking a pin opens a new tab at its address; on a pin that has wandered from its page, the wandered page is kept in loose tabs and the pin gets a fresh tab at home. Off, ⌘-click adds the pin to your tab selection.",
              keys: ["pins.commandNewTab"],
              words: ["command click", "cmd click", "pinned", "arc", "selection", "multi select"]),
        .init(id: "newtab.floating", group: "opening",
              title: "New tab in a floating field", detail: "⌘T raises the address field over the page, as in Arc",
              more: "Return opens what you typed in a new tab; Escape, ⌘W or a click outside puts it away.",
              keys: ["newtab.floating"], words: ["command bar", "cmd t", "spotlight"]),
        .init(id: "newtab.recent", group: "opening",
              title: "Recent places in the new tab", detail: "Before you type, ⌘T's field lists the last three places you went",
              more: "From History on this Mac, leaving out pages already open, which ⌘K finds. Nothing is picked until an arrow key picks it, and a private tab lists nothing.",
              keys: ["newtab.recent"], words: ["recent", "history", "suggestions", "cmd t", "last visited"], parent: "newtab.floating"),
        .init(id: "newtab.arc", group: "opening",
              title: "⌘T finds your open tabs", detail: "As you type, an open tab or a pin that matches is picked, and Return goes to it",
              more: "As you type, an open tab that matches is picked, else a pin, else the place from history the field completes to, so Return switches to a page you have instead of opening it again. ↑ lets go of the tab, and Return opens what you typed.",
              keys: ["newtab.arc"], words: ["arc", "open tabs", "switch tab", "pins", "cmd t", "tab search"], parent: "newtab.floating"),
        .init(id: "commandbar", group: "opening",
              title: "Address bar commands", detail: "\"settings\" or \"new tab\" alone in the address field goes there",
              more: "Part of a name, like \"down\" or \"dwn\", shows the command lower in the list, with every menu command and Settings page whose name has the words typed, as Arc's Command Bar.",
              keys: ["commandbar"], words: ["commands", "command palette"]),
        .init(id: "start.fresh", group: "opening",
              title: "Start with a fresh window", detail: "Pins, groups and named tabs come back; last time's others don't",
              keys: [Preferences.freshKey], words: ["restore", "session", "startup"]),

        // General › Autofill
        .init(id: "contacts.fill", group: "forms",
              title: "Autofill contact details", detail: "Use your Contacts card to fill in forms.",
              more: "A click fills the rest of the form's empty boxes too. Only your own card is read, and macOS asks first.",
              keys: ["contacts.fill"], words: ["autofill", "address", "email", "phone", "name", "contacts", "me card"]),

        // Privacy
        .init(id: "sites.keep", group: "blocking",
              title: "Prevent cross-site tracking", detail: "As in Safari. Private tabs keep it on",
              more: "On, as in Safari, a site you mostly reach from a tracker's link (YouTube from Google, GitHub from a sign-in button) can lose its saved preferences, and in time its sign-in, after a week of browsing without a click or typing on it. Off, sites you rarely open keep their sign-ins, and trackers inside other sites can follow you across them again, as in Chrome.",
              keys: ["sites.keep"], words: ["itp", "cookies", "tracking"]),
        .init(id: "privacy.clickIDs", group: "blocking",
              title: "Remove click trackers from links", detail: "gclid, fbclid and the like go before the page loads. Private tabs always",
              more: "The IDs an ad network adds to a link so the site can tell whose click it was. Campaign tags (utm_) stay, as in Safari.",
              keys: ["privacy.clickIDs"], words: ["gclid", "fbclid", "click id", "link tracking", "tracking parameters"]),
        .init(id: "privacy.gpc", group: "blocking",
              title: "Global Privacy Control", detail: "Global Privacy Control, with every request. Private tabs always",
              more: "Sends Sec-GPC: 1, which some laws make a site honour.",
              keys: ["privacy.gpc"], words: ["gpc", "do not sell", "do not track", "dnt", "global privacy control"]),
        .init(id: "privacy.httpsFirst", group: "blocking",
              title: "Try HTTPS first", detail: "An http:// page loads over HTTPS where the site has it",
              more: "Where it hasn't, the page loads as asked. Local addresses (localhost, .test, .local, IP addresses) are left as they are.",
              keys: ["privacy.httpsFirst"], words: ["https", "https only", "https first", "secure", "upgrade", "http"]),
        .init(id: "notifications.ask", group: "permissions",
              title: "Allow notification requests", detail: "Only a site you allow reaches your Mac's notifications",
              keys: ["notifications.ask"], words: ["notifications", "alerts", "push"]),
        .init(id: "privacy.forget", group: "permissions",
              title: "Site permissions", detail: "What each site was allowed or refused",
              words: ["permissions", "camera", "microphone", "location", "reset"]),
        .init(id: "clear.history", group: "clear",
              title: "History", detail: "Every address you have been to", words: ["clear history"]),
        .init(id: "clear.cookies", group: "clear",
              title: "Cookies and sign-ins", detail: "Signs you out of every site", words: ["cookies", "sign out"]),
        .init(id: "clear.cache", group: "clear",
              title: "Cache", detail: "Only what was fetched to draw pages", words: ["clear cache", "empty caches", "cache storage"]),

        // Keyboard & Mouse
        .init(id: "links.peek", group: "mouse",
              title: "Peek at a link", detail: "Its page opens in a panel over the one you're reading",
              more: "Escape puts it away; the other button keeps it as a tab.",
              keys: ["links.peek", "links.peekClick"], words: ["preview", "shift click", "peek"]),
        .init(id: "links.peek.stays", group: "mouse",
              title: "Peek stays with its tab", detail: "Another tab hides it, with its video and sound paused, and coming back shows it",
              keys: ["links.peek.stays"], words: ["peek", "keep peek", "switch tabs"], parent: "links.peek"),
        .init(id: "links.optionSplit", group: "mouse",
              title: "⌥-click a link opens it in Split View", detail: "Its page beside the one you're reading, as Open Link in Split View",
              more: "Off, ⌥-click follows the link as a click does. In Safari it downloads the link instead.",
              keys: ["links.optionSplit"], words: ["option click", "alt click", "split", "side by side", "link", "open beside"]),
        .init(id: "autoscroll", group: "mouse",
              title: "Scroll with the middle button", detail: "Click the wheel, then move the mouse to scroll, as on Windows",
              keys: ["autoscroll"], words: ["middle click", "autoscroll", "wheel"]),
        .init(id: "pages.bounce", group: "mouse",
              title: "Bounce at the top and bottom", detail: "A page stretches a little past its ends and springs back, as in Safari",
              keys: ["pages.bounce"], words: ["elastic", "rubber band", "overscroll", "bounce", "smooth scrolling", "safari"]),
        .init(id: "swipe.history", group: "mouse",
              title: "Hold a swipe to open history", detail: "Keep your fingers down after a swipe back to pick a page",
              more: "Swipe back or forward and keep your fingers down: the pages that way appear, and moving up or down picks one.",
              keys: ["swipe.history"], words: ["gesture", "trackpad", "back"]),
        .init(id: "launcher.on", group: "anywhere",
              title: "Global address field", detail: "A key of your own raises it over the app you're in, as Spotlight does",
              more: "Return opens what you typed in a new tab of Search's window in front, or goes to the tab that already has it, and brings Search forward. Escape, a click outside or the key again puts it away and leaves you where you were. With a window of Search's in front, the key is left to the page: ⌘L is the field there.",
              keys: ["launcher.on", "launcher.key"],
              words: ["spotlight", "launcher", "global", "hotkey", "shortcut", "quick search", "raycast", "alfred", "anywhere"]),
        .init(id: "launcher.key", group: "anywhere",
              title: "Global shortcut", detail: "Press it in any app to bring the address field up",
              keys: ["launcher.key"], words: ["hotkey", "global shortcut", "shift command space"], parent: "launcher.on"),
        .init(id: "launcher.little", group: "anywhere",
              title: "Open in a small window", detail: "Return opens the page in a small window over the app you're in, not in Search's window",
              more: "As links from other apps can (Settings › General): a small window with the page and Open in Search, to read and close or to keep. A page already open in a tab, picked from the list, still goes to its tab.",
              keys: ["launcher.little"], words: ["little arc", "little window", "small window", "quick look", "option command n"], parent: "launcher.on"),

        // About
        .init(id: "bench", group: "developer",
              title: "Enable test socket", detail: "A local socket for testing; its tabs never take over",
              more: "Its tabs open beside yours with a flask on them. See ./bench.",
              keys: ["bench"], words: ["automation", "script", "developer"]),
        .init(id: "agents", group: "developer",
              title: "Allow coding agents", detail: "Claude Code or Codex can ask to browse in tabs of its own, while you watch",
              more: "Each time one connects, the window asks you first, unless you ticked “Always allow” for it — offered only for Claude Code's own `claude`, signed by Anthropic; kept 30 days at most and 7 after its last use, never with your tabs, and asked again after you press Stop; forget it here. Nothing is drawn over the page: the tab it works in wears a small dot, and Stop is on the sidebar’s foot and in File › Stop Agent (⌃⌥⌘.) until it goes. It works in tabs of its own; your tabs it can read only if you tick “Let it see my open tabs”, and never uses. It never sees passwords, card numbers, one-time codes, private tabs, cookies or Settings, and can't download or choose files. It connects through a file on this Mac only, never the network: claude mcp add search -- /path/to/Search/search-mcp.",
              keys: ["agents"],
              words: ["agent", "ai", "claude", "claude code", "codex", "mcp", "automation", "computer use", "developer"]),

        // Moved to a menu, or always on: only the find field says so.
        .init(id: "autocorrect", group: "pages",
              title: "Correct spelling as you type", detail: "Now in Edit › Spelling and Grammar, as in Safari",
              keys: ["autocorrect"], words: ["autocorrect", "spelling", "spell"], findOnly: true),
        .init(id: "inlinePredictions", group: "pages",
              title: "Show inline predictions", detail: "The grey rest of a word as you type; in Edit › Spelling and Grammar",
              keys: ["inlinePredictions"], words: ["inline", "predictions", "predictive text", "suggestions", "completion", "autocomplete", "autocorrect", "spelling"], findOnly: true),
        .init(id: "note.split", group: "window",
              title: "Split View", detail: "Always there: ⌥-click a tab, drag a tab onto a page, or press ⌥⌘N",
              keys: ["splitView"], words: ["split", "side by side"], kind: .note, findOnly: true),
        .init(id: "note.groups", group: "newtabs",
              title: "Tab groups", detail: "Always there: right-click a tab › Add to New Group",
              keys: ["tabs.groups"], words: ["groups", "folders"], kind: .note, findOnly: true),
        .init(id: "note.panel", group: "links",
              title: "Websites in the side panel", detail: "Always there: View › Side Panel, or right-click a tab",
              keys: ["panel.sites"], words: ["side panel", "claude", "chatgpt"], kind: .note, findOnly: true),
        .init(id: "note.translate", group: "pages",
              title: "Translate pages on this Mac", detail: "Always there: right-click a page › Translate Page",
              keys: ["translate.pages"], words: ["translate", "language"], kind: .note, findOnly: true),
        .init(id: "extensions.sites", group: "extensions",
              title: "Where an extension runs", detail: "Each extension's Runs on: all sites, sites you name, or on click",
              more: "Fewer sites means less memory on the rest. Right-click an extension's button to run it on the site you're on.",
              keys: ["extensions.sites"],
              words: ["site access", "sites", "permissions", "host", "on click", "activetab", "memory", "extension"],
              kind: .note, findOnly: true),
        .init(id: "note.awake", group: "memory",
              title: "Keep selected sites awake", detail: "Always there: Keep This Site Awake, on the site's card",
              keys: ["tabs.keepAwake"], words: ["awake", "sleep"], kind: .note, findOnly: true),
        .init(id: "note.sitesearch", group: "search",
              title: "Search a site from the address field", detail: "Always there: type red, then Tab, and search Reddit",
              keys: ["search.sites"], words: ["tab to search", "site search"], kind: .note, findOnly: true),
        .init(id: "note.pinback", group: "pins",
              title: "A pin's number again goes back", detail: "Always there: press a pin's ⌘ number again to go back",
              keys: ["pins.numberBack"], words: ["cmd 1", "toggle"], kind: .note, findOnly: true),
        .init(id: "note.switcher", group: "mouse",
              title: "Keys in the tab switcher", detail: "Always there: ⌃W, ⌃R, ⌃M and ⌃O while ⌃Tab is up",
              keys: ["switcher.keys"], words: ["ctrl tab", "switcher"], kind: .note, findOnly: true),
        .init(id: "note.links", group: "links",
              title: "Show where links go", detail: "Always there: a link's address at the bottom of the page",
              keys: ["links.show"], words: ["status bar", "hover"], kind: .note, findOnly: true),
        .init(id: "note.flick", group: "video",
              title: "Flick the floating video to a corner", detail: "Always there: two fingers send it to the corner they point at",
              keys: ["float.flicks"], words: ["flick", "corner"], kind: .note, findOnly: true),
    ] as [SettingsItem]).filter(offered)

    /// Rows for a feature this Mac's WebKit doesn't have aren't listed at
    /// all, on the page or in the find field (see Privacy.swift).
    private static func offered(_ item: SettingsItem) -> Bool {
        switch item.id {
        case "privacy.clickIDs": return ClickIDs.possible
        case "privacy.gpc": return PrivacySignal.possible
        case "privacy.httpsFirst": return HTTPSFirst.possible
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
        case "inspector.dark": return prefs.look != .dark
        case "sidebar.player", "sidebar.doorsUp", "sidebar.foldButton", "sidebar.narrowIcons": return !prefs.sideIcons
        case "layout.cardsFullScreen": return prefs.cards
        case "tabs.liquid": return LiquidTab.available && !prefs.sideIcons
        case "pins.folders": return prefs.listsPins
        case "sidebar.foldIcons": return !prefs.sideHides
        case "tabs.frontBeside": return prefs.newTabPlace == .next
        case "newtab.recent", "newtab.arc": return prefs.floatingNewTab
        case "links.little.tabs": return prefs.littleLinks
        case "mail.default": return prefs.webmail != .none
        case "links.peek.stays": return prefs.peeksLinks || prefs.pinsPeek
        case "launcher.key": return prefs.launcher
        default: return true
        }
    }

    /// What a dimmed dependent row says instead of its own line.
    static func needs(_ item: SettingsItem) -> String {
        switch item.id {
        case "pages.dusk": return "Only while Search isn't set to Light"
        case "inspector.dark": return "Only while Search isn't set to Dark"
        case "sidebar.doorsUp", "sidebar.foldButton", "sidebar.narrowIcons": return "Only with titles in the column"
        case "tabs.liquid": return LiquidTab.available ? "Only with titles in the sidebar" : "Liquid Glass needs macOS 26"
        case "sidebar.foldIcons": return "Only with the column down a side and not hidden until the edge"
        case "sidebar.player": return "Only with titles in the sidebar"
        case "tabs.frontBeside": return "Only with New tab position on After current"
        case "newtab.recent", "newtab.arc": return "Only with the new tab in a floating field"
        case "links.little.tabs": return "Only with links from other apps in a small window"
        case "mail.default": return "Only with a webmail chosen for email links"
        case "links.peek.stays": return "Only when links or pins open peeks"
        case "launcher.key": return "Only with the address field from any app on"
        default: return "Only with the tabs down a side"
        }
    }
}

// MARK: - merged controls

/// The sidebar on either side, with titles or icons only.
enum TabsLayout: String, CaseIterable, Identifiable {
    case left, right, icons
    var id: String { rawValue }
    var title: String {
        switch self {
        case .left: return "Left"
        case .right: return "Right"
        case .icons: return "Icons only"
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
        get { sideIcons ? .icons : (sidePosition == .right ? .right : .left) }
        set {
            switch newValue {
            case .icons:
                sideIcons = true
            case .left, .right:
                sidePosition = newValue == .right ? .right : .left
                sideIcons = false
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
        var rows: Bool
        var keep: (home: Bool, peek: Bool)
        var floating: Bool
    }

    var arcSnapshot: ArcSetup {
        ArcSetup(layout: tabsLayout, rows: listsPins, keep: (pinsGoHome, pinsPeek), floating: floatingNewTab)
    }

    var looksLikeArc: Bool {
        tabsLayout == .left && listsPins && pinsGoHome && pinsPeek && floatingNewTab
    }

    /// Turns Arc's way on and says what changed.
    @discardableResult
    func setUpLikeArc() -> [String] {
        var changed: [String] = []
        if tabsLayout != .left { tabsLayout = .left; changed.append("tabs on the left") }
        if !listsPins { listsPins = true; changed.append("pinned rows") }
        if !(pinsGoHome && pinsPeek) { pinsKeepSite = true; changed.append("pins keep their site") }
        if !floatingNewTab { floatingNewTab = true; changed.append("the floating new tab") }
        return changed
    }

    func restore(_ before: ArcSetup) {
        tabsLayout = before.layout
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
            "sidebar.slides": prefs.slidesColumn,
            "always": [
                "splitView": prefs.splitView, "tabs.groups": prefs.usesTabGroups,
                "panel.sites": prefs.sitesInPanel, "translate": PageTranslator.enabled,
                "tabs.keepAwake": prefs.keepsSitesAwake, "search.sites": prefs.searchesSites,
                "pins.numberBack": prefs.pinNumberGoesBack,
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
        case "pins.folders":
            guard let on = value as? Bool else { return false }
            prefs.pinFolders = on
        case "sidebar.slides":
            guard let on = value as? Bool else { return false }
            prefs.slidesColumn = on
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
