# Roadmap

What is being worked on, what comes next, and what is not on the list, with
where each request came from: GitHub issues, pull requests, and the replies
to the launch on X. Anything finished moves to the **Unreleased** section of
[CHANGELOG.md](CHANGELOG.md), which becomes the next update.

Want something that isn't here? [Open an issue](https://github.com/driceroland/Search/issues).
Want to build something that is? Say so on its issue first, so two people
don't build it twice.

## Now — fixes for the next update

- [ ] **Bitwarden goes blank after signing in** (and for one person doesn't load). Before signing in it works — popup, WebAssembly, background — so this needs an account to reproduce. *(X, several)*
- [ ] **Search quits as it opens on macOS 14.8.3.** Nothing in the build points to it yet; waiting on the crash report. *(X)*
- [ ] **Vimium C doesn't start**: WebKit fails to load its background (Vimium itself works). *(X)*

## Next — small additions people asked for

- [ ] **Middle-click closes a tab.** *(X)*
- [ ] **The sidebar hides by itself** until the pointer reaches the edge, as an option on top of ⌘S. *(X, several)*
- [ ] **A setting to turn off the reading-progress fill** in the tab you are on. *(X)*
- [ ] **Import from Comet**, alongside Chrome, Arc, Brave, Edge and Dia. *(X)*
- [ ] **Homebrew**: `brew install --cask search`. *(X)*
- [ ] **Intel Macs.** *(X)*

## Later — bigger pieces of work

- [ ] **More of the extension APIs**: the side panel, and the proxy API VPN and proxy extensions rely on. *([#12](https://github.com/driceroland/Search/issues/12), X)*
- [ ] **An address bar that stays visible** above the page, as an option. *([#15](https://github.com/driceroland/Search/issues/15))*
- [ ] **A tab switcher with previews** (⌃Tab held down). *(X)*
- [ ] **Your own keyboard shortcuts.** *(X)*
- [ ] **Driving Search from an agent** (an MCP server over the bench), for automation and testing. *(X, [#14](https://github.com/driceroland/Search/pull/14))*
- [ ] **Web push notifications**, as far as WebKit lets an app other than Safari have them. *(X)*
- [ ] **Smoother scrolling with a mouse wheel.** To look into. *(X)*
- [ ] **Tab groups.** To weigh against keeping the sidebar quiet. *(X)*

## Not on the list, for now

- **Windows and Linux.** Search is made of the Mac's own WebKit and AppKit; there is nothing to carry over.
- **macOS before 14.** The app leans on what macOS 14 added to WebKit.
- **Accounts and sync** (bookmarks with Google, tabs across devices). Search has no server and keeps everything on your Mac; importing is the way in.
