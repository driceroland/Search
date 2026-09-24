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
- [ ] **Vimium C doesn't start**: WebKit fails to load its background (Vimium itself works). *(X)*
- [ ] **Passkeys under the sign-in field.** A site's passkey button brings up the Mac's passkey sheet now; next is the suggestion Safari shows as you click into a sign-in field. *(X, [#17](https://github.com/driceroland/Search/issues/17))*

## Next — small additions people asked for

- [ ] **Import from Comet**, alongside Chrome, Arc, Brave, Edge and Dia. *(X)*
- [ ] **Intel Macs.** *(X)*

## Later — bigger pieces of work

- [ ] **More of the extension APIs**: the side panel, and the proxy API VPN and proxy extensions rely on. *([#12](https://github.com/driceroland/Search/issues/12), X)*
- [ ] **A tab switcher with previews** (⌃Tab held down). *(X, [#24](https://github.com/driceroland/Search/pull/24))*
- [ ] **Your own keyboard shortcuts.** *(X, [#36](https://github.com/driceroland/Search/pull/36))*
- [ ] **Driving Search from an agent** (an MCP server over the bench), for automation and testing. *(X, [#14](https://github.com/driceroland/Search/pull/14))*
- [ ] **Web push notifications**, as far as WebKit lets an app other than Safari have them. *(X)*
- [ ] **Smoother scrolling with a mouse wheel.** To look into. *(X)*
- [ ] **A title bar in the page's colour**, as an option, without bringing back the toolbar. *([#25](https://github.com/driceroland/Search/pull/25))*
- [ ] **Extensions per space**: each space with the extensions it wants, on and off apart from the others. WebKit has one extension controller for the whole app, so this means one per space. Drice's call, 24 Sep: later. *(X)*

## Not on the list, for now

- **An address bar above the page** ([#15](https://github.com/driceroland/Search/issues/15)). The card behind a tab's icon — the site, whether its connection is secure, copy, print, zoom — does that part without a bar.
- **Tab groups and folders** ([#23](https://github.com/driceroland/Search/issues/23), [#68](https://github.com/driceroland/Search/issues/68)). Spaces keep sets of tabs apart, and the column stays quiet.
- **Windows and Linux.** Search is made of the Mac's own WebKit and AppKit; there is nothing to carry over.
- **macOS before 14.** The app leans on what macOS 14 added to WebKit.
- **Accounts and sync** (bookmarks with Google, tabs across devices). Search has no server and keeps everything on your Mac; importing is the way in.
