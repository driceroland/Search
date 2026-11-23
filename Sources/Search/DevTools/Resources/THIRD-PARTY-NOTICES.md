# Third-party notices

## Lighthouse

Portions of DevTools are adapted from Lighthouse under the Apache License, Version 2.0. [Lighthouse source](https://github.com/GoogleChrome/lighthouse) · [License text](LICENSE-Lighthouse.txt)

- Legacy JavaScript detection adapts parts of Lighthouse 13.6.0's detector, Copyright 2025 Google LLC, to Swift and Search's WebKit trace model. [JavaScript detector](https://github.com/GoogleChrome/lighthouse/blob/v13.6.0/core/lib/legacy-javascript/legacy-javascript.js)
- The bundled polyfill table combines Lighthouse 13.6.0's module data and dependency graph. Search nests the module records under `polyfills`, renames `corejs` to `coreJS`, and supplies `false` where the original omits the flag. [Module data](https://github.com/GoogleChrome/lighthouse/blob/v13.6.0/core/lib/legacy-javascript/polyfill-module-data.json) · [Dependency graph](https://github.com/GoogleChrome/lighthouse/blob/v13.6.0/core/lib/legacy-javascript/polyfill-graph-data.json)
- Search's Lighthouse report uses Lighthouse audit names, category weights and scoring thresholds. The Swift scoring and simulated throttling implementations list their Lighthouse sources in `DeveloperLighthouse.swift` and `DeveloperLighthouseLantern.swift`.
