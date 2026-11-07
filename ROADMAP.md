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

## Done, in the next version

- [x] **A site's permissions in its card** The site card lists what the site may use (camera, microphone, location, notifications, sound) and lets each be changed or forgotten there. *(email, [#782](https://github.com/driceroland/Search/issues/782), [#868](https://github.com/driceroland/Search/issues/868), [#869](https://github.com/driceroland/Search/issues/869), [#940](https://github.com/driceroland/Search/pull/940))*
- [x] **Offer to save sign-ins sent by the page's script** form.submit() from a link, a timer or a styled box fires no submit event, so no offer came. *([#705](https://github.com/driceroland/Search/pull/705))*
- [x] **Accounts for the exact host first** With logins for admin.example.com and admin-qa.example.com, both show on either. Show the host's own accounts first (or only). *([#723](https://github.com/driceroland/Search/pull/723))*
- [x] **Settings follow defaults write while running** A defaults write to Search's settings lands in the running app, and its switch moves, as a click in Settings would. *([#736](https://github.com/driceroland/Search/issues/736), [#946](https://github.com/driceroland/Search/pull/946))*
- [x] **Verification codes from Apple Passwords** The one-time codes kept in Apple's Passwords app offered under a code field, as Safari does. *(email, [#855](https://github.com/driceroland/Search/pull/855))*
- [x] **Reading mode misses parts of some articles** Whole article as in Safari; and reading mode follows a dark window by default. *([#757](https://github.com/driceroland/Search/issues/757), [#774](https://github.com/driceroland/Search/pull/774))*
- [x] **A notification opens the tab that sent it** Clicking a site's notification goes to the tab it came from, not the first tab on that site. *([#776](https://github.com/driceroland/Search/issues/776), [#864](https://github.com/driceroland/Search/pull/864))*
- [x] **A sleeping tab wakes zoomed in** The picture shown while a tab wakes comes back at twice its size on a Retina screen. *([#781](https://github.com/driceroland/Search/issues/781), [#820](https://github.com/driceroland/Search/issues/820), [#871](https://github.com/driceroland/Search/pull/871))*
- [x] **Dark SVG icons vanish in dark mode** *([#807](https://github.com/driceroland/Search/issues/807), [#917](https://github.com/driceroland/Search/pull/917))*
- [x] **Copy a download's address** In Downloads, to hand it to another download app *([#853](https://github.com/driceroland/Search/issues/853), [#863](https://github.com/driceroland/Search/pull/863))*
- [x] **Shift-Return searches with a second engine** Optional picker, off until set *([#848](https://github.com/driceroland/Search/issues/848), [#856](https://github.com/driceroland/Search/pull/856))*
- [x] **A carried tab springs back at each swap** Carrying a tab, each change of place draws it back where it was for a moment before it glides to the pointer, most past a Split View pair. *([#886](https://github.com/driceroland/Search/issues/886), [#979](https://github.com/driceroland/Search/pull/979))*
- [x] **The blocker's switch for a site in its card** Turning the blocker off for one site is in Settings › Privacy today; the site's card is where people look for it. *([#861](https://github.com/driceroland/Search/issues/861) ×2)*
- [x] **Engine suggestions wear the engine's icon** Every row in the address field's list that searches wears the mark of where it searches, and a site put in the field with Tab matches its rows. *([#879](https://github.com/driceroland/Search/issues/879), [#881](https://github.com/driceroland/Search/pull/881))*
- [x] **A site in the field names itself** With a site put in the address field with Tab, the empty field says Search and the site's name. *([#888](https://github.com/driceroland/Search/pull/888))*
- [x] **The page hears nothing under the address field and panels** Under the address field, the tab switcher, the hidden elements' list, Welcome, What's New and the Find bar, the page no longer reacts to the pointer. *([#877](https://github.com/driceroland/Search/issues/877), [#878](https://github.com/driceroland/Search/pull/878))*
- [x] **Past searches under a site in the field** With a site put in the field with Tab, or a site shortcut, the list offers what you searched that site for before, read from your history and never in a private tab; your engine's suggestions too when the site is your engine. *([#880](https://github.com/driceroland/Search/issues/880), [#882](https://github.com/driceroland/Search/pull/882))*
- [x] **Search pages in history read as searches** A results page you visited shows in the address field's list as the words you searched and the site, not as its address. *([#889](https://github.com/driceroland/Search/pull/889))*
- [x] **A carried tab stays under the pointer past a pair** With Split View on, a tab carried along the sidebar or the tab row stays under the pointer as it passes a pair and lands where it is let go. *([#883](https://github.com/driceroland/Search/issues/883), [#884](https://github.com/driceroland/Search/pull/884))*
- [x] **A tab whose video is full screen elsewhere can be gone back to** Choosing again a tab whose video is still full screen in its own Space no longer leaves the window without its column. *([#876](https://github.com/driceroland/Search/pull/876))*
- [x] **The downloads button pulses when a download starts** One short pulse of the downloads button when a download begins, still under Reduce Motion. *([#830](https://github.com/driceroland/Search/issues/830), [#865](https://github.com/driceroland/Search/pull/865))*
- [x] **A private tab's PDF stays out of Downloads** A PDF saved with the PDF bar's button from a private tab is announced and listed nowhere, like any other private download. *([#866](https://github.com/driceroland/Search/pull/866))*
- [x] **Claude in Chrome's window gives back its tab first** windows.create listed the space's pins first; Claude grouped tabs[0], a pin, and every action failed *([#872](https://github.com/driceroland/Search/issues/872))*
- [x] **Discord signs you out with the column out** A page read the whole window, column included, as its width; Discord took the difference for developer tools open. *([#916](https://github.com/driceroland/Search/issues/916))*
- [x] **Letters beside a tab's title** With Tabs show: Letters, rows showed no letter beside the title, though the setting says they do. *([#919](https://github.com/driceroland/Search/issues/919), [#860](https://github.com/driceroland/Search/issues/860))*
- [x] **Reduce Motion stills the last three animations** The empty tab's glow, the slide between spaces and the space icon's turn keep still with Reduce Motion on. *([#901](https://github.com/driceroland/Search/pull/901))*
- [x] **A carried pair comes apart only where shown** A Split View pair let go a few points past its edge stays a pair, unless resting there showed it coming apart. *([#885](https://github.com/driceroland/Search/issues/885), [#887](https://github.com/driceroland/Search/pull/887))*
- [x] **A tab just passed shows while one is carried** Carrying a tab across the top, the others wear a faint grey so the one half under it still shows. *([#898](https://github.com/driceroland/Search/issues/898), [#899](https://github.com/driceroland/Search/pull/899))*
- [x] **Back stays off on a pin put down** A pin put down with ⌘W and clicked again no longer shows Back lit with nothing behind it. *([#891](https://github.com/driceroland/Search/issues/891), [#896](https://github.com/driceroland/Search/pull/896))*
- [x] **⇧⌘T brings back Search's own pages** History, Settings, Downloads and the rest come back with ⇧⌘T, still one tab of each. *([#892](https://github.com/driceroland/Search/issues/892), [#897](https://github.com/driceroland/Search/pull/897))*
- [x] **⇧⌘T brings a tab back with its history** A reopened tab keeps Back, Forward and its place on the page. Private tabs are still never kept. *([#890](https://github.com/driceroland/Search/issues/890), [#895](https://github.com/driceroland/Search/pull/895))*
- [x] **⌘W puts the raised field away** With the address field raised over a page by ⌘L or ⌘K, ⌘W puts the field away, as after ⌘T. *([#903](https://github.com/driceroland/Search/issues/903), [#910](https://github.com/driceroland/Search/pull/910))*
- [x] **An address typed into ⌘K opens a new tab** What no open tab answers to is a last row in ⌘K's list and opens in a new tab, not over the page. *([#904](https://github.com/driceroland/Search/issues/904), [#911](https://github.com/driceroland/Search/pull/911))*
- [x] **The key that raised the field puts it away** ⌘T, ⌘L or ⌘K again puts its field away, and switching between them keeps what was typed. *([#905](https://github.com/driceroland/Search/issues/905), [#912](https://github.com/driceroland/Search/pull/912))*
- [x] **The field says where Return goes** The empty field's placeholder names a new tab, this tab, or an open tab, whichever key raised it. *([#906](https://github.com/driceroland/Search/issues/906), [#913](https://github.com/driceroland/Search/pull/913))*
- [x] **A video on another screen stays put when you switch apps** With Float the video when you switch apps on, a video in a window on a TV or second display floated out when you worked in another app on the other screen. It now floats only when the other app comes up on the same screen. *(message, [#894](https://github.com/driceroland/Search/issues/894), [#761](https://github.com/driceroland/Search/issues/761))*
- [x] **Optional native messaging for extensions** An extension that asks for native messaging among its optional permissions can reach its app on this Mac once allowed. *([#741](https://github.com/driceroland/Search/issues/741), [#751](https://github.com/driceroland/Search/pull/751))*
- [x] **Now playing in the sidebar** A tab playing sound out of sight shows at the foot of the sidebar with its pause; off by default. *([#764](https://github.com/driceroland/Search/pull/764))*
- [x] **Clearer line on the focused split page** In Split View, the page with the keys has a stronger line round it. *([#937](https://github.com/driceroland/Search/issues/937))*
- [x] **Sidebar drag splits the page again** A tab carried from the sidebar onto the page can split it again. *([#927](https://github.com/driceroland/Search/issues/927))*
- [x] **One ⇧⌘T brings back a closed pair** After Close Both Pages, one ⇧⌘T brings the pair back together. *([#929](https://github.com/driceroland/Search/issues/929))*
- [x] **⌥⌘N on a pair puts it apart** The key that makes a split takes it away again. *([#931](https://github.com/driceroland/Search/issues/931))*
- [x] **Empty split half finds open tabs** Typing in the empty half of a pair offers matching open tabs. *([#933](https://github.com/driceroland/Search/issues/933))*
- [x] **Split zones shown while carrying a tab** A page shows where a carried tab would split it. *([#935](https://github.com/driceroland/Search/issues/935))*
- [x] **Links opened in front join their group** Plus closing such a page goes back to where it was clicked, and an optional switch puts them beside their page. *([#961](https://github.com/driceroland/Search/issues/961))*
- [x] **Closed tabs stop their sound** A tab closed while playing stops its media and doesn't come back in the background. *([#943](https://github.com/driceroland/Search/pull/943))*
- [x] **uBlock Origin Lite and GitLab** Rules WebKit can't follow correctly are left out, so GitLab loads. *([#858](https://github.com/driceroland/Search/pull/858))*
- [x] **Extension popup in the right window** With several windows, a popup opens in the window where its button was pressed. *([#839](https://github.com/driceroland/Search/pull/839))*
- [x] **Keep the window in use during full screen** Optional: browse other tabs while a video is full screen on another desktop. Off by default. *([#972](https://github.com/driceroland/Search/issues/972))*
- [x] **Recent places in the new tab** Optional: ⌘T lists recent places before anything is typed. Off by default. *([#907](https://github.com/driceroland/Search/issues/907))*
- [x] **History suggestions weigh frequency** Places you visit often rank above ones seen once. *([#944](https://github.com/driceroland/Search/pull/944))*
- [x] **Choose the translation language** Settings › Browsing › Pages: which language pages are translated into. *([#821](https://github.com/driceroland/Search/pull/821))*
- [x] **Small windows reopen where left** A link's small window opens at the place and size it was last left, centred if that screen is gone. *([#789](https://github.com/driceroland/Search/pull/789))*
- [x] **Links from apps find their open tab** With links from other apps in a small window, a link to a page already open goes to its tab. Off by default. *([#798](https://github.com/driceroland/Search/pull/798))*
- [x] **Muted video floats on desktop switch** A muted video WebKit paused out of sight floats when you go to another desktop; one paused by hand stays. *([#791](https://github.com/driceroland/Search/pull/791))*

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
- [ ] **iCloud Passwords keeps its pairing** On macOS 27 iCloud Passwords asks for its code again every couple of minutes; the keep-alive no longer holds. *([#610](https://github.com/driceroland/Search/issues/610))*
- [ ] **History scrolling stutters in full screen** search://history scrolls smoothly in a window but stutters in full screen, worse with a Sidecar iPad connected. *([#730](https://github.com/driceroland/Search/issues/730))*
- [ ] **Dusk memory on restless pages** Dusk copies style sheets again and again on pages whose styles never settle, and keeps the old copies. *([#740](https://github.com/driceroland/Search/issues/740))*
- [ ] **Pins after closing windows quickly** Closing several windows fast can lose a pin and draw New Tab upside down. *([#750](https://github.com/driceroland/Search/issues/750))*

## Next — small additions people asked for

- [ ] **Box Tools** Let app.box.com reach its local helper on this Mac, as Chrome does. The person who asked offered to test a build. *(email)*
- [ ] **1Password desktop app, in the FAQ** 1Password with its desktop app. Say in the FAQ that Search is added in 1Password › Settings › Browser › Add Browser.
- [ ] **A user agent per tab** Presets and a string of your own, per tab, as in Safari's Develop menu; shares its plumbing with Responsive Design Mode. *([#460](https://github.com/driceroland/Search/issues/460))*
- [ ] **Icons drawn as SVG** A site whose only icon is an SVG shows a letter: only bitmap icons are decoded today. Draw SVG icons without opening a new decoder in the app. *([#680](https://github.com/driceroland/Search/issues/680))*
- [ ] **Links from another app's local page to localhost** A local file opened by another app that redirects to http://localhost stops there, while Safari and Firefox follow it. *([#775](https://github.com/driceroland/Search/issues/775))*
- [ ] **Split View opens and closes smoothly** No line before the pane slides in, no white frame and jump on close. *([#771](https://github.com/driceroland/Search/issues/771), X)*
- [ ] **No white flash in the side panel and between pages** Dark mode: the panel on opening and a tab moving to its next page stay dark. *([#768](https://github.com/driceroland/Search/issues/768))*
- [ ] **Floating video only when the page is out of sight** Side by side with another app or on a second display, the video stays in its page. *([#761](https://github.com/driceroland/Search/issues/761))*
- [ ] **A snappier hidden sidebar** Shorter slide, window buttons arrive with the column. *([#760](https://github.com/driceroland/Search/issues/760))*
- [ ] **Signed-out spaces keep their own history** A page visited in one signed-out space doesn't show in another's history or suggestions. *([#758](https://github.com/driceroland/Search/issues/758))*
- [ ] **Link actions on a right-clicked image** Open the image in a new tab or a split, copy its address, as with ⌘-click. *([#756](https://github.com/driceroland/Search/issues/756))*
- [ ] **A very long group fills the whole column** A group with hundreds of tabs pushes everything out of reach; it should scroll inside the column. *([#755](https://github.com/driceroland/Search/issues/755))*
- [ ] **Video in a peek turns black** Opening a peek's video player, then a link under the video, leaves a black layer over it. *(email)*
- [ ] **Tabs in a group shift when swiping spaces** The indent of a group's tabs moves on every swipe between spaces. *(email)*
- [ ] **Split View from a tab dropped on a tab** Dropping a tab onto another tab in the column only reorders; a hint or a split there would make Split View easier to find. *(email)*
- [ ] **Always-on settings apart in Settings search** Results that can't be changed show in their own section, so they don't look like a bug. *(email)*
- [ ] **Saved cards in payment fields** Offer saved cards under a card field, Stripe's frames included, filled after Touch ID. Safari's saved cards aren't open to other apps, so Search keeps its own, in the keychain. *(X)*
- [ ] **YouTube asks for cookies in every new tab** *([#779](https://github.com/driceroland/Search/issues/779))*
- [ ] **AirDrop sheet freezes** *([#792](https://github.com/driceroland/Search/issues/792))*
- [ ] **New tab field keeps the cursor while a page loads** *([#796](https://github.com/driceroland/Search/issues/796))*
- [ ] **Address suggestions match inside the address** Typing a word from the middle of an address, like a page's name, suggests it. *([#796](https://github.com/driceroland/Search/issues/796))*
- [ ] **1Password sign-in unstable** *([#802](https://github.com/driceroland/Search/issues/802))*
- [ ] **Best Buy sign-in** *(email)*
- [ ] **OpenAI sign-in page** *(email)*
- [ ] **Bitwarden asks for WebAssembly** *(email)*
- [ ] **The − on a closed pin does nothing** Hovering a pin that is already put down still shows − *(email)*
- [ ] **A pin opened and closed quickly keeps spinning** The loading sign loops until the page is let finish loading *(email)*
- [ ] **Floating video for Google Drive** Drive's player sits in a youtube.googleapis.com frame *([#851](https://github.com/driceroland/Search/issues/851))*
- [ ] **Client certificates for sign-in** Government sites in Spain and Europe; no picker today *([#847](https://github.com/driceroland/Search/issues/847))*
- [ ] **Choose the translation language** *([#821](https://github.com/driceroland/Search/pull/821))*
- [ ] **Closing a pin in the switcher shows nothing** W in the tab switcher puts a pin down but its card looks the same, so it seems nothing happened. *(email)*
- [ ] **The hidden elements' list holds the page still** With the list open the page can't scroll, and resting on a line scrolls the page to it with no way back to where you were. *(email)*
- [ ] **⌘T's floating field loses the caret on macOS 14** With New tab in a floating field on, on macOS 14 and an Intel Mac, the field takes the caret for a moment after ⌘T and then loses it. *(email)*
- [ ] **Back closes a tab a link opened** Back, or the swipe back, on a tab with nothing to go back to closes it and returns to the tab that opened it, as in Arc and Safari. As an option. *([#921](https://github.com/driceroland/Search/issues/921), [#759](https://github.com/driceroland/Search/issues/759))*
- [ ] **Drag a download out of Downloads** A finished download whose file is still there can be dragged to Finder or another app, as a file. *([#920](https://github.com/driceroland/Search/issues/920))*
- [ ] **Remember a site's choice to open an app** A box in the Open app question to always let that site open that app, listed in Settings › Privacy with Remove. *([#909](https://github.com/driceroland/Search/issues/909))*
- [ ] **Open Link in Private Tab** In a link's right-click menu, after Open Link in New Tab, as the bookmarks bar already has it. *([#902](https://github.com/driceroland/Search/issues/902))*
- [ ] **Escape stays with the page in full screen** In the window's own full screen (the green button, ⌃⌘F), one Escape takes the window out of full screen even when a site wanted it, to close its own pop-up. Safari leaves the window as it is and gives the key to the page; only a video's full screen goes at one Escape. Needs checking against Press Esc twice to leave full screen, which keeps the first press from the page. *([#981](https://github.com/driceroland/Search/issues/981))*
- [ ] **Fill in your contact details** Off by default: a box for your name, email, phone or address offers your own card in Contacts, filled on a click, as Safari does. *([#925](https://github.com/driceroland/Search/pull/925))*

## Later — bigger pieces of work

- [ ] **More extension APIs** More of the extension APIs. The side panel, and invisible offscreen documents ([#192](https://github.com/driceroland/Search/pull/192)). *([#12](https://github.com/driceroland/Search/issues/12), X, [#192](https://github.com/driceroland/Search/pull/192) ×2, [#273](https://github.com/driceroland/Search/issues/273), [#351](https://github.com/driceroland/Search/issues/351), [#352](https://github.com/driceroland/Search/pull/352), [#484](https://github.com/driceroland/Search/issues/484))*
- [ ] **Faster animations** Spaces especially, compared with Zen. *(email)*
- [ ] **Extensions per space** Each space with the extensions it wants, on and off apart from the others. WebKit has one extension controller for the whole app, so this means one per space. Drice's call, 24 Sep: later. *(X)*
- [ ] **User scripts fail on GitHub** Tampermonkey runs each script through an inline script, and WebKit holds it to the page's content security policy, where Chrome exempts it; GitHub's policy blocks it. No safe narrow fix yet. *([#289](https://github.com/driceroland/Search/issues/289), [#319](https://github.com/driceroland/Search/issues/319))*
- [ ] **Optional ad-blocking add-on** A stronger blocker as an optional add-on in Settings, downloaded on demand so it only takes space for those who want it. Search's built-in blocker stays as it is meanwhile. *(message, [#738](https://github.com/driceroland/Search/pull/738))*
- [ ] **Unsaved text on move to window** A tab moved into a window that shows another space signs in with that space, as Move to Space does; unlike Move to Space, it doesn't first ask about text typed and not sent.
- [ ] **Little window: blocker and passwords** A page in the small window for outside links doesn't get the ad blocker's per-site settings or the accounts list under a sign-in box until it is moved into your tabs.
- [ ] **Pin a tab group** A whole tab group kept like a pin: several Slacks, each with its client's sites, told apart and kept. *([#392](https://github.com/driceroland/Search/issues/392), email)*
- [ ] **Tabs shared across windows** A space's tabs belong to the space, and any window can show them, with a stand-in where a tab is open in another window, as in Arc. Pins already are the same in every window. *([#417](https://github.com/driceroland/Search/issues/417))*
- [ ] **A picture behind the new tab** An image behind the new tab page, perhaps from Unsplash. Off unless turned on, if it ever comes. *([#447](https://github.com/driceroland/Search/issues/447))*
- [ ] **Main process grows over days** The app's own process grew to several times its fresh size over a week of use; find what accumulates (closed windows, caches).
- [ ] **Small windows: alone and keyed** A link small window opens alone, takes its keys, closes with a swipe back, cascades, and shows in the switcher. *([#431](https://github.com/driceroland/Search/pull/431), [#519](https://github.com/driceroland/Search/pull/519), [#474](https://github.com/driceroland/Search/pull/474), [#493](https://github.com/driceroland/Search/pull/493), [#480](https://github.com/driceroland/Search/pull/480))*
- [ ] **Proxy for the whole browser** HTTP and SOCKS5 proxy in Settings, off by default, everything through it. *([#510](https://github.com/driceroland/Search/pull/510))*
- [ ] **Float a whole page** Any page, not only a video, in the floating window, and meetings that float when you switch away. Off unless turned on. *([#584](https://github.com/driceroland/Search/pull/584))*
- [ ] **One window per space** A switch so each space opens in a window of its own. *([#611](https://github.com/driceroland/Search/issues/611))*
- [ ] **Why a tab stays awake** A small view listing which tabs sleep and why the others stay awake. Off by default. *([#624](https://github.com/driceroland/Search/issues/624), [#628](https://github.com/driceroland/Search/pull/628))*
- [ ] **A quick drawer to switch spaces** Click the space mark for a small panel of spaces to switch, drag to reorder and add; settings move to a right-click. *([#682](https://github.com/driceroland/Search/issues/682))*
- [ ] **Raycast extension** Search tabs, spaces and bookmarks from Raycast. Search already speaks AppleScript (Search.sdef), so an extension can be built on it; idea 389 brings a tab to the front. *(email)*
- [ ] **Open in another browser** Right-click a link, a tab or a bookmark › Open in Chrome, Firefox or another browser installed on the Mac, as Orion and Quiche do. *(email)*
- [ ] **Hide the buttons under the column** Choose which of the buttons at the foot of the column show: extensions, bookmarks, profiles. *(email)*
- [ ] **Sleep tabs by memory** When Search's pages pass a share of the Mac's memory, the least recently used tabs sleep first, like Chrome's Memory Saver. Off by default. *(X)*
- [ ] **A tab's memory on hover** Hovering a tab shows how much memory its page uses, as in Chrome. Off by default. *(X)*
- [ ] **Screenshot tool** Take a picture of a page or part of it, as Arc's capture did. *(email, [#753](https://github.com/driceroland/Search/issues/753))*
- [ ] **Swipe past the last space goes round** Swiping past the last space opens the new space form; an option to go back to the first space instead, so a swipe goes round the spaces. *(email)*
- [ ] **Developer mode for a site** Mark a site (a domain or subdomain, like a staging server) as in development, as Arc did: its tabs are tinted, and a small bar shows the address with a screenshot button and the inspector. *(email)*
- [ ] **Private tabs that look private** A private tab is hard to tell from a normal one: a darker frame or a ghost icon while on it. *(email)*
- [ ] **Translate into a language of your own** Translate Page into a chosen language instead of the Mac's, System Default unless changed. *([#747](https://github.com/driceroland/Search/issues/747))*
- [ ] **Clear recently closed too** Clear Browsing Data could also empty Recently Closed and close open tabs. *([#749](https://github.com/driceroland/Search/issues/749))*
- [ ] **search:// links from other apps** Link routers, Raycast or Shortcuts open a link in a space, a profile or a private tab. Never from a web page. *([#770](https://github.com/driceroland/Search/issues/770))*
- [ ] **Side panel site per space, kept loaded** Each space remembers its own panel site; closing the panel keeps the page. *([#769](https://github.com/driceroland/Search/issues/769))*
- [ ] **Export and import settings** One file with settings, shortcuts, search sites, and optionally pins and spaces. *([#763](https://github.com/driceroland/Search/issues/763), [#845](https://github.com/driceroland/Search/pull/845))*
- [ ] **Suggestions match anywhere, with typos** The address field finds words inside titles and addresses, and commands from part of their name. *([#762](https://github.com/driceroland/Search/issues/762))*
- [ ] **Groups inside groups** Sub-folders in the column, as in Arc, kept on import. *([#754](https://github.com/driceroland/Search/issues/754))*
- [ ] **Other app icons** A few icons to pick from for the Dock. *(email)*
- [ ] **⌘-clicked links group under their tab** Tabs opened with ⌘-click from one page gather in a group with it, as in Dia. Off by default. *(email)*
- [ ] **crxMouse Gestures editor goes blank** *([#778](https://github.com/driceroland/Search/issues/778))*
- [ ] **Picture in picture buttons slightly off** *([#785](https://github.com/driceroland/Search/issues/785))*
- [ ] **New tab field fades out** *([#786](https://github.com/driceroland/Search/issues/786))*
- [ ] **Launcher from other apps** An optional shortcut that opens a small field from any app to find a tab or open a page. *([#783](https://github.com/driceroland/Search/issues/783))*
- [ ] **Spaces: name, colour and more** *([#806](https://github.com/driceroland/Search/issues/806))*
- [ ] **Pins in every space stay signed in** *([#808](https://github.com/driceroland/Search/issues/808))*
- [ ] **Warn before downloading twice** *([#829](https://github.com/driceroland/Search/issues/829))*
- [ ] **Show that a download started** *([#830](https://github.com/driceroland/Search/issues/830))*
- [ ] **VPN extensions** *([#831](https://github.com/driceroland/Search/issues/831))*
- [ ] **Zotero Connector** *(email)*
- [ ] **Neat Download Manager** *(email)*
- [ ] **Todoist and Clockify extensions** *(email)*
- [ ] **Dia pins and spaces import** *(email)*
- [ ] **Full screen on ⌃⌘F** *(email)*
- [ ] **Your own CSS and JS for a site, like Arc's Boosts** Built in, no extension needed; edit what you wrote; off by default *(email)*
- [ ] **Bigger text in the sidebar** Sidebar tab titles feel small; no way to size them *(email)*
- [ ] **A button to dock or float the sidebar** As ⌘S does, from the sidebar itself *([#852](https://github.com/driceroland/Search/issues/852))*
- [ ] **One live pin shared by every space** A pin kept in every space could be one tab, the same page and playback in each space, rather than a copy per space. As an option. *([#875](https://github.com/driceroland/Search/issues/875))*
- [ ] **Open a tab in a little window** The little window links from other apps open in, for a tab or a link from inside Search too, to move and keep beside the main window. *([#874](https://github.com/driceroland/Search/issues/874))*
- [ ] **A picked tab stays under its folded group** Picking a tab from a folded group keeps that one tab showing under the group's header, until it's put away. *([#873](https://github.com/driceroland/Search/issues/873))*
- [ ] **Camera and microphone shown on their tab** A tab using the camera or microphone says so on the tab, with a way to pause each. *([#870](https://github.com/driceroland/Search/issues/870))*
- [ ] **Hide the profile mark in the column** With profiles in one window, an option to show only the space's mark, for one space per profile. *([#867](https://github.com/driceroland/Search/issues/867))*
- [ ] **Search's own video controls** Plain controls of Search's over a site's own video player, for sites whose controls get in the way. *([#862](https://github.com/driceroland/Search/issues/862))*
- [ ] **The folded column slides out** The column folded away appears at once at the window's edge; it could slide out, as it did in Arc. *(email)*
- [ ] **Option-click opens a link in Split View** A chosen modified click on a link opens it beside the page in Split View, as in Dia. Off unless chosen, since Option-click downloads a link in Safari. *([#975](https://github.com/driceroland/Search/issues/975))*
- [ ] **Back and Forward kept across a relaunch** Each tab comes back after a quit with its page only; keep its Back and Forward list too, as other browsers do. *([#893](https://github.com/driceroland/Search/issues/893))*
- [ ] **Page scripts set up once per tab** A tab removes and adds back all of Search's own page scripts on every veil or style change; set the fixed ones up once. *([#859](https://github.com/driceroland/Search/issues/859))*
- [ ] **ChatGPT's side panel signed in** ChatGPT's panel needs its site's cookies in a frame under the extension page; waits on a WebKit fix. *([#837](https://github.com/driceroland/Search/issues/837))*

## Pull requests to review

- [ ] **Send links to a space** Links from chosen sites open in a given space, with its sign-ins, as Arc's Air Traffic Control does. *(email, [#595](https://github.com/driceroland/Search/issues/595) ×2, [#596](https://github.com/driceroland/Search/pull/596), [#721](https://github.com/driceroland/Search/issues/721), [#722](https://github.com/driceroland/Search/pull/722))*
- [ ] **uBlock blocks from the first second after launch** Session rules set again at every launch recompile every rule, and new tabs go unblocked meanwhile. *([#711](https://github.com/driceroland/Search/pull/711))*
- [ ] **Redraw only what changed** Typing, Find and swipes redraw only the views that show them; rows stop observing the whole browser. *([#706](https://github.com/driceroland/Search/pull/706))*

## Drice's call

- [ ] **The page behind a new tab** The page you came from stays visible behind the new tab, as in Arc. *([#465](https://github.com/driceroland/Search/issues/465), [#683](https://github.com/driceroland/Search/issues/683))*
- [ ] **A pinned tab in a group** Move a pinned tab into a tab group without unpinning it first, as Arc's pinned folders allow. *([#692](https://github.com/driceroland/Search/issues/692))*
- [ ] **Peek into a folded group** Rest the pointer on a folded group to see its tabs in a small list and pick one, as in Arc's folder previews. Off unless turned on. *([#690](https://github.com/driceroland/Search/issues/690))*
- [ ] **Bring a tab to the front from a script** A tab id and one focus command in the AppleScript dictionary, so a launcher such as Raycast can switch to a tab. Everything else stays read-only. *([#684](https://github.com/driceroland/Search/issues/684))*

## Asked to try again on the latest version

- [ ] **Google sign-in flashes with Proton Pass** With Proton Pass signed in, Google's sign-in page reloads every half second. Presumed fixed in 1.0.2 by [#126](https://github.com/driceroland/Search/pull/126) and the passkey changes; to confirm with the person who saw it. *(X)*
- [ ] **Passkey from a phone** Signing in with a passkey held on an iPhone (the QR code) fails, here on an Apple Account sign-in. *([#679](https://github.com/driceroland/Search/issues/679))*
- [ ] **1Password's unlock doesn't open** With 1Password locked, its button in a field and the toolbar button open nothing. *([#685](https://github.com/driceroland/Search/issues/685))*
- [ ] **Bitwarden says WebAssembly isn't supported** Bitwarden's popup refuses to start on some Macs; waiting on the macOS version and the popup's console. *([#716](https://github.com/driceroland/Search/issues/716))*
- [ ] **NordPass** The NordPass extension doesn't work. *(X)*
- [ ] **Google Docs scrolls slowly while editing** Scrolling a document in edit mode stutters; in view mode it's fine. *(email)*
- [ ] **Ghostery misses some ads** Ghostery blocks less reliably than in Chrome or Safari. *(email)*

## Just in, not sorted yet

- [ ] **Bookmarks bar: move and new folder** Rearrange bookmarks on the bar itself (the bar now moves the window, so perhaps with a key held) and make a folder from the bar. *(email)*
- [ ] **Links from a pin open a new tab** A link followed from a pinned tab opens beside it, so the pin stays on its page. *(email)*
- [ ] **Bookmarks per space** Each space keeps bookmarks of its own. *(email ×2)*
- [ ] **Window colours** A colour for the window, or for each space, with a light and a dark version, as in Helium and Arc. *(email ×3)*
- [ ] **Extension side panels** Extensions that open in Chrome's side panel, like ChatGPT's and Claude's, have nowhere to open: WebKit has no side panel. *(email)*
- [ ] **Group tabs by dropping one on another** Drop a tab onto another in the column and the two become a group. *(email)*
- [ ] **One place for ⌘T, ⌘K and ⌘Y** New tab, the open tabs and history reached from a single field. *(email)*
- [ ] **Open tabs from Helium** Bringing things over from Helium takes its bookmarks, history, passwords and extensions, but not the tabs it has open. *(email, [#840](https://github.com/driceroland/Search/issues/840), [#841](https://github.com/driceroland/Search/pull/841))*
- [ ] **⌘L again closes the address** A second ⌘L puts away the address field it opened, as Esc does. *(email)*
- [ ] **Tabs that pause, not reload** An option to keep a resting tab's page and let WebKit suspend it, off by default. *([#520](https://github.com/driceroland/Search/issues/520))*
- [ ] **Option-Command arrows to move between tabs** *([#532](https://github.com/driceroland/Search/issues/532))*
- [ ] **Share the screen with its sound** WebKit gives a shared screen no sound track, even when a call asks for one; it would mean capturing the sound ourselves and feeding it to the page. *([#540](https://github.com/driceroland/Search/issues/540))*
- [ ] **Floating video flickers popping out** The video shifts and flickers as it pops out of the page. *([#543](https://github.com/driceroland/Search/issues/543), [#547](https://github.com/driceroland/Search/pull/547), [#562](https://github.com/driceroland/Search/pull/562), [#584](https://github.com/driceroland/Search/pull/584))*
- [ ] **Float a meeting page when you switch away** *([#544](https://github.com/driceroland/Search/issues/544), [#547](https://github.com/driceroland/Search/pull/547))*
- [ ] **CleanMyMac flags Search as unwanted** CleanMyMac's "Mac Search - PUA" is a false positive: Search is a notarised Developer ID app, and MacPaw has been told. *([#556](https://github.com/driceroland/Search/issues/556))*
- [ ] **YouTube dislike counts don't show** Return YouTube Dislike installs but its counts never appear on YouTube; a userscript doing the same works. *([#588](https://github.com/driceroland/Search/issues/588))*
- [ ] **Some sites stay on http** Choose hosts that are never sent to https. *([#671](https://github.com/driceroland/Search/issues/671))*
- [ ] **PDFs sent as downloads open in a tab** A setting to show a PDF the site sends as a download, with Save still there, off by default. *([#672](https://github.com/driceroland/Search/issues/672))*
- [ ] **Trackpad taps for spaces and tabs** A light tap from the trackpad when a space swipe, a tab drag or the column's edge crosses the point where letting go changes something, as the back swipe and Split View's divider already do. *([#695](https://github.com/driceroland/Search/issues/695))*
- [ ] **Choose which space comes first** Pick the space Search opens on and lists first, instead of the original first space. *(email)*
- [ ] **Rounded corners in full screen** An option to keep the page as a card, with its rounded corners, in full screen. *(email)*
- [ ] **The page as a card with tabs across the top** The card around the page (Settings › Appearance) is offered only with tabs in the column; asked for with tabs across the top too. *([#712](https://github.com/driceroland/Search/issues/712))*
- [ ] **Drag a tab to another window** Drag a tab from one window's tabs into another open window, as its menu's Move to Window does now. *([#734](https://github.com/driceroland/Search/issues/734))*
- [ ] **Choose Left or Right under vertical tabs** Settings › Appearance › Tabs as two levels: across the top or down the side, then which side, then icons only. *([#728](https://github.com/driceroland/Search/issues/728))*
- [ ] **Page menu items in the tab's right-click menu** Sound, keep alive and the other page settings also reachable from a tab's right-click menu, and from the icons-only column, where a click doesn't open the address field's menu. *([#728](https://github.com/driceroland/Search/issues/728))*
- [ ] **Pinned extensions in the icons-only column** The icons-only column shows only the puzzle; pinned extensions could stand under it. *([#728](https://github.com/driceroland/Search/issues/728))*

## Not on the list, for now

- **Web processes start before the window** The web process pool is made before the first window; check whether 1.0.2's launch order already covers it. Measured at about 1.5 ms on macOS 26 (8–9 ms on macOS 27): not worth the change it needs. *([#157](https://github.com/driceroland/Search/issues/157))*
- **Hidden sidebar closes too soon** It closes while the pointer is over the extension buttons at its foot. Maybe fixed by [#115](https://github.com/driceroland/Search/pull/115) in 1.0.2; unconfirmed. No reply; reopen anytime. *(email)*
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
- **Accounts and sync** Bookmarks with Google, tabs across devices. Search has no server and keeps everything on your Mac; importing is the way in. *([#224](https://github.com/driceroland/Search/issues/224), email ×2, [#488](https://github.com/driceroland/Search/issues/488), [#674](https://github.com/driceroland/Search/issues/674))*
- **Page slides with the sidebar** The page moves with the sidebar as it opens instead of redrawing in steps, with no gap at the edge; the PR also adds a speed setting. Since 0469c15 the page already slides with the column and is resized once; no speed setting, Settings stays short. *([#252](https://github.com/driceroland/Search/pull/252))*
- **Touch Bar controls** Back, forward, reload, the tabs and a new tab button on the Touch Bar, stepping aside when a field or video needs it. Not planned: Search stays minimal. *([#274](https://github.com/driceroland/Search/issues/274), [#275](https://github.com/driceroland/Search/pull/275))*
- **A name that's easier to find** “Search” is hard to find when searching for a browser; a more distinctive name is suggested. The name stays Search. Where it has to be found, it's Search Browser, or Search by Office Commun. *([#276](https://github.com/driceroland/Search/issues/276), [#676](https://github.com/driceroland/Search/issues/676))*
- **A new look for the back swipe** The swipe back and forward draws a shape pulled out of the edge that follows the fingers, instead of arrows sliding the other way. Not planned: Search stays minimal. *([#281](https://github.com/driceroland/Search/issues/281), [#282](https://github.com/driceroland/Search/pull/282))*
- **Back closes a link's own tab** Back from the first page of a tab a link opened closes that tab and returns to the page it came from. Not planned: Search stays minimal. *([#283](https://github.com/driceroland/Search/pull/283), [#759](https://github.com/driceroland/Search/issues/759))*
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
- **Each checkout tests in its own world** Build tests from two checkouts no longer share one test world. The tests' harness already gives each checkout its own world; moving Store.world's default would move every session's at once *([#497](https://github.com/driceroland/Search/pull/497))*
- **Tabs tinted by their site** Each tab in the column tinted with its site's colour. Search keeps the column plain; a window colour of your own is on the list instead. *([#748](https://github.com/driceroland/Search/issues/748))*
