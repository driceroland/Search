# Browser appearance

Settings → Appearance contains Theme, Bar height (30–52 points), Transparency,
Blur strength, and Accent color. Defaults keep the existing opaque, 52-point
layout and graphite selection. Preferences persist; macOS Reduce Transparency
restores opaque chrome and disables the transparency and blur sliders.

Above 0% transparency the live page fills the window behind the tab strip or
sidebar. Controls remain opaque. Native traffic lights, folded-bar hit regions,
and space-swipe geometry use the chosen height. Find and account overlays retain
room for the controls.

Blur uses a clipped AppKit background-filter view beside WebKit in `StageView`.
Its Gaussian radius varies from 0 to 30. A following `CIColorMatrix` restores
output alpha, preventing edge samples outside the page from washing out its
colors at higher blur strengths. Transparency is applied separately.

Match page uses WebKit's observed `themeColor`, falling back to
`underPageBackgroundColor`. Metadata changes, navigation, and tab switches update
the selection without page scripts or polling. Neutral page colors use the
normal graphite selection so a white or black page cannot hide the selected tab.
Seven fixed accent colors remain available.

## Native regression checks

Build with `swift build`, then run these sequentially on macOS:

```sh
python3 tests/compact-bars.py
python3 tests/chrome-blur.py
python3 tests/chrome-blur-opacity.py
python3 tests/chrome-page-accent.py
```

The tests launch disposable apps with separate preferences and profiles. The
DEBUG-only native probe can drive only a `SEARCH_PROBE` process. Compositor
captures use ScreenCaptureKit's current-process API (macOS 14.4+), without
capturing another app or requesting screen access. Do not run the suites in
parallel: native focus is shared.

The controls suite checks height, lights, live page state, click targets, both
layouts, and restart persistence. The blur suite compares actual stripe contrast
under the bars against the uncovered page. The opacity suite compares solid page
colors at 10%, 50%, and 100% blur with transparency fixed at 80%; checking filter
configuration or contrast alone misses edge fading. The page-accent suite uses
real DOM metadata/background changes and checks the resolved accent color,
tab switching, fixed-color selection, and persistence.

Verified on 24 September 2026: 63 control checks, 7 rendered-blur checks,
11 fixed-transparency checks, and 12 page-accent checks passed. Both debug and
release builds passed. At fixed 80% transparency, the measured RGB channel drift
between 10%, 50%, and 100% blur was zero in both tab layouts.
