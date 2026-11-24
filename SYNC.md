# Sync

How Search on iPhone and Search on the Mac share open tabs, pins, bookmarks
and a few settings. Both apps follow this page exactly; change it in both
or not at all.

On by default on the iPhone and for new Mac installs; existing Mac users
are offered it (the Mac's What's New). Either way it's switched in
Settings ("Sync with iCloud"). A device that has it off simply doesn't
take part.

## Where

- CloudKit container `iCloud.com.officecommun.search`, the **private**
  database: the person's own iCloud. Nothing goes through a server of ours
  and nobody but the person can read it.
- One custom zone: `Search` (owner: current user).
- `CKSyncEngine` on both sides (iOS 17+, macOS 14+).
- CloudKit environment: **Production** on both, debug builds included, so
  every build sees the same data. (The schema is created in Development
  once, then deployed to Production in the CloudKit Console.)
- On the Mac, only the **Personal** profile syncs. Other profiles stay on
  that Mac.

## Records

One record type, `Item`. Its record name says what it holds:

| Record name | Holds (JSON) | Written by |
|---|---|---|
| `device.<device-uuid>` | `DeviceTabs`: this device's open tabs | that device only |
| `pins.<space-uuid>` | `[PinDef]`: one space's pins, in order | any device |
| `bookmarks` | `[Bookmark]`: the whole tree | any device |
| `spaces` | `[Space]`: the Mac's spaces | the Mac |
| `pinfolders.<space-uuid>` | `[{id, name, parent?, feed?}]`: one space's pin folders | the Mac; the iPhone keeps it as-is and doesn't apply it |
| `settings` | `SharedSettings` | any device |

Fields of every `Item`:

- `encryptedValues["data"]`: `Data`, the JSON. End-to-end encrypted.
- `at`: `Date`, when the device that wrote it changed it. Not encrypted;
  it says nothing about the content.

No other fields, ever: a field in production can't be taken back. New
things get new record names, not new fields.

## Shapes

The Mac's own `Codable` types, so its files and the records are the same
JSON. Unknown keys are ignored on read; missing optional keys are nil.

```
PinDef        { id: UUID, letter: String, home: String, title: String, name: String? }
Bookmark      { id: UUID, title: String, url: String?, children: [Bookmark]? }   // url nil = folder
Space         { id: UUID, name: String, colour: Int, icon: String?, ... }        // the Mac's Space
DeviceTabs    { name: String, platform: "ios" | "macos", at: Date, tabs: [{ url: String, title: String }] }
SharedSettings{ engine: String?, custom: String?, suggest: String?, look: String? } // Engine / Look raw values
```

- Dates are JSONEncoder's default (seconds since 2001, a number).
- The first space is `00000000-0000-0000-0000-000000000001`; the iPhone shows
  that space's pins unless another is chosen.
- `DeviceTabs.tabs`: ordinary web pages only, no pinned tabs (pins travel as
  pins), **never private tabs**. The Mac sends every window's tabs of every
  space as one list.
- `DeviceTabs.name`: the device's own name as the person knows it (the Mac's
  computer name). The other side shows it ("On Drice's MacBook Pro"). `at`
  is when the list was written; a device writes again only when `tabs` or
  `name` changed, never for `at` alone.
- **Fields a device doesn't know ride along.** A `PinDef` may carry more
  than the five fields above (the Mac's `listed`, `folder`, …). A device
  that rewrites a pin starts from the last version it read and changes only
  the fields it owns; anything else is kept as it was. A missing field
  means "unchanged", not "cleared".
- `PinDef.pair` (optional, from the Mac): a split view pinned as a split.
  The iPhone keeps it untouched on write-back and opens the pin's `home`,
  the split's first page.
- A pin's `title` is the one it was pinned with; a device doesn't rewrite it
  from the page's current title.
- Engine values: `google duckduckgo bing ecosia startpage kagi brave qwant
  custom`. Look values: `light dark system`. An unknown value is ignored.
- `SharedSettings.suggest`: a custom engine's suggestions address, optional:
  https, with `%s` where the words go. Empty or absent, and a custom engine
  has none, as before. It may be on a different host than `custom`.

## Rules

- **Latest wins, per record.** A change sets `at` to now. A record that
  arrives with an older `at` than the local one is ignored and the local
  one is sent again. A `serverRecordChanged` conflict keeps whichever has
  the newer `at`.
- **Joining merges.** The first time a device turns sync on, it fetches
  everything first, and joins only once that fetch has succeeded: after a
  failed fetch it writes nothing and tries again later. Pins (per space) and bookmarks already on the device
  are added to what's in iCloud (matched by `id`, then by address) and the
  union goes up. Settings: iCloud's win. Nothing is written over before
  that first fetch.
- **No echo.** Each app keeps the last JSON it wrote or read per record, in
  its own canonical encoding (sorted keys), and sends only when the new
  JSON differs.
- **Turning sync off** deletes this device's `device.<uuid>` record, so its
  tabs leave the other devices. Everything else stays.
- **"Delete Search's data from iCloud"** deletes the zone, for every device.
  A device that sees the zone gone **turns its sync off** (and says why);
  it doesn't recreate the zone or put its data back. What's on each device
  stays.
- **Spaces.** A space deleted on the Mac leaves `spaces`; the first space is
  never deleted. Its `pins.<space>` record may stay in iCloud; it's ignored.
  An iPhone showing a space that's gone falls back to the first.
- **Mac only, not in this contract:** pins shown in every space (shared
  pins), the folder sync (mutually exclusive with this one), a space's
  downloads folder.
- **History, passwords, site data, private tabs: never synced.**

## Where this lives

- iPhone: `Sources/Sync.swift` (engine, shapes, bookmarks, the two lists).
- Mac: `Sources/Search/ICloudSync.swift` (engine, shapes, merge), and
  `Sources/Search/SyncDefault.swift` (on for a new install once its welcome
  is left, with the switch in sight on the welcome's first page; an install
  from before keeps what it had and is offered it first on the What's New
  card). The same page lives in both repositories.

## Examples

`device.6F1C…` (an iPhone):

```json
{"at":785164000,"name":"iPhone","platform":"ios","tabs":[{"title":"Example Domain","url":"https://example.com/"}]}
```

`pins.00000000-0000-0000-0000-000000000001`:

```json
[{"home":"https://mail.google.com/","id":"0E4B…","letter":"M","title":"Inbox"},
 {"folder":"…","home":"https://github.com/","id":"7A2D…","letter":"G","listed":true,"title":"GitHub"}]
```

(The second pin carries Mac-only fields; the iPhone keeps them as they are.)

`bookmarks`:

```json
[{"id":"…","title":"Reading","children":[{"id":"…","title":"Example","url":"https://example.com/"}]},
 {"id":"…","title":"Office Commun","url":"https://officecommun.com/"}]
```

`spaces`:

```json
[{"id":"00000000-0000-0000-0000-000000000001","name":"Personal","colour":0,"icon":"house"},
 {"id":"…","name":"Work","colour":3,"icon":"briefcase"}]
```

`settings`:

```json
{"custom":"","engine":"duckduckgo","look":"system","suggest":""}
```
