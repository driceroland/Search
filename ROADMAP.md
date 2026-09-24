# Roadmap

Every idea and every report about Search, in one place: what is being built
right now, what goes out with the next version, what comes after, and what
is not on the list — each with where it came from. GitHub issues, pull
requests, the emails that reach hello@officecommun.com and the replies on X
all land here.

**The live version is [officecommun.com/search/roadmap](https://officecommun.com/search/roadmap)**:
it changes the moment the work does. This file is a copy of the same list,
written by `./ideas md`. What has shipped is in [CHANGELOG.md](CHANGELOG.md).

Want something that isn't here? [Open an issue](https://github.com/driceroland/Search/issues).
Want to build something that is? Say so on its issue first, so two people
don't build it twice.

## Keeping it whole

The list is only worth something if nothing is missing from it and nothing
in it is stale. Whoever works on Search keeps it that way, with `./ideas`
(`./ideas help` for everything it does):

- **Every new idea or report gets its line the day it arrives**, whatever the
  source: an issue, a pull request, an email, a reply on X, a message.
  `./ideas find` first: if it is already there, `./ideas from ID SOURCE` adds
  the new voice instead of a second line.
- **Say what you're building as you start**: `./ideas start ID "who"`, and
  `./ideas done ID` when it's on main, in the same breath as its line in
  CHANGELOG.md. The page shows both at once.
- **`./ideas check`** compares the list with GitHub: every open issue and pull
  request without its idea, and every idea still to do whose issue or pull
  request is closed. Run it whenever you pick up where someone else left off.
- **`./ideas md`** writes this file again; commit it with the work.
- **Public.** Emails are marked *(email)*, never with a name or an address. A
  security report sent privately never comes here, not even in outline: it
  is fixed, it ships, and only then is it credited in CHANGELOG.md.

## Done, in the next version

- [x] **Media pauses when switching spaces** Music or a video playing in one space stops when you switch to another. *([#74](https://github.com/driceroland/Search/issues/74))*
- [x] **History is slow** History is slow to open, stutters as it scrolls, and Escape doesn't close it. *([#67](https://github.com/driceroland/Search/issues/67))*
- [x] **Web Inspector blanks the page** With the Web Inspector open, resizing the window turns the page blank. *([#91](https://github.com/driceroland/Search/issues/91))*
- [x] **History keeps each video apart** History keeps different articles and videos from the same site apart. *([#154](https://github.com/driceroland/Search/pull/154))*
- [x] **⌘W stops bouncing between pins** A pin already put down stays down. *([#125](https://github.com/driceroland/Search/pull/125))*
- [x] **Local certificates, trusted only here** A certificate is taken on trust only for this Mac itself. On main already; the pull request closes, with thanks, when it ships. *([#165](https://github.com/driceroland/Search/pull/165), [#133](https://github.com/driceroland/Search/issues/133))*
- [x] **User scripts stay in their package** A user script's file is read from the extension's own package. On main already; the pull request closes, with thanks, when it ships. *([#198](https://github.com/driceroland/Search/pull/198))*
- [x] **Copying a password asks first** Copy in Passwords asks who you are first, as Show does. On main already; the pull request closes, with thanks, when it ships. *([#203](https://github.com/driceroland/Search/pull/203))*
- [x] **Links to other apps ask first** On main already; the pull request closes, with thanks, when it ships. *([#206](https://github.com/driceroland/Search/pull/206))*
- [x] **Extension reloads ask for new access** Reloading an extension loaded from a folder asks before it gets more access, and keeps the old version on no. *([#135](https://github.com/driceroland/Search/issues/135), [#161](https://github.com/driceroland/Search/pull/161))*
- [x] **Extension update check** The update check reads the version from the right place. *([#201](https://github.com/driceroland/Search/pull/201))*
- [x] **Passwords keep to Search's own** Passwords asks the keychain only about Search's own items. [#205](https://github.com/driceroland/Search/pull/205) builds on it: an http page is offered only what was kept from http. *([#208](https://github.com/driceroland/Search/pull/208), [#205](https://github.com/driceroland/Search/pull/205))*
- [x] **Pop-ups need a click** *([#207](https://github.com/driceroland/Search/pull/207))*
- [x] **Folded tab bar gets its own ground** The tab bar folded away with ⌘S comes back on a ground of its own: the page no longer shows through between the tabs.
- [x] **Install updates by hand** Settings › About › Install updates on its own, on by default. Off, Search still says when a version is out and installs it when you press Install. *(email)*

## Now — fixes for the next update

- [ ] **Bitwarden goes blank after sign-in** For one person it doesn't load at all. Before signing in it works — popup, WebAssembly, background. Probably fixed by 1Password's worker fix ([#126](https://github.com/driceroland/Search/pull/126)) and the extension storage fix in 1.0.2; needs a real account to confirm. Also asked: a self-hosted Vaultwarden server behind the extension. *(X, email)*
- [ ] **Bitwarden on Intel Macs** The extension says "WebAssembly is not supported" on an Intel Mac. *([#175](https://github.com/driceroland/Search/issues/175))*
- [ ] **Google sign-in flashes with Proton Pass** With Proton Pass signed in, Google's sign-in page reloads every half second. Presumed fixed in 1.0.2 by [#126](https://github.com/driceroland/Search/pull/126) and the passkey changes; to confirm with the person who saw it. *(X)*
- [ ] **Vimium C doesn't start** WebKit fails to load its background (Vimium itself works). A fix is waiting in [#170](https://github.com/driceroland/Search/pull/170). *(X, email, [#170](https://github.com/driceroland/Search/pull/170))*
- [ ] **Passkeys under the sign-in field** A site's passkey button brings up the Mac's passkey sheet now; next is the suggestion Safari shows as you click into a sign-in field. *([#17](https://github.com/driceroland/Search/issues/17), X)*
- [ ] **iCloud Passwords** Pairing asks for the code twice ([#217](https://github.com/driceroland/Search/pull/217) fixes the first code); one person says it doesn't work at all, details asked. *([#17](https://github.com/driceroland/Search/issues/17), email ×2, [#217](https://github.com/driceroland/Search/pull/217))*
- [ ] **Window stutters between screens** Dragging the window from one screen to another stutters. Needs a trace recorded on two screens. *(X)*
- [ ] **Web processes start before the window** The web process pool is made before the first window; check whether 1.0.2's launch order already covers it. *([#157](https://github.com/driceroland/Search/issues/157))*
- [ ] **⌘F lands on the back button** On some pages ⌘F focuses the back button instead of the find field. *([#172](https://github.com/driceroland/Search/issues/172))*
- [ ] **Mouse wheel stuck on some pages** A mouse wheel doesn't scroll a page that listens to the wheel itself. A fix is waiting in [#194](https://github.com/driceroland/Search/pull/194). *([#180](https://github.com/driceroland/Search/issues/180), [#194](https://github.com/driceroland/Search/pull/194))*
- [ ] **Wrong icons on some tabs** Meta AI shows Google's G, Swagger UI stays on a letter. A fix is waiting in [#216](https://github.com/driceroland/Search/pull/216). *([#181](https://github.com/driceroland/Search/issues/181), [#216](https://github.com/driceroland/Search/pull/216))*
- [ ] **Window flashes at its default size** At launch the window opens at its default size for an instant, then takes its saved size. A fix is waiting in [#204](https://github.com/driceroland/Search/pull/204). *([#202](https://github.com/driceroland/Search/issues/202), [#204](https://github.com/driceroland/Search/pull/204))*
- [ ] **Early content scripts miss restored pages** A content script that runs at document_start can miss the page restored at a hidden launch. *([#199](https://github.com/driceroland/Search/issues/199))*
- [ ] **Suggestions slow with a big history** Address suggestions slow down with a large history. *([#200](https://github.com/driceroland/Search/issues/200))*
- [ ] **Stuttering pages** Details to gather. *([#211](https://github.com/driceroland/Search/issues/211))*
- [ ] **Full-screen video goes black** A video put full screen goes black. A fix is waiting in [#220](https://github.com/driceroland/Search/pull/220). *([#220](https://github.com/driceroland/Search/pull/220))*
- [ ] **Floating video on Twitch, Netflix, X** The floating video misbehaves on some sites. Only part of the picture on Twitch and Netflix, sometimes the player without a picture on YouTube, only some of the time on X; Netflix subtitles disappear from it ([#190](https://github.com/driceroland/Search/pull/190)). *([#123](https://github.com/driceroland/Search/issues/123), email ×2, [#190](https://github.com/driceroland/Search/pull/190))*
- [ ] **Videos stuck muted** Some video sites play muted, with nothing to turn the sound on. *([#223](https://github.com/driceroland/Search/issues/223))*
- [ ] **Ad blocker leaves empty spaces** On news sites like AS.com, blocked ads leave gaps in the page. *([#159](https://github.com/driceroland/Search/issues/159))*
- [ ] **Chatbot pages struggle or crash** grok.com and other chatbot pages; details asked. *(email)*
- [ ] **x.com reloads before sign-in** x.com reloads over and over before signing in. Not reproduced; asked whether extensions are installed. *(email)*
- [ ] **Figma and LinkedIn feel slow** Figma blurs for a moment as you zoom in; LinkedIn's feed and profiles scroll with lag. *(email)*
- [ ] **Spaces sometimes don't switch** *(email)*
- [ ] **Hidden sidebar closes too soon** It closes while the pointer is over the extension buttons at its foot. Maybe fixed by [#115](https://github.com/driceroland/Search/pull/115) in 1.0.2; unconfirmed. *(email)*
- [ ] **Middle-click on YouTube links** A middle-click on YouTube links works only some of the time. 1.0.2 added middle-click on links; to confirm there. *(email)*
- [ ] **Extension popups miss messages** Extension popups and extension pages don't receive messages from the extension's background in a test run (the offscreen document does). To check in a window on screen; would matter for popups waiting on the background.
- [ ] **Dragging a pin redraws the column** Dragging a pin redraws the whole column each frame, as dragging a tab did before 1.0.2.
- [ ] **Bookmarks popover closes on fold** The bookmarks popover closes when the hidden sidebar folds (it counts as leaving the sidebar). A fix is waiting in [#89](https://github.com/driceroland/Search/pull/89). *([#88](https://github.com/driceroland/Search/issues/88), [#89](https://github.com/driceroland/Search/pull/89))*
- [ ] **Settings sidebar corners** The Settings sidebar has rounded inner corners. A fix is waiting in [#222](https://github.com/driceroland/Search/pull/222). *([#221](https://github.com/driceroland/Search/issues/221), [#222](https://github.com/driceroland/Search/pull/222))*
- [ ] **Toolbar buttons too tight** The back, forward and reload buttons sit edge to edge. A fix is waiting in [#209](https://github.com/driceroland/Search/pull/209). *([#185](https://github.com/driceroland/Search/issues/185), [#209](https://github.com/driceroland/Search/pull/209))*
- [ ] **⇧⌘C copies without a word** ⇧⌘C copies the address, but nothing in the app says so. A fix is waiting in [#182](https://github.com/driceroland/Search/pull/182). *([#176](https://github.com/driceroland/Search/issues/176), [#182](https://github.com/driceroland/Search/pull/182))*
- [ ] **Bitwarden with a self-hosted server** Signing in from the extension to a self-hosted Bitwarden server says the user doesn't exist, while the same address works in a tab. To fix before 1.0.3. *(X)*

## Next — small additions people asked for

- [ ] **Import an .html bookmarks file** The format every browser exports. Only direct import from Chrome, Arc, Brave, Edge and Dia exists today. *(email ×2)*
- [ ] **Import from Comet** Alongside Chrome, Arc, Brave, Edge and Dia. *(X)*
- [ ] **Import from Helium, Firefox, Zen** Import from Helium, Firefox and Zen. Both waiting as pull requests. *([#178](https://github.com/driceroland/Search/pull/178), [#215](https://github.com/driceroland/Search/pull/215))*
- [ ] **Tab switcher with previews** ⌃Tab held down shows the tabs with previews. Off until turned on; Option-Tab asked too, as in AltTab. Waiting on its author to rebase and simplify. *([#24](https://github.com/driceroland/Search/pull/24), X, email)*
- [ ] **Your own keyboard shortcuts** In Settings › Shortcuts. Waiting on its author to rebase and simplify. Editing extension shortcuts belongs with it ([#189](https://github.com/driceroland/Search/issues/189)). *([#36](https://github.com/driceroland/Search/pull/36), [#189](https://github.com/driceroland/Search/issues/189), X)*
- [ ] **Hard reload with ⇧⌘R** ⌘R reloads, ⇧⌘R reloads from the network. Waiting in [#179](https://github.com/driceroland/Search/pull/179). *([#171](https://github.com/driceroland/Search/issues/171), [#179](https://github.com/driceroland/Search/pull/179))*
- [ ] **Reduce motion** Reduce motion for Search's own interface. Two pull requests do it ([#187](https://github.com/driceroland/Search/pull/187), [#210](https://github.com/driceroland/Search/pull/210)); one is to be picked. *([#186](https://github.com/driceroland/Search/issues/186), [#187](https://github.com/driceroland/Search/pull/187), [#210](https://github.com/driceroland/Search/pull/210))*
- [ ] **Default page zoom** One zoom for every site, in Settings › General. *([#177](https://github.com/driceroland/Search/pull/177))*
- [ ] **Site search keywords** Type a site's keyword, then your search. *([#188](https://github.com/driceroland/Search/pull/188))*
- [ ] **Address bar commands** A word like "settings" reaches the app itself. *([#212](https://github.com/driceroland/Search/pull/212))*
- [ ] **Hold a swipe to pick from history** Hold a back or forward swipe to pick a page from history. *([#191](https://github.com/driceroland/Search/pull/191))*
- [ ] **Tabs load when shown** Tabs opened together don't all load at once: they wait until they're shown. *([#195](https://github.com/driceroland/Search/issues/195), [#196](https://github.com/driceroland/Search/pull/196))*
- [ ] **Links from other apps skip the pins** A link opened from another app never lands among the pins. *([#219](https://github.com/driceroland/Search/issues/219))*
- [ ] **Don't reopen tabs at launch** A switch to start with a fresh window instead of last time's tabs. *(email)*
- [ ] **Pins as a list** Pins as a list, in rows instead of small squares. Also: site icons on pins without them in the tab list (one setting does both today), and Arc-style pinned rows above New Tab. *([#183](https://github.com/driceroland/Search/issues/183), email ×2)*
- [ ] **Pins shared by every space** Pins shared by every space, plus each space's own, as in Arc. *(email)*
- [ ] **Box Tools** Let app.box.com reach its local helper on this Mac, as Chrome does. The person who asked offered to test a build. *(email)*
- [ ] **1Password desktop app, in the FAQ** 1Password with its desktop app. Say in the FAQ that Search is added in 1Password › Settings › Browser › Add Browser.
- [ ] **Intel Macs** One build for both kinds of Mac, only as a change to build.sh, as [#100](https://github.com/driceroland/Search/pull/100) began. *([#46](https://github.com/driceroland/Search/issues/46), X)*

## Later — bigger pieces of work

- [ ] **More extension APIs** More of the extension APIs. The side panel, and invisible offscreen documents ([#192](https://github.com/driceroland/Search/pull/192)). *([#12](https://github.com/driceroland/Search/issues/12), X, [#192](https://github.com/driceroland/Search/pull/192))*
- [ ] **Drive Search from an agent** An MCP server over the bench, for automation and testing. An earlier pull request, [#14](https://github.com/driceroland/Search/pull/14), began one. *(X)*
- [ ] **Web push notifications** As far as WebKit lets an app other than Safari have them. *(X)*
- [ ] **Smoother mouse-wheel scrolling** Smoother scrolling with a mouse wheel. To look into. *(X)*
- [ ] **Split view** Two tabs or more side by side in one window. *([#173](https://github.com/driceroland/Search/issues/173))*
- [ ] **Faster animations** Spaces especially, compared with Zen. *(email)*
- [ ] **Block YouTube's ads** YouTube's ads. They come from youtube.com itself, which the blocker's lists can't tell apart. Whether to go that far is an open question. *([#218](https://github.com/driceroland/Search/issues/218), email)*
- [ ] **Extensions per space** Each space with the extensions it wants, on and off apart from the others. WebKit has one extension controller for the whole app, so this means one per space. Drice's call, 24 Sep: later. *(X)*

## Pull requests to review

- [ ] **Search doesn't come to the front** When another app, like Mail, opens a link in Search, its window stays behind. *([#95](https://github.com/driceroland/Search/issues/95))*

## Drice's call

- [ ] **Double-click for a new tab** A double-click below the tabs opens a new one. *([#162](https://github.com/driceroland/Search/issues/162), [#167](https://github.com/driceroland/Search/pull/167))*
- [ ] **Tab bar in the page's colour** The tab bar or title bar in the page's own colour. *([#158](https://github.com/driceroland/Search/issues/158), [#168](https://github.com/driceroland/Search/pull/168), [#25](https://github.com/driceroland/Search/pull/25))*
- [ ] **Pins go back to their page** A pin goes back to the page it was pinned at when you put it down. *([#141](https://github.com/driceroland/Search/issues/141))*
- [ ] **Dark mode for the Search site** A dark mode for the site's Search page. *([#51](https://github.com/driceroland/Search/issues/51))*
- [ ] **Detach a tab into a window** Detach a tab into its own window. Search has one window, like [#72](https://github.com/driceroland/Search/issues/72). *([#184](https://github.com/driceroland/Search/pull/184), [#72](https://github.com/driceroland/Search/issues/72))*
- [ ] **Home page or home button** A home page or home button. *(email)*
- [ ] **Sidebar on the right** The sidebar on the right. *(email)*
- [ ] **Toolbar buttons on the left** Back, forward and reload on the left with the tabs across the top. *(email)*
- [ ] **Autocomplete in a new tab** What exactly was asked, to find out. *(X)*
- [ ] **Little window for outside links** A little window for links opened from other apps, and a shortcut to open it from anywhere. *(X)*

## Asked to try again on the latest version

- [ ] **Google asks for a reCAPTCHA** Google search asks for a reCAPTCHA. 1.0.2 no longer tells pages it is a separate app and says it is Safari. *([#26](https://github.com/driceroland/Search/issues/26))*
- [ ] **NordPass doesn't work** *([#98](https://github.com/driceroland/Search/issues/98))*
- [ ] **A tab loses track of its site** A tab's site switches, and the tab doesn't follow. Not reproduced. *([#28](https://github.com/driceroland/Search/issues/28))*
- [ ] **Page shortcuts vs Search's** Keep a page's editing shortcuts while Search's own still work. 1.0.2 gives the page the first go at its shortcuts; asked whether it's enough. *([#147](https://github.com/driceroland/Search/issues/147))*

## Not on the list, for now

- **Address bar above the page** The card behind a tab's icon — the site, whether its connection is secure, copy, print, zoom — does that part without a bar. *([#15](https://github.com/driceroland/Search/issues/15), [#56](https://github.com/driceroland/Search/pull/56))*
- **Tab groups and folders** Spaces keep sets of tabs apart, and the column stays quiet. *([#23](https://github.com/driceroland/Search/issues/23), [#68](https://github.com/driceroland/Search/issues/68), [#31](https://github.com/driceroland/Search/pull/31), [#54](https://github.com/driceroland/Search/pull/54), [#76](https://github.com/driceroland/Search/pull/76))*
- **Bookmarks in the column** The bookmarks bar, off unless turned on, and the Bookmarks menu are where they live. *([#58](https://github.com/driceroland/Search/issues/58), [#69](https://github.com/driceroland/Search/pull/69))*
- **Customization page** Settings stays short. *([#101](https://github.com/driceroland/Search/issues/101), [#105](https://github.com/driceroland/Search/pull/105), [#106](https://github.com/driceroland/Search/pull/106), [#107](https://github.com/driceroland/Search/pull/107), [#108](https://github.com/driceroland/Search/pull/108), [#143](https://github.com/driceroland/Search/pull/143))*
- **Hidden sidebar delay setting** The default is what changes instead. *([#118](https://github.com/driceroland/Search/issues/118))*
- **Floating launcher** ⌘S and a folded column already give the page the whole window. *([#18](https://github.com/driceroland/Search/issues/18))*
- **Proxy extensions** WebKit doesn't give it to extensions. *([#12](https://github.com/driceroland/Search/issues/12))*
- **Drag a tab into a new window** Search has one window. *([#72](https://github.com/driceroland/Search/issues/72))*
- **Snoozing tabs** For now. *([#111](https://github.com/driceroland/Search/pull/111))*
- **Vim mode** Vimium works. *([#160](https://github.com/driceroland/Search/pull/160))*
- **Brazilian Portuguese** For now. *([#113](https://github.com/driceroland/Search/pull/113))*
- **Windows and Linux** Search is made of the Mac's own WebKit and AppKit; there is nothing to carry over. *([#62](https://github.com/driceroland/Search/issues/62), [#64](https://github.com/driceroland/Search/issues/64), [#65](https://github.com/driceroland/Search/issues/65), [#197](https://github.com/driceroland/Search/pull/197))*
- **macOS before 14** The app leans on what macOS 14 added to WebKit.
- **Accounts and sync** Bookmarks with Google, tabs across devices. Search has no server and keeps everything on your Mac; importing is the way in. *([#224](https://github.com/driceroland/Search/issues/224))*
