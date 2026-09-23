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

- Spaces: separate sets of tabs in the one window, each with its own cookies and sign-ins and, if you like, its own downloads folder. Turn them on in Settings › Tabs, then switch with ⌃1–⌃9 or the dot beside the tabs. ([#4](https://github.com/driceroland/Search/issues/4))
- Rename a tab: Rename in a tab's right-click menu, or Tabs › Rename Tab, types a name over the title in place. The name stays with the tab wherever it goes, and survives a quit; emptying the field gives the page's own title back.
- Web Inspector: turn it on in Settings › General, and Inspect Element is in a page's right-click menu. ([#13](https://github.com/driceroland/Search/issues/13))
- ⌘S folds the sidebar away and the page takes the whole window; the left edge brings the tabs back out. Thanks [@kndpt](https://github.com/kndpt) ([#7](https://github.com/driceroland/Search/pull/7))
- A skill that teaches coding agents to drive Search with `./bench`. Thanks [@jasonkneen](https://github.com/jasonkneen) ([#14](https://github.com/driceroland/Search/pull/14))

### Fixed

- Folded away with ⌘S and brought out at the edge, the column arrives whole: the traffic lights and the pinned tabs come in with it instead of standing there before it.
- A double-click along the top of the window fills the screen, as a title bar's does: it was answered twice and ended where it started. In the column's mode the page's top edge takes it too, folded away with ⌘S included, where nothing did.
- Extensions that open something inside a page no longer make it reload: signing in to Google with iCloud Passwords installed reloaded the page over and over, and every Vimium key that opens its bar or its link hints reloaded the page. Such a panel now gets the same answers from the browser as in Chrome. ([#2](https://github.com/driceroland/Search/issues/2))
- Dragging a tab to put it elsewhere in the row across the top moves the tab, not the whole window, and a tab being dragged stays under the pointer as it passes the others, in the column too.
- The address field on a new tab holds still while its suggestions appear under it, instead of jumping up. Thanks [@fschrhunt](https://github.com/fschrhunt) ([#16](https://github.com/driceroland/Search/pull/16))
- 1Password's Sign in button works: an extension's page can send its tab to a website again, where it used to do nothing.
- Tab moves between a form's fields again, as in every browser; ⌃Tab and ⌃⇧Tab switch tabs.
- ⌘1–⌘9 (and ⌘0 to reset the zoom) work on every keyboard layout, AZERTY included: they follow the key, not the character it types.
- A private tab now leaves nothing behind: it no longer shows up in Recently Closed. Thanks [@yuxino](https://github.com/yuxino) ([#6](https://github.com/driceroland/Search/pull/6))
- ⌘L then Return keeps the whole address, the part after `?` included. Thanks [@yuxino](https://github.com/yuxino) ([#5](https://github.com/driceroland/Search/pull/5))
- A floating video shows the whole picture on YouTube, and the page comes back to its tab when it lands. Thanks [@Chinteyley](https://github.com/Chinteyley) ([#9](https://github.com/driceroland/Search/pull/9))
- No white flash when a link opens a new tab in dark mode. Thanks [@RanaOsamaAsif](https://github.com/RanaOsamaAsif) ([#3](https://github.com/driceroland/Search/pull/3))
- Typing no longer makes the Mac beep when a page hasn't put its cursor in a field yet — starting a reply on X, for one. ([cc8aa58](https://github.com/driceroland/Search/commit/cc8aa58))

## 1.0 — 23 September 2026

The first version. A browser for the Mac with nothing in the way: tabs in a row or down the side, pinned tabs that keep their place, and one field for addresses and searches. Ads blocked before they load, passwords and passkeys in your keychain, anything on a page hidden for good, reading mode, floating video, Chrome extensions from the Chrome Web Store (macOS 15.4 or later), and tabs that sleep after half an hour. 2.9 MB, on the engine already in macOS.
