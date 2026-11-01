import SwiftUI
import WebKit
import Combine

// MARK: - passwords

extension Browser {
    struct Offer: Equatable {
        let login: Login
        /// The same account is already kept, with a different password.
        let changed: Bool
    }

    struct Suggesting: Equatable {
        let tab: Tab.ID
        var spot: CGRect
        /// Without secrets: one is read only for the account picked.
        let logins: [Kept]
        /// The Mac's passkeys for a page waiting for one under its field.
        var passkeys: [Passkeys.Offered] = []
        /// The page the list was made for: its site, and whether it came in
        /// the clear. A click fills only a page that still is that one.
        let host: String
        let clear: Bool
        /// Hung from a first step's name box: a pick puts in the name alone.
        var nameOnly = false
        /// When it came up. A page can put the caret in a sign-in box
        /// itself, an invisible one under the pointer included: a click that
        /// was already on its way is not a choice, so the list takes none for
        /// its first half second, as Chrome's does.
        var shown = Date()
    }

    func keepOffer() {
        guard let offer = offering else { return }
        offering = nil
        let login = offer.login
        guard Vault.save(host: login.host, user: login.user, password: login.password, used: Date(), clear: login.clear, in: login.profile) else {
            announce("The keychain refused it")
            return
        }
        relist()
        announce(offer.changed ? "Password updated for \(login.host)" : "Password saved for \(login.host)")
    }

    func dropOffer() { offering = nil }

    /// Never for this site. Some sites you sign into on purpose with nothing
    /// you want remembered.
    func neverOffer() {
        guard let offer = offering else { return }
        Vault.never(offer.login.host, in: offer.login.profile)
        offering = nil
        announce("Never for \(offer.login.host)")
    }

