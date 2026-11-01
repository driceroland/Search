# Contributing

This is a small, mostly-solo project, reviewed the same way it's written. Contributions are welcome, but a few things make one land faster.

## Before writing code

For anything beyond a small fix, open an issue first describing what you want to change and why. It saves a rewritten pull request later if the direction doesn't fit.

## New features: off until someone turns them on

Shy stays small by default. Anything new that changes how the browser
looks or behaves — spaces, groups, a visible address bar, a new panel — is:

- **minimal**: the smallest version that does the job, in the app's own quiet style;
- **optional, and off by default**: someone who never asks for it never sees it;
- **findable**: a switch in Settings, and a line on the What's New card if it's a big one, so people know it's there to turn on.

Fixes and things every browser is expected to do (Tab moving between a form's fields, ⌘1–⌘9) don't need a switch. Before building a bigger feature, look at how other browsers do it and read what people asked for on its issue.

## Where the code is

`Sources/Shy` is sorted by what each part of the browser does:

- **App**: the app itself, its windows, menus, keys, look, settings store and the scripts it puts into pages.
- **Browser**: one window's model: `Browser.swift` holds what it knows, and each `Browser+…` file does one thing with it (opening, rows, find, the field, downloads…). Spaces, profiles, pins, folders and the session are here too.
- **Tab**: one tab and its page: `Tab.swift` and its `Tab+…` files, the web view (`PageView`), and everything a page can ask for or be given: dialogs, forms, notifications, translation, reading mode, icons.
- **Column** and **Stage**: what you see, the column of tabs, and the page area with split view, peeks and the side panel.
- **Address**: the field and what it understands: addresses, keywords, engines, site search, clean links.
- **Library**: history, bookmarks, downloads and imports.
- **Privacy**: passwords, passkeys and the ad blocker.
- **Settings**, **Agent** (the MCP side and its socket), **Bench** (test builds only) and **Extensions**.
- **Scripts**: the JavaScript, as `.js` files.

A type that grew past a few hundred lines keeps its state in its own file and its work in `Type+Concern.swift` extensions beside it. A delegate's methods stay in the extension that declares the conformance, since WebKit only finds them there.

## Where things are tracked

- [Issues](https://github.com/nxcco/shy/issues): every idea and report, and what is being worked on.
- The git history: what changed and why. A commit message says what is different for someone using Shy, not only what the code does.

## What tends to get merged

- **Small, focused changes.** One thing per pull request, easy to read start to finish.
- **No new dependencies.** The whole point of this app is staying small; a browser this size doesn't need a package for something Foundation or WebKit already does.
- **Matches the existing style.** Comments here explain *why*, not *what the next line does* — read a couple of existing files before adding a new one. No force-unwraps on anything that can plausibly fail (a network response, a file read, a keychain lookup).
- **Builds clean.** `swift build` with zero warnings you introduced.

## What doesn't

- Rewrites of things that already work, for style reasons alone.
- Anything that phones home, adds analytics, or changes what leaves the app over the network.
- Vendoring Chromium or any other engine. This is a WebKit browser on purpose.
- A real key or token anywhere: in code, a test, an issue, a pull request or a pasted log. Tests use keys that are obviously made up. `gitleaks git --pre-commit --staged` with the repo's `.gitleaks.toml` catches most of them before a commit; it is worth running as a pre-commit hook.

## Review

Pull requests are reviewed by Drice, usually with Claude Code doing a first pass on the diff before a human look. That means a review can be fast even when nobody's watching the repo in real time, but it isn't a guarantee of a same-day answer — this isn't anyone's full-time job. Pinging a stale PR after a couple of weeks is completely fine.

## Reporting a bug

Open an issue with: what you did, what you expected, what happened instead, and your macOS version. A crash log, if there is one, lives at `~/Library/Application Support/Shy/crash.log` — it only ever stays on your Mac unless you paste it into the issue yourself.
