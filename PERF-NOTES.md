# perf-many-tabs notes (25 Nov 2026) — not for main

Bench: Tests/perf_many_tabs.py (world: 3 spaces 50/30/20 %, 6 pins each, 1/3 of tabs in groups of 6,
local pages: 60 % static article, 20 % clock+poll, 10 % mail-like title counter, 10 % rAF animation).
Hidden probe, SEARCH_MEASURE=1, SEARCH_PERF=1. Profiles: Tests/perf_profile.py + perf_profile_sum.py.
Results in /private/tmp/claude-501/pmt-results/*.jsonl

## Log
- 13:20 baseline build = origin/main 25bce516 + instrumentation (cde83af1).
- 13:31 baseline (2 rounds, medians) — see report table. Idle/memory fine (lazy tabs work: 1 web process
  until visited). Costs that grow with N: select/new/close ~0.4 ms per tab in the longest pass,
  space switch 470 ms @50 -> 1150 ms @400, column scroll pass 32 ms @50 -> 920 ms @400.
- Profiles @400 (base-*.trace): ~85-90 % of the main thread is SwiftUI/AttributeGraph handling the
  column's N row views (ForEach diff DynamicContainerInfo.updateItems, StackLayout sizing every row,
  propagate_dirty on geometry). Scroll: ScrollViewCommitMutation -> propagate_dirty over every row's
  geometry readers (Carried: 2 onGeometryChange + visualEffect + GroupDropFrames reader per row).
  Search's own O(N*G): Browser.visibleTabs(in:)->tabs(in:)->grouping(all tabs) per group, Parked.drawn
  filter per group, Browser.active linear search (~10-15 % of select samples).
- perf-column 82a1beec (lazy loose rows + rail + map box) measured on this bench, 1 sample:
  200: select 100->70, space 569->380, scroll 370->73 ms; 400: space 1150->880, scroll 918->490,
  close got worse 205->462, launch longest 288->577.
- F1 = grouping/active caches + single-pass Parked.drawn.
- F2 = KeyedRow: loose rows Equatable-keyed so unchanged rows are not remade.
- 13:58 F1 A/B (x2 interleaved, longest/busy ms): 400 pin 166->128, close 246->198, select 172->164,
  space 1392->1340; 200 within noise. Committed 3cb31917.
- 14:10 F2 KeyedRow A/B vs F1: within noise (select 174->164, space 1293->1088 but scroll noisy) ->
  per-row body re-evaluation is not the cost; dropped (patch in pmt-results/f2-keyedrow.patch).
- 14:20 3-way @400 x2 (longest/busy ms):
  f1:    select 165/471 again 148 pin 147 new 98 close 172 space 1185/1421 scroll 1047/3119
  d1 (diagnostic: Carried's per-row geometry readers removed, drag broken): scroll 611/2908, space 1032
  lazy2 (perf-column 82a1beec on f1): select 129/353 again 117 pin 100 new 73 close 379(!) space 930/1047 scroll 856/2529
- Hub ask (idea 1024): perfkeyspace verb + keyspace case: ⌃N press -> taken/page/settled.
- 14:30 keyspace (f1 code, 2 rounds, medians, ms from the key press): see report.
  ⌃N at once: page+rows taken 162 @50, 216 @200, 366 @400 (one pass holds it all).
  ⌃N with the slide: page ahead 129/132/173, column takes the space at ~1.3-1.5 s (the slide).
  Next/Previous Space (command run inside the bench pass): 229/475/811 — 2x ⌃N at 200/400, unexplained, open lead.
  settledMs ~1.5-1.9 s is the debounced session write 1.2 s later (a pass > 4 ms), not the column.
- 14:35 Arc import (2 Arc profiles, 4 spaces, folders, favourites), f1 code: 200 tabs longest pass 411 ms,
  400 tabs 612 ms (callMs 132), then idle 0.1 % CPU, 1 web process, 217 MB. The 100 % CPU freeze is NOT
  reproduced with local pages: tabs stay lazy after the import. Suspects left: real sites' icons/titles
  fetched after an import, Profile 1's spaces in a second window, extensions.
