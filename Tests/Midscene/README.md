# Search Midscene E2E

## Why desktop tests

Search is a native SwiftUI/AppKit application containing WKWebView, not a web
application. Its existing `Tests/SearchTests` suite checks imports, persistence,
downloads and extensions; Python probes drive model state in hidden windows.
There was no GitHub Actions workflow. These tests use `@midscene/test` to add visible user journeys
through the real application, using `@midscene/computer` rather than a Chromium
page that would miss Search's native menus, sheets and file chooser.

The design references [Rome #466](https://github.com/rome-os/rome/pull/466) and
[its follow-up #551](https://github.com/rome-os/rome/pull/551) and
[report/publication separation #678](https://github.com/rome-os/rome/pull/678), plus the local
Rome test harness. It borrows isolation, credential gates, serial shards and
native report handling. Rome's business cases and web server are not reused.
The desktop API is described in the [Midscene documentation](https://midscenejs.com/platforms/desktop).

## Cases and isolation

`cases/*.yaml` contains the executable Midscene Test workflows; `cases.json` is
the reviewed inventory. `midscene.config.ts` registers `ComputerAgent` through
`createMidsceneNodes`, plus the deterministic `app.open` setup node. User actions are `aiAct` prompts;
visible outcomes are `aiAssert` prompts. No selectors or probe commands perform
user steps. The existing bench socket is used only as a startup readiness marker.

Every case must include `aiAct` and end with `aiAssert` checking the final visible
result. Intermediate outcomes should also use `aiAssert`. Model-free collection
rejects missing assertions and actions left after the last assertion, including on PRs.

| Shard | Cases |
| --- | --- |
| import | Bookmarks file import; repeated import without duplicates |
| navigation | Navigate to a local page and find three occurrences of a word |

Every case starts a fresh process from a temporary app copy with a unique
bundle ID and `SEARCH_PROBE=midscene-<uuid>`. This gives it its own defaults
suite, support folder, WebKit storage and synthetic browser discovery root.
Each case generates its own Netscape bookmarks export and loopback HTTP server
with an ephemeral port. The update feed is also redirected to that server.
Fixtures have no external resources and a restrictive CSP. The model credentials
are removed from the launched application's environment.
`SEARCH_E2E_VISIBLE=1` opts this isolated process out of the bench's normal
hide-on-activation policy. Legacy probe runs remain hidden by default; without
this flag their windows cannot be used for screenshot-driven E2E.

This is the native equivalent of Rome's fresh browser context, not a shared
Playwright session. Only the child process started by the harness is terminated;
its temporary files, probe defaults and named WebKit caches are removed.
Force-killing the test runner can interrupt cleanup, so use a disposable desktop
account. Password/keychain and real installed-browser imports are intentionally
outside this initial inventory. The harness does not implement a system-wide
network firewall: additional cases must keep all page requests local.

## Local commands

Requires macOS 14+, Node 22.12+, Xcode command line tools and an English desktop
with a US keyboard layout. Use a dedicated test account/desktop: the SDK drives
the actual mouse and keyboard and screenshots contain the visible screen.
Grant Accessibility, Screen Recording, and Automation of System Events to the
terminal/runner that launches Node. Do not run multiple desktop shards together.

```sh
./build.sh debug
cd Tests/Midscene
npm ci
npm run check                    # No model or desktop access
# Export the four MIDSCENE_MODEL_* variables from .env.example securely.
MIDSCENE_DESKTOP_ENABLED=1 MIDSCENE_SHARD=import npm test
# Omit MIDSCENE_SHARD to run the whole inventory serially.
npm run report
```

`SEARCH_E2E_APP` can override the built app path. The default is
`../../build/Search.app` on Apple Silicon or `../../build/intel/Search.app` on Intel,
relative to `Tests/Midscene`. Missing credentials,
unknown shards and absent builds fail before any desktop agent is created.
The desktop opt-in is mandatory. No model retry is automatic: investigate the
native HTML before rerunning a failed journey.

## CI configuration

Every PR and pushed branch runs type checking, native framework YAML collection, report regression tests and Swift
regressions with no model secrets. The seven WebKit download tests run in
separate XCTest processes via `Tests/run-ci-tests.py`; all Swift cases remain
required. They use GitHub-hosted `macos-15-intel`. Visual
tests run only on upstream main or an explicit owner dispatch in a fork, with
`MIDSCENE_DESKTOP_ENABLED=true`. A fork push runs only the secret-free checks;
`MIDSCENE_TRUSTED_REF` no longer grants automatic access to model credentials.
PR events never run model tests. Recovery input `report_source_run_id` skips
Swift, desktop capability, builds and model calls, while still validating the harness.

The Intel hosted runner passed the SDK screenshot, mouse movement and permissions
checks on 2026-09-30, exposing a 1920×1080 display. In the same check, ARM
`macos-15` exposed zero displays and failed screenshot capture. The optional
`desktop-capability` job records current runner evidence without model credentials.
No self-hosted runner is required. Set repository secrets `MIDSCENE_MODEL_API_KEY`,
`MIDSCENE_MODEL_NAME`, `MIDSCENE_MODEL_BASE_URL`, `MIDSCENE_MODEL_FAMILY` for a
supported vision model. Install/build steps do not receive those secrets.
The model endpoint must be reachable from GitHub's hosted network. Desktop
availability does not imply access to an internal model gateway: a connection
timeout should be resolved with a reachable provider or an approved runner with
the necessary network access, rather than by changing assertions or adding retries.
Both matrix shards run serially with `fail-fast: false`; a concurrency group
also serializes separate workflow runs. Each hosted job gets a fresh VM.

Reports do not require GitHub Pages. After aggregation the combined native report,
original shard reports, screenshots and `summary.md` are uploaded for 14 days,
before checking report completeness. A separate read-only **Midscene results before
publication** job displays counts and artifact links without waiting for Pages or
its environment approval. A failed merge retains original reports and keeps CI red.

Pages is optional: a maintainer can select Settings → Pages → Build and deployment
→ Source → GitHub Actions. The workflow never enables Pages or changes repository
settings. Upstream main is eligible in code; a fork additionally requires manual
dispatch and `MIDSCENE_PUBLISH_REPO` equal to its exact full repository name.
`publish_pages=false` verifies reports without deployment. Search uses its dedicated
report site; this workflow is not intended to replace an unrelated Pages website.

Once optional publication completes, the second read-only **Midscene results** job
records aggregation and publication status. Visual shard jobs do not write duplicate
case Summaries. Before publication, counts and artifact links are shown without empty
case tables; only successful deployment enables the detailed tables and web links.
The final case tables have an explicit Report column, clickable 160-pixel screenshots and exact native
`runner-step` anchors, failed/incomplete cases first and passes in a collapsed
appendix. Missing Pages, failed or cancelled publication cannot remove the earlier
Summary or downloadable reports. Published paths are `runs/<run>/<attempt>/`.
The site retains up to three recent trusted runs within a 900 MiB limit, replaces
old content for a rerun, and uses native HTML instead of generating a substitute.

Manually dispatch **Midscene desktop E2E** with `report_source_run_id` to rebuild an
existing completed run while its shard artifacts remain downloadable, without
model calls. The old standalone Recover workflow is replaced by this input.
Source and history must belong to the same repository and Midscene workflow.
Upstream sources require a trusted event and a commit in main history; fork
sources require manual dispatch. PRs, fork pushes, other workflows and incomplete
runs are rejected. Both history-run and artifact lookups paginate. Shard/combined
artifact names include the attempt, and recovery uses the authenticated source
attempt so previous rerun output cannot fill missing cases.

## Native reports and failure handling

`npm test` calls the official `runTestProject` API; Midscene Test owns execution,
step timeouts, lifecycle teardown, outcomes and the unified native framework
report. The entry script only clears old output and exports case metadata for
CI Summary. `npm run nodes` generates the official Node Spec and is also part
of the secret-free checks. `tsx` is pinned for compatibility with the framework
CLI's CommonJS config loader.

Each case also saves a standalone Midscene HTML report with screenshots embedded,
a final PNG, and a `results.json` entry. Reports are written even after AI
assertion failure. The package pins Midscene versions in its npm lockfile.
The report job downloads shards into separate directories, merges via
`mergeReportFiles` from `@midscene/core`, and builds a Markdown case table from
the manifest. When every expected case has one matching native framework report,
it merges those reports to preserve the Midscene Test case and step view. Otherwise
it falls back to available standalone SDK reports. It never creates a substitute
HTML report, and always keeps the originals.

A missing case/report/screenshot or failed merge makes the report job fail.
Per-case reports remain in the combined artifact and can still be published
when native merging fails. Partial merged output is removed. Starting a new
shard deletes old `midscene_run`; assembling a report removes its old native
merge before processing the current results. Tests cover exact links, screenshots,
merge failure fallback and incomplete reruns.

A per-case runtime JSON records only the owned test world's bookmarks and process
identity, so isolation failures can be distinguished from UI assertion failures.
The setup raises the owned process's window and verifies its foreground PID.
Visual CI runs independently of the Swift regression job; failures in either
suite remain failures, and a Swift failure does not suppress visual evidence.

A shard timeout or setup failure may yield no report for its unfinished cases;
the aggregate Summary records those cases as missing rather than passed. Job
logs retain startup errors. The replacement model configuration was verified
to return AI responses from hosted Intel CI. Earlier runs exposed an isolation
problem: legacy probe mode hid the test window, allowing local AI steps to target
an existing Search window. Those local outcomes are invalid. The explicit visible
E2E mode corrects that startup policy. All three AI journeys passed on hosted
`macos-15-intel` using the replacement model configuration in
[run 36677518910](https://github.com/quanru/Search/actions/runs/36677518910)
on 2026-09-30. Both import cases produced exactly one folder with two bookmarks
in separate test worlds; the navigation screenshot shows `1 of 3` matches.
That earlier overall workflow was red because the separate Swift private-download
regression timed out waiting for download state. The download fixture was subsequently
repaired by attaching the WebKit delegate inside the startDownload callback. One successful visual run is
initial integration evidence, rather than proof of long-term model stability.

## Latest alignment validation (2026-10-09)

[Rome #678 alignment run](https://github.com/quanru/Search/actions/runs/37873391557)
passed all three AI cases (four aiAssert checks), all 51 Swift tests, 38 report/policy
regressions and Pages publication. The publication-independent Summary finished
before deployment began. The native report and exact case HTML/JPEG assets return 200.

[Recovery without Pages](https://github.com/quanru/Search/actions/runs/37875049797)
passed with model, desktop and Swift jobs skipped.
[Recovery with Pages/history](https://github.com/quanru/Search/actions/runs/37875250336)
also passed without model calls; the original and rebuilt native URLs remain available.

## Adoption scope and evidence

This branch is based on `fix/hosted-webkit-regressions`, which separately fixes
WebKit test delegate timing and fixture transfer synchronization. It does not
include the browser-folder selection/import-boundary product changes from #415.
Review the regression prerequisite independently; the Midscene change then adds
only the isolated visible probe entry point, AI cases and CI/report pipeline.

Visual shards download one app built for the current workflow attempt. Cases
still launch separate ad-hoc-signed copies with fresh data; sharing a binary does
not share a running process or a test world. Repeated import asserts both import
completion messages before checking the final unique bookmark list.

Report-rebuild runs make no model calls and do not count as stability samples.
Use independent full runs for cold-start evidence. A failure demonstration must
use a separate branch with an intentionally wrong visible-result `aiAssert`,
inspect the failed native step and screenshot, and never merge that assertion
into the passing suite. Pages is optional; raw and combined artifacts remain the
primary fallback when publication fails.