    /// The caret in a sign-in box: the accounts kept for this site, and the
    /// Mac's passkeys for a page waiting for one, hang from the box, and go
    /// when the caret does. Nothing is filled on its own — the way Safari
    /// does it, and what a person expects.
    func hang(from tab: Tab, _ spot: CGRect?, passwords: Bool, name: Bool = false) {
        guard let spot else {
            if field?.tab == tab.id { field = nil }
            if looked?.tab == tab.id { looked = nil }
            if pickedInto == tab.id { pickedInto = nil }
            guard suggesting?.tab == tab.id else { return }
            lowering?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, suggesting?.tab == tab.id else { return }
                suggesting = nil
            }
            lowering = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
            return
        }
        lowering?.cancel()
        field = (tab.id, spot, passwords, name)
        guard tab.id == activeID, pickedInto != tab.id,
              let host = curtain.host(of: tab.pageAddress)
        else { return }
        // A page that came over plain http can have been written by
        // anyone on the way here — a café's network, a hotel's. It is
        // offered only what was kept from plain http too, never an
        // account kept from the https site of the same name.
        let inTheClear = tab.pageAddress?.scheme?.lowercased() == "http"
        // The same box, moved by a scroll: the list up follows it, keeping
        // its accounts and the moment it came up (a click is refused for
        // its first half second, which every frame used to start again);
        // a box with no accounts stays without, and the keychain isn't
        // asked again until the caret leaves.
        if let looked, looked.tab == tab.id, looked.host == host, looked.clear == inTheClear, looked.name == name {
            if var up = suggesting, up.tab == tab.id, up.spot != spot {
                up.spot = spot
                suggesting = up
            }
            return
        }
        looked = (tab.id, host, inTheClear, name)
        // Passwords only for a box that goes with one: a box for passkeys
        // alone has no password to put anywhere.
        var kept = prefs.fillsPasswords && passwords
            ? Vault.kept(matching: host, in: profile(of: tab)).filter { !inTheClear || $0.clear } : []
        // The account whose name the step before was sent with comes first:
        // the password page of a sign-in that asks for the name first.
        if let given = tab.givenName(),
           let at = kept.firstIndex(where: { $0.user.caseInsensitiveCompare(given) == .orderedSame }) {
            kept.insert(kept.remove(at: at), at: 0)
        }
        let known = Array(kept.prefix(5))
        let passkeys = Passkeys.shared.offered(in: tab.built)
        guard !known.isEmpty || !passkeys.isEmpty else {
            suggesting = nil
            return
        }
        // What is under the pointer changed: the half second starts again.
        if let up = suggesting, up.tab == tab.id, up.logins == known, up.passkeys == passkeys, up.nameOnly == name {
            suggesting?.spot = spot
            return
        }
        suggesting = Suggesting(tab: tab.id, spot: spot, logins: known, passkeys: passkeys, host: host, clear: inTheClear,
                                nameOnly: name)
    }

    /// One of the accounts in the list, picked by name.
    func choose(_ login: Kept) {
        lowering?.cancel()
        guard let list = suggesting, let tab = tabs.first(where: { $0.id == list.tab }) else { return }
        guard Date().timeIntervalSince(list.shown) > 0.5 else { return }
        suggesting = nil
        // The tab may have gone somewhere else while the list was up: a
        // redirect, a script. What was offered for one site is never put
        // into another's page.
        guard curtain.host(of: tab.pageAddress) == list.host,
              (tab.pageAddress?.scheme?.lowercased() == "http") == list.clear
        else { return }
        pickedInto = tab.id
        // A first step: the name alone, the password waits for its page.
        if list.nameOnly {
            tab.fillName(login.user, onlyOn: tab.pageAddress) { [weak self] worked in
                if !worked { self?.announce("Couldn't find the sign-in fields anymore") }
            }
            return
        }
        // Its secret is read now, once it is picked: see `Vault.kept(for:)`.
        guard let login = Vault.login(login) else {
            announce("The keychain refused it")
            return
        }
        tab.fill(user: login.user, password: login.password, onlyOn: tab.pageAddress) { [weak self] worked in
            if !worked { self?.announce("Couldn't find the sign-in fields anymore") }
        }
        // A private tab's sign-in leaves no date behind.
        if !tab.shy { Vault.touch(login) }
    }

    /// One of the passkeys in the list: the Mac's sheet for it, and the
    /// page's request answered with it.
    func choose(_ passkey: Passkeys.Offered) {
        lowering?.cancel()
        guard let list = suggesting, let tab = tabs.first(where: { $0.id == list.tab }), let web = tab.built else { return }
        guard Date().timeIntervalSince(list.shown) > 0.5 else { return }
        suggesting = nil
        guard curtain.host(of: tab.pageAddress) == list.host,
              (tab.pageAddress?.scheme?.lowercased() == "http") == list.clear
        else { return }
        pickedInto = tab.id
        Passkeys.shared.sign(in: web, with: passkey.id)
    }

    func dropChoice() { suggesting = nil }

    // The list of what is kept.

    /// Passwords, in a tab. The list is read again each time it is asked for.
    var managing: Bool {
        get { pageTab(.passwords) != nil }
        set { if newValue { show(InternalPage(.passwords)) } else { putAway(.passwords) } }
    }

    struct SiteRow {
        let host: String
        let logins: [Kept]
    }

    /// Grouped by site, filtered by what has been typed.
    var shownSites: [SiteRow] {
        let needle = hunting.trimmingCharacters(in: .whitespaces).lowercased()
        let rows = needle.isEmpty ? saved : saved.filter {
            $0.host.contains(needle) || $0.user.lowercased().contains(needle)
        }
        let groups = Dictionary(grouping: rows, by: \.host)
        return groups.keys.sorted().map { host in
            SiteRow(host: host, logins: groups[host]!.sorted { $0.user < $1.user })
        }
    }

    func relist() { saved = Vault.all(in: profileID) }

    func keep(host: String, user: String, password: String) {
        guard Vault.save(host: host, user: user, password: password, in: profileID) else {
            announce("The keychain refused it")
            return
        }
        relist()
        announce("Kept for \(host)")
    }

    func forget(_ login: Kept) {
        Vault.forget(host: login.host, user: login.user, in: login.profile)
        relist()
    }

    /// The panel's Remove All…, or Remove N… while its search narrows the
    /// list: every account the list shows, out of the keychain, once asked.
    /// Only what is shown, so a search for one site never takes the rest
    /// with it. For moving what is kept to a manager of one's own: all at
    /// once, rather than one Remove at a time (#469). Asked, then proved the
    /// way showing one is, since it can't be undone; Return is Cancel's.
    func forgetShown() {
        let shown = shownSites.flatMap(\.logins)
        guard !shown.isEmpty, !forgetting else { return }
        let count = shown.count
        let many = count == 1 ? "1 password" : "\(count) passwords"
        Ask.sure(
            count == 1 ? "Remove 1 Password?" : "Remove \(count) Passwords?",
            detail: "They're taken out of your keychain. Only the passwords Shy keeps are removed: password managers, other apps and other browsers keep theirs. This can't be undone.",
            confirm: "Remove",
            returnCancels: true
        ) { [weak self] in
            Vault.prove("remove \(many)") { ok in
                guard ok, let self, !self.forgetting else { return }
                // A keychain delete is a few milliseconds, a few hundred of
                // them a second: off the main thread, as imports are (#380).
                self.forgetting = true
                DispatchQueue.global(qos: .userInitiated).async {
                    // Counted as the keychain answers, not as asked: one
                    // it kept is not reported gone.
                    let gone = shown.filter { Vault.forget(host: $0.host, user: $0.user, in: $0.profile) }.count
                    DispatchQueue.main.async {
                        self.forgetting = false
                        self.relist()
                        let removed = gone == 1 ? "1 password" : "\(gone) passwords"
                        self.announce(gone == count ? "Removed \(removed)"
                            : gone == 0 ? "The keychain refused them"
                            : "Removed \(gone) of \(many)")
                    }
                }
            }
        }
    }

    /// A password copied is asked for the way one shown is. It goes on this
    /// Mac's clipboard only, not to your other devices', marked concealed
    /// and transient, which is what clipboard managers go by to keep it out
    /// of their history, and it is taken off again after a minute and a
    /// half unless something else has been copied since.
    func copy(_ login: Kept) {
        Vault.prove("copy the password for \(login.host)") { [weak self] ok in
            guard ok, let self else { return }
            // Read here, once the Mac has said who this is: what the panel
            // drew its list from holds no secrets.
            guard let password = Vault.secret(of: login) else {
                self.announce("The keychain refused it")
                return
            }
            let board = NSPasteboard.general
            board.prepareForNewContents(with: .currentHostOnly)
            board.setString(password, forType: .string)
            board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
            board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
            let copied = board.changeCount
            DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
                if board.changeCount == copied { board.clearContents() }
            }
            announce("Password copied")
        }
    }

    /// Something another browser exported: a bookmarks page, a passwords
    /// file, or Safari's own export (see ImportFile). Read once, never copied.
    func importFile() {
        guard fileImport == nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.html, .commaSeparatedText, .plainText, .zip, .json]
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Bring In"
        panel.message = "A file another browser exported: bookmarks (.html), passwords (.csv), or Safari's File › Export Browsing Data (.zip)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { announce((await takeFile(url)).said) }
    }

    /// The file's bookmarks, history and passwords, taken in as a browser's
    /// are: bookmarks merged without doubles, history counted once. Says
    /// what came in, and after Safari's export, that the file holds your
    /// passwords in the clear.
    struct FileTake {
        let said: String
        let bookmarks: Int
        let already: Int
        let places: Int
        let kept: Int
        let skipped: Int
        let cancelled: Bool
    }

    @discardableResult
    func takeFile(_ url: URL) async -> FileTake {
        // The profile on screen when it was asked for, wherever the window goes meanwhile.
        let profile = profileID
        let bookmarks = self.bookmarks, history = self.history
        guard !Browser.fileImportTerminating, fileImport == nil else { return FileTake(said: "An import is already running", bookmarks: 0, already: 0, places: 0, kept: 0, skipped: 0, cancelled: false) }
        let id = UUID()
        fileImport = FileImportJob(id: id, filename: url.lastPathComponent, message: "Reading…")
        let control = ImportFile.Control { [weak self] progress in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.fileImport?.id == id, self.fileImport?.cancelling == false else { return }
                self.fileImport?.message = progress.message
                self.fileImport?.completed = progress.completed
                self.fileImport?.total = progress.total
            }
        }
        fileImportControl = control
        Browser.activeFileImports[id] = control
        defer {
            Browser.activeFileImports[id] = nil
            if fileImport?.id == id { fileImport = nil; fileImportControl = nil }
        }
        var added = 0, already = 0, places = 0, kept = 0, skipped = 0
        var safari = false
        var failed = false
        var mergedBookmarks = false
        do {
            let found: ImportFile.Found = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try ImportFile.read(url, control: control)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
            safari = found.fromSafari
            try control.checkCancellation()
            let name = found.fromSafari ? "Safari" : url.deletingPathExtension().lastPathComponent
            if !found.bookmarks.isEmpty {
                fileImport?.message = "Merging bookmarks…"
                fileImport?.completed = 0
                fileImport?.total = nil
                let result = try await bookmarks.takeFile(found.bookmarks, from: name, control: control)
                mergedBookmarks = true
                added = result.added
                already = result.already
            }
            if !found.places.isEmpty {
                fileImport?.message = "Adding history…"
                fileImport?.completed = 0
                fileImport?.total = found.places.count
                for batch in stride(from: 0, to: found.places.count, by: 200) {
                    guard !control.isCancelled else { break }
                    let end = min(batch + 200, found.places.count)
                    for place in found.places[batch..<end] {
                        history.take(place.url, title: place.title, count: place.count, last: place.last)
                        places += 1
                    }
                    fileImport?.completed = places
                    fileImport?.total = found.places.count
                    await Task.yield()
                }
                if places > 0 { history.settle() }
            }
            if !found.passwords.isEmpty && !control.isCancelled {
                fileImport?.message = "Saving passwords…"
                fileImport?.completed = 0
                fileImport?.total = nil
                for text in found.passwords {
                    guard !control.isCancelled else { break }
                    let result = await withCheckedContinuation { continuation in
                        DispatchQueue.global(qos: .userInitiated).async {
                            continuation.resume(returning: Vault.take(csv: text, control: control, in: profile))
                        }
                    }
                    kept += result.kept
                    skipped += result.skipped
                }
            }
        } catch {
            failed = !control.isCancelled
        }
        if kept > 0 || skipped > 0 {
            saved = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: Vault.all(in: profile))
                }
            }
        }
        func count(_ n: Int, _ one: String, _ many: String) -> String { n == 1 ? "1 \(one)" : "\(n) \(many)" }
        var parts: [String] = []
        if added > 0 || already > 0 {
            parts.append(already == 0 ? count(added, "bookmark", "bookmarks") : "\(count(added, "new bookmark", "new bookmarks")), \(already) already here")
        }
        if places > 0 { parts.append(count(places, "place", "places")) }
        if kept > 0 || skipped > 0 {
            parts.append(skipped == 0 ? count(kept, "password", "passwords") : "\(count(kept, "password", "passwords")), \(skipped) skipped")
        }
        var said = parts.joined(separator: " · ")
        if control.isCancelled {
            said = said.isEmpty ? (mergedBookmarks ? "Import cancelled after merging bookmarks" : "Import cancelled; nothing was changed") : "Import cancelled after " + said
        }
        else if failed { said = said.isEmpty ? "That file couldn't be read" : "Import stopped after " + said }
        else if said.isEmpty { said = mergedBookmarks ? "Bookmark folders imported" : "Nothing to bring in from that file" }
        if safari, kept > 0 {
            said += " — the exported file holds your passwords in the clear: delete it now"
        }
        return FileTake(said: said, bookmarks: added, already: already, places: places, kept: kept, skipped: skipped, cancelled: control.isCancelled)
    }
}
