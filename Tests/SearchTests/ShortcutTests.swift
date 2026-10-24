import AppKit
import WebKit
import XCTest
@testable import Search

@MainActor
final class ShortcutTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "shortcuts-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() async throws {
        Store.settings.removeObject(forKey: "shortcuts")
        Store.settings.removeObject(forKey: "links.peekClick")
    }

    override func tearDown() async throws {
        Store.settings.removeObject(forKey: "shortcuts")
        Store.settings.removeObject(forKey: "links.peekClick")
    }

    func testSpaceKeysCanMoveClearResetAndReload() {
        let store = ShortcutStore()
        let original = KeyCombo("1", command: false, control: true)
        let replacement = KeyCombo("1", option: true)
        XCTAssertEqual(store.customCommand(on: original)?.id, "spaces.1")
        store.assign(replacement, to: "spaces.1")
        XCTAssertNil(store.customCommand(on: original))
        XCTAssertTrue(store.isFreed(original))
        XCTAssertEqual(ShortcutStore().customCommand(on: replacement)?.id, "spaces.1")
        store.clear("spaces.1")
        XCTAssertNil(store.key(for: "spaces.1"))
        XCTAssertNil(ShortcutStore().key(for: "spaces.1"))
        store.reset("spaces.1")
        XCTAssertEqual(store.customCommand(on: original)?.id, "spaces.1")
        XCTAssertFalse(store.anyChanged)
    }

    /// ⌃Tab's switcher on a key of its own, as Arc allows: ⇧ walks back,
    /// its modifiers hold it up, and ⌃Tab can go to another command.
    func testRecentTabsSwitcherCanBeRebound() {
        let store = ShortcutStore()
        let controlTab = KeyCombo("tab", command: false, control: true)
        let back = KeyCombo("tab", command: false, shift: true, control: true)
        XCTAssertEqual(store.key(for: Command.recentTabs), controlTab)
        XCTAssertEqual(KeyCombo.recentSwitch(controlTab, key: controlTab), false)
        XCTAssertEqual(KeyCombo.recentSwitch(back, key: controlTab), true)
        XCTAssertEqual(store.recentHold, .control)

        // Tab with ⌃ or ⌥ is a key to give; alone, with ⇧ or with ⌘ it isn't.
        XCTAssertFalse(KeyCombo.isReserved(controlTab))
        XCTAssertFalse(KeyCombo.isReserved(KeyCombo("tab", command: false, option: true)))
        XCTAssertTrue(KeyCombo.isReserved(KeyCombo("tab", command: false)))
        XCTAssertTrue(KeyCombo.isReserved(KeyCombo("tab", command: false, shift: true)))
        XCTAssertTrue(KeyCombo.isReserved(KeyCombo("tab")))

        let optionE = KeyCombo("e", command: false, option: true)
        store.assign(optionE, to: Command.recentTabs)
        XCTAssertEqual(ShortcutStore().key(for: Command.recentTabs), optionE)
        XCTAssertEqual(KeyCombo.recentSwitch(optionE, key: optionE), false)
        XCTAssertEqual(KeyCombo.recentSwitch(KeyCombo("e", command: false, shift: true, option: true), key: optionE), true)
        XCTAssertNil(KeyCombo.recentSwitch(controlTab, key: optionE))
        XCTAssertEqual(store.recentHold, .option)
        XCTAssertTrue(store.recentHeld([.option, .shift]))
        XCTAssertFalse(store.recentHeld([.control]))
        // ⌃Tab, freed, goes to the page — or to the command it is given.
        XCTAssertTrue(store.isFreed(controlTab))
        store.assign(controlTab, to: "tabs.next")
        XCTAssertEqual(store.customCommand(on: controlTab)?.id, "tabs.next")
        XCTAssertEqual(store.key(for: Command.recentTabs), optionE)
        store.resetAll()
        XCTAssertEqual(store.key(for: Command.recentTabs), controlTab)
    }

    func testConflictsWithSpaceKeysUseExistingReassignmentAndReset() {
        let store = ShortcutStore()
        let original = KeyCombo("2", command: false, control: true)
        XCTAssertFalse(KeyCombo.isReserved(original))
        XCTAssertTrue(KeyCombo.isReserved(KeyCombo("2")))
        XCTAssertTrue(KeyCombo.isReserved(KeyCombo("c")))
        XCTAssertEqual(store.owner(of: original, except: "tabs.next")?.id, "spaces.2")
        store.assign(original, to: "tabs.next")
        XCTAssertNil(store.key(for: "spaces.2"))
        XCTAssertEqual(store.customCommand(on: original)?.id, "tabs.next")
        XCTAssertEqual(ShortcutStore().customCommand(on: original)?.id, "tabs.next")
        store.reset("spaces.2")
        XCTAssertEqual(store.customCommand(on: original)?.id, "spaces.2")
        XCTAssertNil(store.key(for: "tabs.next"))
        XCTAssertEqual(ShortcutStore().customCommand(on: original)?.id, "spaces.2")
        store.resetAll()
        XCTAssertEqual(store.customCommand(on: original)?.id, "spaces.2")
        XCTAssertNil(Store.settings.data(forKey: "shortcuts"))
    }

    func testSpaceKeysReadPhysicalDigitsOnOtherLayouts() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.control], timestamp: 0, windowNumber: 0, context: nil,
            characters: "&", charactersIgnoringModifiers: "&", isARepeat: false, keyCode: 18))
        XCTAssertEqual(KeyCombo(event: event), KeyCombo("1", command: false, control: true))
    }

    func testPeekChoicePersistsAndInvalidValueKeepsDefault() {
        XCTAssertEqual(Preferences().peekClick, .shift)
        let prefs = Preferences()
        prefs.peekClick = .optionShift
        XCTAssertEqual(Preferences().peekClick, .optionShift)
        Store.settings.set("not-a-choice", forKey: "links.peekClick")
        XCTAssertEqual(Preferences().peekClick, .shift)
    }

    func testNavigationUsesChosenPeekClickAndKeepsOtherActions() async throws {
        _ = NSApplication.shared
        let server = try LocalDownloadServer()
        defer { server.stop() }
        let browser = Browser(record: WindowRecord())
        let tab = browser.benchOpen(server.url("page"))
        browser.activeID = tab.id
        let peeks = browser.prefs.peeksLinks, click = browser.prefs.peekClick
        browser.prefs.peeksLinks = true
        defer {
            browser.closePeek()
            browser.closeAll()
            browser.prefs.peeksLinks = peeks
            browser.prefs.peekClick = click
        }
        let target = server.url("destination")

        func policy(_ flags: NSEvent.ModifierFlags, type: WKNavigationType = .linkActivated,
                    download: Bool = false) async -> WKNavigationActionPolicy {
            await withCheckedContinuation { continuation in
                browser.webView(tab.web, decidePolicyFor: LinkAction(target, flags, type, download),
                                preferences: WKWebpagePreferences()) { answer, _ in
                    continuation.resume(returning: answer)
                }
            }
        }

        for choice in PeekClick.allCases {
            browser.prefs.peekClick = choice
            let result = await policy(choice.flags)
            XCTAssertEqual(result, .cancel)
            for _ in 0..<50 where browser.peekTab == nil {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(browser.peekTab?.address, target)
            browser.closePeek()
        }
        browser.prefs.peekClick = .optionShift
        let ordinary = await policy([])
        XCTAssertEqual(ordinary, .allow)
        let old = await policy(.shift)
        XCTAssertEqual(old, .allow)
        let script = await policy([.option, .shift], type: .other)
        XCTAssertEqual(script, .allow)
        let download = await policy([.option, .shift], download: true)
        XCTAssertEqual(download, .download)
        XCTAssertNil(browser.peekTab)
        let count = browser.tabs.count
        let command = await policy(.command)
        XCTAssertEqual(command, .cancel)
        XCTAssertEqual(browser.tabs.count, count + 1)
        XCTAssertNil(browser.peekTab)
        browser.prefs.peeksLinks = false
        let disabled = await policy([.option, .shift])
        XCTAssertEqual(disabled, .allow)
        XCTAssertNil(browser.peekTab)
    }
}

private final class LinkAction: WKNavigationAction {
    private let url: URL
    private let flags: NSEvent.ModifierFlags
    private let kind: WKNavigationType
    private let download: Bool

    init(_ url: URL, _ flags: NSEvent.ModifierFlags, _ kind: WKNavigationType, _ download: Bool) {
        self.url = url
        self.flags = flags
        self.kind = kind
        self.download = download
        super.init()
    }

    override var request: URLRequest { URLRequest(url: url) }
    override var navigationType: WKNavigationType { kind }
    override var modifierFlags: NSEvent.ModifierFlags { flags }
    override var buttonNumber: Int { 1 }
    override var targetFrame: WKFrameInfo? { nil }
    override var shouldPerformDownload: Bool { download }
}
