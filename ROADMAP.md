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

## Being built now

- [ ] **Window stutters between screens** Dragging the window from one screen to another stutters. Needs a trace recorded on two screens. *(X)*
- [ ] **Figma and LinkedIn feel slow** Figma blurs for a moment as you zoom in; LinkedIn's feed and profiles scroll with lag. *(email)*
- [ ] **Suggestions in the tab's address field** History suggestions while editing the address inside the tab, as in the ⌘L field. *([#534](https://github.com/driceroland/Search/issues/534))*

## Done, in the next version

- [x] **Passkeys under the sign-in field** Passkeys listed under the sign-in field, as Safari does. About two days of work, and it needs a real passkey test on a signed build. *([#17](https://github.com/driceroland/Search/issues/17), X)*
- [x] **Stuttering pages** Some pages stutter while scrolling: X, Instagram, WhatsApp Web, heavy pages with images and video. 1.0.4 halved what scrolling costs Search; what's left is being traced page by page. *([#211](https://github.com/driceroland/Search/issues/211), [#357](https://github.com/driceroland/Search/issues/357), email ×2)*
- [x] **Floating video on Twitch, Netflix, X** Netflix: the picture now stays inside the floating window and subtitles show ([#190](https://github.com/driceroland/Search/pull/190), on main). Still open: part of the picture on Twitch, sometimes no picture on YouTube, only some of the time on X. *([#123](https://github.com/driceroland/Search/issues/123), email ×2, [#190](https://github.com/driceroland/Search/pull/190))*
- [x] **Chatbot pages struggle or crash** grok.com and other chatbot pages; details asked. *(email)*
- [x] **Extension popups miss messages** An extension's pages never heard what its background sent them, so Bitwarden's passkey window stayed blank and its sync timed out. #383 passes each message on. *([#383](https://github.com/driceroland/Search/pull/383), [#388](https://github.com/driceroland/Search/issues/388))*
- [x] **Dragging a pin redraws the column** Dragging a pin redraws the whole column each frame, as dragging a tab did before 1.0.2.
- [x] **Don't reopen tabs at launch** A switch to start with a fresh window instead of last time's tabs. *(email, [#406](https://github.com/driceroland/Search/issues/406))*
- [x] **Pins as a list** Pins as a list, in rows instead of small squares. Also: site icons on pins without them in the tab list (one setting does both today), and Arc-style pinned rows above New Tab. *([#183](https://github.com/driceroland/Search/issues/183), email ×2, [#426](https://github.com/driceroland/Search/pull/426))*
- [x] **Intel Macs** Search on Intel Macs, tested on a real one. A universal app would double its size (about 12 MB), so the choice is between that and a separate download for Intel. The build itself already works. *([#46](https://github.com/driceroland/Search/issues/46), X)*
- [x] **Notifications from sites** Sites like WhatsApp, Slack or Gmail can show notifications while Search is open, after asking you, site by site. Not when Search is closed: WebKit gives apps other than Safari no web push. *(X, [#328](https://github.com/driceroland/Search/issues/328))*
- [x] **Split view** Two tabs or more side by side in one window. *([#173](https://github.com/driceroland/Search/issues/173), [#277](https://github.com/driceroland/Search/issues/277), [#280](https://github.com/driceroland/Search/pull/280), email, [#381](https://github.com/driceroland/Search/pull/381), [#484](https://github.com/driceroland/Search/issues/484), [#513](https://github.com/driceroland/Search/issues/513))*
- [x] **Turn the floating video off per site** Choose the sites where a video never floats. *([#267](https://github.com/driceroland/Search/issues/267))*
- [x] **Copying images on WhatsApp Web** Copying an image from WhatsApp Web, and its attachment screen, don't work as expected. Copy Image couldn't read pictures a page makes itself (blob: addresses), which WhatsApp's photos are: fixed for the next version. The attachment screen needs checking with an account. *(email)*
- [x] **Bookmark icons inside folders** Site icons disappear for bookmarks inside folders. *(email)*
- [x] **Empty corner in full screen** In full screen, an empty corner shows where the window buttons were. *(email)*
- [x] **Tampermonkey can't install from a link** Its rule that catches .user.js links is one WebKit refuses (a regular expression it doesn't support), so a script has to be pasted into Tampermonkey's editor. *([#289](https://github.com/driceroland/Search/issues/289))*
- [x] **Faster import of huge folders** Big imports run in the background with their progress and a Cancel, so Search keeps answering while 250,000 bookmarks come in. *([#380](https://github.com/driceroland/Search/pull/380))*
- [x] **Find counts its matches** Find on Page shows “3 of 17”, with Match Case and Whole Words, and the current match stands out. *([#377](https://github.com/driceroland/Search/pull/377))*
- [x] **Bitwarden's popup, pop-out and unlock** The popup follows a narrower width its page asks for, windows.update moves and sizes the pop-out, and a PIN typed into an extension's own page is no longer offered as a password. *([#384](https://github.com/driceroland/Search/pull/384), [#385](https://github.com/driceroland/Search/pull/385), [#386](https://github.com/driceroland/Search/pull/386), [#408](https://github.com/driceroland/Search/pull/408))*
- [x] **Update actions in the Search menu** Check for Updates becomes Download, Install or Restart to Update as the update moves along, with its progress shown there. *([#373](https://github.com/driceroland/Search/pull/373))*
- [x] **History keeps similar addresses apart** localhost:3000 and localhost:4000, or /A and /a, no longer overwrite each other in history and suggestions. *([#374](https://github.com/driceroland/Search/pull/374))*
- [x] **A failed extension update keeps the old one** Installing or updating an extension swaps it in whole, so a failure leaves the working version in place. *([#376](https://github.com/driceroland/Search/pull/376))*
- [x] **Pause and resume downloads** Pause, resume and retry a download, and see why one failed, in Downloads. *([#378](https://github.com/driceroland/Search/pull/378))*
- [x] **Sites can ask for your location** A site that asks for your location gets nothing today. It will ask, as in Safari, and you allow it once or always for that site. *([#387](https://github.com/driceroland/Search/issues/387), email)*
- [x] **AI, optional** Off by default: summarize a page or ask about it, with a model you download to run on your Mac, or with your own key. Nothing is sent anywhere unless you choose a provider. *(X, [#397](https://github.com/driceroland/Search/issues/397))*
- [x] **Screen recording from extensions** Loom, Screencastify, Awesome Screenshot, Tella, ScreenPal and Vidyard record your screen or a window from their Chrome extensions: macOS asks what to share each time, and a pill says who is recording, with Stop. Not a single tab, and not the tab's sound: WebKit has neither. *(email)*
- [x] **Esc closes an untouched new tab** Esc on a tab just opened with ⌘T, with nothing typed, closes it and goes back to the tab you were on. *([#389](https://github.com/driceroland/Search/issues/389), [#393](https://github.com/driceroland/Search/pull/393))*
- [x] **A new tab keeps what was typed** Words typed into a new tab's field and not yet sent stay with that tab when you look at another and come back. *([#390](https://github.com/driceroland/Search/issues/390), [#394](https://github.com/driceroland/Search/pull/394))*
- [x] **Bookmarks look broken at some sizes** The bookmarks' look breaks at some window or column sizes; to look at with the screenshots in the report. *([#391](https://github.com/driceroland/Search/issues/391))*
- [x] **Find paints every match** Every match on the page painted, the current one in another colour. *([#409](https://github.com/driceroland/Search/pull/409))*
- [x] **Passkey sign-in on GitHub** Signing in to GitHub with a passkey kept on the Mac fails, where Safari and Chrome succeed. *([#407](https://github.com/driceroland/Search/issues/407))*
- [x] **Keys beep in games** Arrow keys in some web games make the Mac's beep on each press. *([#402](https://github.com/driceroland/Search/issues/402), [#410](https://github.com/driceroland/Search/pull/410))*
- [x] **Extension scripts from inside a page** An extension page shown inside a website can run a function in a tab, as a web clipper does.
- [x] **SingleFile saves pages** SingleFile's worker starts, and the file it makes is saved.
- [x] **Find paints every match** Find on Page paints every match yellow, the current one orange. *([#409](https://github.com/driceroland/Search/pull/409))*
- [x] **Search a site from the address field** Type the start of a site's name, then Tab: what you type next searches that site. Popular sites built in; sites that offer a search join by themselves. *(X)*
- [x] **Test worlds from fresh.sh refuse the bench** fresh.sh launches a world meant to be driven without -g -j, so the no-window guard trips at once. A pull request is coming from the reporter. *([#411](https://github.com/driceroland/Search/issues/411))*
- [x] **Arc pins without icons** Spaces, pins and asleep tabs brought over from Arc wear a letter until each is opened: the import adopts Arc's icons for bookmarks only. *([#416](https://github.com/driceroland/Search/issues/416))*
- [x] **Icons that change after load** An icon a page swaps after loading, like GitHub's with its theme, isn't followed, and a light and a dark icon overwrite each other. *([#423](https://github.com/driceroland/Search/issues/423))*
- [x] **Live video jumps** A live stream on X jumped every few seconds: its player nudges the speed between 1 and 1.04, and each step through exactly 1 made WebKit rebuild the sound and hold the picture. *(message)*
- [x] **Tab address field scrolls with the caret** Editing a tab's address, the field was wider than the row, so the caret and the end of a long address went out of sight. *([#419](https://github.com/driceroland/Search/issues/419), [#517](https://github.com/driceroland/Search/issues/517), [#555](https://github.com/driceroland/Search/pull/555))*
- [x] **Site card never covers the address** Near the bottom of the screen, the site card was pushed up over the address being edited; it opens above it now. *([#418](https://github.com/driceroland/Search/issues/418))*
- [x] **Icons per port** localhost:3000 and localhost:4321 shared one icon; icons are kept by host and port now. *([#413](https://github.com/driceroland/Search/issues/413))*
- [x] **Column gone after a video's full screen** Leaving a YouTube video's full screen with Esc left the tab column hidden until it was switched off and on in the View menu. *(email)*
- [x] **Close a tab group** Close Group in a group's menu closes the group and every tab in it; ⇧⌘T brings them back into it. *(email)*
- [x] **Hidden column's shadow lingers** When the hidden column slides away, its shadow stays a moment after it's gone, then vanishes at once. *([#441](https://github.com/driceroland/Search/issues/441))*
- [x] **⌘W closes the panel in front** With Settings or another panel open, ⌘W closes it (after a peek), in Escape's order, instead of the page behind. *([#452](https://github.com/driceroland/Search/pull/452))*
- [x] **One ⇧⌘T undoes Clear** The tabs one Clear closes come back with a single ⇧⌘T, each in its place. *([#432](https://github.com/driceroland/Search/pull/432))*
- [x] **Switcher previews while Find is open** ⌃Tab skipped the switcher's previews when the find bar was open. *([#553](https://github.com/driceroland/Search/issues/553))*
- [x] **Pages talking to extensions** A site an extension lists in externally_connectable can send it messages (Claude in Chrome sign-in). *([#496](https://github.com/driceroland/Search/issues/496))*
- [x] **New window in full screen** ⌘N in full screen gives the new window a full-screen space of its own. *([#515](https://github.com/driceroland/Search/issues/515), [#531](https://github.com/driceroland/Search/pull/531))*
- [x] **Pinned extensions push the column off the side** *([#535](https://github.com/driceroland/Search/issues/535))*
- [x] **Bookmarks menu empties on a changing title** With a tab whose title keeps changing (a download page showing its speed), the open Bookmarks menu lost its bookmarks. *(email)*
- [x] **Square corners on popovers (macOS 15)** Before macOS 26, the bookmarks and extensions popovers and the site card showed square corners. *(email)*

## Now — fixes for the next update

- [ ] **Spaces sometimes don't switch** *(email)*
- [ ] **Smoother mouse-wheel scrolling** Smoother scrolling with a mouse wheel, as Safari animates each notch. To look into with the scrolling work. *(X)*
- [ ] **Eagle extension doesn't work** The Eagle extension from the Chrome Web Store fails to work in Search. *(email)*
- [ ] **Affinity's Connect reloads the page** The Affinity extension's Connect button, in the popup its puzzle-piece button opens, reloaded the page instead of opening its sign-in. Its sign-in opens with a popup window: 1.0.4 opens it as a window, 1.0.5 as a small window of the sign-in page, and the return to the extension after signing in works. To check with an account on the release candidate. *(email)*
- [ ] **Extension windows as small windows** Both reported as not working on 1.0.3. NordPass: its vault opens with a popup window, which becomes a small window of its page in 1.0.5 (on main; to check on the release candidate). Loom: screen recording needs Chrome's desktopCapture and tabCapture, which WebKit doesn't have; only a bridge through WebKit's own screen sharing could get there. *(email)*
- [ ] **Icons per port** Icons are kept per host, so every port of localhost shares the first one seen. *([#413](https://github.com/driceroland/Search/issues/413))*
- [ ] **Bookmarks dropdown cut short** In the list under the bookmark button, an open folder shows a row and a half and can't be seen whole: the list doesn't grow when a folder opens. *(email)*
- [ ] **Apple Passwords under the sign-in field** Passwords saved in the Mac's Passwords app listed under the sign-in field, as in Safari, without the iCloud Passwords extension. It goes through Apple's own helper, which only a Developer ID build may launch. Off unless turned on. *([#425](https://github.com/driceroland/Search/issues/425), email ×3)*
- [ ] **Side panel** A panel beside the page for extensions that open in Chrome's side panel (ChatGPT, Claude, Sider, Merlin), and for Search's AI. *(email)*
- [ ] **The page as a card, with a bar above it** A bar above the page with back, forward, reload, the page's title and its address; the page drawn as a card with a small gap around it and rounded corners; Settings opened as a tab. *(message)*
- [ ] **Tabs across the top after an import** Across the top, pins and tabs read as one row of marks: a line between them, and a ground behind a tab shrunk to its mark, go into the new layout's strip. After an import, a pill to turn the bookmarks bar on. *([#449](https://github.com/driceroland/Search/issues/449))*
- [ ] **Loading shown with the column hidden** With the column hidden nothing says a page is loading; the new layout's bar above the page will show it. *([#443](https://github.com/driceroland/Search/issues/443))*
- [ ] **Arc import twice: a second pin** Bringing Arc over again adds a second pin for a site whose pin has moved address (Gmail): the guard compares the pin's current address. *([#482](https://github.com/driceroland/Search/issues/482))*
- [ ] **Remove all saved passwords** A Remove All… in the passwords panel, for someone moving to a password manager. *([#469](https://github.com/driceroland/Search/issues/469))*
- [ ] **Swipe between pages as the Mac says** A sideways scroll goes back or forward only when the Mac's own Swipe between pages setting allows it. *([#464](https://github.com/driceroland/Search/issues/464), [#467](https://github.com/driceroland/Search/pull/467))*
- [ ] **Proxy for the whole browser** HTTP and SOCKS5 proxy in Settings, off by default, everything through it. *([#510](https://github.com/driceroland/Search/pull/510))*

## Next — small additions people asked for

- [ ] **Pins shared by every space** Pins shared by every space, plus each space's own, as in Arc. *(email, [#463](https://github.com/driceroland/Search/pull/463))*
- [ ] **Box Tools** Let app.box.com reach its local helper on this Mac, as Chrome does. The person who asked offered to test a build. *(email)*
- [ ] **1Password desktop app, in the FAQ** 1Password with its desktop app. Say in the FAQ that Search is added in 1Password › Settings › Browser › Add Browser.
- [ ] **Import: extension-only profiles, ego lite, a protected folder** Find browser profiles that only hold extensions, add ego lite as a source (no passwords), and let you choose a browser's data folder when macOS refuses Search access to it. *([#415](https://github.com/driceroland/Search/pull/415) ×2, [#507](https://github.com/driceroland/Search/pull/507))*
- [ ] **Export as PDF** File › Export as PDF…: the whole page as one long PDF, as Safari does, through WebKit's createPDF. *([#446](https://github.com/driceroland/Search/issues/446), [#461](https://github.com/driceroland/Search/pull/461))*
- [ ] **Arc import keeps its shape** Arc's folders are dropped when tab groups are off; its pinned pages come as ordinary tabs rather than pinned rows. *([#478](https://github.com/driceroland/Search/issues/478), [#582](https://github.com/driceroland/Search/pull/582))*
- [ ] **A user agent per tab** Presets and a string of your own, per tab, as in Safari's Develop menu; shares its plumbing with Responsive Design Mode. *([#460](https://github.com/driceroland/Search/issues/460))*
- [ ] **Import says when macOS refuses a browser's folder** When macOS won't let Search read another browser's folder, the import sheet says so and points to choosing the folder, instead of reporting that nothing was found. *([#583](https://github.com/driceroland/Search/issues/583))*
- [ ] **The folded column comes out faster** The folded column and tab bar slide out as quickly as Arc's and Dia's, and are kept ready instead of being built again on every peek. *([#585](https://github.com/driceroland/Search/pull/585), [#586](https://github.com/driceroland/Search/pull/586))*
- [ ] **Site card corners on macOS 26** The site card keeps its rounded corners on macOS 26 too. *([#576](https://github.com/driceroland/Search/pull/576))*

## Later — bigger pieces of work

- [ ] **Vimium C's keys do nothing** Its background starts from 1.0.4, where WebKit failed to load it; its keys don't answer yet. The original Vimium works meanwhile. *(X, email, [#170](https://github.com/driceroland/Search/pull/170))*
- [ ] **More extension APIs** More of the extension APIs. The side panel, and invisible offscreen documents ([#192](https://github.com/driceroland/Search/pull/192)). *([#12](https://github.com/driceroland/Search/issues/12), X, [#192](https://github.com/driceroland/Search/pull/192) ×2, [#273](https://github.com/driceroland/Search/issues/273), [#351](https://github.com/driceroland/Search/issues/351), [#352](https://github.com/driceroland/Search/pull/352), [#484](https://github.com/driceroland/Search/issues/484))*
- [ ] **Drive Search from an agent** An MCP server over the bench, for automation and testing. An earlier pull request, [#14](https://github.com/driceroland/Search/pull/14), began one. *(X)*
- [ ] **Faster animations** Spaces especially, compared with Zen. *(email)*
- [ ] **Extensions per space** Each space with the extensions it wants, on and off apart from the others. WebKit has one extension controller for the whole app, so this means one per space. Drice's call, 24 Sep: later. *(X)*
- [ ] **User scripts fail on GitHub** Tampermonkey runs each script through an inline script, and WebKit holds it to the page's content security policy, where Chrome exempts it; GitHub's policy blocks it. No safe narrow fix yet. *([#289](https://github.com/driceroland/Search/issues/289), [#319](https://github.com/driceroland/Search/issues/319))*
- [ ] **Select several tabs** Select tabs with ⌘-click and ⇧-click, then copy all their addresses at once. *([#309](https://github.com/driceroland/Search/issues/309), email, [#454](https://github.com/driceroland/Search/pull/454))*
- [ ] **Optional ad-blocking add-on** A stronger blocker as an optional add-on in Settings, downloaded on demand so it only takes space for those who want it. Search's built-in blocker stays as it is meanwhile. *(message)*
- [ ] **Tabs that close themselves** Close tabs left untouched for a long time, as Arc does. *(email, [#445](https://github.com/driceroland/Search/issues/445), [#429](https://github.com/driceroland/Search/pull/429))*
- [ ] **Unsaved text on move to window** A tab moved into a window that shows another space signs in with that space, as Move to Space does; unlike Move to Space, it doesn't first ask about text typed and not sent.
- [ ] **Little window: blocker and passwords** A page in the small window for outside links doesn't get the ad blocker's per-site settings or the accounts list under a sign-in box until it is moved into your tabs.
- [ ] **Pin a tab group** A whole tab group kept like a pin: several Slacks, each with its client's sites, told apart and kept. *([#392](https://github.com/driceroland/Search/issues/392))*
- [ ] **Tabs shared across windows** A space's tabs belong to the space, and any window can show them, with a stand-in where a tab is open in another window, as in Arc. Pins already are the same in every window. *([#417](https://github.com/driceroland/Search/issues/417))*
- [ ] **A picture behind the new tab** An image behind the new tab page, perhaps from Unsplash. Off unless turned on, if it ever comes. *([#447](https://github.com/driceroland/Search/issues/447))*
- [ ] **The page behind a new tab** The page you came from stays visible behind the new tab, as in Arc. *([#465](https://github.com/driceroland/Search/issues/465))*
- [ ] **Main process grows over days** The app's own process grew to several times its fresh size over a week of use; find what accumulates (closed windows, caches).
- [ ] **How soon tabs sleep** A choice for how long a tab waits before it sleeps, off unless changed. *([#448](https://github.com/driceroland/Search/pull/448))*
- [ ] **Light pages darkened** Light pages shown in their own colours, darkened, while Search is dark. Off by default. *([#450](https://github.com/driceroland/Search/pull/450))*
- [ ] **Ports after a worker restart** Extension ports are told when their worker restarted, so they reconnect. *([#453](https://github.com/driceroland/Search/pull/453), [#514](https://github.com/driceroland/Search/pull/514))*
- [ ] **Small windows: alone and keyed** A link small window opens alone, takes its keys, closes with a swipe back, cascades, and shows in the switcher. *([#431](https://github.com/driceroland/Search/pull/431), [#519](https://github.com/driceroland/Search/pull/519), [#474](https://github.com/driceroland/Search/pull/474), [#493](https://github.com/driceroland/Search/pull/493), [#480](https://github.com/driceroland/Search/pull/480))*
- [ ] **Keys in the tab switcher** Arrow keys and more in the ⌃Tab switcher, off unless turned on. *([#495](https://github.com/driceroland/Search/pull/495))*
- [ ] **Home page from an extension** Settings › General › Home page, while an extension offers a page for new tabs. *([#472](https://github.com/driceroland/Search/pull/472))*
- [ ] **Native hosts end on EOF** A native messaging host's connection ends when its output closes. *([#483](https://github.com/driceroland/Search/pull/483))*
- [ ] **UTF-8 in extension scripts** Non-ASCII text in injected extension scripts stays intact. *([#521](https://github.com/driceroland/Search/pull/521))*
- [ ] **Closed windows freed** A window closed while others stay open gives its memory back, and one put away in the Dock can be found. *([#549](https://github.com/driceroland/Search/pull/549), [#554](https://github.com/driceroland/Search/pull/554))*
- [ ] **Framed sites keep cookies** With Prevent cross-site tracking off, a framed site keeps its cookies, as in Chrome. *([#550](https://github.com/driceroland/Search/pull/550))*
- [ ] **Back and Forward lists** Hold or right-click Back and Forward to pick a page from that way. *([#567](https://github.com/driceroland/Search/pull/567))*
- [ ] **Shortcuts on any keyboard layout** Shortcuts work on Cyrillic and other non-Latin layouts. *([#568](https://github.com/driceroland/Search/pull/568))*
- [ ] **Reload from origin by right-click** Right-click Reload for Reload from Origin. *([#571](https://github.com/driceroland/Search/pull/571))*
- [ ] **Pages at 120 Hz: never, on power, always** The 120 Hz switch becomes three choices. *([#572](https://github.com/driceroland/Search/pull/572))*
- [ ] **Pages sized inside the window** A page's ideal size is kept inside the window without moving its safe areas. *([#468](https://github.com/driceroland/Search/pull/468))*
- [ ] **Remove all passwords** Remove All… in the passwords panel, behind Touch ID. *([#469](https://github.com/driceroland/Search/issues/469), [#471](https://github.com/driceroland/Search/pull/471))*
- [ ] **Side panel and private tabs** A window-wide extension panel stays up while a private tab is in front; hide it then unless that extension may run in private tabs (after #536).
- [ ] **Float a whole page** Any page, not only a video, in the floating window, and meetings that float when you switch away. Off unless turned on. *([#584](https://github.com/driceroland/Search/pull/584))*

## Drice's call

- [ ] **Pressing a pin's number again** ⌘1–⌘9 pressed again on the pin you are on takes it back to the page it was pinned at, as a double-click on it does. *(email)*
- [ ] **Pin letters of your own** A pin without an icon wears a capital letter; choose a lowercase one, two letters, or a symbol instead. *(email)*
- [ ] **Responsive Design Mode** Look at a page as an iPhone, a Pixel or an iPad would, from the View menu, as in Safari's Develop menu. *([#412](https://github.com/driceroland/Search/pull/412))*
- [ ] **Links from a pin open in a peek** As in Arc: a link from a pinned tab to another site opens in a peek, so the pin stays on its site. Off unless turned on. *([#577](https://github.com/driceroland/Search/issues/577), [#581](https://github.com/driceroland/Search/pull/581))*

## Asked to try again on the latest version

- [ ] **Google sign-in flashes with Proton Pass** With Proton Pass signed in, Google's sign-in page reloads every half second. Presumed fixed in 1.0.2 by [#126](https://github.com/driceroland/Search/pull/126) and the passkey changes; to confirm with the person who saw it. *(X)*
- [ ] **Hidden sidebar closes too soon** It closes while the pointer is over the extension buttons at its foot. Maybe fixed by [#115](https://github.com/driceroland/Search/pull/115) in 1.0.2; unconfirmed. *(email)*
- [ ] **macOS text replacements in pages** The Mac's own text replacements don't work in text boxes on web pages. Tried on 1.0.3 and on the next version: a replacement typed then followed by a space is replaced in a text field, a text area and an editable page area. To ask: on which site, with which replacement, and does it work in Safari there? *(email)*
- [ ] **The column seems to refresh** Reported as a sidebar refresh issue. Asked whether the column itself redraws or the page reloads as it comes out. *(email)*
- [ ] **Black screen after full screen** In full screen, opening another window leaves the screen black. Asked which window: another app's, or one a page opens. *(email)*
- [ ] **Cesturify's sessions command** An extension command that uses the sessions permission does nothing. Asked which command. *(email)*
- [ ] **Reading Mode keeps the cookie notice** On some sites Reading Mode keeps the privacy or cookie notice instead of the article. Asked which site. *(email)*
- [ ] **Part of LinkedIn won't expand** Something on LinkedIn doesn't open when clicked. Asked which part: a post, its comments, or something else. *(email)*
- [ ] **GitHub's Files page slow to paint** A GitHub pull request's Files page can stay blank for tens of seconds while its CSS comes in; a bare WKWebView is about as slow. Waiting on a comparison with Safari. *([#458](https://github.com/driceroland/Search/issues/458))*
- [ ] **Profiles shared by several spaces** A space can already keep its own sign-ins. Asked: a profile several spaces share, with its own history and bookmarks too. *([#459](https://github.com/driceroland/Search/issues/459))*

## Just in, not sorted yet

- [ ] **Bookmarks bar: move and new folder** Rearrange bookmarks on the bar itself (the bar now moves the window, so perhaps with a key held) and make a folder from the bar. *(email)*
- [ ] **A site's permissions in its card** The site card lists what the site may use (camera, microphone, location, notifications, sound) and lets each be changed or forgotten there. *(email)*
- [ ] **Links from a pin open a new tab** A link followed from a pinned tab opens beside it, so the pin stays on its page. *(email)*
- [ ] **Quicker tab highlight** The highlight that slides to the tab you pick feels slow; make it quicker or instant. *(email, [#466](https://github.com/driceroland/Search/issues/466))*
- [ ] **Bookmarks per space** Each space keeps bookmarks of its own. *(email)*
- [ ] **Window colours** A colour for the window, or for each space, with a light and a dark version, as in Helium and Arc. *(email ×2)*
- [ ] **Extension side panels** Extensions that open in Chrome's side panel, like ChatGPT's and Claude's, have nowhere to open: WebKit has no side panel. *(email)*
- [ ] **Group tabs by dropping one on another** Drop a tab onto another in the column and the two become a group. *(email)*
- [ ] **Send links to a space** Links from chosen sites open in a given space, with its sign-ins, as Arc's Air Traffic Control does. *(email)*
- [ ] **One place for ⌘T, ⌘K and ⌘Y** New tab, the open tabs and history reached from a single field. *(email)*
- [ ] **Open tabs from Helium** Bringing things over from Helium takes its bookmarks, history, passwords and extensions, but not the tabs it has open. *(email)*
- [ ] **⌘L again closes the address** A second ⌘L puts away the address field it opened, as Esc does. *(email)*
- [ ] **A right-click menu on the bookmarks bar** *([#438](https://github.com/driceroland/Search/issues/438), [#439](https://github.com/driceroland/Search/pull/439))*
- [ ] **Change the keys for spaces and the peek click** *([#498](https://github.com/driceroland/Search/issues/498))*
- [ ] **Extensions on private tabs when allowed** *([#508](https://github.com/driceroland/Search/issues/508), [#536](https://github.com/driceroland/Search/pull/536))*
- [ ] **Pop-ups after a click and a request** A window a page opens a few seconds after your click, once its server answers, is let through. *([#511](https://github.com/driceroland/Search/issues/511), [#503](https://github.com/driceroland/Search/pull/503), [#509](https://github.com/driceroland/Search/pull/509))*
- [ ] **Media keys back to the music app** Once a video is paused, the media keys go back to Spotify or Music. *([#512](https://github.com/driceroland/Search/issues/512))*
- [ ] **Tabs that pause, not reload** An option to keep a resting tab's page and let WebKit suspend it, off by default. *([#520](https://github.com/driceroland/Search/issues/520))*
- [ ] **Open a typed file path** A full or ~/ path that names a file opens it instead of searching. *([#523](https://github.com/driceroland/Search/issues/523), [#557](https://github.com/driceroland/Search/pull/557))*
- [ ] **Search under Open With** Listed as an alternate app for PDFs, pictures and text files. *([#524](https://github.com/driceroland/Search/issues/524))*
- [ ] **A local text file opens as text** *([#525](https://github.com/driceroland/Search/issues/525))*
- [ ] **Ask before a website shares the screen** *([#528](https://github.com/driceroland/Search/issues/528), [#530](https://github.com/driceroland/Search/pull/530))*
- [ ] **Option-Command arrows to move between tabs** *([#532](https://github.com/driceroland/Search/issues/532))*
- [ ] **A new tab when the last tab closes** Closing the last tab beside the pins leaves a new tab instead of waking a pin (switch, off). *([#537](https://github.com/driceroland/Search/issues/537), [#538](https://github.com/driceroland/Search/pull/538))*
- [ ] **Extension updates while Search stays open** *([#539](https://github.com/driceroland/Search/issues/539))*
- [ ] **Share the screen with its sound** *([#540](https://github.com/driceroland/Search/issues/540))*
- [ ] **Bitwarden popup spins** Its background never answers the popup (no runtime.onConnect listener). *([#541](https://github.com/driceroland/Search/issues/541))*
- [ ] **Floating video flickers popping out** The video shifts and flickers as it pops out of the page. *([#543](https://github.com/driceroland/Search/issues/543), [#547](https://github.com/driceroland/Search/pull/547), [#562](https://github.com/driceroland/Search/pull/562))*
- [ ] **Float a meeting page when you switch away** *([#544](https://github.com/driceroland/Search/issues/544), [#547](https://github.com/driceroland/Search/pull/547))*
- [ ] **Crash on a two-step sign-in page** *([#548](https://github.com/driceroland/Search/issues/548))*
- [ ] **Sized pop-ups as small windows** A pop-up a page asks for at its own size opens as a small window, off by default. *([#552](https://github.com/driceroland/Search/issues/552))*
- [ ] **CleanMyMac flags Search as unwanted** *([#556](https://github.com/driceroland/Search/issues/556))*
- [ ] **Reading mode follows dark mode** *([#563](https://github.com/driceroland/Search/issues/563), [#564](https://github.com/driceroland/Search/pull/564), [#565](https://github.com/driceroland/Search/pull/565), [#566](https://github.com/driceroland/Search/pull/566))*
- [ ] **Pages use more memory than in Chrome** *([#569](https://github.com/driceroland/Search/issues/569))*
- [ ] **Roomier tab rows in the column** *([#570](https://github.com/driceroland/Search/issues/570))*

## Not on the list, for now

- **Web processes start before the window** The web process pool is made before the first window; check whether 1.0.2's launch order already covers it. Measured at about 1.5 ms on macOS 26 (8–9 ms on macOS 27): not worth the change it needs. *([#157](https://github.com/driceroland/Search/issues/157))*
- **Block YouTube's ads** YouTube's ads. They come from youtube.com itself, which the blocker's lists can't tell apart. Whether to go that far is an open question. Search's built-in blocker stays as it is; blocking YouTube's ads is not planned. An optional ad-blocking add-on, downloaded only by those who want it, may come later. *([#218](https://github.com/driceroland/Search/issues/218), email ×4)*
- **Tab bar in the page's colour** The tab bar or title bar in the page's own colour. Not planned: Search stays minimal. *([#158](https://github.com/driceroland/Search/issues/158), [#168](https://github.com/driceroland/Search/pull/168), [#25](https://github.com/driceroland/Search/pull/25))*
- **Dark mode for the Search site** A dark mode for the site's Search page. The Search page keeps the one look it has. *([#51](https://github.com/driceroland/Search/issues/51))*
- **Home page or home button** A home page or home button. Not planned: Search stays minimal. *(email, [#299](https://github.com/driceroland/Search/pull/299))*
- **Autocomplete in a new tab** What exactly was asked, to find out. The address field already completes from your history, bookmarks and open tabs; nothing more specific was asked. *(X)*
- **A tab loses track of its site** A tab's site switches, and the tab doesn't follow. Not reproduced; closed, to reopen with steps. *([#28](https://github.com/driceroland/Search/issues/28))*
- **Address bar above the page** The card behind a tab's icon — the site, whether its connection is secure, copy, print, zoom — does that part without a bar. *([#15](https://github.com/driceroland/Search/issues/15), [#56](https://github.com/driceroland/Search/pull/56), email)*
- **Bookmarks in the column** The bookmarks bar, off unless turned on, and the Bookmarks menu are where they live. *([#58](https://github.com/driceroland/Search/issues/58), [#69](https://github.com/driceroland/Search/pull/69), email)*
- **Customization page** Settings stays short. *([#101](https://github.com/driceroland/Search/issues/101), [#105](https://github.com/driceroland/Search/pull/105), [#106](https://github.com/driceroland/Search/pull/106), [#107](https://github.com/driceroland/Search/pull/107), [#108](https://github.com/driceroland/Search/pull/108), [#143](https://github.com/driceroland/Search/pull/143), [#231](https://github.com/driceroland/Search/pull/231), [#262](https://github.com/driceroland/Search/pull/262), [#263](https://github.com/driceroland/Search/issues/263), [#321](https://github.com/driceroland/Search/issues/321), [#322](https://github.com/driceroland/Search/issues/322), [#288](https://github.com/driceroland/Search/issues/288), [#350](https://github.com/driceroland/Search/pull/350))*
- **Hidden sidebar delay setting** The default is what changes instead. *([#118](https://github.com/driceroland/Search/issues/118))*
- **Floating launcher** ⌘S and a folded column already give the page the whole window. *([#18](https://github.com/driceroland/Search/issues/18))*
- **Proxy extensions** WebKit doesn't give it to extensions. *([#12](https://github.com/driceroland/Search/issues/12), [#533](https://github.com/driceroland/Search/issues/533))*
- **Snoozing tabs** For now. *([#111](https://github.com/driceroland/Search/pull/111))*
- **Vim mode** Vimium works. *([#160](https://github.com/driceroland/Search/pull/160))*
- **Brazilian Portuguese** For now. *([#113](https://github.com/driceroland/Search/pull/113))*
- **Windows and Linux** Search is made of the Mac's own WebKit and AppKit; there is nothing to carry over. *([#62](https://github.com/driceroland/Search/issues/62), [#64](https://github.com/driceroland/Search/issues/64), [#65](https://github.com/driceroland/Search/issues/65), [#197](https://github.com/driceroland/Search/pull/197))*
- **macOS before 14** The app leans on what macOS 14 added to WebKit.
- **Accounts and sync** Bookmarks with Google, tabs across devices. Search has no server and keeps everything on your Mac; importing is the way in. *([#224](https://github.com/driceroland/Search/issues/224), email, [#488](https://github.com/driceroland/Search/issues/488))*
- **Page slides with the sidebar** The page moves with the sidebar as it opens instead of redrawing in steps, with no gap at the edge; the PR also adds a speed setting. Since 0469c15 the page already slides with the column and is resized once; no speed setting, Settings stays short. *([#252](https://github.com/driceroland/Search/pull/252))*
- **Translate pages on the Mac** Translate a page, or the text in a picture, on the Mac itself; nothing is sent anywhere. Off until turned on. Not for now: Search stays small. *([#265](https://github.com/driceroland/Search/pull/265))*
- **Touch Bar controls** Back, forward, reload, the tabs and a new tab button on the Touch Bar, stepping aside when a field or video needs it. Not planned: Search stays minimal. *([#274](https://github.com/driceroland/Search/issues/274), [#275](https://github.com/driceroland/Search/pull/275))*
- **A name that's easier to find** “Search” is hard to find when searching for a browser; a more distinctive name is suggested. The name stays Search. Where it has to be found, it's Search Browser, or Search by Office Commun. *([#276](https://github.com/driceroland/Search/issues/276))*
- **A new look for the back swipe** The swipe back and forward draws a shape pulled out of the edge that follows the fingers, instead of arrows sliding the other way. Not planned: Search stays minimal. *([#281](https://github.com/driceroland/Search/issues/281), [#282](https://github.com/driceroland/Search/pull/282))*
- **Back closes a link's own tab** Back from the first page of a tab a link opened closes that tab and returns to the page it came from. Not planned: Search stays minimal. *([#283](https://github.com/driceroland/Search/pull/283))*
- **Sites as their own apps** Make a small app of its own for a site kept open all day, from the Tabs menu. Not planned: sites stay in Search's tabs and spaces. *([#292](https://github.com/driceroland/Search/pull/292))*
- **Interface in other languages** Search's own interface follows the Mac's language, starting with Simplified Chinese or Japanese. No translations for now. *([#304](https://github.com/driceroland/Search/issues/304), [#317](https://github.com/driceroland/Search/pull/317), [#334](https://github.com/driceroland/Search/issues/334))*
- **Screenshot one element** Pick an element on the page and save or copy a picture cropped to it. The Web Inspector already captures a single element: right-click it in the Elements tab, Capture Screenshot. *([#308](https://github.com/driceroland/Search/issues/308))*
- **Blurry text in Jupyter** Text in a Jupyter notebook on localhost looks slightly blurry, unlike in Chrome. The reporter couldn't make it happen again after reinstalling, and closed the report; reopen if it comes back. *([#329](https://github.com/driceroland/Search/issues/329))*
- **Hide page clutter with a model** A small on-device model decides which parts of a page to hide. The built-in blocker stays as it is, without a model deciding what to hide. An optional ad-blocking add-on may come later. *([#339](https://github.com/driceroland/Search/issues/339))*
- **Two sidebars** Bookmarks in a sidebar on one side and tabs on the other, both at once. The column stays as quiet as possible: tabs only. Bookmarks live in the bookmarks bar (optional) and the Bookmarks menu. *([#359](https://github.com/driceroland/Search/issues/359))*
- **New tabs at the top of the column** An option to open new tabs at the top of the column instead of after the current tab. Search keeps new tabs where every browser puts them. *(email)*
- **An icon-only column** A narrow column that shows only the tabs' icons. Folding the column away (⌘S) and the tabs across the top already give the page the room; a third layout would be one more to keep working. *(email)*
- **Safari's own extensions** Load extensions installed for Safari, such as wBlock, besides the Chrome Web Store's. Safari's extensions live inside their apps and talk to them through Safari alone, and content blockers hand their rules to Safari only. Their Chrome Web Store versions work in Search. *(email ×2)*
- **Dragging a tab moves the window again** In 1.0.4 a tab grabbed by its upper half can move the window instead of the tab; a contribution also reworks how a carried tab is drawn and dragged out. It made the window immovable again, undoing #286; a smaller pull request is welcome. *([#395](https://github.com/driceroland/Search/pull/395))*
- **A colour of your own for the chrome** Pick a colour for the tab bar and the panels. Settings stays short: the chrome follows the Mac's light or dark look. *([#396](https://github.com/driceroland/Search/issues/396))*
- **Group tabs automatically** Tabs put into groups for you, on request or as they open. Search stays minimal: tab groups are made by hand, on purpose. *([#398](https://github.com/driceroland/Search/issues/398))*
- **A load line across the page** A thin line along the top of a loading page. The tab's own ring already shows a page loading. *([#401](https://github.com/driceroland/Search/pull/401), [#400](https://github.com/driceroland/Search/pull/400))*
- **Icons follow the page** A site that changes its icon after load (GitHub with its theme) shows the new one; light and dark icons are kept apart. Duplicate of 239 *([#423](https://github.com/driceroland/Search/issues/423))*
- **Move the window by the top of a page** As in Arc and Dia: dragging an empty part of a site's top bar, or of a page's top edge, moves the window. Off unless turned on. In 1.0.5 the page gets a bar of its own above it, which moves the window like a title bar; no need to take presses from the page itself. *([#427](https://github.com/driceroland/Search/pull/427))*
