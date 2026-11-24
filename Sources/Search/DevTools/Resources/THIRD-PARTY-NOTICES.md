# Third-party notices

## Lighthouse

Portions of DevTools are adapted from Lighthouse under the Apache License, Version 2.0. [Lighthouse source](https://github.com/GoogleChrome/lighthouse) · [License text](LICENSE-Lighthouse.txt)

- Legacy JavaScript detection adapts parts of Lighthouse 13.6.0's detector, Copyright 2025 Google LLC, to Swift and Search's WebKit trace model. [JavaScript detector](https://github.com/GoogleChrome/lighthouse/blob/v13.6.0/core/lib/legacy-javascript/legacy-javascript.js)
- The bundled polyfill table combines Lighthouse 13.6.0's module data and dependency graph. Search nests the module records under `polyfills`, renames `corejs` to `coreJS`, and supplies `false` where the original omits the flag. [Module data](https://github.com/GoogleChrome/lighthouse/blob/v13.6.0/core/lib/legacy-javascript/polyfill-module-data.json) · [Dependency graph](https://github.com/GoogleChrome/lighthouse/blob/v13.6.0/core/lib/legacy-javascript/polyfill-graph-data.json)
- Search's Lighthouse report uses Lighthouse audit names, category weights and scoring thresholds. The Swift scoring and simulated throttling implementations list their Lighthouse sources in `DeveloperLighthouse.swift` and `DeveloperLighthouseLantern.swift`.

## Speedline

The Swift Speed Index calculation adapts Speedline's RGB histograms, near-white pixel exclusion, and frame progress calculation. Speedline is copyright Pierre-Marie Dartus and distributed under the MIT License. [Histogram source](https://github.com/paulirish/speedline/blob/626ed07ca71ea91991fb033e659dc7e2f81f2e6c/core/lib/frame.js) · [Frame progress source](https://github.com/paulirish/speedline/blob/626ed07ca71ea91991fb033e659dc7e2f81f2e6c/core/lib/speed-index.js) · [License text](LICENSE-Speedline.txt)

## Chromium DevTools

The Swift APCA calculation adapts Chromium DevTools' luminance and signed contrast functions. Chromium DevTools is copyright The Chromium Authors and distributed under its BSD-style license. The Chromium implementation references the APCA work by Myndex. [Chromium source](https://github.com/ChromeDevTools/devtools-frontend/blob/b6c7456a9a228c45bcdd7cf5f35eb278b2698f0d/front_end/core/common/ColorUtils.ts#L95-L147) · [Myndex reference](https://github.com/Myndex/SAPC-APCA) · [License text](LICENSE-Chromium-DevTools.txt)
