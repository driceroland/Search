import AppKit
import AuthenticationServices
import SwiftUI
import WebKit

#if DEBUG
extension Bench {
    /// Find, translation, notifications and their answers, accounts.
    func pageCommand(_ verb: String, _ request: [String: Any], _ browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        switch verb {
        case "find":
            // Find on Page as typed into its bar, then Next or Previous
            // pressed, and what the bar says once the page has answered.
            guard Store.testing else { answer(["error": "find only works on a --test run"]); return }
            let start = Date()
            browser.finding = true
            browser.matchCase = request["case"] as? Bool ?? false
            browser.wholeWords = request["words"] as? Bool ?? false
            // The same words again would count as Next, as they do in the bar.
            let text = request["text"] as? String ?? ""
            if browser.needle != text { browser.needle = text }
            for _ in 0..<(request["next"] as? Int ?? 0) { browser.look(forward: true) }
            for _ in 0..<(request["back"] as? Int ?? 0) { browser.look(forward: false) }
            func settled(_ tries: Int) {
                let status = browser.findStatus
                if (status != nil && !browser.findBusy) || tries > 200 {
                    answer(["status": status ?? "", "ms": Int(Date().timeIntervalSince(start) * 1000)])
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { settled(tries + 1) }
            }
            settled(0)
        case "translate":
            // Translate Page on a tab, as its menu does, answered once the
            // first pass is in (what it measured); original puts it back;
            // state is the tab's sign, its frames, the last page menu and
            // the languages always translated; always/never LANG are the
            // sign's Always Translate. Changing anything: test runs only.
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            let action = request["action"] as? String ?? "start"
            guard Store.testing || ["state", "start", "original"].contains(action) else {
                answer(["error": "translate \(action) only works on a --test run"]); return
            }
            let state: () -> [String: Any] = {
                var mark: [String: Any] = [:]
                if let m = tab.translation {
                    mark = ["from": m.from ?? "", "to": m.to]
                    switch m.phase {
                    case .working: mark["phase"] = "working"
                    case .done: mark["phase"] = "done"
                    case .failed(let message): mark["phase"] = "failed"; mark["message"] = message
                    }
                }
                return [
                    "enabled": PageTranslator.enabled, "available": PageTranslator.available,
                    "mark": mark, "running": tab.translator != nil, "frames": tab.translateFrames.count,
                    "report": tab.translator?.report ?? [:], "menu": tab.built?.translateItem()?.title ?? "",
                    "always": browser.prefs.translateAlways.sorted(), "tabAlways": tab.translateLanguages.sorted(),
                    "wake": tab.translateOnWake?.to ?? "", "shy": tab.shy,
                ]
            }
            switch action {
            case "original":
                tab.translator?.end(restore: true)
                answer(state())
            case "state":
                answer(state())
            case "toggle":
                // What choosing the page menu's item does.
                guard let item = tab.built?.translateItem() else { answer(["error": "no Translate Page item"]); return }
                tab.built?.perform(item.action, with: item)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { answer(state()) }
            case "always", "never":
                guard let code = request["lang"] as? String else { answer(["error": "translate always|never LANG"]); return }
                tab.setAlwaysTranslates(code, action == "always")
                answer(state())
            default:
                let target = (request["lang"] as? String).map(Locale.Language.init(identifier:)) ?? PageTranslator.reader
                if PageTranslator.start(tab, to: target, done: { report in
                    var reply = state()
                    reply["report"] = report
                    answer(reply)
                }) == nil { return }
            }

        case "visible":
            // Refused: it lent the tab to a window of its own, off every
            // screen, so that WebKit would count the page as seen. No bench
            // verb makes a window for now, off screen or not, after windows
            // reached a screen during test runs; what needs a page to be
            // seen is checked on a release candidate instead.
            answer(["error": "visible is switched off: it made a window, and no bench verb makes one for now — check this on a release candidate"])

        case "notifications":
            // What a test run would have posted, and every site's answer.
            guard Store.testing else { answer(["error": "notifications only works on a --test run"]); return }
            answer(["recorded": SiteNotifications.shared.recorded, "choices": SiteNotifications.choices(in: browser.profileID),
                    "asking": browser.asking.map { "\($0.host) \($0.wants)" } ?? ""])

        case "answer":
            guard Store.testing else { answer(["error": "answer only works on a --test run"]); return }
            switch request["with"] as? String {
            case "once": browser.allowCaptureOnce()
            case "always": browser.allowCapture()
            case "no": browser.denyCapture()
            case "screen": browser.shareScreen()
            case "window": browser.shareWindow()
            case "noscreen": browser.denyShare()
            default: answer(["error": "answer once|always|no|screen|window|noscreen"]); return
            }
            answer(["asking": browser.asking.map { "\($0.host) \($0.wants)" } ?? "", "locationAnswered": Browser.locationAnswered ?? "",
                    "displayAnswered": Browser.displayAnswered as Any? ?? NSNull()])

        case "accounts":
            // The list under the sign-in box the caret is in — passkeys, then
            // passwords — and, with "pick", a click on its row by number,
            // counted from 0. Only on a SHY_PROBE run: it would sign in.
            // Also the name the save question would keep ("offer"), and,
            // with "forget", every login this test world kept — its own
            // label's, never another world's or the real one's. "keep" is
            // the save question's Save.
            guard Store.testing else { answer(["error": "accounts only works on a --test run"]); return }
            if request["keep"] as? Bool == true { browser.keepOffer() }
            if request["forget"] as? Bool == true {
                Vault.all(in: browser.profileID).forEach { Vault.forget(host: $0.host, user: $0.user, in: browser.profileID) }
                browser.dropOffer()
            } else if let user = request["forget"] as? String {
                // One account's, as Settings › Passwords forgets it: "" is
                // the login kept under no name.
                Vault.all(in: browser.profileID).filter { $0.user == user }.forEach { Vault.forget(host: $0.host, user: $0.user, in: browser.profileID) }
            }
            let offer: [String: Any] = browser.offering.map { ["user": $0.login.user, "host": $0.login.host, "changed": $0.changed] } ?? [:]
            // Every account this world keeps, by name, without a secret.
            let users = Vault.all(in: browser.profileID).map(\.user)
            guard let list = browser.suggesting else { answer(["shown": false, "offer": offer, "kept": users.count, "users": users]); return }
            let rows = list.passkeys.map { ["passkey": $0.name] } + list.logins.map { ["login": $0.user] }
            if let pick = request["pick"] as? Int {
                guard rows.indices.contains(pick) else { answer(["error": "no row \(pick)"]); return }
                if pick < list.passkeys.count { browser.choose(list.passkeys[pick]) } else { browser.choose(list.logins[pick - list.passkeys.count]) }
            }
            answer(["shown": true, "rows": rows, "nameOnly": list.nameOnly, "offer": offer, "kept": users.count, "users": users,
                    "spot": [list.spot.minX, list.spot.minY, list.spot.width, list.spot.height]])

        default:
            answer(["error": "unknown command “\(verb)”"])
        }
    }
}
#endif
