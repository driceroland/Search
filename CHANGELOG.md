# Changelog

What changes in Search from one version to the next, newest first.

**Unreleased** gathers what is done since the last version, as it lands:
every fix and every addition gets its line the day it is merged. When a
version ships, the section takes its number and date, its gist becomes the
paragraph in `NOTES.md` (what Settings and the updater show), and the list
is what gets posted as the update. What is planned but not done yet lives
in [ROADMAP.md](ROADMAP.md).

## Unreleased

### Added

- Spaces with the tabs across the top: two fingers up or down over the bar, or a notch of a mouse wheel, bring the next space's tabs in as these go; past the last, a new space is made right in the bar. "New Space…" makes it in place in the column too.
- Reopen Closed Tab is in the right-click menu of every tab, in the row and in the column, beside Close Other Tabs; it was only on ⌘⇧T and in the History menu. Thanks [@andupoto](https://x.com/andupoto) for asking
- Extensions on private tabs, if you allow them: Settings › Extensions › Allow on private tabs, off by default. It applies to private tabs opened after it is turned on. Thanks [@merttopuz](https://github.com/merttopuz) ([#55](https://github.com/driceroland/Search/pull/55))
- Scroll with the middle button, as on Windows: click the wheel on a page, then move the mouse up or down; another click stops it. Settings › General › Scroll with the middle button.
- Homebrew: `brew install --cask driceroland/tap/search`, and `brew upgrade` brings each new version.
- ⌘S folds the tab bar away in its layout across the top too, as it folds the column: the page takes the whole height, and the bar comes back down over it when the pointer rests against the top edge. The View menu says Hide Tab Bar there.

### Fixed

- The stand-in traffic lights drawn while Search is in the background are no longer redrawn each time the window changes screen or size, only when they move.
- An empty tab no longer works the processor while it waits: the slow breath under the address field was redrawn by the app every frame, about a sixth of a core with nothing happening. The same breath now runs in macOS's own animation layer, at no cost to Search.
- With extensions installed, the window no longer waits for them: they load once it is up. The first launch after an update, when Search fits its Chrome compatibility layer to each extension again, does that away from the main thread — with Grammarly, the window had stood still for half a second. Thanks [@andupoto](https://x.com/andupoto) for the report
- Search opens faster when you have many bookmarks: the Bookmarks menu used to be built in full, every folder included, before the window could appear — about a quarter of a second for 1,500 bookmarks, at every launch. Its bookmarks are now put in as the menu opens, a folder's as that folder opens. Thanks [@andupoto](https://x.com/andupoto) for the report
- Before macOS 15.4, where Search can't run extensions, the Chrome Web Store no longer shows an "Add to Search" button that did nothing when pressed; Settings › Extensions says what they need. Thanks [@andupoto](https://x.com/andupoto) for the report
- Started hidden — `open -j`, or anything that launches Search in the background — Search comes up with its window, hidden with it until shown, where it could come up with no window at all.
- A new tab starts loading the moment you press Return or pick a bookmark. Each new tab used to start its web process from cold first — about 40 to 60 milliseconds with the window stuck — where it now takes about 10. Thanks [@andupoto](https://x.com/andupoto) for the report
- A bookmark picked from the list under its button closes the list as its page starts, instead of leaving it open over the page. Thanks [@andupoto](https://x.com/andupoto) for the report
- A link pasted into the address field shows at once. Every key and every paste sorted the whole history again for the History menu, and cut every address in it into pieces to find its host, before the field could catch up. Thanks [@andupoto](https://x.com/andupoto) for the report
- Passkeys work: a site's "Sign in with a passkey" or "Create a passkey" brings up your Mac's own passkey sheet — Touch ID with your passkeys from iCloud Keychain or a password app, your iPhone over the QR code, or a security key — where it could end in "authentication failed" on every site. Left to WebKit, a sign-in page that offers your passkey under its name field kept a request open with macOS, and if Search quit or crashed while such a page was open, macOS went on refusing all of Search's passkeys until the Mac restarted. Search now carries passkeys out itself, as Chrome does, and never leaves one open; the first time, macOS asks whether Search may use them. **Passkeys still failing after the update? Restart your Mac once.** Not yet: the passkey offered under a sign-in field as the page loads — the site's passkey button is the way in for now. ([#17](https://github.com/driceroland/Search/issues/17))
- ⌘⇧N no longer piles up empty private tabs: one already open comes to the end of the row, as with ⌘T.
- A new space's choice of sign-ins reads in full in the column ("Signed in" / "Signed out"), where it was cut short.

## 1.0.1 — 23 September 2026

### Added

- A middle-click on a tab closes it, in the row across the top and in the column. A pinned tab is put down, as with ⌘W. Thanks [@lusqua](https://github.com/lusqua) ([#27](https://github.com/driceroland/Search/pull/27))
- Rename a tab: Rename in a tab's right-click menu, or Tabs › Rename Tab, types a name over the title in place. The name stays with the tab wherever it goes, and survives a quit; emptying the field gives the page's own title back. Thanks [@theosementa](https://github.com/theosementa) ([#32](https://github.com/driceroland/Search/pull/32))
- The sidebar can hide by itself until the pointer reaches the left edge: Settings › Tabs › Hide the sidebar until the pointer reaches the edge. ⌘S still brings it out to stay. Thanks [@lusqua](https://github.com/lusqua) ([#30](https://github.com/driceroland/Search/pull/30))
- Spaces: separate sets of tabs in the one window, each with its own icon and, if you like, its own downloads folder — signed in wherever your other spaces are, or starting afresh with cookies and sign-ins of its own, as you choose when you make it. Turn them on in Settings › Tabs, then switch with ⌃1–⌃9, the space's icon, or two fingers sideways over the column of tabs, where the next space slides in beside this one; past the last, the column offers to make a new one. ([#4](https://github.com/driceroland/Search/issues/4))
- Web Inspector: Inspect Element in a page's right-click menu, and in the View menu the inspector (⌥⌘I), the JavaScript console (⌥⌘J) and picking an element (⌥⌘C), the keys Chrome and Arc use. ([#13](https://github.com/driceroland/Search/issues/13))
- ⌘S folds the sidebar away and the page takes the whole window; the left edge brings the tabs back out. Thanks [@kndpt](https://github.com/kndpt) ([#7](https://github.com/driceroland/Search/pull/7))
- Search with something other than Google: Settings › General › Search with offers DuckDuckGo, Bing, Ecosia, Startpage and Kagi, or any address with `%s` where the words go. Google stays the default. Thanks [@karadoganyi](https://github.com/karadoganyi) ([#43](https://github.com/driceroland/Search/issues/43))
- The grey that fills the tab you're on as you read down the page can be turned off: Settings › Tabs › Show how far you've read. Thanks [@karadoganyi](https://github.com/karadoganyi) ([#57](https://github.com/driceroland/Search/pull/57))
- A skill that teaches coding agents to drive Search with `./bench`. Thanks [@jasonkneen](https://github.com/jasonkneen) ([#14](https://github.com/driceroland/Search/pull/14))
- Extensions can be pinned to the toolbar from Settings › Extensions, not just from the puzzle-piece menu.

### Fixed

- Search opens on macOS 14 again: it quit as it opened, before its window, setting the look chosen in Settings on an application that didn't exist yet. Thanks [@serhiitroinin](https://github.com/serhiitroinin) ([#38](https://github.com/driceroland/Search/pull/38))
- A column of more tabs than the window holds scrolls between the pinned tabs and its foot, instead of running under the traffic lights and off the bottom of the window; the tab you go to is brought into view. Thanks [@lusqua](https://github.com/lusqua) ([#39](https://github.com/driceroland/Search/pull/39))
- ⌘T never leaves two empty tabs: an empty tab already open elsewhere in the row comes to its end and opens, with whatever was typed in it and not gone to cleared. ([#35](https://github.com/driceroland/Search/issues/35)) Thanks [@SamarthaB10](https://github.com/SamarthaB10)
- While a tab's address or name is being edited in the tab itself, a click anywhere else — the page, the column below, the rest of the strip — keeps what was typed, as Return does, instead of throwing it away. An address left as it was loads nothing again.
- Folded away with ⌘S and brought out at the edge, the column arrives whole: the traffic lights and the pinned tabs come in with it instead of standing there before it.
- A double-click along the top of the window fills the screen, as a title bar's does: it was answered twice and ended where it started. In the column's mode the page's top edge takes it too, folded away with ⌘S included, where nothing did.
- ⌘← and ⌘→ move through text while editing; adding Shift selects text instead of navigating away from the page. Thanks [@yuxino](https://github.com/yuxino) ([#19](https://github.com/driceroland/Search/pull/19))
- Extensions that open something inside a page no longer make it reload: signing in to Google with iCloud Passwords installed reloaded the page over and over, and every Vimium key that opens its bar or its link hints reloaded the page. Such a panel now gets the same answers from the browser as in Chrome. ([#2](https://github.com/driceroland/Search/issues/2))
- Dragging a tab to put it elsewhere in the row across the top moves the tab, not the whole window, and a tab being dragged stays under the pointer as it passes the others, in the column too.
- A fresh install follows the Mac's appearance: on a Mac set to dark the browser and its pages start out dark, instead of always starting light. Thanks [@mikuteto-dev](https://github.com/mikuteto-dev) ([#22](https://github.com/driceroland/Search/pull/22))
- The address field on a new tab holds still while its suggestions appear under it, instead of jumping up. Thanks [@fschrhunt](https://github.com/fschrhunt) ([#16](https://github.com/driceroland/Search/pull/16))
- 1Password's Sign in button works: an extension's page can send its tab to a website again, where it used to do nothing.
- A video in the floating window costs no more to play than in its tab. The window's shadow made WindowServer composite every frame; it has none now. ([#33](https://github.com/driceroland/Search/issues/33)) Thanks [@AxxzyWasTaken](https://github.com/AxxzyWasTaken)
- Tab moves between a form's fields again, as in every browser; ⌃Tab and ⌃⇧Tab switch tabs.
- ⌘1–⌘9 (and ⌘0 to reset the zoom) work on every keyboard layout, AZERTY included: they follow the key, not the character it types.
- A private tab now leaves nothing behind: it no longer shows up in Recently Closed. Thanks [@yuxino](https://github.com/yuxino) ([#6](https://github.com/driceroland/Search/pull/6))
- ⌘L then Return keeps the whole address, the part after `?` included. Thanks [@yuxino](https://github.com/yuxino) ([#5](https://github.com/driceroland/Search/pull/5))
- A floating video shows the whole picture on YouTube, and the page comes back to its tab when it lands. Thanks [@Chinteyley](https://github.com/Chinteyley) ([#9](https://github.com/driceroland/Search/pull/9))
- No white flash when a link opens a new tab in dark mode. Thanks [@RanaOsamaAsif](https://github.com/RanaOsamaAsif) ([#3](https://github.com/driceroland/Search/pull/3))
- Typing no longer makes the Mac beep when a page hasn't put its cursor in a field yet — starting a reply on X, for one. ([cc8aa58](https://github.com/driceroland/Search/commit/cc8aa58))

## 1.0 — 23 September 2026

The first version. A browser for the Mac with nothing in the way: tabs in a row or down the side, pinned tabs that keep their place, and one field for addresses and searches. Ads blocked before they load, passwords and passkeys in your keychain, anything on a page hidden for good, reading mode, floating video, Chrome extensions from the Chrome Web Store (macOS 15.4 or later), and tabs that sleep after half an hour. 2.9 MB, on the engine already in macOS.
