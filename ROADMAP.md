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
- [ ] **Translate pages on the Mac** Translate a page, or the text in a picture, on the Mac itself; nothing is sent anywhere. Off until turned on. *([#265](https://github.com/driceroland/Search/pull/265), email)*
- [ ] **Apple Passwords under the sign-in field** Passwords saved in the Mac's Passwords app listed under the sign-in field, as in Safari, without the iCloud Passwords extension. It goes through Apple's own helper, which only a Developer ID build may launch. Off unless turned on. *([#425](https://github.com/driceroland/Search/issues/425), email ×3)*
- [ ] **Profiles: separate sets of spaces with their own sign-ins, history and bookmarks** A profile above spaces, as in Chrome and Arc: its own spaces, sign-ins, history and bookmarks, in windows of its own. Personal is everything there is today. *([#459](https://github.com/driceroland/Search/issues/459))*

## Done, in the next version

- [x] **Pressing a pin's number again** ⌘1–⌘9 pressed again on the pin you are on takes you back to the tab you were on before it. Off by default. *(email)*
- [x] **A right-click menu on the bookmarks bar** *([#438](https://github.com/driceroland/Search/issues/438), [#439](https://github.com/driceroland/Search/pull/439))*
- [x] **Copy Clean Link** In a tab's menu: copy its address without tracking parameters. *([#594](https://github.com/driceroland/Search/issues/594))*
- [x] **Websites in the side panel** Keep a site such as claude.ai or chatgpt.com open in the side panel beside the page, not only an extension's panel. Off until you put one there. *(email)*
- [x] **Ask before quitting** An optional question before ⌘Q quits Search, off by default. *([#653](https://github.com/driceroland/Search/issues/653), [#659](https://github.com/driceroland/Search/pull/659))*
- [x] **Tab numbers while ⌘ is held** Holding ⌘ shows which tab ⌘1–9 picks, off by default. *([#654](https://github.com/driceroland/Search/issues/654), [#658](https://github.com/driceroland/Search/pull/658))*
- [x] **Native picture in picture as a choice** macOS's own picture in picture as an alternative to the floating video. *([#591](https://github.com/driceroland/Search/issues/591))*

## Now — fixes for the next update

- [ ] **Spaces sometimes don't switch** *(email)*
- [ ] **Smoother mouse-wheel scrolling** Smoother scrolling with a mouse wheel, as Safari animates each notch. To look into with the scrolling work. *(X)*
- [ ] **Eagle extension doesn't work** The Eagle extension from the Chrome Web Store fails to work in Search. *(email)*
- [ ] **Extension windows as small windows** Both reported as not working on 1.0.3. NordPass: its vault opens with a popup window, which becomes a small window of its page in 1.0.5 (on main; to check on the release candidate). Loom: screen recording needs Chrome's desktopCapture and tabCapture, which WebKit doesn't have; only a bridge through WebKit's own screen sharing could get there. *(email)*
- [ ] **Icons per port** Icons are kept per host, so every port of localhost shares the first one seen. *([#413](https://github.com/driceroland/Search/issues/413))*
- [ ] **Bookmarks dropdown cut short** In the list under the bookmark button, an open folder shows a row and a half and can't be seen whole: the list doesn't grow when a folder opens. *(email)*
- [ ] **The page as a card, with a bar above it** A bar above the page with back, forward, reload, the page's title and its address; the page drawn as a card with a small gap around it and rounded corners; Settings opened as a tab. *(message)*
- [ ] **Loading shown with the column hidden** With the column hidden nothing says a page is loading; the new layout's bar above the page will show it. *([#443](https://github.com/driceroland/Search/issues/443))*
- [ ] **Arc import twice: a second pin** Bringing Arc over again adds a second pin for a site whose pin has moved address (Gmail): the guard compares the pin's current address. *([#482](https://github.com/driceroland/Search/issues/482))*
- [ ] **Proxy for the whole browser** HTTP and SOCKS5 proxy in Settings, off by default, everything through it. *([#510](https://github.com/driceroland/Search/pull/510))*
- [ ] **iCloud Passwords keeps its pairing** On macOS 27 iCloud Passwords asks for its code again every couple of minutes; the keep-alive no longer holds. *([#610](https://github.com/driceroland/Search/issues/610))*
- [ ] **A peek opens at the default zoom** A link opened in a peek starts at 100% instead of the default page zoom from Settings, or the site's own zoom. *([#691](https://github.com/driceroland/Search/issues/691))*
- [ ] **One letter completes a site you visit often** Typing x then Return goes to x.com when it's a site you visit often; inline completion starts at two letters today. *([#696](https://github.com/driceroland/Search/issues/696))*

## Next — small additions people asked for

- [ ] **Box Tools** Let app.box.com reach its local helper on this Mac, as Chrome does. The person who asked offered to test a build. *(email)*
- [ ] **1Password desktop app, in the FAQ** 1Password with its desktop app. Say in the FAQ that Search is added in 1Password › Settings › Browser › Add Browser.
- [ ] **A user agent per tab** Presets and a string of your own, per tab, as in Safari's Develop menu; shares its plumbing with Responsive Design Mode. *([#460](https://github.com/driceroland/Search/issues/460))*
- [ ] **Icons drawn as SVG** A site whose only icon is an SVG shows a letter: only bitmap icons are decoded today. Draw SVG icons without opening a new decoder in the app. *([#680](https://github.com/driceroland/Search/issues/680))*
- [ ] **Esc twice to leave full screen** A switch, as in Arc: the first Esc in full screen stays and says so, a second one leaves. *([#678](https://github.com/driceroland/Search/pull/678))*
- [ ] **Dev builds named after their branch** A development build carries its branch's name and its own icon, so several builds can run side by side. *([#475](https://github.com/driceroland/Search/pull/475))*
- [ ] **Each checkout tests in its own world** Build tests from two checkouts no longer share one test world. *([#497](https://github.com/driceroland/Search/pull/497))*

## Later — bigger pieces of work

- [ ] **More extension APIs** More of the extension APIs. The side panel, and invisible offscreen documents ([#192](https://github.com/driceroland/Search/pull/192)). *([#12](https://github.com/driceroland/Search/issues/12), X, [#192](https://github.com/driceroland/Search/pull/192) ×2, [#273](https://github.com/driceroland/Search/issues/273), [#351](https://github.com/driceroland/Search/issues/351), [#352](https://github.com/driceroland/Search/pull/352), [#484](https://github.com/driceroland/Search/issues/484))*
- [ ] **Drive Search from an agent** An MCP server over the bench, for automation and testing. An earlier pull request, [#14](https://github.com/driceroland/Search/pull/14), began one. *(X)*
- [ ] **Faster animations** Spaces especially, compared with Zen. *(email)*
- [ ] **Extensions per space** Each space with the extensions it wants, on and off apart from the others. WebKit has one extension controller for the whole app, so this means one per space. Drice's call, 24 Sep: later. *(X)*
- [ ] **User scripts fail on GitHub** Tampermonkey runs each script through an inline script, and WebKit holds it to the page's content security policy, where Chrome exempts it; GitHub's policy blocks it. No safe narrow fix yet. *([#289](https://github.com/driceroland/Search/issues/289), [#319](https://github.com/driceroland/Search/issues/319))*
- [ ] **Optional ad-blocking add-on** A stronger blocker as an optional add-on in Settings, downloaded on demand so it only takes space for those who want it. Search's built-in blocker stays as it is meanwhile. *(message)*
- [ ] **Unsaved text on move to window** A tab moved into a window that shows another space signs in with that space, as Move to Space does; unlike Move to Space, it doesn't first ask about text typed and not sent.
- [ ] **Little window: blocker and passwords** A page in the small window for outside links doesn't get the ad blocker's per-site settings or the accounts list under a sign-in box until it is moved into your tabs.
- [ ] **Pin a tab group** A whole tab group kept like a pin: several Slacks, each with its client's sites, told apart and kept. *([#392](https://github.com/driceroland/Search/issues/392), email)*
- [ ] **Tabs shared across windows** A space's tabs belong to the space, and any window can show them, with a stand-in where a tab is open in another window, as in Arc. Pins already are the same in every window. *([#417](https://github.com/driceroland/Search/issues/417))*
- [ ] **A picture behind the new tab** An image behind the new tab page, perhaps from Unsplash. Off unless turned on, if it ever comes. *([#447](https://github.com/driceroland/Search/issues/447))*
- [ ] **Main process grows over days** The app's own process grew to several times its fresh size over a week of use; find what accumulates (closed windows, caches).
- [ ] **Small windows: alone and keyed** A link small window opens alone, takes its keys, closes with a swipe back, cascades, and shows in the switcher. *([#431](https://github.com/driceroland/Search/pull/431), [#519](https://github.com/driceroland/Search/pull/519), [#474](https://github.com/driceroland/Search/pull/474), [#493](https://github.com/driceroland/Search/pull/493), [#480](https://github.com/driceroland/Search/pull/480))*
- [ ] **UTF-8 in extension scripts** Non-ASCII text in injected extension scripts stays intact. *([#521](https://github.com/driceroland/Search/pull/521))*
- [ ] **Back and Forward lists** Hold or right-click Back and Forward to pick a page from that way. *([#567](https://github.com/driceroland/Search/pull/567))*
- [ ] **Float a whole page** Any page, not only a video, in the floating window, and meetings that float when you switch away. Off unless turned on. *([#584](https://github.com/driceroland/Search/pull/584))*
- [ ] **One window per space** A switch so each space opens in a window of its own. *([#611](https://github.com/driceroland/Search/issues/611))*
- [ ] **Why a tab stays awake** A small view listing which tabs sleep and why the others stay awake. Off by default. *([#624](https://github.com/driceroland/Search/issues/624), [#628](https://github.com/driceroland/Search/pull/628))*
- [ ] **A quick drawer to switch spaces** Click the space mark for a small panel of spaces to switch, drag to reorder and add; settings move to a right-click. *([#682](https://github.com/driceroland/Search/issues/682))*

## Pull requests to review

- [ ] **Ask before a website shares the screen** *([#528](https://github.com/driceroland/Search/issues/528), [#530](https://github.com/driceroland/Search/pull/530), [#651](https://github.com/driceroland/Search/pull/651))*
- [ ] **Sized pop-ups as small windows** A pop-up a page asks for at its own size opens as a small window, off by default. *([#552](https://github.com/driceroland/Search/issues/552), [#660](https://github.com/driceroland/Search/pull/660))*
- [ ] **Side panel and private tabs** A window-wide extension panel stays up while a private tab is in front; hide it then unless that extension may run in private tabs (after #536). *([#662](https://github.com/driceroland/Search/issues/662), [#677](https://github.com/driceroland/Search/pull/677))*
- [ ] **Each app on one host wears its own icon** Icons kept per page instead of per host, so apps under sub-paths of one server each show their own. *([#641](https://github.com/driceroland/Search/pull/641) ×2)*
- [ ] **Extensions take less memory** Extensions with big content scripts kept a copy per site and per tab, gigabytes in all. *([#663](https://github.com/driceroland/Search/issues/663), [#669](https://github.com/driceroland/Search/pull/669), [#604](https://github.com/driceroland/Search/pull/604))*
- [ ] **Figma's permissions page** Figma's extension asks for more permissions and gets nothing back. *([#675](https://github.com/driceroland/Search/pull/675))*

## Drice's call

- [ ] **The page behind a new tab** The page you came from stays visible behind the new tab, as in Arc. *([#465](https://github.com/driceroland/Search/issues/465), [#683](https://github.com/driceroland/Search/issues/683))*
- [ ] **A pinned tab in a group** Move a pinned tab into a tab group without unpinning it first, as Arc's pinned folders allow. *([#692](https://github.com/driceroland/Search/issues/692))*
- [ ] **Peek into a folded group** Rest the pointer on a folded group to see its tabs in a small list and pick one, as in Arc's folder previews. Off unless turned on. *([#690](https://github.com/driceroland/Search/issues/690))*
- [ ] **Bring a tab to the front from a script** A tab id and one focus command in the AppleScript dictionary, so a launcher such as Raycast can switch to a tab. Everything else stays read-only. *([#684](https://github.com/driceroland/Search/issues/684))*
- [ ] **A tab gives when pressed** A tab shrinks slightly under the pointer while pressed, and the tab switcher's corners match the rest of Search. *([#686](https://github.com/driceroland/Search/pull/686))*
- [ ] **Reading mode uses a site's own Markdown** When a site publishes a Markdown copy of a page, reading mode reads that instead of guessing; the page's own styles stay out of the reader. Off unless turned on. *([#687](https://github.com/driceroland/Search/pull/687), [#689](https://github.com/driceroland/Search/pull/689))*
- [ ] **Lighter animations in Low Power Mode** Interface springs become short ease-outs while Low Power Mode is on or the Mac runs hot. Off unless turned on. *([#688](https://github.com/driceroland/Search/pull/688))*

## Asked to try again on the latest version

- [ ] **Google sign-in flashes with Proton Pass** With Proton Pass signed in, Google's sign-in page reloads every half second. Presumed fixed in 1.0.2 by [#126](https://github.com/driceroland/Search/pull/126) and the passkey changes; to confirm with the person who saw it. *(X)*
- [ ] **Google Docs blurry on one Mac** Docs, Sheets and Slides look soft on a Retina screen for one person; not reproduced. *([#666](https://github.com/driceroland/Search/issues/666))*
- [ ] **Passkey from a phone** Signing in with a passkey held on an iPhone (the QR code) fails, here on an Apple Account sign-in. *([#679](https://github.com/driceroland/Search/issues/679))*
- [ ] **1Password's unlock doesn't open** With 1Password locked, its button in a field and the toolbar button open nothing. *([#685](https://github.com/driceroland/Search/issues/685))*

## Just in, not sorted yet

- [ ] **Bookmarks bar: move and new folder** Rearrange bookmarks on the bar itself (the bar now moves the window, so perhaps with a key held) and make a folder from the bar. *(email)*
- [ ] **A site's permissions in its card** The site card lists what the site may use (camera, microphone, location, notifications, sound) and lets each be changed or forgotten there. *(email)*
- [ ] **Links from a pin open a new tab** A link followed from a pinned tab opens beside it, so the pin stays on its page. *(email)*
- [ ] **Bookmarks per space** Each space keeps bookmarks of its own. *(email)*
- [ ] **Window colours** A colour for the window, or for each space, with a light and a dark version, as in Helium and Arc. *(email ×2)*
- [ ] **Extension side panels** Extensions that open in Chrome's side panel, like ChatGPT's and Claude's, have nowhere to open: WebKit has no side panel. *(email)*
- [ ] **Group tabs by dropping one on another** Drop a tab onto another in the column and the two become a group. *(email)*
- [ ] **Send links to a space** Links from chosen sites open in a given space, with its sign-ins, as Arc's Air Traffic Control does. *(email, [#595](https://github.com/driceroland/Search/issues/595) ×2, [#596](https://github.com/driceroland/Search/pull/596))*
- [ ] **One place for ⌘T, ⌘K and ⌘Y** New tab, the open tabs and history reached from a single field. *(email)*
- [ ] **Open tabs from Helium** Bringing things over from Helium takes its bookmarks, history, passwords and extensions, but not the tabs it has open. *(email)*
- [ ] **⌘L again closes the address** A second ⌘L puts away the address field it opened, as Esc does. *(email)*
- [ ] **Tabs that pause, not reload** An option to keep a resting tab's page and let WebKit suspend it, off by default. *([#520](https://github.com/driceroland/Search/issues/520))*
- [ ] **Option-Command arrows to move between tabs** *([#532](https://github.com/driceroland/Search/issues/532))*
- [ ] **Share the screen with its sound** WebKit gives a shared screen no sound track, even when a call asks for one; it would mean capturing the sound ourselves and feeding it to the page. *([#540](https://github.com/driceroland/Search/issues/540))*
- [ ] **Floating video flickers popping out** The video shifts and flickers as it pops out of the page. *([#543](https://github.com/driceroland/Search/issues/543), [#547](https://github.com/driceroland/Search/pull/547), [#562](https://github.com/driceroland/Search/pull/562))*
- [ ] **Float a meeting page when you switch away** *([#544](https://github.com/driceroland/Search/issues/544), [#547](https://github.com/driceroland/Search/pull/547))*
- [ ] **CleanMyMac flags Search as unwanted** CleanMyMac's "Mac Search - PUA" is a false positive: Search is a notarised Developer ID app, and MacPaw has been told. *([#556](https://github.com/driceroland/Search/issues/556))*
- [ ] **Reading mode follows dark mode** *([#563](https://github.com/driceroland/Search/issues/563), [#564](https://github.com/driceroland/Search/pull/564), [#565](https://github.com/driceroland/Search/pull/565), [#566](https://github.com/driceroland/Search/pull/566))*
- [ ] **YouTube dislike counts don't show** Return YouTube Dislike installs but its counts never appear on YouTube; a userscript doing the same works. *([#588](https://github.com/driceroland/Search/issues/588))*
- [ ] **Some sites stay on http** Choose hosts that are never sent to https. *([#671](https://github.com/driceroland/Search/issues/671))*
- [ ] **PDFs sent as downloads open in a tab** A setting to show a PDF the site sends as a download, with Save still there, off by default. *([#672](https://github.com/driceroland/Search/issues/672))*
- [ ] **Dragging tabs into and within a group** Adding a fourth tab to a group, and reordering inside one, reported not to work. *([#673](https://github.com/driceroland/Search/issues/673))*
- [ ] **Trackpad taps for spaces and tabs** A light tap from the trackpad when a space swipe, a tab drag or the column's edge crosses the point where letting go changes something, as the back swipe and Split View's divider already do. *([#695](https://github.com/driceroland/Search/issues/695))*

## Not on the list, for now

- **Web processes start before the window** The web process pool is made before the first window; check whether 1.0.2's launch order already covers it. Measured at about 1.5 ms on macOS 26 (8–9 ms on macOS 27): not worth the change it needs. *([#157](https://github.com/driceroland/Search/issues/157))*
- **Hidden sidebar closes too soon** It closes while the pointer is over the extension buttons at its foot. Maybe fixed by [#115](https://github.com/driceroland/Search/pull/115) in 1.0.2; unconfirmed. No reply; reopen anytime. *(email)*
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
- **Accounts and sync** Bookmarks with Google, tabs across devices. Search has no server and keeps everything on your Mac; importing is the way in. *([#224](https://github.com/driceroland/Search/issues/224), email, [#488](https://github.com/driceroland/Search/issues/488), [#674](https://github.com/driceroland/Search/issues/674))*
- **Page slides with the sidebar** The page moves with the sidebar as it opens instead of redrawing in steps, with no gap at the edge; the PR also adds a speed setting. Since 0469c15 the page already slides with the column and is resized once; no speed setting, Settings stays short. *([#252](https://github.com/driceroland/Search/pull/252))*
- **Touch Bar controls** Back, forward, reload, the tabs and a new tab button on the Touch Bar, stepping aside when a field or video needs it. Not planned: Search stays minimal. *([#274](https://github.com/driceroland/Search/issues/274), [#275](https://github.com/driceroland/Search/pull/275))*
- **A name that's easier to find** “Search” is hard to find when searching for a browser; a more distinctive name is suggested. The name stays Search. Where it has to be found, it's Search Browser, or Search by Office Commun. *([#276](https://github.com/driceroland/Search/issues/276), [#676](https://github.com/driceroland/Search/issues/676))*
- **A new look for the back swipe** The swipe back and forward draws a shape pulled out of the edge that follows the fingers, instead of arrows sliding the other way. Not planned: Search stays minimal. *([#281](https://github.com/driceroland/Search/issues/281), [#282](https://github.com/driceroland/Search/pull/282))*
- **Back closes a link's own tab** Back from the first page of a tab a link opened closes that tab and returns to the page it came from. Not planned: Search stays minimal. *([#283](https://github.com/driceroland/Search/pull/283))*
- **Sites as their own apps** Make a small app of its own for a site kept open all day, from the Tabs menu. Not planned: sites stay in Search's tabs and spaces. *([#292](https://github.com/driceroland/Search/pull/292))*
- **Interface in other languages** Search's own interface follows the Mac's language, starting with Simplified Chinese or Japanese. No translations for now. *([#304](https://github.com/driceroland/Search/issues/304), [#317](https://github.com/driceroland/Search/pull/317), [#334](https://github.com/driceroland/Search/issues/334), [#632](https://github.com/driceroland/Search/issues/632))*
- **Screenshot one element** Pick an element on the page and save or copy a picture cropped to it. The Web Inspector already captures a single element: right-click it in the Elements tab, Capture Screenshot. *([#308](https://github.com/driceroland/Search/issues/308))*
- **Blurry text in Jupyter** Text in a Jupyter notebook on localhost looks slightly blurry, unlike in Chrome. The reporter couldn't make it happen again after reinstalling, and closed the report; reopen if it comes back. *([#329](https://github.com/driceroland/Search/issues/329))*
- **Hide page clutter with a model** A small on-device model decides which parts of a page to hide. The built-in blocker stays as it is, without a model deciding what to hide. An optional ad-blocking add-on may come later. *([#339](https://github.com/driceroland/Search/issues/339))*
- **Two sidebars** Bookmarks in a sidebar on one side and tabs on the other, both at once. The column stays as quiet as possible: tabs only. Bookmarks live in the bookmarks bar (optional) and the Bookmarks menu. *([#359](https://github.com/driceroland/Search/issues/359))*
- **New tabs at the top of the column** An option to open new tabs at the top of the column instead of after the current tab. Search keeps new tabs where every browser puts them. *(email)*
- **An icon-only column** A narrow column that shows only the tabs' icons. Folding the column away (⌘S) and the tabs across the top already give the page the room; a third layout would be one more to keep working. *(email)*
- **The column seems to refresh** Reported as a sidebar refresh issue. Asked whether the column itself redraws or the page reloads as it comes out. No reply; reopen anytime. *(email)*
- **Black screen after full screen** In full screen, opening another window leaves the screen black. Asked which window: another app's, or one a page opens. No reply; reopen anytime. *(email)*
- **Cesturify's sessions command** An extension command that uses the sessions permission does nothing. Asked which command. No reply; reopen anytime. *(email)*
- **Safari's own extensions** Load extensions installed for Safari, such as wBlock, besides the Chrome Web Store's. Safari's extensions live inside their apps and talk to them through Safari alone, and content blockers hand their rules to Safari only. Their Chrome Web Store versions work in Search. *(email ×2, [#636](https://github.com/driceroland/Search/issues/636))*
- **Reading Mode keeps the cookie notice** On some sites Reading Mode keeps the privacy or cookie notice instead of the article. Asked which site. No reply; reopen anytime. *(email)*
- **Part of LinkedIn won't expand** Something on LinkedIn doesn't open when clicked. Asked which part: a post, its comments, or something else. No reply; reopen anytime. *(email)*
- **Pin letters of your own** A pin without an icon wears a capital letter; choose a lowercase one, two letters, or a symbol instead. Too niche for now. *(email)*
- **A colour of your own for the chrome** Pick a colour for the tab bar and the panels. Settings stays short: the chrome follows the Mac's light or dark look. *([#396](https://github.com/driceroland/Search/issues/396))*
- **Group tabs automatically** Tabs put into groups for you, on request or as they open. Search stays minimal: tab groups are made by hand, on purpose. *([#398](https://github.com/driceroland/Search/issues/398))*
- **A load line across the page** A thin line along the top of a loading page. The tab's own ring already shows a page loading. *([#401](https://github.com/driceroland/Search/pull/401), [#400](https://github.com/driceroland/Search/pull/400))*
- **Responsive Design Mode** Look at a page as an iPhone, a Pixel or an iPad would, from the View menu, as in Safari's Develop menu. A developer tool, not what Search is for. *([#412](https://github.com/driceroland/Search/pull/412))*
- **Icons follow the page** A site that changes its icon after load (GitHub with its theme) shows the new one; light and dark icons are kept apart. Duplicate of 239 *([#423](https://github.com/driceroland/Search/issues/423))*
- **Move the window by the top of a page** As in Arc and Dia: dragging an empty part of a site's top bar, or of a page's top edge, moves the window. Off unless turned on. In 1.0.5 the page gets a bar of its own above it, which moves the window like a title bar; no need to take presses from the page itself. *([#427](https://github.com/driceroland/Search/pull/427))*
- **GitHub's Files page slow to paint** A GitHub pull request's Files page can stay blank for tens of seconds while its CSS comes in; a bare WKWebView is about as slow. Waiting on a comparison with Safari. No reply; reopen anytime. *([#458](https://github.com/driceroland/Search/issues/458))*
- **Bitwarden popup spins** Its background never answers the popup (no runtime.onConnect listener). Stopped happening for the reporter; reopen anytime. *([#541](https://github.com/driceroland/Search/issues/541))*
- **Ask before a site's first pop-up** Ask even for a pop-up after a click, beyond what Safari and Chrome do. Goes further than Safari and Chrome; 1.0.6 brings Safari's blocked pop-up sign instead. *([#656](https://github.com/driceroland/Search/issues/656), [#661](https://github.com/driceroland/Search/pull/661))*
