// Rendering's media features that WebKit can't override
// (DeveloperRenderingPage.swift): a function expression taking a media
// query list's text and the features to emulate, by name, and giving the
// text back with each test of one of those features swapped for a test
// that always matches or never does. `(forced-colors: active)` under
// {"forced-colors": "active"} becomes `(min-width: 0px)`; under "none",
// `(not (min-width: 0px))`. A test with no value, `(prefers-contrast)`,
// matches unless the value emulated is `none` or `no-preference`.
// color-gamut is a range: a page emulated as p3 matches srgb and p3 but
// not rec2020. Everything else in the text is kept as written.
(text, overrides) => {
    const always = "(min-width: 0px)";
    const never = "(not (min-width: 0px))";
    const ranges = {"color-gamut": ["srgb", "p3", "rec2020"]};
    const has = Object.prototype.hasOwnProperty;
    const matches = (feature, value, emulated) => {
        if (value === undefined) return emulated !== "none" && emulated !== "no-preference";
        const order = ranges[feature];
        if (order) {
            const at = order.indexOf(value);
            return at >= 0 && at <= order.indexOf(emulated);
        }
        return value === emulated;
    };
    return String(text).replace(/\(\s*([a-zA-Z-]+)\s*(?::\s*([a-zA-Z0-9-]+)\s*)?\)/g, (whole, name, value) => {
        const feature = name.toLowerCase();
        if (!overrides || !has.call(overrides, feature)) return whole;
        const wanted = value === undefined ? undefined : value.toLowerCase();
        return matches(feature, wanted, String(overrides[feature]).toLowerCase()) ? always : never;
    });
}
