import AppKit
import XCTest
@testable import Search

@MainActor
final class QuitConfirmationTests: XCTestCase {
    private var previous: Any?

    override class func setUp() {
        setenv("SEARCH_PROBE", "quit-confirmation-\(getpid())", 1)
        super.setUp()
    }

    override func setUp() async throws {
        _ = NSApplication.shared
        previous = Store.settings.object(forKey: Preferences.confirmQuitKey)
        Store.settings.set(true, forKey: Preferences.confirmQuitKey)
    }

    override func tearDown() async throws {
        Store.settings.set(previous, forKey: Preferences.confirmQuitKey)
    }

    func testOffByDefaultAndPreferencePersists() {
        Store.settings.removeObject(forKey: Preferences.confirmQuitKey)
        let prefs = Preferences()
        XCTAssertFalse(prefs.confirmsQuit)
        XCTAssertTrue(Links.shouldQuit())
        prefs.confirmsQuit = true
        XCTAssertTrue(Preferences().confirmsQuit)
        prefs.confirmsQuit = false
        XCTAssertTrue(Links.shouldQuit())
        XCTAssertNil(NSApp.modalWindow)
    }

    func testCancelDeclinesQuitAndCanAskAgain() {
        XCTAssertFalse(answer("Cancel"))
        XCTAssertTrue(answer("Quit"))
    }

    func testCancelIsTheDefaultAndQuitHasNoKeyEquivalent() {
        XCTAssertFalse(answer("Cancel") {
            XCTAssertEqual(NSApp.modalWindow?.defaultButtonCell?.title, "Cancel")
            let quit = self.buttons(NSApp.modalWindow?.contentView).first { $0.title == "Quit" }
            XCTAssertEqual(quit?.keyEquivalent, "")
        })
    }

    func testEscapeDeclinesQuit() {
        XCTAssertFalse(answer {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                        windowNumber: NSApp.modalWindow!.windowNumber, context: nil,
                                        characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                        isARepeat: false, keyCode: 53)!
            NSApp.sendEvent(event)
        })
    }

    func testRepeatedQuitDoesNotOpenAnotherQuestion() {
        XCTAssertFalse(answer("Cancel") {
            let window = NSApp.modalWindow
            XCTAssertFalse(Links.shouldQuit())
            XCTAssertTrue(NSApp.modalWindow === window)
        })
    }

    func testConfirmationWithoutBrowserWindowsAndOverExistingSheet() {
        XCTAssertTrue(answer("Quit"))
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 400, height: 200),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                             styleMask: .titled, backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        window.beginSheet(sheet)
        XCTAssertFalse(answer("Cancel"))
        XCTAssertTrue(window.attachedSheet === sheet)
        window.endSheet(sheet)
        sheet.close()
        window.close()
    }

    private func answer(_ title: String? = nil, whileAsking: (() -> Void)? = nil) -> Bool {
        var answered = false
        let fallback = Timer(timeInterval: 2, repeats: false) { _ in
            MainActor.assumeIsolated {
                if !answered { NSApp.stopModal(withCode: .abort) }
            }
        }
        RunLoop.main.add(fallback, forMode: .common)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard let window = NSApp.modalWindow else { return XCTFail("No quit confirmation") }
            whileAsking?()
            guard let title else { return }
            if let button = self.buttons(window.contentView).first(where: { $0.title == title }) {
                button.performClick(nil)
            } else {
                XCTFail("No \(title) button")
            }
        }
        let result = Links.shouldQuit()
        answered = true
        XCTAssertTrue(fallback.isValid, "The native action must dismiss the confirmation")
        fallback.invalidate()
        return result
    }

    private func buttons(_ view: NSView?) -> [NSButton] {
        guard let view else { return [] }
        return (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons($0) }
    }
}
