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

- [ ] **Import an .html bookmarks file** Bookmarks from an .html file, passwords from a .csv, and Safari's own export (File › Export Browsing Data): ready, lands after 1.0.4. *(email ×2)*
- [ ] **Import from Helium, Firefox, Zen** Helium is in the next version. Firefox and Zen — bookmarks, history and passwords — are ready and land after 1.0.4. *([#178](https://github.com/driceroland/Search/pull/178), [#215](https://github.com/driceroland/Search/pull/215), email ×3)*

## Done, in the next version

- [x] **Bitwarden goes blank after sign-in** For one person it doesn't load at all. Before signing in it works — popup, WebAssembly, background. Probably fixed by 1Password's worker fix ([#126](https://github.com/driceroland/Search/pull/126)) and the extension storage fix in 1.0.2; needs a real account to confirm. Also asked: a self-hosted Vaultwarden server behind the extension. *(X, email ×2, [#343](https://github.com/driceroland/Search/pull/343))*
- [x] **iCloud Passwords** Pairs on the first code and stays paired: its first messages now wait for Apple's helper, and an extension talking to an app on the Mac stays awake, as in Chrome. Tested with a stand-in helper; to confirm with Apple's own in the next build. *([#17](https://github.com/driceroland/Search/issues/17), email ×3, [#217](https://github.com/driceroland/Search/pull/217), [#250](https://github.com/driceroland/Search/issues/250))*
- [x] **Early content scripts miss restored pages** A content script that runs at document_start can miss the page restored at a hidden launch. *([#199](https://github.com/driceroland/Search/issues/199))*
- [x] **Suggestions slow with a big history** Address suggestions slow down with a large history. *([#200](https://github.com/driceroland/Search/issues/200), [#306](https://github.com/driceroland/Search/pull/306))*
- [x] **Bookmarks popover closes on fold** The bookmarks popover closes when the hidden sidebar folds (it counts as leaving the sidebar). A fix is waiting in [#89](https://github.com/driceroland/Search/pull/89). *([#88](https://github.com/driceroland/Search/issues/88), [#89](https://github.com/driceroland/Search/pull/89))*
- [x] **Settings sidebar corners** The Settings sidebar has rounded inner corners. A fix is waiting in [#222](https://github.com/driceroland/Search/pull/222). *([#221](https://github.com/driceroland/Search/issues/221), [#222](https://github.com/driceroland/Search/pull/222), [#226](https://github.com/driceroland/Search/issues/226))*
- [x] **⇧⌘C copies without a word** ⇧⌘C copies the address, but nothing in the app says so. A fix is waiting in [#182](https://github.com/driceroland/Search/pull/182). *([#176](https://github.com/driceroland/Search/issues/176), [#182](https://github.com/driceroland/Search/pull/182))*
- [x] **Import from Comet** Alongside Chrome, Arc, Brave, Edge and Dia. *(X, [#301](https://github.com/driceroland/Search/pull/301))*
- [x] **Hard reload with ⌥⌘R** ⌘R reloads, ⇧⌘R reloads from the network. Waiting in [#179](https://github.com/driceroland/Search/pull/179). *([#171](https://github.com/driceroland/Search/issues/171), [#179](https://github.com/driceroland/Search/pull/179))*
- [x] **Reduce motion** Reduce motion for Search's own interface. Two pull requests do it ([#187](https://github.com/driceroland/Search/pull/187), [#210](https://github.com/driceroland/Search/pull/210)); one is to be picked. *([#186](https://github.com/driceroland/Search/issues/186), [#187](https://github.com/driceroland/Search/pull/187), [#210](https://github.com/driceroland/Search/pull/210))*
- [x] **Default page zoom** One zoom for every site, in Settings › General. *([#177](https://github.com/driceroland/Search/pull/177), [#355](https://github.com/driceroland/Search/pull/355))*
- [x] **Links from other apps skip the pins** A link opened from another app never lands among the pins. *([#219](https://github.com/driceroland/Search/issues/219), [#245](https://github.com/driceroland/Search/pull/245))*
- [x] **Double-click for a new tab** A double-click below the tabs opens a new one. *([#162](https://github.com/driceroland/Search/issues/162), [#167](https://github.com/driceroland/Search/pull/167))*
- [x] **Toolbar buttons on the left** Back, forward and reload on the left with the tabs across the top. *(email, [#297](https://github.com/driceroland/Search/issues/297), [#298](https://github.com/driceroland/Search/pull/298))*
- [x] **NordPass doesn't work** *([#98](https://github.com/driceroland/Search/issues/98), [#323](https://github.com/driceroland/Search/pull/323))*
- [x] **Little window for outside links** A little window for links opened from other apps, and a shortcut to open it from anywhere. *(X, [#227](https://github.com/driceroland/Search/pull/227))*
- [x] **⌥⌫ with an inline completion** With the rest of an address offered inline, Option-Backspace does nothing; it should drop the offer and delete the last word typed. *([#228](https://github.com/driceroland/Search/issues/228), [#244](https://github.com/driceroland/Search/pull/244))*
- [x] **Pop-ups named by their site** A window a page opens at a size of its own is named in the tabs by its site, not by the title the page chose. *(message)*
- [x] **A bookmark with a bad address crashes** Clicking a bookmark whose address is missing or unreadable, as an extension can leave one, crashed the window; it now does nothing instead. *([#234](https://github.com/driceroland/Search/pull/234))*
- [x] **A build that can't sign says it's done** An unsigned build without a certificate reported a finished app even when signing failed; it now stops and shows why. *([#235](https://github.com/driceroland/Search/pull/235))*
- [x] **Passwords panel reads every secret** Opening the passwords panel read each saved password just to draw the list, one keychain call per row; the list now reads only sites and accounts, and a password only when asked for. *([#237](https://github.com/driceroland/Search/pull/237))*
- [x] **Second click reopens an extension popup** Clicking a pinned extension's button while its popup is open closed and reopened it; the second click now leaves it closed. *([#248](https://github.com/driceroland/Search/pull/248))*
- [x] **Extension popup opens away from its button** After switching between tabs on top and in a sidebar, a pinned extension's popup could open away from its button. *([#254](https://github.com/driceroland/Search/pull/254))*
- [x] **Zoom's “Join from app” does nothing** The button on Zoom's meeting page that should open the Zoom app does nothing in Search. *([#255](https://github.com/driceroland/Search/issues/255))*
- [x] **Connection details get cut off** The site information panel kept its first size, so the connection details were clipped; it now fits them. *([#258](https://github.com/driceroland/Search/pull/258))*
- [x] **Editing an address drops part of it** Clicking a tab's address to edit it lost the port, the query, the #fragment and plain http, so Return went to the wrong page. *([#264](https://github.com/driceroland/Search/pull/264), email)*
- [x] **A tab that never finishes loading uses CPU** A page that never finishes loading kept Search at about 20% CPU, even in the background, because its loading ring redrew the window every frame. *([#268](https://github.com/driceroland/Search/issues/268), [#269](https://github.com/driceroland/Search/pull/269))*
- [x] **Scrolling costs more than in Safari** Each frame of a scroll made Search redraw its window and report the caret, so scrolling cost Search's app about 2.5 times what it costs Safari. *([#270](https://github.com/driceroland/Search/issues/270), [#271](https://github.com/driceroland/Search/pull/271), [#287](https://github.com/driceroland/Search/pull/287), email)*
- [x] **Sideways mouse wheel changes space** A mouse's sideways or thumb wheel moves from one space to the next in the sidebar, as two fingers do on a trackpad. *([#272](https://github.com/driceroland/Search/pull/272))*
- [x] **Docked Web Inspector lost on tab switch** With the Web Inspector docked, switching tabs and back left the page short above an empty space and the inspector gone. *([#278](https://github.com/driceroland/Search/pull/278))*
- [x] **Floating video needs two clicks to drag** The floating video only dragged or resized on the second click; the first one now works. *([#279](https://github.com/driceroland/Search/pull/279), email)*
- [x] **PDF download button does nothing** The download button in the bar over a PDF did nothing; it now saves the file where downloads go. *([#290](https://github.com/driceroland/Search/pull/290))*
- [x] **⌘← leaves the page from a frame's text box** With the caret in a text box inside a frame, ⌘← and ⌘→ went back and forward in history and lost what was typed. *([#293](https://github.com/driceroland/Search/pull/293), [#324](https://github.com/driceroland/Search/issues/324))*
- [x] **“Open Link in New Window” opens a tab** The link menu said New Window but opened a new tab; it now says New Tab. *([#295](https://github.com/driceroland/Search/issues/295), [#296](https://github.com/driceroland/Search/pull/296))*
- [x] **Passbolt doesn't work** Passbolt's popup opens tiny and empty, and its setup page never shows. *([#300](https://github.com/driceroland/Search/issues/300))*
- [x] **Native helpers set up for Vivaldi or Opera** An extension whose helper app registered with Vivaldi or Opera couldn't reach it; those folders are read too. *([#302](https://github.com/driceroland/Search/pull/302))*
- [x] **Move a tab to another space** Right-click a tab › Move to Space, keeping the tab and its history. *([#303](https://github.com/driceroland/Search/issues/303), [#332](https://github.com/driceroland/Search/pull/332))*
- [x] **Passkeys drop the PRF extension** Sites that derive a key from a passkey get no PRF result in Search and treat the passkey as unsupported. *([#312](https://github.com/driceroland/Search/issues/312), [#313](https://github.com/driceroland/Search/pull/313))*
- [x] **Middle-click a bookmark** A middle-click on a bookmark opens it in a new background tab; with ⇧, it switches to it. *([#315](https://github.com/driceroland/Search/issues/315), [#316](https://github.com/driceroland/Search/pull/316))*
- [x] **Extension popups blank or refused** 1.0.3 loaded extension popups from a copy, which Dark Reader, Bitwarden's two-step code and others refused, and some came up blank. 1.0.4 loads them from their own address again. *([#320](https://github.com/driceroland/Search/issues/320), email ×3)*
- [x] **⇧⌘⌫ opens Clear Browsing Data** A shortcut and a History menu item open the existing clearing controls; nothing is cleared until chosen. *([#336](https://github.com/driceroland/Search/issues/336), [#338](https://github.com/driceroland/Search/pull/338), [#344](https://github.com/driceroland/Search/pull/344))*
- [x] **⌘← and ⌘→ stopped going back** Since pages get their shortcuts first, WebKit kept ⌘←/⌘→. Fixed in 959e7b8. *([#324](https://github.com/driceroland/Search/issues/324))*
- [x] **0.0.0.0 and .local addresses don't open** Dev servers print 0.0.0.0; WebKit refused it silently. Opened as localhost now; [::1], .local and 172.16/12 over http. 982886f. *(X)*
- [x] **Links from Notion leave Search behind** Electron apps don't hand the front over; Search asks again. 14defb9, unverified on screen. *(X)*
- [x] **Import from Chrome's channels and Opera** Chrome Beta, Dev and Canary, Opera and Opera GX are found and brought in like Chrome.
- [x] **Import misses some profiles** A Chrome profile with bookmarks or history but no saved passwords wasn't found, nor a browser keeping its profile in a folder of its own. When a browser is on the Mac but nothing is found, the welcome now says where Search looked. *(email)*

## Now — fixes for the next update

- [ ] **Bitwarden on Intel Macs** The extension says "WebAssembly is not supported" on an Intel Mac. *([#175](https://github.com/driceroland/Search/issues/175))*
- [ ] **Google sign-in flashes with Proton Pass** With Proton Pass signed in, Google's sign-in page reloads every half second. Presumed fixed in 1.0.2 by [#126](https://github.com/driceroland/Search/pull/126) and the passkey changes; to confirm with the person who saw it. *(X)*
- [ ] **Vimium C's keys do nothing** Its background starts from 1.0.4, where WebKit failed to load it; its keys don't answer yet. The original Vimium works meanwhile. *(X, email, [#170](https://github.com/driceroland/Search/pull/170))*
- [ ] **Passkeys under the sign-in field** A site's passkey button brings up the Mac's passkey sheet now; next is the suggestion Safari shows as you click into a sign-in field. *([#17](https://github.com/driceroland/Search/issues/17), X)*
- [ ] **Window stutters between screens** Dragging the window from one screen to another stutters. Needs a trace recorded on two screens. *(X)*
- [ ] **⌘F lands on the back button** On some pages ⌘F focuses the back button instead of the find field. *([#172](https://github.com/driceroland/Search/issues/172))*
- [ ] **Wrong icons on some tabs** Meta AI shows Google's G, Swagger UI stays on a letter. [#216](https://github.com/driceroland/Search/pull/216) fixes it; two small changes asked before it goes in. *([#181](https://github.com/driceroland/Search/issues/181), [#216](https://github.com/driceroland/Search/pull/216))*
- [ ] **Window flashes at its default size** At launch the window opens at its default size for an instant, then takes its saved size. [#204](https://github.com/driceroland/Search/pull/204) tried a fix; in a test it lost the saved size instead, so changes were asked. *([#202](https://github.com/driceroland/Search/issues/202), [#204](https://github.com/driceroland/Search/pull/204))*
- [ ] **Stuttering pages** Details to gather. *([#211](https://github.com/driceroland/Search/issues/211), [#357](https://github.com/driceroland/Search/issues/357), email)*
- [ ] **Floating video on Twitch, Netflix, X** Netflix: the picture now stays inside the floating window and subtitles show ([#190](https://github.com/driceroland/Search/pull/190), on main). Still open: part of the picture on Twitch, sometimes no picture on YouTube, only some of the time on X. *([#123](https://github.com/driceroland/Search/issues/123), email ×2, [#190](https://github.com/driceroland/Search/pull/190))*
- [ ] **Videos stuck muted** Some video sites play muted, with nothing to turn the sound on. *([#223](https://github.com/driceroland/Search/issues/223))*
- [ ] **Ad blocker leaves empty spaces** On news sites like AS.com, blocked ads leave gaps in the page. *([#159](https://github.com/driceroland/Search/issues/159))*
- [ ] **Chatbot pages struggle or crash** grok.com and other chatbot pages; details asked. *(email)*
- [ ] **Figma and LinkedIn feel slow** Figma blurs for a moment as you zoom in; LinkedIn's feed and profiles scroll with lag. *(email)*
- [ ] **Spaces sometimes don't switch** *(email)*
- [ ] **Hidden sidebar closes too soon** It closes while the pointer is over the extension buttons at its foot. Maybe fixed by [#115](https://github.com/driceroland/Search/pull/115) in 1.0.2; unconfirmed. *(email)*
- [ ] **Middle-click on YouTube links** A middle-click on YouTube links works only some of the time. 1.0.2 added middle-click on links; to confirm there. *(email)*
- [ ] **Extension popups miss messages** Extension popups and extension pages don't receive messages from the extension's background in a test run (the offscreen document does). To check in a window on screen; would matter for popups waiting on the background.
- [ ] **Dragging a pin redraws the column** Dragging a pin redraws the whole column each frame, as dragging a tab did before 1.0.2.
- [ ] **Your own keyboard shortcuts** In Settings › Shortcuts. Waiting on its author to rebase and simplify. Editing extension shortcuts belongs with it ([#189](https://github.com/driceroland/Search/issues/189)). *([#36](https://github.com/driceroland/Search/pull/36), [#189](https://github.com/driceroland/Search/issues/189), X, email ×2)*
- [ ] **Pins go back to their page** A pin goes back to the page it was pinned at when you put it down. *([#141](https://github.com/driceroland/Search/issues/141), email)*
- [ ] **Several windows** More than one window, each with its own tabs: ⌘N opens a new one, and a tab dragged out of the column or the bar becomes a window of its own. *([#184](https://github.com/driceroland/Search/pull/184), [#72](https://github.com/driceroland/Search/issues/72), [#230](https://github.com/driceroland/Search/issues/230), [#247](https://github.com/driceroland/Search/issues/247), [#291](https://github.com/driceroland/Search/pull/291), [#294](https://github.com/driceroland/Search/pull/294), email ×2)*
- [ ] **Sidebar on the right** The sidebar on the right. *(email, [#253](https://github.com/driceroland/Search/issues/253), [#314](https://github.com/driceroland/Search/pull/314), [#340](https://github.com/driceroland/Search/pull/340))*
- [ ] **Drag a tab into a new window** Comes with several windows. *([#72](https://github.com/driceroland/Search/issues/72))*
- [ ] **Hidden sidebar covers the window buttons** In full screen with the sidebar shown on hover, the close, minimise and zoom buttons can't be clicked. *([#241](https://github.com/driceroland/Search/issues/241))*
- [ ] **Floating video jumps on the way in and out** Floating a video, or landing it back in its tab, makes it jump in size and flicker, most visibly on YouTube. *([#246](https://github.com/driceroland/Search/issues/246), [#257](https://github.com/driceroland/Search/issues/257))*
- [ ] **Move & Resize greyed out** macOS's Window › Move & Resize commands and their shortcuts don't work on Search's window. *([#286](https://github.com/driceroland/Search/issues/286))*
- [ ] **User scripts fail on GitHub** ScriptCat's GM_xmlhttpRequest works in the next version (#319). Tampermonkey's scripts on sites with a strict content security policy still don't run: WebKit checks the script it inserts against the page's policy, and gives apps no way around it. In Tampermonkey, Sandbox Mode › JavaScript and DOM works today. *([#289](https://github.com/driceroland/Search/issues/289), [#319](https://github.com/driceroland/Search/issues/319))*
- [ ] **New folders and renaming in bookmarks** Renaming a bookmark or folder is in the next version (#342). New folders and folders inside folders wait on #354, asked to be split into smaller pull requests. *([#305](https://github.com/driceroland/Search/issues/305), [#341](https://github.com/driceroland/Search/issues/341), [#342](https://github.com/driceroland/Search/pull/342), [#354](https://github.com/driceroland/Search/pull/354), email)*
- [ ] **Dock icon dark on dark** With macOS's dark Dock icons, Search's icon is black on black. *([#337](https://github.com/driceroland/Search/issues/337))*
- [ ] **Two fingers on a canvas go back a page** On a canvas or whiteboard page, panning sideways with two fingers goes back a page instead of moving the canvas. *([#360](https://github.com/driceroland/Search/issues/360), [#361](https://github.com/driceroland/Search/pull/361))*
- [ ] **Space name at the top** Show the current space's name where the tabs are, not only its icon. *(email)*
- [ ] **A loading sign on pins** Pinned tabs show nothing while their page loads. *(email)*
- [ ] **New tabs at the top of the column** An option to open new tabs at the top of the column instead of after the current tab. *(email)*
- [ ] **Hard to move the window with the column folded** With the column folded away there's little to grab: only the thin band along the top edge moves the window. *(email)*
- [ ] **Stop videos playing by themselves** A switch like Safari's Auto-Play, so videos wait for a click; asked about YouTube's autoplay. YouTube's own switch in the player works meanwhile. *(email)*

## Next — small additions people asked for

- [ ] **Tab switcher with previews** ⌃Tab held down shows the tabs with previews. Off until turned on; Option-Tab asked too, as in AltTab. Waiting on its author to rebase and simplify. *([#24](https://github.com/driceroland/Search/pull/24), X, email ×3, [#260](https://github.com/driceroland/Search/pull/260), [#358](https://github.com/driceroland/Search/pull/358))*
- [ ] **Site search keywords** Type a site's keyword, then your search. *([#188](https://github.com/driceroland/Search/pull/188))*
- [ ] **Address bar commands** A word like "settings" reaches the app itself. *([#212](https://github.com/driceroland/Search/pull/212), email)*
- [ ] **Hold a swipe to pick from history** Hold a back or forward swipe to pick a page from history. *([#191](https://github.com/driceroland/Search/pull/191))*
- [ ] **Tabs load when shown** Tabs opened together don't all load at once: they wait until they're shown. *([#195](https://github.com/driceroland/Search/issues/195), [#196](https://github.com/driceroland/Search/pull/196))*
- [ ] **Don't reopen tabs at launch** A switch to start with a fresh window instead of last time's tabs. *(email)*
- [ ] **Pins as a list** Pins as a list, in rows instead of small squares. Also: site icons on pins without them in the tab list (one setting does both today), and Arc-style pinned rows above New Tab. *([#183](https://github.com/driceroland/Search/issues/183), email ×2)*
- [ ] **Pins shared by every space** Pins shared by every space, plus each space's own, as in Arc. *(email)*
- [ ] **Box Tools** Let app.box.com reach its local helper on this Mac, as Chrome does. The person who asked offered to test a build. *(email)*
- [ ] **1Password desktop app, in the FAQ** 1Password with its desktop app. Say in the FAQ that Search is added in 1Password › Settings › Browser › Add Browser.
- [ ] **Intel Macs** One build for both kinds of Mac, only as a change to build.sh, as [#100](https://github.com/driceroland/Search/pull/100) began. *([#46](https://github.com/driceroland/Search/issues/46), X)*
- [ ] **Tab groups and folders** Tabs gathered into named groups in the column and the bar across the top, off until turned on in Settings › Tabs. Drice liked #242; it's being made to work with every other feature for 1.0.5. *([#23](https://github.com/driceroland/Search/issues/23), [#68](https://github.com/driceroland/Search/issues/68), [#31](https://github.com/driceroland/Search/pull/31), [#54](https://github.com/driceroland/Search/pull/54), [#76](https://github.com/driceroland/Search/pull/76), [#242](https://github.com/driceroland/Search/pull/242), [#333](https://github.com/driceroland/Search/issues/333), email)*
- [ ] **⌃Tab in recent-use order** ⌃Tab goes to the tab used last in this space, not the neighbour in the row; holding it walks back through them. Also asks for its own shortcut recorders in Settings › Tabs. *([#225](https://github.com/driceroland/Search/pull/225), [#345](https://github.com/driceroland/Search/issues/345), [#356](https://github.com/driceroland/Search/pull/356), email ×2)*
- [ ] **A downloads button** A button beside Bookmarks opens the downloads panel, to follow a download's progress. The PR also closes every other tab with ⇧⌘K and extends the ⌃Tab switcher. *([#330](https://github.com/driceroland/Search/pull/330), [#353](https://github.com/driceroland/Search/issues/353), email)*

## Later — bigger pieces of work

- [ ] **More extension APIs** More of the extension APIs. The side panel, and invisible offscreen documents ([#192](https://github.com/driceroland/Search/pull/192)). *([#12](https://github.com/driceroland/Search/issues/12), X, [#192](https://github.com/driceroland/Search/pull/192), [#273](https://github.com/driceroland/Search/issues/273), [#351](https://github.com/driceroland/Search/issues/351), [#352](https://github.com/driceroland/Search/pull/352))*
- [ ] **Drive Search from an agent** An MCP server over the bench, for automation and testing. An earlier pull request, [#14](https://github.com/driceroland/Search/pull/14), began one. *(X)*
- [ ] **Web push notifications** As far as WebKit lets an app other than Safari have them. *(X, [#328](https://github.com/driceroland/Search/issues/328))*
- [ ] **Split view** Two tabs or more side by side in one window. *([#173](https://github.com/driceroland/Search/issues/173), [#277](https://github.com/driceroland/Search/issues/277), [#280](https://github.com/driceroland/Search/pull/280), email)*
- [ ] **Faster animations** Spaces especially, compared with Zen. *(email)*
- [ ] **Extensions per space** Each space with the extensions it wants, on and off apart from the others. WebKit has one extension controller for the whole app, so this means one per space. Drice's call, 24 Sep: later. *(X)*
- [ ] **Optional ad-blocking add-on** A stronger blocker as an optional add-on in Settings, downloaded on demand so it only takes space for those who want it. Search's built-in blocker stays as it is meanwhile. *(message)*

## Pull requests to review

- [ ] **Search doesn't come to the front** When another app, like Mail, opens a link in Search, its window stays behind. *([#95](https://github.com/driceroland/Search/issues/95))*
- [ ] **Smoother mouse-wheel scrolling** Smoother scrolling with a mouse wheel. To look into. *(X)*
- [ ] **Hidden sidebar is hard to bring out** The strip at the window's edge that brings out a folded sidebar is thin, and a pointer that overshoots the edge misses it; a wider strip and overshoot are being looked at. *([#239](https://github.com/driceroland/Search/issues/239), [#243](https://github.com/driceroland/Search/pull/243), [#256](https://github.com/driceroland/Search/pull/256))*
- [ ] **A download's tab stays behind** A download link that opens a new tab left that tab open on the file's address, and opening it again downloaded the file again; it now closes. *([#284](https://github.com/driceroland/Search/issues/284), [#285](https://github.com/driceroland/Search/pull/285))*

## Drice's call

- [ ] **Web processes start before the window** The web process pool is made before the first window; check whether 1.0.2's launch order already covers it. *([#157](https://github.com/driceroland/Search/issues/157))*
- [ ] **Dark mode for the Search site** A dark mode for the site's Search page. *([#51](https://github.com/driceroland/Search/issues/51))*
- [ ] **Autocomplete in a new tab** What exactly was asked, to find out. *(X)*
- [ ] **Dock the floating video at the side** Swipe the floating video into the side of the screen and it tucks away, leaving a sliver to bring it back by, as in Dia. *([#229](https://github.com/driceroland/Search/pull/229))*
- [ ] **AppleScript reads the current tab** Scripts and launchers can ask Search for the address and name of the tab in front, in Safari's own terms, so a Safari script works with only the app's name changed. *([#232](https://github.com/driceroland/Search/issues/232), [#233](https://github.com/driceroland/Search/pull/233))*
- [ ] **Pins per row** Choose how many pinned icons sit in a row at the top of the sidebar. *([#240](https://github.com/driceroland/Search/issues/240))*
- [ ] **⌘Return in the address field duplicates** After ⌘L, ⌘Return opens a copy of the current tab instead of reloading it. *([#249](https://github.com/driceroland/Search/issues/249), [#311](https://github.com/driceroland/Search/pull/311))*
- [ ] **Page slides with the sidebar** The page moves with the sidebar as it opens instead of redrawing in steps, with no gap at the edge; the PR also adds a speed setting. *([#252](https://github.com/driceroland/Search/pull/252))*
- [ ] **Import sign-ins and extensions** Importing from another browser can also bring its sign-ins, off unless ticked, and install the extensions it has. *([#261](https://github.com/driceroland/Search/pull/261))*
- [ ] **Translate pages on the Mac** Translate a page, or the text in a picture, on the Mac itself; nothing is sent anywhere. Off until turned on. *([#265](https://github.com/driceroland/Search/pull/265))*
- [ ] **Turn the floating video off per site** Choose the sites where a video never floats. *([#267](https://github.com/driceroland/Search/issues/267))*
- [ ] **A name that's easier to find** “Search” is hard to find when searching for a browser; a more distinctive name is suggested. *([#276](https://github.com/driceroland/Search/issues/276))*
- [ ] **Sites as their own apps** Make a small app of its own for a site kept open all day, from the Tabs menu. *([#292](https://github.com/driceroland/Search/pull/292))*
- [ ] **Screenshot one element** Pick an element on the page and save or copy a picture cropped to it. *([#308](https://github.com/driceroland/Search/issues/308))*
- [ ] **Select several tabs** Select tabs with ⌘-click and ⇧-click, then copy all their addresses at once. *([#309](https://github.com/driceroland/Search/issues/309))*
- [ ] **Unload a tab by hand** Put a tab to sleep, or every other tab, keeping it in the row until it's shown again. *([#310](https://github.com/driceroland/Search/issues/310))*
- [ ] **⌘Return keeps a peek as a tab** While a peek is open, ⌘Return keeps it as a tab, the way Escape puts it away. *([#325](https://github.com/driceroland/Search/issues/325), [#326](https://github.com/driceroland/Search/pull/326))*
- [ ] **Keep running after the window closes** Closing the window leaves Search running, as most Mac apps do. *([#327](https://github.com/driceroland/Search/issues/327))*
- [ ] **Tracking prevention signs people out** Some sites sign people out because of the tracking prevention. Whether to relax it, per site or at all, is a call to make. *([#362](https://github.com/driceroland/Search/issues/362))*

## Asked to try again on the latest version

- [ ] **Google asks for a reCAPTCHA** Google search asks for a reCAPTCHA. 1.0.2 no longer tells pages it is a separate app and says it is Safari. *([#26](https://github.com/driceroland/Search/issues/26))*
- [ ] **A tab loses track of its site** A tab's site switches, and the tab doesn't follow. Not reproduced. *([#28](https://github.com/driceroland/Search/issues/28))*
- [ ] **Page shortcuts vs Search's** Keep a page's editing shortcuts while Search's own still work. 1.0.2 gives the page the first go at its shortcuts; asked whether it's enough. *([#147](https://github.com/driceroland/Search/issues/147), [#238](https://github.com/driceroland/Search/issues/238), email)*
- [ ] **The column seems to refresh** Reported as a sidebar refresh issue. Asked whether the column itself redraws or the page reloads as it comes out. *(email)*
- [ ] **Black screen after full screen** In full screen, opening another window leaves the screen black. Asked which window: another app's, or one a page opens. *(email)*
- [ ] **Cesturify's sessions command** An extension command that uses the sessions permission does nothing. Asked which command. *(email)*
- [ ] **Affinity's Connect reloads the page** The Affinity extension's Connect button reloads the page instead of opening its sign-in. Asked where the button is. *(email)*
- [ ] **Reading Mode keeps the cookie notice** On some sites Reading Mode keeps the privacy or cookie notice instead of the article. Asked which site. *(email)*
- [ ] **Part of LinkedIn won't expand** Something on LinkedIn doesn't open when clicked. Asked which part: a post, its comments, or something else. *(email)*

## Just in, not sorted yet

- [ ] **Blurry text in Jupyter** Text in a Jupyter notebook on localhost looks slightly blurry, unlike in Chrome. *([#329](https://github.com/driceroland/Search/issues/329))*
- [ ] **Hide page clutter with a model** A small on-device model decides which parts of a page to hide. *([#339](https://github.com/driceroland/Search/issues/339))*
- [ ] **Copying images on WhatsApp Web** Copying an image from WhatsApp Web, and its attachment screen, don't work as expected. *(email)*
- [ ] **Eagle extension doesn't work** The Eagle extension from the Chrome Web Store fails to work in Search. *(email)*
- [ ] **macOS text replacements in pages** The Mac's own text replacements don't work in text boxes on web pages. *(email)*
- [ ] **Bookmark icons inside folders** Site icons disappear for bookmarks inside folders. *(email)*
- [ ] **Empty corner in full screen** In full screen, an empty corner shows where the window buttons were. *(email)*

## Not on the list, for now

- **Block YouTube's ads** YouTube's ads. They come from youtube.com itself, which the blocker's lists can't tell apart. Whether to go that far is an open question. Search's built-in blocker stays as it is; blocking YouTube's ads is not planned. An optional ad-blocking add-on, downloaded only by those who want it, may come later. *([#218](https://github.com/driceroland/Search/issues/218), email ×3)*
- **Tab bar in the page's colour** The tab bar or title bar in the page's own colour. Not planned: Search stays minimal. *([#158](https://github.com/driceroland/Search/issues/158), [#168](https://github.com/driceroland/Search/pull/168), [#25](https://github.com/driceroland/Search/pull/25))*
- **Home page or home button** A home page or home button. Not planned: Search stays minimal. *(email, [#299](https://github.com/driceroland/Search/pull/299))*
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
- **Touch Bar controls** Back, forward, reload, the tabs and a new tab button on the Touch Bar, stepping aside when a field or video needs it. Not planned: Search stays minimal. *([#274](https://github.com/driceroland/Search/issues/274), [#275](https://github.com/driceroland/Search/pull/275))*
- **A new look for the back swipe** The swipe back and forward draws a shape pulled out of the edge that follows the fingers, instead of arrows sliding the other way. Not planned: Search stays minimal. *([#281](https://github.com/driceroland/Search/issues/281), [#282](https://github.com/driceroland/Search/pull/282))*
- **Back closes a link's own tab** Back from the first page of a tab a link opened closes that tab and returns to the page it came from. Not planned: Search stays minimal. *([#283](https://github.com/driceroland/Search/pull/283))*
- **Interface in other languages** Search's own interface follows the Mac's language, starting with Simplified Chinese or Japanese. No translations for now. *([#304](https://github.com/driceroland/Search/issues/304), [#317](https://github.com/driceroland/Search/pull/317), [#334](https://github.com/driceroland/Search/issues/334))*
- **Two sidebars** Bookmarks in a sidebar on one side and tabs on the other, both at once. The column stays as quiet as possible: tabs only. Bookmarks live in the bookmarks bar (optional) and the Bookmarks menu. *([#359](https://github.com/driceroland/Search/issues/359))*
- **Tabs that close themselves** Close tabs left untouched for a long time, as Arc does. A tab you leave alone sleeps after half an hour and costs nothing, so there's nothing to clear away. *(email)*
- **An icon-only column** A narrow column that shows only the tabs' icons. Folding the column away (⌘S) and the tabs across the top already give the page the room; a third layout would be one more to keep working. *(email)*
- **Safari's own extensions** Load extensions installed for Safari, such as wBlock, besides the Chrome Web Store's. Safari's extensions live inside their apps and talk to them through Safari alone, and content blockers hand their rules to Safari only. Their Chrome Web Store versions work in Search. *(email ×2)*
