import AppKit
import AuthenticationServices
import SwiftUI
import WebKit

#if DEBUG
// What the commands share: finding a tab, describing it, waiting for it, shooting it, and the room off screen it lives in.
extension Bench {
    /// The tab a request names, among the ones the bench opened itself. The
    /// bench is how this browser is driven while somebody is using it, and
    /// reading, clicking or sleeping in one of their tabs is not part of
    /// that: a script here is meant for tabs marked with the flask. A
    /// SHY_PROBE run has nobody's tabs in it, so there any tab answers,
    /// as for `tap` and `select`: a popup a bench page opened with
    /// `window.open` carries no flask and would be out of reach otherwise.
    func find(_ request: [String: Any], in browser: Browser) -> Tab? {
        guard let ref = (request["id"] as? String)?.lowercased(), !ref.isEmpty else { return nil }
        return browser.tabs.first { (Store.testing || $0.bench) && $0.id.uuidString.lowercased().hasPrefix(ref) }
    }

    func missing(_ request: [String: Any]) -> [String: Any] {
        ["error": "no tab “\(request["id"] as? String ?? "")” — see tabs"]
    }

    func describe(_ tab: Tab) -> [String: Any] {
        [
            "id": Bench.short(tab),
            "url": tab.address?.absoluteString ?? "",
            "page": tab.pageAddress?.absoluteString ?? "",
            "internal": tab.page?.url.absoluteString ?? "",
            "title": tab.title,
            "name": tab.name ?? "",
            // The folder it is in, by name.
            "folder": browser?.folder(of: tab)?.name ?? "",
            "loading": tab.loading,
            "hollow": tab.hollow,
            "view": tab.built?.url?.absoluteString ?? "",
            "bench": tab.bench,
            "active": tab.id == browser?.activeID,
            // Where the page is, as its tab would say it at rest, and whether
            // it says it now: the setting on, the tab you're on, not edited
            // (see AtRest.swift).
            "atRest": AtRest.of(tab.restAddress)?.text ?? "",
            "atRestShown": browser.map { tab.id == $0.activeID && $0.editingTab != tab.id && AtRest.said(tab.restAddress, always: $0.prefs.showsAddress) != nil } ?? false,
            "asleep": tab.asleep,
            "shy": tab.shy,
            "noisy": tab.noisy,
            "muted": tab.muted,
            "extensions": { if #available(macOS 15.4, *) { return tab.carriesExtensions } else { return false } }(),
            // The page's WebKit process, for measuring what it holds.
            "process": tab.built.flatMap { $0.value(forKey: "_webProcessIdentifier") as? Int } ?? 0,
            // The icon it wears, as one averaged colour: enough to tell a
            // test's plain squares apart. "" for none.
            "icon": tab.icon.map(Bench.colour) ?? "",
        ]
    }

    static func colour(_ image: NSImage) -> String {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return "" }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 1, height: 1))
        NSGraphicsContext.restoreGraphicsState()
        guard let c = rep.colorAt(x: 0, y: 0) else { return "" }
        return String(format: "%02x%02x%02x", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }

    static func short(_ tab: Tab) -> String {
        String(tab.id.uuidString.prefix(8)).lowercased()
    }

    /// One of the folders' lines as the column draws it: what it is, and
    /// how far in.
    static func line(_ line: FolderLine) -> [String: Any] {
        switch line {
        case .folder(let folder, let depth):
            ["folder": folder.name, "folded": folder.folded, "depth": depth]
        case .tab(let tab, let depth, _):
            ["tab": short(tab), "depth": depth]
        }
    }

    /// The address field, wherever it is in the window.
    static func addressField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.delegate is AddressField.Coordinator { return field }
        for sub in view.subviews { if let found = addressField(in: sub) { return found } }
        return nil
    }

    /// Milliseconds from `start` to the run loop's next rest — after every
    /// observer that runs before it sleeps, Core Animation's commit included.
    static func whenResting(since start: CFTimeInterval, _ then: @escaping @MainActor (Double) -> Void) {
        var observer: CFRunLoopObserver?
        observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max) { _, _ in
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            let rested = (CACurrentMediaTime() - start) * 1000
            MainActor.assumeIsolated { then(rested) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    /// Once the page has stopped loading, or the time is up.
    func wait(for tab: Tab, until limit: Date, _ answer: @escaping ([String: Any]) -> Void) {
        if !tab.loading, tab.address != nil, tab.failure == nil || true {
            // A beat for the document's own scripts to settle.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else { return }
                var out = describe(tab)
                if let failure = tab.failure { out["failure"] = failure }
                answer(out)
            }
            return
        }
        guard Date() < limit else {
            var out = describe(tab)
            out["timeout"] = true
            answer(out)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.wait(for: tab, until: limit, answer)
        }
    }

    /// Set once `pages on` has shown a hidden probe again, so WebKit paints
    /// its pages: from then on the app is no longer hidden, and a window
    /// ordered in would come onto the screen.
    static var pagesShown = false

    /// Windows a test run let onto a screen. Every answer names them from
    /// then on, and ./bench fails: a test must never show a window there.
    private(set) static var caught: [String] = []

    private static var watching: [NSObjectProtocol] = []

    static func onScreen(_ window: NSWindow) -> Bool {
        NSScreen.screens.contains { $0.frame.intersects(window.frame) }
    }

    /// A window about to be ordered in during a test run with pages shown
    /// (Windows.open, Windows.show): the app hidden again first, so it
    /// waits unseen. Moving it off the screen isn't enough — AppKit pulls a
    /// titled window back onto one as it comes in. `pages on` again puts
    /// every window away before it shows the app.
    static func keepOff(_ window: NSWindow) {
        guard Store.testing, pagesShown else { return }
        NSApp.hide(nil)
        pagesShown = false
    }

    /// Any other window that comes onto a screen in a test run — a sheet, a
    /// panel, one made by a path nobody thought of: taken off at once and
    /// named in every answer.
    static func watchScreens() {
        guard watching.isEmpty else { return }
        // The app itself shown or brought forward by anything but `pages on`
        // (which never activates it): hidden again at once.
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didUnhideNotification] {
            watching.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                MainActor.assumeIsolated {
                    if note.name == NSApplication.didUnhideNotification, pagesShown { return }
                    caught.append("the app \(note.name == NSApplication.didUnhideNotification ? "shown" : "brought forward")")
                    NSApp.hide(nil)
                    pagesShown = false
                }
            })
        }
        watching.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main
        ) { note in
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow, window.isVisible,
                      window.occlusionState.contains(.visible), onScreen(window) else { return }
                caught.append("\(type(of: window)) “\(window.title)” at \(NSStringFromRect(window.frame))")
                NSApp.hide(nil)
                pagesShown = false
            }
        })
    }

    /// A page nobody is looking at has to be somewhere to be laid out at all.
    /// The stage takes it back the moment you pick its tab, and it comes
    /// here again when the bench next needs it.
    func house(_ tab: Tab) {
        guard tab.bench, tab.web.window == nil else { return }
        let window = room ?? makeRoom()
        tab.web.frame = window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        tab.web.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(tab.web)
    }

    func makeRoom() -> NSWindow {
        // Off every screen, and never key or main: it exists so that a web
        // view has a window, and for nothing else.
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 1280, height: 800),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        window.hasShadow = false
        window.orderBack(nil)
        room = window
        return window
    }

    func shoot(_ tab: Tab, to file: URL, width: Double?, _ answer: @escaping ([String: Any]) -> Void) {
        shoot(tab.web, to: file, width: width, answer)
    }

    func shoot(_ web: WKWebView, to file: URL, width: Double?, _ answer: @escaping ([String: Any]) -> Void) {
        let shot = WKSnapshotConfiguration()
        shot.afterScreenUpdates = true
        if let width { shot.snapshotWidth = NSNumber(value: width) }
        web.takeSnapshot(with: shot) { image, error in
            MainActor.assumeIsolated {
                guard let image, let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:])
                else {
                    answer(["error": error?.localizedDescription ?? "no picture"])
                    return
                }
                do {
                    try png.write(to: file)
                    answer(["path": file.path, "width": rep.pixelsWide, "height": rep.pixelsHigh])
                } catch {
                    answer(["error": error.localizedDescription])
                }
            }
        }
    }

    /// A JavaScript value the way JSON can carry it.
    static func plain(_ value: Any?) -> Any {
        guard let value else { return NSNull() }
        if JSONSerialization.isValidJSONObject(["v": value]) { return value }
        return String(describing: value)
    }

    /// Where an element's middle is, in the page's own points, scrolled
    /// into view first. A selector, or `text=…` for a button or link by its
    /// words.
    static func locate(_ selector: String) -> String {
        let sel = (try? JSONSerialization.data(withJSONObject: [selector])).flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "\"\""
        return """
        (function () {
          var s = \(sel), el = null;
          if (s.indexOf('text=') === 0) {
            var want = s.slice(5).trim().toLowerCase();
            el = Array.prototype.find.call(document.querySelectorAll('button, a, [role=button], input[type=submit]'), function (e) {
              return ((e.innerText || e.value || '').trim().toLowerCase()) === want;
            }) || null;
          } else {
            el = document.querySelector(s);
          }
          if (!el) return null;
          el.scrollIntoView({ block: 'center', inline: 'nearest' });
          var r = el.getBoundingClientRect();
          return [r.left + r.width / 2, r.top + r.height / 2];
        })()
        """
    }

    /// Click, type into, or submit the element a selector names. Typing goes
    /// through the field's own setter and fires the events a keystroke
    /// would, the same as the password filler, so frameworks notice.
    static func act(_ verb: String, selector: String, text: String) -> String {
        let sel = (try? JSONSerialization.data(withJSONObject: [selector])).flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "\"\""
        let txt = (try? JSONSerialization.data(withJSONObject: [text])).flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "\"\""
        return """
        (function () {
          var el = document.querySelector(\(sel));
          if (!el) return 'nothing matches ' + \(sel);
          if (el.scrollIntoView) el.scrollIntoView({ block: 'center', inline: 'nearest' });
          var verb = '\(verb)';
          if (verb === 'click') { el.focus && el.focus(); el.click(); return 'ok'; }
          if (verb === 'submit') {
            var form = el.tagName === 'FORM' ? el : el.form || el.closest('form');
            if (!form) return 'no form around ' + \(sel);
            if (form.requestSubmit) form.requestSubmit(); else form.submit();
            return 'ok';
          }
          el.focus && el.focus();
          var value = \(txt);
          if (el.isContentEditable) {
            el.textContent = value;
            el.dispatchEvent(new InputEvent('input', { bubbles: true, data: value, inputType: 'insertText' }));
            return 'ok';
          }
          var proto = el.tagName === 'TEXTAREA' ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
          var setter = Object.getOwnPropertyDescriptor(proto, 'value');
          if (setter && setter.set) setter.set.call(el, value); else el.value = value;
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          return 'ok';
        })();
        """
    }
}
#endif
