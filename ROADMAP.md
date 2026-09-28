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

- [ ] **Stuttering pages** Some pages stutter while scrolling: X, Instagram, WhatsApp Web, heavy pages with images and video. 1.0.4 halved what scrolling costs Search; what's left is being traced page by page. *([#211](https://github.com/driceroland/Search/issues/211), [#357](https://github.com/driceroland/Search/issues/357), email ×2)*
- [ ] **Figma and LinkedIn feel slow** Figma blurs for a moment as you zoom in; LinkedIn's feed and profiles scroll with lag. *(email)*
- [ ] **Intel Macs** Search on Intel Macs, tested on a real one. A universal app would double its size (about 12 MB), so the choice is between that and a separate download for Intel. The build itself already works. *([#46](https://github.com/driceroland/Search/issues/46), X)*

## Done, in the next version

- [x] **Passkeys under the sign-in field** Passkeys listed under the sign-in field, as Safari does. About two days of work, and it needs a real passkey test on a signed build. *([#17](https://github.com/driceroland/Search/issues/17), X)*
- [x] **Chatbot pages struggle or crash** grok.com and other chatbot pages; details asked. *(email)*
- [x] **Extension popups miss messages** An extension's pages never heard what its background sent them, so Bitwarden's passkey window stayed blank and its sync timed out. #383 passes each message on. *([#383](https://github.com/driceroland/Search/pull/383), [#388](https://github.com/driceroland/Search/issues/388))*
- [x] **Dragging a pin redraws the column** Dragging a pin redraws the whole column each frame, as dragging a tab did before 1.0.2.
- [x] **Split view** Two tabs or more side by side in one window. *([#173](https://github.com/driceroland/Search/issues/173), [#277](https://github.com/driceroland/Search/issues/277), [#280](https://github.com/driceroland/Search/pull/280), email, [#381](https://github.com/driceroland/Search/pull/381))*
- [x] **Copying images on WhatsApp Web** Copying an image from WhatsApp Web, and its attachment screen, don't work as expected. Copy Image couldn't read pictures a page makes itself (blob: addresses), which WhatsApp's photos are: fixed for the next version. The attachment screen needs checking with an account. *(email)*
- [x] **Bookmark icons inside folders** Site icons disappear for bookmarks inside folders. *(email)*
- [x] **Empty corner in full screen** In full screen, an empty corner shows where the window buttons were. *(email)*
- [x] **Find counts its matches** Find on Page shows “3 of 17”, with Match Case and Whole Words, and the current match stands out. *([#377](https://github.com/driceroland/Search/pull/377))*
- [x] **Bitwarden's popup, pop-out and unlock** The popup follows a narrower width its page asks for, windows.update moves and sizes the pop-out, and a PIN typed into an extension's own page is no longer offered as a password. *([#384](https://github.com/driceroland/Search/pull/384), [#385](https://github.com/driceroland/Search/pull/385), [#386](https://github.com/driceroland/Search/pull/386))*
- [x] **Update actions in the Search menu** Check for Updates becomes Download, Install or Restart to Update as the update moves along, with its progress shown there. *([#373](https://github.com/driceroland/Search/pull/373))*
- [x] **History keeps similar addresses apart** localhost:3000 and localhost:4000, or /A and /a, no longer overwrite each other in history and suggestions. *([#374](https://github.com/driceroland/Search/pull/374))*
- [x] **A failed extension update keeps the old one** Installing or updating an extension swaps it in whole, so a failure leaves the working version in place. *([#376](https://github.com/driceroland/Search/pull/376))*
- [x] **Pause and resume downloads** Pause, resume and retry a download, and see why one failed, in Downloads. *([#378](https://github.com/driceroland/Search/pull/378))*
- [x] **Sites can ask for your location** A site that asks for your location gets nothing today. It will ask, as in Safari, and you allow it once or always for that site. *([#387](https://github.com/driceroland/Search/issues/387))*

## Now — fixes for the next update

- [ ] **Window stutters between screens** Dragging the window from one screen to another stutters. Needs a trace recorded on two screens. *(X)*
- [ ] **Floating video on Twitch, Netflix, X** Netflix: the picture now stays inside the floating window and subtitles show ([#190](https://github.com/driceroland/Search/pull/190), on main). Still open: part of the picture on Twitch, sometimes no picture on YouTube, only some of the time on X. *([#123](https://github.com/driceroland/Search/issues/123), email ×2, [#190](https://github.com/driceroland/Search/pull/190))*
- [ ] **Spaces sometimes don't switch** *(email)*
- [ ] **Smoother mouse-wheel scrolling** Smoother scrolling with a mouse wheel, as Safari animates each notch. To look into with the scrolling work. *(X)*
- [ ] **Eagle extension doesn't work** The Eagle extension from the Chrome Web Store fails to work in Search. *(email)*
- [ ] **Affinity's Connect reloads the page** The Affinity extension's Connect button, in the popup its puzzle-piece button opens, reloaded the page instead of opening its sign-in. Its sign-in opens with a popup window: 1.0.4 opens it as a window, 1.0.5 as a small window of the sign-in page, and the return to the extension after signing in works. To check with an account on the release candidate. *(email)*
- [ ] **Extension windows as small windows** Both reported as not working on 1.0.3. NordPass: its vault opens with a popup window, which becomes a small window of its page in 1.0.5 (on main; to check on the release candidate). Loom: screen recording needs Chrome's desktopCapture and tabCapture, which WebKit doesn't have; only a bridge through WebKit's own screen sharing could get there. *(email)*
- [ ] **AI, optional** Off by default: summarize a page or ask about it, with a model you download to run on your Mac, or with your own key. Nothing is sent anywhere unless you choose a provider. *(X, [#397](https://github.com/driceroland/Search/issues/397))*

## Next — small additions people asked for

- [ ] **Don't reopen tabs at launch** A switch to start with a fresh window instead of last time's tabs. *(email)*
- [ ] **Pins as a list** Pins as a list, in rows instead of small squares. Also: site icons on pins without them in the tab list (one setting does both today), and Arc-style pinned rows above New Tab. *([#183](https://github.com/driceroland/Search/issues/183), email ×2)*
- [ ] **Pins shared by every space** Pins shared by every space, plus each space's own, as in Arc. *(email)*
- [ ] **Box Tools** Let app.box.com reach its local helper on this Mac, as Chrome does. The person who asked offered to test a build. *(email)*
- [ ] **1Password desktop app, in the FAQ** 1Password with its desktop app. Say in the FAQ that Search is added in 1Password › Settings › Browser › Add Browser.
- [ ] **Tampermonkey can't install from a link** Its rule that catches .user.js links is one WebKit refuses (a regular expression it doesn't support), so a script has to be pasted into Tampermonkey's editor. *([#289](https://github.com/driceroland/Search/issues/289))*

## Later — bigger pieces of work

- [ ] **Vimium C's keys do nothing** Its background starts from 1.0.4, where WebKit failed to load it; its keys don't answer yet. The original Vimium works meanwhile. *(X, email, [#170](https://github.com/driceroland/Search/pull/170))*
- [ ] **More extension APIs** More of the extension APIs. The side panel, and invisible offscreen documents ([#192](https://github.com/driceroland/Search/pull/192)). *([#12](https://github.com/driceroland/Search/issues/12), X, [#192](https://github.com/driceroland/Search/pull/192), [#273](https://github.com/driceroland/Search/issues/273), [#351](https://github.com/driceroland/Search/issues/351), [#352](https://github.com/driceroland/Search/pull/352))*
- [ ] **Drive Search from an agent** An MCP server over the bench, for automation and testing. An earlier pull request, [#14](https://github.com/driceroland/Search/pull/14), began one. *(X)*
- [ ] **Faster animations** Spaces especially, compared with Zen. *(email)*
- [ ] **Extensions per space** Each space with the extensions it wants, on and off apart from the others. WebKit has one extension controller for the whole app, so this means one per space. Drice's call, 24 Sep: later. *(X)*
- [ ] **Turn the floating video off per site** Choose the sites where a video never floats. *([#267](https://github.com/driceroland/Search/issues/267))*
- [ ] **User scripts fail on GitHub** Tampermonkey runs each script through an inline script, and WebKit holds it to the page's content security policy, where Chrome exempts it; GitHub's policy blocks it. No safe narrow fix yet. *([#289](https://github.com/driceroland/Search/issues/289), [#319](https://github.com/driceroland/Search/issues/319))*
- [ ] **Select several tabs** Select tabs with ⌘-click and ⇧-click, then copy all their addresses at once. *([#309](https://github.com/driceroland/Search/issues/309))*
- [ ] **Optional ad-blocking add-on** A stronger blocker as an optional add-on in Settings, downloaded on demand so it only takes space for those who want it. Search's built-in blocker stays as it is meanwhile. *(message)*
- [ ] **Unsaved text on move to window** A tab moved into a window that shows another space signs in with that space, as Move to Space does; unlike Move to Space, it doesn't first ask about text typed and not sent.
- [ ] **Little window: blocker and passwords** A page in the small window for outside links doesn't get the ad blocker's per-site settings or the accounts list under a sign-in box until it is moved into your tabs.

## Pull requests to review

- [ ] **Esc closes an untouched new tab** Esc on a tab just opened with ⌘T, with nothing typed, closes it and goes back to the tab you were on. *([#389](https://github.com/driceroland/Search/issues/389), [#393](https://github.com/driceroland/Search/pull/393))*
- [ ] **A new tab keeps what was typed** Words typed into a new tab's field and not yet sent stay with that tab when you look at another and come back. *([#390](https://github.com/driceroland/Search/issues/390), [#394](https://github.com/driceroland/Search/pull/394))*
- [ ] **Dragging a tab moves the window again** In 1.0.4 a tab grabbed by its upper half can move the window instead of the tab; a contribution also reworks how a carried tab is drawn and dragged out. *([#395](https://github.com/driceroland/Search/pull/395))*

## Drice's call

- [ ] **Notifications from sites** Sites like WhatsApp, Slack or Gmail can show notifications while Search is open, after asking you, site by site. Not when Search is closed: WebKit gives apps other than Safari no web push. *(X, [#328](https://github.com/driceroland/Search/issues/328))*
- [ ] **Pressing a pin's number again** ⌘1–⌘9 pressed again on the pin you are on takes it back to the page it was pinned at, as a double-click on it does. *(email)*
- [ ] **Pin letters of your own** A pin without an icon wears a capital letter; choose a lowercase one, two letters, or a symbol instead. *(email)*
- [ ] **A colour of your own for the chrome** Pick a colour for the tab bar and the panels. *([#396](https://github.com/driceroland/Search/issues/396))*

## Asked to try again on the latest version

- [ ] **Bitwarden on Intel Macs** Not reproduced on an Intel build run here, where Bitwarden's SDK loads; likely macOS 15's WebKit rather than the chip. Asked for the popup's console errors and the macOS version. *([#175](https://github.com/driceroland/Search/issues/175))*
- [ ] **Google sign-in flashes with Proton Pass** With Proton Pass signed in, Google's sign-in page reloads every half second. Presumed fixed in 1.0.2 by [#126](https://github.com/driceroland/Search/pull/126) and the passkey changes; to confirm with the person who saw it. *(X)*
- [ ] **Hidden sidebar closes too soon** It closes while the pointer is over the extension buttons at its foot. Maybe fixed by [#115](https://github.com/driceroland/Search/pull/115) in 1.0.2; unconfirmed. *(email)*
- [ ] **A tab loses track of its site** A tab's site switches, and the tab doesn't follow. Not reproduced. *([#28](https://github.com/driceroland/Search/issues/28))*
- [ ] **macOS text replacements in pages** The Mac's own text replacements don't work in text boxes on web pages. Tried on 1.0.3 and on the next version: a replacement typed then followed by a space is replaced in a text field, a text area and an editable page area. To ask: on which site, with which replacement, and does it work in Safari there? *(email)*
- [ ] **The column seems to refresh** Reported as a sidebar refresh issue. Asked whether the column itself redraws or the page reloads as it comes out. *(email)*
- [ ] **Black screen after full screen** In full screen, opening another window leaves the screen black. Asked which window: another app's, or one a page opens. *(email)*
- [ ] **Cesturify's sessions command** An extension command that uses the sessions permission does nothing. Asked which command. *(email)*
- [ ] **Reading Mode keeps the cookie notice** On some sites Reading Mode keeps the privacy or cookie notice instead of the article. Asked which site. *(email)*
- [ ] **Part of LinkedIn won't expand** Something on LinkedIn doesn't open when clicked. Asked which part: a post, its comments, or something else. *(email)*

## Just in, not sorted yet

- [ ] **Bookmarks look broken at some sizes** The bookmarks' look breaks at some window or column sizes; to look at with the screenshots in the report. *([#391](https://github.com/driceroland/Search/issues/391))*
- [ ] **Pin a tab group** A whole tab group kept like a pin: several Slacks, each with its client's sites, told apart and kept. *([#392](https://github.com/driceroland/Search/issues/392))*
- [ ] **Group tabs automatically** Tabs put into groups for you, on request or as they open. *([#398](https://github.com/driceroland/Search/issues/398))*

## Not on the list, for now

- **Web processes start before the window** The web process pool is made before the first window; check whether 1.0.2's launch order already covers it. Measured at about 1.5 ms on macOS 26 (8–9 ms on macOS 27): not worth the change it needs. *([#157](https://github.com/driceroland/Search/issues/157))*
- **Block YouTube's ads** YouTube's ads. They come from youtube.com itself, which the blocker's lists can't tell apart. Whether to go that far is an open question. Search's built-in blocker stays as it is; blocking YouTube's ads is not planned. An optional ad-blocking add-on, downloaded only by those who want it, may come later. *([#218](https://github.com/driceroland/Search/issues/218), email ×3)*
- **Tab bar in the page's colour** The tab bar or title bar in the page's own colour. Not planned: Search stays minimal. *([#158](https://github.com/driceroland/Search/issues/158), [#168](https://github.com/driceroland/Search/pull/168), [#25](https://github.com/driceroland/Search/pull/25))*
- **Dark mode for the Search site** A dark mode for the site's Search page. The Search page keeps the one look it has. *([#51](https://github.com/driceroland/Search/issues/51))*
- **Home page or home button** A home page or home button. Not planned: Search stays minimal. *(email, [#299](https://github.com/driceroland/Search/pull/299))*
- **Autocomplete in a new tab** What exactly was asked, to find out. The address field already completes from your history, bookmarks and open tabs; nothing more specific was asked. *(X)*
- **Address bar above the page** The card behind a tab's icon — the site, whether its connection is secure, copy, print, zoom — does that part without a bar. *([#15](https://github.com/driceroland/Search/issues/15), [#56](https://github.com/driceroland/Search/pull/56), email)*
- **Bookmarks in the column** The bookmarks bar, off unless turned on, and the Bookmarks menu are where they live. *([#58](https://github.com/driceroland/Search/issues/58), [#69](https://github.com/driceroland/Search/pull/69), email)*
- **Customization page** Settings stays short. *([#101](https://github.com/driceroland/Search/issues/101), [#105](https://github.com/driceroland/Search/pull/105), [#106](https://github.com/driceroland/Search/pull/106), [#107](https://github.com/driceroland/Search/pull/107), [#108](https://github.com/driceroland/Search/pull/108), [#143](https://github.com/driceroland/Search/pull/143), [#231](https://github.com/driceroland/Search/pull/231), [#262](https://github.com/driceroland/Search/pull/262), [#263](https://github.com/driceroland/Search/issues/263), [#321](https://github.com/driceroland/Search/issues/321), [#322](https://github.com/driceroland/Search/issues/322), [#288](https://github.com/driceroland/Search/issues/288), [#350](https://github.com/driceroland/Search/pull/350))*
- **Hidden sidebar delay setting** The default is what changes instead. *([#118](https://github.com/driceroland/Search/issues/118))*
- **Floating launcher** ⌘S and a folded column already give the page the whole window. *([#18](https://github.com/driceroland/Search/issues/18))*
- **Proxy extensions** WebKit doesn't give it to extensions. *([#12](https://github.com/driceroland/Search/issues/12))*
- **Snoozing tabs** For now. *([#111](https://github.com/driceroland/Search/pull/111))*
- **Vim mode** Vimium works. *([#160](https://github.com/driceroland/Search/pull/160))*
- **Brazilian Portuguese** For now. *([#113](https://github.com/driceroland/Search/pull/113))*
- **Windows and Linux** Search is made of the Mac's own WebKit and AppKit; there is nothing to carry over. *([#62](https://github.com/driceroland/Search/issues/62), [#64](https://github.com/driceroland/Search/issues/64), [#65](https://github.com/driceroland/Search/issues/65), [#197](https://github.com/driceroland/Search/pull/197))*
- **macOS before 14** The app leans on what macOS 14 added to WebKit.
- **Accounts and sync** Bookmarks with Google, tabs across devices. Search has no server and keeps everything on your Mac; importing is the way in. *([#224](https://github.com/driceroland/Search/issues/224), email)*
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
- **Tabs that close themselves** Close tabs left untouched for a long time, as Arc does. A tab you leave alone sleeps after half an hour and costs nothing, so there's nothing to clear away. *(email)*
- **An icon-only column** A narrow column that shows only the tabs' icons. Folding the column away (⌘S) and the tabs across the top already give the page the room; a third layout would be one more to keep working. *(email)*
- **Safari's own extensions** Load extensions installed for Safari, such as wBlock, besides the Chrome Web Store's. Safari's extensions live inside their apps and talk to them through Safari alone, and content blockers hand their rules to Safari only. Their Chrome Web Store versions work in Search. *(email ×2)*
- **Screen recording from extensions** Loom and other recorders need Chrome's desktopCapture and tabCapture, which WebKit doesn't give extensions. WebKit has no desktopCapture or tabCapture for extensions. A bridge onto getDisplayMedia would be a project with an uncertain outcome; the Loom app for Mac records alongside Search. *(email)*
