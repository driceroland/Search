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

- ⌘S folds the sidebar away and the page takes the whole window; the left edge brings the tabs back out. Thanks [@kndpt](https://github.com/kndpt) ([#7](https://github.com/driceroland/Search/pull/7))
- A skill that teaches coding agents to drive Search with `./bench`. Thanks [@jasonkneen](https://github.com/jasonkneen) ([#14](https://github.com/driceroland/Search/pull/14))
- Extensions can be pinned to the toolbar from Settings › Extensions, not just from the puzzle-piece menu.

### Fixed

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
