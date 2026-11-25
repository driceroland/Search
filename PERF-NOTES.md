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

## Phase 2 (25 Nov, 14:30-15:55)
- Lazy stack (perf-column's way, groups lazy too, no rail): 400 tabs select 162->111, close 182->79,
  space 1378->425, scroll 928->249 (lz1, 1 round) and column_scroll 34/34, BUT its guessed height for rows
  not made was 3x too tall (23,705 vs 6,136 pt) and a tab far down was not scrolled to
  (Tests/column_lazy.py: last loose tab, last group). Dropped.
- 3bc54d7e windowed column: SideBar.columnPlan (exact arithmetic, same as previewLines), only units in
  [band-R/2, band+2R] U [active-R, active+R] made, placed by top guides in a ZStack of the whole height;
  one scroll mark at the tab in front. Arrival rescroll a turn later + while the room settles (0.6 s).
  column_lazy 19/19 (base hook build 17/17 on the older 17 checks), column_scroll 34/34, pin_drag,
  pin_folders, close_in_group, fold_all_groups, new_tab_in_group, space_switch, space_landing, pin_line,
  close_group, group_to_space, icon_column, pin_folder_scroll, fold_keep all pass. slide_column 14/3 fails
  the same 3 on base. side_hover prints timings only (no pass line).
- d78cb2fc drag tracking: loose rows placed by Carried's top guide (held: place at pick-up + travel), no
  visual effect / origin / loose-rect reader; group and loose drop frames from the plan; grouped rows keep
  the stack way (visual effect) but no GroupDropFrames reader. Unit tests: same 72/81 as base (Narrow 2,
  PinDrag 7 fail on base too).
- acb284a9 stepKey: Next/Previous Space pressed on ⌥⌘K/⌥⌘J.
- Results in pmt-results/fin-*.jsonl (1 round, interleaved apps; machine noisier than phase 1: base ⌃N
  at 50 tabs 515 ms vs 162 in phase 1).
- Open: scroll at 400 still has a ~0.5 s pass (rows 37 built). Suspect: band change re-evaluates the
  whole SideBar body (band is SideBar @State), the map's pages included. Next: band in a child view that
  holds only the rows' window, then profile scroll (perf_profile.py 400 scroll).
- 15:55 final, 1 round each, longest pass ms (busy): see pmt-results/fin-*.jsonl.
  400: select 171->127, again 164->125, pin 163->98, new 105->56, close 236->122, space 1491->466,
  scroll 635->556 (busy 2230->1992). 200: close 130->83, new 63->48, space 711->511, scroll 322->214
  (busy 1487->572). 50: unchanged within noise.
  Item 2 alone (w1 -> w2): within noise on this bench except scroll at 200 (428->214, busy 1846->572).
  Next/Previous Space pressed (stepKey) = run in the bench pass (step): 662 vs 650 @400, 510 vs 557 @200,
  ⌃N 479/421: the gap is in the command's path, not the bench; not found yet.

## Phase 3 (25 Nov, 15:55-17:10), rebased on origin/main 9b67323c (1.0.21)
- 260b1652 ColumnWindow holds the band (child view) + windowStep = room/6: scroll @400 longest 556 -> 137-192
  (child only) -> 21-29 ms (max 36) on a fresh probe. Profile before: AttributeGraph update/propagate_dirty,
  no Search frames; the band change re-evaluated the whole SideBar and made ~22 rows at once.
- 6828ff60 band kept per space: rows made on a switch into the 200-tab space 82 -> 34. Switch pass now
  ~160-220 ms at 400 and ~130-200 at 50: N-independent. Profile @50: NSWindow layout -> NSHostingView.layout
  inside NSAnimationContext (~20 %), CA commit; the bench's own Bench.columnOffset/scrolls walk adds ~7 %
  of spacetime passes. Taking the space as the slide starts (3a) needs that fixed ~150-200 ms cut first: not done.
- 3b: ⌃N and Next/Previous on the SAME pair cost the same (perfkeyspace 2<->3: 559 vs 552; 1<->2: 190 each).
  The gap was the bench: "step" alternated S1<->S2 while ⌃N alternated S0<->S1. Open: perfkeyspace on a
  pair with the third space reads ~550 while spacetime reads ~180 for the same pair.
- 4f... mark back in SideBar (in ColumnWindow it was drawn after onChange: space_switch 6 fails); space_switch
  finds the landing by the bench's new per-pass "space" (it relied on >= 50 rows made).
- Open: after keyspace's glide runs (perfkeyspace glide), the scroll at 400 is slow again (550 ms; base
  same sequence 638). Fresh, after select, after space: 21-47 ms. Not found yet.
