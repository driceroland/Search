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
- [ ] **Extension fixes held until 1.0.1 is out:** the field on an extension's new tab page ([#42](https://github.com/driceroland/Search/pull/42)), popups at their own size ([#48](https://github.com/driceroland/Search/pull/48)), pinning extensions from Settings ([#50](https://github.com/driceroland/Search/pull/50)).

## Next — small additions people asked for

- [ ] **Where a link goes, shown on hover**, as an option. *([#29](https://github.com/driceroland/Search/pull/29))*
- [ ] **Import from Comet**, alongside Chrome, Arc, Brave, Edge and Dia. *(X)*
- [ ] **Intel Macs.** *(X)*

## Later — bigger pieces of work

- [ ] **More of the extension APIs**: the side panel, and the proxy API VPN and proxy extensions rely on. *([#12](https://github.com/driceroland/Search/issues/12), X)*
- [ ] **An address bar that stays visible** above the page, as an option. *([#15](https://github.com/driceroland/Search/issues/15))*
- [ ] **A tab switcher with previews** (⌃Tab held down). *(X, [#24](https://github.com/driceroland/Search/pull/24))*
- [ ] **Your own keyboard shortcuts.** *(X, [#36](https://github.com/driceroland/Search/pull/36))*
- [ ] **Driving Search from an agent** (an MCP server over the bench), for automation and testing. *(X, [#14](https://github.com/driceroland/Search/pull/14))*
- [ ] **Web push notifications**, as far as WebKit lets an app other than Safari have them. *(X)*
- [ ] **Smoother scrolling with a mouse wheel.** To look into. *(X)*
- [ ] **Tab groups.** To weigh against keeping the sidebar quiet, now that there are Spaces. *(X, [#31](https://github.com/driceroland/Search/pull/31))*
- [ ] **A title bar in the page's colour**, as an option, without bringing back the toolbar. *([#25](https://github.com/driceroland/Search/pull/25))*

## Not on the list, for now

- **Windows and Linux.** Search is made of the Mac's own WebKit and AppKit; there is nothing to carry over.
- **macOS before 14.** The app leans on what macOS 14 added to WebKit.
- **Accounts and sync** (bookmarks with Google, tabs across devices). Search has no server and keeps everything on your Mac; importing is the way in.
