import Foundation

// Chrome DevTools' Issues tool (More tools › Issues), on WebKit. WebKit's
// inspector has no Audits domain, so nothing sends issues ready-made:
// they are worked out here from what Search already hears. The Console's
// messages (CSP violations, mixed content, CORS failures, deprecations),
// the Set-Cookie headers of the page's responses, the requests the
// Network panel lists, and a snapshot of the page's form fields. All of
// that reasoning is pure and lives in this file (DeveloperIssueRules);
// DeveloperIssuesModel.swift collects the inputs, DeveloperIssuesView.swift
// draws the result.

/// Chrome's three kinds of issue, in the order the pane lists them.
enum DeveloperIssueKind: String, CaseIterable, Identifiable, Comparable {
    case pageError = "Page Errors"
    case breakingChange = "Breaking Changes"
    case improvement = "Improvements"

    var id: Self { self }

    static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }

    /// One issue of this kind, as the counter's tooltip says it.
    func count(_ count: Int) -> String {
        switch self {
        case .pageError: count == 1 ? "1 page error" : "\(count) page errors"
        case .breakingChange: count == 1 ? "1 breaking change" : "\(count) breaking changes"
        case .improvement: count == 1 ? "1 possible improvement" : "\(count) possible improvements"
        }
    }

    /// One of this kind, as an icon's tooltip names it.
    var name: String {
        switch self {
        case .pageError: "Page error"
        case .breakingChange: "Breaking change"
        case .improvement: "Improvement"
        }
    }

    var icon: String {
        switch self {
        case .pageError: "exclamationmark.bubble.fill"
        case .breakingChange: "exclamationmark.bubble.fill"
        case .improvement: "text.bubble.fill"
        }
    }
}

/// Chrome's issue categories, in the order "Group by category" lists them.
enum DeveloperIssueCategory: String, CaseIterable, Identifiable {
    case cookie = "Cookie"
    case mixedContent = "Mixed Content"
    case contentSecurityPolicy = "Content Security Policy"
    case cors = "Cross Origin Resource Sharing"
    case crossOriginEmbedderPolicy = "Cross Origin Embedder Policy"
    case generic = "Generic"
    case lowTextContrast = "Low Text Contrast"
    case quirksMode = "Quirks Mode"
    case other = "Other"

    var id: Self { self }
}

/// A "Learn more" link under an issue.
struct DeveloperIssueLink: Equatable, Hashable {
    let title: String
    let url: String
}

/// What went wrong, one per issue type Chrome describes: its category,
/// its usual kind, its title and explanation, and where to read more.
enum DeveloperIssueCode: String, CaseIterable {
    // Content Security Policy
    case cspURL, cspInline, cspEval, cspTrustedTypes
    // Mixed content
    case mixedContent
    // CORS
    case corsAllowOrigin, corsPreflight, corsHeaderNotAllowed, corsMethodNotAllowed, corsCredentials, corsScheme, corsRedirect
    // Cookies
    case cookieSameSiteNoneInsecure, cookieTooLarge, cookieAttributeTooLarge, cookieInvalidDomain, cookieThirdPartyBlocked
    // Generic: forms
    case formEmptyIdAndName, formDuplicateId, formInputWithNoLabel, formLabelForNonExistingId, formLabelForName,
         formLabelHasNoField, formAriaLabelledByNonExistingId, formAutocompleteEmpty, formAutocompleteMissing
    // Generic: ARIA attributes on any element
    case ariaInvalidRole, ariaUnknownAttribute, ariaInvalidValue, ariaMissingReference, ariaHiddenFocusable
    // Cross-origin isolation
    case coepCorpMissing, coopCoepInvalid, crossOriginIsolationIncomplete
    // Other
    case sharedArrayBuffer, deprecation, quirksMode, lowTextContrast

    /// Lighthouse's inspector-issues audit fails only on these: mixed
    /// content, cookie, blocked-by-response (CORP/COEP), heavy ad and CSP
    /// issues. Form, ARIA, CORS, quirks-mode and the other issues stay in
    /// the Issues tool without costing Best Practices; the form and ARIA
    /// ones are Accessibility's audits already.
    var countsInLighthouse: Bool {
        switch self {
        case .cspURL, .cspInline, .cspEval, .cspTrustedTypes, .mixedContent, .coepCorpMissing,
             .cookieSameSiteNoneInsecure, .cookieTooLarge, .cookieAttributeTooLarge, .cookieInvalidDomain, .cookieThirdPartyBlocked:
            true
        default:
            false
        }
    }

    var category: DeveloperIssueCategory {
        switch self {
        case .cspURL, .cspInline, .cspEval, .cspTrustedTypes: .contentSecurityPolicy
        case .mixedContent: .mixedContent
        case .corsAllowOrigin, .corsPreflight, .corsHeaderNotAllowed, .corsMethodNotAllowed, .corsCredentials, .corsScheme,
             .corsRedirect: .cors
        case .cookieSameSiteNoneInsecure, .cookieTooLarge, .cookieAttributeTooLarge, .cookieInvalidDomain,
             .cookieThirdPartyBlocked: .cookie
        case .formEmptyIdAndName, .formDuplicateId, .formInputWithNoLabel, .formLabelForNonExistingId, .formLabelForName,
             .formLabelHasNoField, .formAriaLabelledByNonExistingId, .formAutocompleteEmpty, .formAutocompleteMissing,
             .ariaInvalidRole, .ariaUnknownAttribute, .ariaInvalidValue, .ariaMissingReference, .ariaHiddenFocusable: .generic
        case .coepCorpMissing, .coopCoepInvalid, .crossOriginIsolationIncomplete: .crossOriginEmbedderPolicy
        case .sharedArrayBuffer, .deprecation: .other
        case .quirksMode: .quirksMode
        case .lowTextContrast: .lowTextContrast
        }
    }

    /// The kind an issue of this type has unless it says otherwise (a
    /// report-only CSP violation is an improvement, say).
    var kind: DeveloperIssueKind {
        switch self {
        case .cspURL, .cspInline, .cspEval, .cspTrustedTypes, .mixedContent,
             .corsAllowOrigin, .corsPreflight, .corsHeaderNotAllowed, .corsMethodNotAllowed, .corsCredentials, .corsScheme,
             .corsRedirect, .cookieTooLarge, .cookieInvalidDomain, .cookieThirdPartyBlocked,
             .formDuplicateId, .formLabelForNonExistingId, .formLabelForName,
             .coepCorpMissing, .coopCoepInvalid, .sharedArrayBuffer: .pageError
        case .cookieSameSiteNoneInsecure, .deprecation: .breakingChange
        case .cookieAttributeTooLarge, .formEmptyIdAndName, .formInputWithNoLabel, .formLabelHasNoField,
             .formAriaLabelledByNonExistingId, .formAutocompleteEmpty, .formAutocompleteMissing, .quirksMode,
             .lowTextContrast, .ariaInvalidRole, .ariaUnknownAttribute, .ariaInvalidValue, .ariaMissingReference,
             .ariaHiddenFocusable, .crossOriginIsolationIncomplete: .improvement
        }
    }

    var title: String {
        switch self {
        case .cspURL: "Content Security Policy of your site blocks some resources"
        case .cspInline: "Content Security Policy blocks inline execution of scripts and stylesheets"
        case .cspEval: "Content Security Policy of your site blocks the use of 'eval' in JavaScript"
        case .cspTrustedTypes: "Trusted Type expected, but String received"
        case .mixedContent: "Mixed content: load all resources via HTTPS to improve the security of your site"
        case .corsAllowOrigin: "Ensure CORS response header values are valid"
        case .corsPreflight: "Ensure preflight responses are valid"
        case .corsHeaderNotAllowed: "Ensure CORS requests include only allowed headers"
        case .corsMethodNotAllowed: "Ensure CORS requests use only allowed methods"
        case .corsCredentials: "Ensure credentialed requests are not sent to CORS resources with origin wildcards"
        case .corsScheme: "Ensure CORS requests are made on supported schemes"
        case .corsRedirect: "Ensure CORS requests are not redirected across origins"
        case .cookieSameSiteNoneInsecure: "Mark cross-site cookies as Secure to allow setting them in cross-site contexts"
        case .cookieTooLarge: "Ensure cookie name and value pairs don’t exceed 4096 characters"
        case .cookieAttributeTooLarge: "Ensure cookie attribute values don’t exceed 1024 characters"
        case .cookieInvalidDomain: "Ensure a cookie’s Domain attribute matches the host that sets it"
        case .cookieThirdPartyBlocked: "Third-party cookies are blocked in this browser"
        case .formEmptyIdAndName: "A form field element should have an id or name attribute"
        case .formDuplicateId: "Duplicate form field id in the same form"
        case .formInputWithNoLabel: "No label associated with a form field"
        case .formLabelForNonExistingId, .formLabelForName: "Incorrect use of <label for=FORM_ELEMENT>"
        case .formLabelHasNoField: "A <label> isn’t associated with a form field"
        case .formAriaLabelledByNonExistingId: "An aria-labelledby attribute doesn’t match any element id"
        case .formAutocompleteEmpty: "Incorrect use of autocomplete attribute"
        case .formAutocompleteMissing: "An element doesn’t have an autocomplete attribute"
        case .ariaInvalidRole: "An element has a role attribute with no valid ARIA role"
        case .ariaUnknownAttribute: "An element uses an ARIA attribute that doesn’t exist"
        case .ariaInvalidValue: "An ARIA attribute has a value it doesn’t allow"
        case .ariaMissingReference: "An ARIA attribute refers to an id that no element has"
        case .ariaHiddenFocusable: "A focusable element is hidden from assistive technology"
        case .coepCorpMissing: "Specify a Cross-Origin Resource Policy to prevent a resource from being blocked"
        case .coopCoepInvalid: "Ensure Cross-Origin-Opener-Policy and Cross-Origin-Embedder-Policy values are valid"
        case .crossOriginIsolationIncomplete: "The page asks for cross-origin isolation but isn’t cross-origin isolated"
        case .sharedArrayBuffer: "SharedArrayBuffer usage is restricted to cross-origin isolated sites"
        case .deprecation: "Deprecated feature used"
        case .quirksMode: "Page layout may be unexpected due to Quirks Mode"
        case .lowTextContrast: "Users may have difficulties reading text content due to insufficient color contrast"
        }
    }

    /// What the issue means and how to fix it, as the expanded issue says.
    var explanation: String {
        switch self {
        case .cspURL:
            "The page’s Content Security Policy blocked resources from loading because their origin isn’t listed in the policy’s directives. Add the origins to the directive named below, or serve the resources from an origin the policy already allows."
        case .cspInline:
            "The page’s Content Security Policy blocked inline scripts, inline event handlers or inline styles. Move the code into separate files, or allow it with a nonce or a hash. Adding 'unsafe-inline' also works but removes much of the policy’s protection."
        case .cspEval:
            "The page’s Content Security Policy blocked eval(), new Function(), or setTimeout and setInterval called with a string. Rewrite the code to avoid evaluating strings, or add 'unsafe-eval' to script-src, which weakens the policy."
        case .cspTrustedTypes:
            "The page requires Trusted Types for scripts, and a string was passed to an injection sink such as innerHTML. Create the value with a Trusted Types policy instead."
        case .mixedContent:
            "This HTTPS page loaded resources over insecure HTTP. Browsers block active mixed content such as scripts, and upgrade or warn about passive content such as images. Load every resource over HTTPS."
        case .corsAllowOrigin:
            "A cross-origin request was blocked because the response’s Access-Control-Allow-Origin header was missing, or didn’t match the requesting origin. The server needs to send a valid Access-Control-Allow-Origin header for this origin."
        case .corsPreflight:
            "A cross-origin request needed a preflight (OPTIONS) request, and the preflight response wasn’t successful. The server must answer the preflight with a 2xx status and valid CORS headers."
        case .corsHeaderNotAllowed:
            "A cross-origin request sent a header that the server’s Access-Control-Allow-Headers response header doesn’t list. Add the header there, or don’t send it."
        case .corsMethodNotAllowed:
            "A cross-origin request used an HTTP method that the server’s Access-Control-Allow-Methods response header doesn’t list. Add the method there, or use one that is allowed."
        case .corsCredentials:
            "A credentialed cross-origin request was blocked: with credentials, Access-Control-Allow-Origin can’t be the wildcard * and Access-Control-Allow-Credentials must be true. Send the exact origin and allow credentials, or make the request without credentials."
        case .corsScheme:
            "Cross-origin requests work only over HTTP and HTTPS. Load the resource over one of those schemes."
        case .corsRedirect:
            "A cross-origin request was redirected in a way the CORS policy doesn’t allow. Request the final address directly, or make sure every response in the redirect chain sends valid CORS headers."
        case .cookieSameSiteNoneInsecure:
            "A cookie was set with SameSite=None but without the Secure attribute. Browsers that follow the current cookie standard, Chrome and Firefox among them, reject such cookies. Add Secure, and serve the response over HTTPS."
        case .cookieTooLarge:
            "A cookie’s name and value together were longer than 4096 characters, so the cookie was rejected. Store less in the cookie, or split it."
        case .cookieAttributeTooLarge:
            "One of a cookie’s attribute values was longer than 1024 characters and is ignored by browsers. Shorten the attribute."
        case .cookieInvalidDomain:
            "A Set-Cookie header named a Domain that the responding host isn’t part of, so the cookie was rejected. Use the response’s own host, or a parent domain of it, or leave out Domain."
        case .cookieThirdPartyBlocked:
            "A cross-site response tried to set a cookie. This browser blocks all third-party cookies, so the cookie was not stored. Use a first-party cookie, partitioned storage, or the Storage Access API."
        case .formEmptyIdAndName:
            "A form field has neither an id nor a name attribute. Either lets the browser autofill the form correctly; without them autofill may not work."
        case .formDuplicateId:
            "Several fields in the same form share an id. Ids must be unique; duplicates can stop autofill and labels from working. Give each field its own id."
        case .formInputWithNoLabel:
            "A form field has no label: no <label> refers to it or wraps it, and it has no aria-label or aria-labelledby. Labels help assistive technology and autofill. Add a <label>."
        case .formLabelForNonExistingId:
            "A label’s for attribute names an id that no element in the document has. Point for at the id of the field it labels."
        case .formLabelForName:
            "A label’s for attribute matches a field’s name, not its id. The for attribute must name the id of the field it labels."
        case .formLabelHasNoField:
            "A <label> has no for attribute and contains no form field, so it labels nothing. Add for, or put the field inside the label."
        case .formAriaLabelledByNonExistingId:
            "A field’s aria-labelledby attribute names an id that no element in the document has. Point it at an element that exists."
        case .formAutocompleteEmpty:
            "A field has an autocomplete attribute with an empty value, which is invalid. Give it a valid token, such as \"email\" or \"current-password\", or remove it."
        case .formAutocompleteMissing:
            "A field looks like it holds a well-known value (an email address, a password, a name) but has no autocomplete attribute. Add one so browsers and password managers can fill it in correctly."
        case .ariaInvalidRole:
            "An element’s role attribute names no role that WAI-ARIA defines, so assistive technology falls back to the element’s native role. Use a valid role, such as \"button\" or \"navigation\", or remove the attribute."
        case .ariaUnknownAttribute:
            "An element has an aria-* attribute that WAI-ARIA doesn’t define, often a misspelling. Assistive technology ignores it. Correct the name, or remove the attribute."
        case .ariaInvalidValue:
            "An ARIA attribute that takes true or false (or, for some, mixed or undefined) has another value, so assistive technology may read it wrongly. Use one of the values the attribute allows."
        case .ariaMissingReference:
            "An ARIA attribute such as aria-labelledby, aria-describedby or aria-controls lists an id that no element in the document has, so the relationship it describes is lost. Point it at an element that exists."
        case .ariaHiddenFocusable:
            "An element with aria-hidden=\"true\" can still receive keyboard focus, or contains an element that can. Keyboard users can reach it, but screen readers announce nothing. Make it unfocusable with tabindex=\"-1\" or inert, or don’t hide it."
        case .coepCorpMissing:
            "The page sends Cross-Origin-Embedder-Policy: require-corp, so cross-origin resources it loads without CORS must send a Cross-Origin-Resource-Policy header. The resources below came without one, and browsers block them. Send Cross-Origin-Resource-Policy: cross-origin (or same-site) with them, load them with CORS, or use COEP credentialless."
        case .coopCoepInvalid:
            "A Cross-Origin-Opener-Policy or Cross-Origin-Embedder-Policy header has a value the browser doesn’t recognise, so it is ignored. COOP takes same-origin, same-origin-allow-popups or unsafe-none; COEP takes require-corp, credentialless or unsafe-none."
        case .crossOriginIsolationIncomplete:
            "The page sends Cross-Origin-Embedder-Policy, which asks for cross-origin isolation, but crossOriginIsolated is false. Isolation needs both Cross-Origin-Opener-Policy: same-origin and Cross-Origin-Embedder-Policy: require-corp (or credentialless) on the top-level document, served over HTTPS or from localhost. Until then, SharedArrayBuffer and precise timers aren’t available."
        case .sharedArrayBuffer:
            "The page used SharedArrayBuffer without being cross-origin isolated. Browsers, WebKit among them, make SharedArrayBuffer available only to cross-origin isolated pages. Send Cross-Origin-Opener-Policy: same-origin and Cross-Origin-Embedder-Policy: require-corp with the document."
        case .deprecation:
            "The page used a feature that is deprecated and may be removed from browsers in the future. The message below names it."
        case .quirksMode:
            "The document is rendered in Quirks Mode because it lacks a <!DOCTYPE html> declaration, or has an old one. Layout may differ from other browsers. Start the document with <!DOCTYPE html>."
        case .lowTextContrast:
            "Some text doesn’t have enough contrast against its background for WCAG AA: at least 4.5 for normal text, 3 for large text. Low-contrast text is hard or impossible for many people to read."
        }
    }

    var links: [DeveloperIssueLink] {
        switch self {
        case .cspURL:
            [DeveloperIssueLink(title: "Content Security Policy - Source Allowlists", url: "https://web.dev/articles/csp#source_allowlists")]
        case .cspInline:
            [DeveloperIssueLink(title: "Content Security Policy - Inline Code", url: "https://web.dev/articles/csp#inline_code_is_considered_harmful")]
        case .cspEval:
            [DeveloperIssueLink(title: "Content Security Policy - Eval", url: "https://web.dev/articles/csp#eval_too")]
        case .cspTrustedTypes:
            [DeveloperIssueLink(title: "Trusted Types API", url: "https://developer.mozilla.org/docs/Web/API/Trusted_Types_API")]
        case .mixedContent:
            [DeveloperIssueLink(title: "Preventing mixed content", url: "https://web.dev/articles/fixing-mixed-content")]
        case .corsAllowOrigin, .corsPreflight, .corsHeaderNotAllowed, .corsMethodNotAllowed, .corsCredentials, .corsScheme,
             .corsRedirect:
            [DeveloperIssueLink(title: "Cross-Origin Resource Sharing (CORS)", url: "https://developer.mozilla.org/docs/Web/HTTP/CORS"),
             DeveloperIssueLink(title: "CORS errors", url: "https://developer.mozilla.org/docs/Web/HTTP/CORS/Errors")]
        case .cookieSameSiteNoneInsecure:
            [DeveloperIssueLink(title: "SameSite cookies explained", url: "https://web.dev/articles/samesite-cookies-explained")]
        case .cookieTooLarge, .cookieAttributeTooLarge, .cookieInvalidDomain:
            [DeveloperIssueLink(title: "Set-Cookie", url: "https://developer.mozilla.org/docs/Web/HTTP/Headers/Set-Cookie")]
        case .cookieThirdPartyBlocked:
            [DeveloperIssueLink(title: "Third-party cookies", url: "https://developer.mozilla.org/docs/Web/Privacy/Guides/Third-party_cookies"),
             DeveloperIssueLink(title: "Full third-party cookie blocking", url: "https://webkit.org/blog/10218/full-third-party-cookie-blocking-and-more/")]
        case .formEmptyIdAndName, .formDuplicateId:
            [DeveloperIssueLink(title: "The form input element", url: "https://developer.mozilla.org/docs/Web/HTML/Element/input")]
        case .formInputWithNoLabel, .formLabelForNonExistingId, .formLabelForName, .formLabelHasNoField:
            [DeveloperIssueLink(title: "The label element", url: "https://developer.mozilla.org/docs/Web/HTML/Element/label")]
        case .formAriaLabelledByNonExistingId:
            [DeveloperIssueLink(title: "aria-labelledby", url: "https://developer.mozilla.org/docs/Web/Accessibility/ARIA/Attributes/aria-labelledby")]
        case .formAutocompleteEmpty, .formAutocompleteMissing:
            [DeveloperIssueLink(title: "HTML attribute: autocomplete", url: "https://developer.mozilla.org/docs/Web/HTML/Attributes/autocomplete")]
        case .ariaInvalidRole:
            [DeveloperIssueLink(title: "WAI-ARIA roles", url: "https://developer.mozilla.org/docs/Web/Accessibility/ARIA/Roles")]
        case .ariaUnknownAttribute, .ariaInvalidValue:
            [DeveloperIssueLink(title: "ARIA states and properties", url: "https://developer.mozilla.org/docs/Web/Accessibility/ARIA/Attributes")]
        case .ariaMissingReference:
            [DeveloperIssueLink(title: "aria-labelledby", url: "https://developer.mozilla.org/docs/Web/Accessibility/ARIA/Attributes/aria-labelledby"),
             DeveloperIssueLink(title: "aria-describedby", url: "https://developer.mozilla.org/docs/Web/Accessibility/ARIA/Attributes/aria-describedby")]
        case .ariaHiddenFocusable:
            [DeveloperIssueLink(title: "aria-hidden", url: "https://developer.mozilla.org/docs/Web/Accessibility/ARIA/Attributes/aria-hidden")]
        case .coepCorpMissing:
            [DeveloperIssueLink(title: "COEP and COOP", url: "https://web.dev/articles/coop-coep"),
             DeveloperIssueLink(title: "Cross-Origin-Resource-Policy", url: "https://developer.mozilla.org/docs/Web/HTTP/Headers/Cross-Origin-Resource-Policy")]
        case .coopCoepInvalid, .crossOriginIsolationIncomplete:
            [DeveloperIssueLink(title: "Making your website cross-origin isolated", url: "https://web.dev/articles/coop-coep"),
             DeveloperIssueLink(title: "crossOriginIsolated", url: "https://developer.mozilla.org/docs/Web/API/Window/crossOriginIsolated")]
        case .sharedArrayBuffer:
            [DeveloperIssueLink(title: "SharedArrayBuffer security requirements", url: "https://developer.mozilla.org/docs/Web/JavaScript/Reference/Global_Objects/SharedArrayBuffer#security_requirements"),
             DeveloperIssueLink(title: "Making your website cross-origin isolated", url: "https://web.dev/articles/coop-coep")]
        case .deprecation:
            [DeveloperIssueLink(title: "Deprecated and obsolete features", url: "https://developer.mozilla.org/docs/Web/JavaScript/Reference/Deprecated_and_obsolete_features")]
        case .quirksMode:
            [DeveloperIssueLink(title: "Quirks Mode and Standards Mode", url: "https://developer.mozilla.org/docs/Web/HTML/Quirks_Mode_and_Standards_Mode")]
        case .lowTextContrast:
            [DeveloperIssueLink(title: "Color and contrast accessibility", url: "https://web.dev/articles/color-and-contrast-accessibility")]
        }
    }
}

/// An element found by a page scan, by its place in that scan's list.
struct DeveloperIssueElement: Hashable {
    /// Which scan found it (DeveloperIssuesModel keeps the scan's elements).
    var scan: String
    var index: Int
}

/// One thing an issue affects: a request, an element, a source line, a
/// cookie or a CSP directive. `label` is what its row shows; the links go
/// to Network (`requestID`), Elements (`element`) or Sources (`url` and
/// `line`).
struct DeveloperAffectedResource: Hashable {
    enum Kind: String, CaseIterable {
        case directive, cookie, request, element, source

        func count(_ count: Int) -> String {
            switch self {
            case .directive: count == 1 ? "1 directive" : "\(count) directives"
            case .cookie: count == 1 ? "1 cookie" : "\(count) cookies"
            case .request: count == 1 ? "1 request" : "\(count) requests"
            case .element: count == 1 ? "1 element" : "\(count) elements"
            case .source: count == 1 ? "1 source" : "\(count) sources"
            }
        }
    }

    var kind: Kind
    var label: String
    /// A status or reason beside the label: "blocked", the CORS problem, the directive.
    var detail: String?
    var url: String?
    var line: Int?
    var column: Int?
    var requestID: String?
    var element: DeveloperIssueElement?

    /// The source location, as a file:line link reads.
    var location: String? {
        guard let url, !url.isEmpty, line != nil else { return nil }
        return ConsoleFormat.location(url, line: line)
    }
}

/// One issue: a single violation, rejected cookie or field, before the
/// pane gathers issues of the same type together. Issues with the same
/// `key` are the same issue reported twice, as Chrome's IssuesManager
/// drops a repeat with the same details.
struct DeveloperIssue: Hashable, Identifiable {
    var code: DeveloperIssueCode
    var kind: DeveloperIssueKind
    var key: String
    /// What sets this issue apart from others of its code in the pane:
    /// a deprecation's message. Issues with different subtitles are listed
    /// apart.
    var subtitle: String?
    var resources: [DeveloperAffectedResource]
    /// A cookie issue about a third-party cookie, hidden unless "Include
    /// third-party cookie issues" is on.
    var thirdParty = false

    var id: String { key }
    /// The row this issue is counted under.
    var groupID: String { code.rawValue + "|" + kind.rawValue + "|" + (subtitle ?? "") }

    init(code: DeveloperIssueCode, kind: DeveloperIssueKind? = nil, key: String, subtitle: String? = nil,
         resources: [DeveloperAffectedResource], thirdParty: Bool = false) {
        self.code = code
        self.kind = kind ?? code.kind
        self.key = key
        self.subtitle = subtitle
        self.resources = resources
        self.thirdParty = thirdParty
    }
}

/// One row of the pane: the issues of one type together, with how many
/// there are and everything they affect.
struct DeveloperIssueGroup: Identifiable, Equatable {
    var id: String
    var code: DeveloperIssueCode
    var kind: DeveloperIssueKind
    var subtitle: String?
    var count: Int
    var resources: [DeveloperAffectedResource]

    var category: DeveloperIssueCategory { code.category }
    var title: String { code.title }

    func resources(_ kind: DeveloperAffectedResource.Kind) -> [DeveloperAffectedResource] {
        resources.filter { $0.kind == kind }
    }
}

/// A heading of the pane, when grouped by kind or by category (or both,
/// kind first): its own rows, and the headings under it.
struct DeveloperIssueSection: Identifiable, Equatable {
    var id: String
    var title: String
    var kind: DeveloperIssueKind?
    var groups: [DeveloperIssueGroup] = []
    var children: [DeveloperIssueSection] = []

    var count: Int { groups.reduce(0) { $0 + $1.count } + children.reduce(0) { $0 + $1.count } }
}

/// A console message as the rules read it.
struct DeveloperIssueMessage: Equatable {
    var level: String
    var text: String
    var source: String?
    var url: String?
    var line: Int?
    var column: Int?

    init(level: String, text: String, source: String? = nil, url: String? = nil, line: Int? = nil, column: Int? = nil) {
        self.level = level
        self.text = text
        self.source = source
        self.url = url
        self.line = line
        self.column = column
    }

    init(_ line: DeveloperToolsSession.ConsoleLine) {
        self.init(level: line.level, text: line.text, source: line.details?.source, url: line.url, line: line.line,
                  column: line.details?.column)
    }
}

/// What the page scan (DeveloperIssues-collect.js) reports of the page's
/// form fields and labels: plain facts, judged by DeveloperIssueRules.forms.
struct DeveloperFormSnapshot: Equatable {
    struct Field: Equatable {
        var index: Int
        var tag: String
        /// An input's type, lowercased; empty for select and textarea.
        var type: String = ""
        var id: String = ""
        var name: String = ""
        /// Nil when the attribute is absent, "" when present but empty.
        var autocomplete: String?
        /// How many <label>s label it (element.labels).
        var labels: Int = 0
        var ariaLabel: String = ""
        var ariaLabelledBy: String = ""
        var title: String = ""
        /// Its form's place in the page's forms, -1 for none.
        var form: Int = -1
        var label: String = ""
    }

    struct Label: Equatable {
        var index: Int
        /// Nil when the label has no for attribute.
        var forID: String?
        /// Whether a form field is inside it.
        var hasField: Bool = false
        var label: String = "label"
    }

    var fields: [Field] = []
    var labels: [Label] = []
    /// Every id in the document.
    var ids: Set<String> = []
    /// document.compatMode is BackCompat.
    var quirks = false
    /// Elements with a role or an aria-* attribute, for the ARIA rules.
    var aria: [DeveloperAriaElement] = []
    /// The page's `crossOriginIsolated`; nil when the scan couldn't tell.
    var crossOriginIsolated: Bool?

    init(fields: [Field] = [], labels: [Label] = [], ids: Set<String> = [], quirks: Bool = false,
         aria: [DeveloperAriaElement] = [], crossOriginIsolated: Bool? = nil) {
        self.fields = fields
        self.labels = labels
        self.ids = ids
        self.quirks = quirks
        self.aria = aria
        self.crossOriginIsolated = crossOriginIsolated
    }

    init(raw: [String: Any]) {
        func string(_ value: Any?) -> String { value as? String ?? "" }
        func int(_ value: Any?, _ fallback: Int) -> Int { (value as? NSNumber)?.intValue ?? fallback }
        fields = (raw["fields"] as? [[String: Any]] ?? []).map { item in
            Field(index: int(item["i"], -1), tag: string(item["tag"]).lowercased(), type: string(item["type"]).lowercased(),
                  id: string(item["id"]), name: string(item["name"]), autocomplete: item["autocomplete"] as? String,
                  labels: int(item["labels"], 0), ariaLabel: string(item["ariaLabel"]),
                  ariaLabelledBy: string(item["ariaLabelledBy"]), title: string(item["title"]), form: int(item["form"], -1),
                  label: string(item["label"]))
        }
        labels = (raw["labels"] as? [[String: Any]] ?? []).map { item in
            Label(index: int(item["i"], -1), forID: item["for"] as? String, hasField: item["hasField"] as? Bool ?? false,
                  label: item["label"] as? String ?? "label")
        }
        ids = Set(raw["ids"] as? [String] ?? [])
        quirks = raw["quirks"] as? Bool ?? false
        aria = (raw["aria"] as? [[String: Any]] ?? []).map(DeveloperAriaElement.init(raw:))
        crossOriginIsolated = raw["isolated"] as? Bool
    }
}

/// How the pane is arranged and filtered.
struct DeveloperIssueOptions: Equatable {
    var includeThirdPartyCookies = false
    var groupByCategory = false
    var groupByKind = true
}

// MARK: - The rules

enum DeveloperIssueRules {
    // MARK: Console messages

    /// Every issue the messages report, in order. A CORS failure is two
    /// messages in WebKit, the reason and then "… cannot load URL due to
    /// access control checks."; they make one issue.
    static func classify(_ messages: [DeveloperIssueMessage]) -> [DeveloperIssue] {
        var issues: [DeveloperIssue] = []
        var pendingCORS: (code: DeveloperIssueCode, reason: String, message: DeveloperIssueMessage)?
        func flushCORS() {
            guard let pending = pendingCORS else { return }
            pendingCORS = nil
            issues.append(corsIssue(pending.code, reason: pending.reason, url: nil, message: pending.message))
        }
        for message in messages {
            if let reason = corsReason(message.text) {
                flushCORS()
                pendingCORS = (reason.code, reason.reason, message)
                continue
            }
            if let url = corsURL(message.text) {
                if let pending = pendingCORS {
                    pendingCORS = nil
                    issues.append(corsIssue(pending.code, reason: pending.reason, url: url, message: message))
                } else {
                    issues.append(corsIssue(.corsAllowOrigin, reason: nil, url: url, message: message))
                }
                continue
            }
            flushCORS()
            if let issue = csp(message) ?? mixedContent(message) ?? isolation(message) ?? deprecation(message) {
                issues.append(issue)
            }
        }
        flushCORS()
        return issues
    }

    /// Whether a console message could be an issue at all, to keep only
    /// those.
    static func isCandidate(_ message: DeveloperIssueMessage) -> Bool {
        guard message.level == "error" || message.level == "warning" || message.source == "security" else { return false }
        let text = message.text
        return text.contains("Content Security Policy") || text.contains("Content-Security-Policy")
            || text.contains("Trusted") || text.contains("insecure content") || text.contains("Mixed Content")
            || text.contains("access control checks") || text.contains("Access-Control-") || text.contains("Preflight")
            || text.contains("Cross origin requests") || text.contains("Cross-Origin Resource Sharing")
            || text.range(of: "deprecated", options: .caseInsensitive) != nil
            || text.contains("SharedArrayBuffer") || text.contains("Cross-Origin-Embedder-Policy")
            || text.contains("Cross-Origin-Resource-Policy")
    }

    private static func source(_ message: DeveloperIssueMessage) -> DeveloperAffectedResource? {
        guard let url = message.url, !url.isEmpty, let line = message.line, line > 0 else { return nil }
        return DeveloperAffectedResource(kind: .source, label: ConsoleFormat.location(url, line: line), url: url, line: line,
                                         column: message.column)
    }

    // MARK: Content Security Policy

    /// WebKit's ContentSecurityPolicy messages: "Refused to load
    /// https://x/a.js because it does not appear in the script-src
    /// directive of the Content Security Policy.", "Refused to execute a
    /// script because its hash, its nonce, or 'unsafe-inline' does not
    /// appear in the script-src directive…", "Refused to evaluate a string
    /// as JavaScript because 'unsafe-eval' does not appear in…", each with
    /// "[Report Only] " in front for a report-only policy.
    static func csp(_ message: DeveloperIssueMessage) -> DeveloperIssue? {
        var text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let reportOnly = text.hasPrefix("[Report Only]")
        if reportOnly { text = String(text.dropFirst("[Report Only]".count)).trimmingCharacters(in: .whitespaces) }
        let trustedTypes = text.contains("TrustedHTML") || text.contains("TrustedScript") || text.contains("Trusted Type")
            || text.contains("require-trusted-types-for")
        guard trustedTypes || (text.hasPrefix("Refused to") && text.contains("Content Security Policy")) else { return nil }
        let directive = first(#"the ([A-Za-z-]+) directive"#, in: text)
            ?? first(#"directive:? ["“]([^"”]+)["”]"#, in: text).map { $0.split(separator: " ").first.map(String.init) ?? $0 }
            ?? first(#"['"]?(require-trusted-types-for|trusted-types)"#, in: text)
        let code: DeveloperIssueCode
        var blocked: String?
        if trustedTypes {
            code = .cspTrustedTypes
            blocked = "trusted-types"
        } else if text.contains("unsafe-eval") || text.hasPrefix("Refused to evaluate") || text.contains("WebAssembly") {
            code = .cspEval
            blocked = "eval"
        } else if let url = blockedURL(text) {
            code = .cspURL
            blocked = url
        } else if text.contains("unsafe-inline") || text.contains("inline") || text.contains("nonce") || text.contains("hash") {
            code = .cspInline
            blocked = "inline"
        } else {
            code = .cspURL
        }
        let status = reportOnly ? "report-only" : "blocked"
        var resources = [DeveloperAffectedResource(kind: .directive, label: directive ?? "(unknown directive)",
                                                   detail: blocked.map { status + ": " + $0 } ?? status)]
        if code == .cspURL, let blocked {
            resources.append(DeveloperAffectedResource(kind: .request, label: blocked, detail: directive, url: blocked))
        }
        if let source = source(message) { resources.append(source) }
        let key = ["csp", code.rawValue, reportOnly ? "report" : "enforce", directive ?? "", blocked ?? "",
                   message.url ?? "", message.line.map(String.init) ?? ""].joined(separator: "|")
        return DeveloperIssue(code: code, kind: reportOnly ? .improvement : nil, key: key, resources: resources)
    }

    /// The address a CSP message says was refused, quoted or not.
    static func blockedURL(_ text: String) -> String? {
        guard let url = first(#"Refused to [^'"]*?['"]?((?:https?|wss?|data|blob|ftp|file):[^\s'"]+)"#, in: text) else { return nil }
        return trimmedURL(url)
    }

    // MARK: Mixed content

    /// WebKit's MixedContentChecker messages, and Chrome's wording too:
    /// "[blocked] The page at https://a requested insecure content from
    /// http://b. This content was blocked and must be served over HTTPS."
    /// and "… This content was automatically upgraded and should be served
    /// over HTTPS." (current WebKit), "[blocked] The page at https://a was
    /// not allowed to display insecure content from http://b." (older).
    static func mixedContent(_ message: DeveloperIssueMessage) -> DeveloperIssue? {
        let text = message.text
        let url: String?
        let status: String
        if let found = first(#"requested insecure content from (\S+?)\.?\s+This (?:content|request) (?:was|has been) automatically upgraded"#, in: text) {
            url = found
            status = "Automatically upgraded"
        } else if let groups = groups(#"The page at \S+ (was not allowed|was allowed) to (?:display|run) insecure content from (\S+)"#, in: text),
                  groups.count == 2 {
            url = groups[1]
            status = groups[0] == "was allowed" && !text.hasPrefix("[blocked]") ? "Warned" : "Blocked"
        } else if let groups = groups(#"Mixed Content: The page at '[^']*' was loaded over HTTPS, but requested an insecure \S+ '([^']+)'\. (.*)"#, in: text),
                  groups.count == 2 {
            url = groups[0]
            let rest = groups[1].lowercased()
            status = rest.contains("blocked") ? "Blocked" : rest.contains("upgraded") ? "Automatically upgraded" : "Warned"
        } else if let found = first(#"requested insecure content from (\S+)"#, in: text) {
            url = found
            status = text.contains("blocked") ? "Blocked" : "Warned"
        } else {
            return nil
        }
        guard let address = url.map(trimmedURL), !address.isEmpty else { return nil }
        return mixedContentIssue(url: address, status: status, source: source(message))
    }

    static func mixedContentIssue(url: String, status: String, requestID: String? = nil,
                                  source: DeveloperAffectedResource? = nil) -> DeveloperIssue {
        var resources = [DeveloperAffectedResource(kind: .request, label: url, detail: status, url: url, requestID: requestID)]
        if let source { resources.append(source) }
        return DeveloperIssue(code: .mixedContent, key: "mixed|" + url, resources: resources)
    }

    /// Requests the Network panel saw over plain HTTP from an HTTPS page,
    /// for mixed content the Console didn't mention. http://localhost and
    /// loopback addresses are trustworthy, as in Chrome.
    static func mixedContent(requests: [(id: String, url: String, failed: Bool)], pageURL: String?) -> [DeveloperIssue] {
        guard let pageURL, pageURL.lowercased().hasPrefix("https:") else { return [] }
        return requests.compactMap { request in
            guard request.url.lowercased().hasPrefix("http:"), let host = URL(string: request.url)?.host()?.lowercased(),
                  !isLoopback(host) else { return nil }
            return mixedContentIssue(url: request.url, status: request.failed ? "Blocked" : "Warned", requestID: request.id)
        }
    }

    private static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host.hasSuffix(".localhost") || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    // MARK: CORS

    /// The reason WebKit logs first for a failed cross-origin request.
    static func corsReason(_ text: String) -> (code: DeveloperIssueCode, reason: String)? {
        let reason = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if reason.hasPrefix("Preflight response is not successful") || reason.contains("preflight") && reason.contains("Access-Control") {
            return (.corsPreflight, reason)
        }
        if reason.contains("is not allowed by Access-Control-Allow-Headers") { return (.corsHeaderNotAllowed, reason) }
        if reason.contains("is not allowed by Access-Control-Allow-Methods") { return (.corsMethodNotAllowed, reason) }
        if reason.contains("Access-Control-Allow-Credentials") || reason.contains("wildcard in Access-Control-Allow-Origin") {
            return (.corsCredentials, reason)
        }
        if reason.hasPrefix("Cross origin requests are only supported for") { return (.corsScheme, reason) }
        if reason.contains("denied by Cross-Origin Resource Sharing policy") || reason.contains("Cross-origin redirection") {
            return (.corsRedirect, reason)
        }
        if reason.contains("is not allowed by Access-Control-Allow-Origin") || reason.contains("Access-Control-Allow-Origin cannot")
            || reason.contains("Access-Control-Allow-Origin") && reason.contains("missing") {
            return (.corsAllowOrigin, reason)
        }
        return nil
    }

    /// "Fetch API cannot load URL due to access control checks.",
    /// "XMLHttpRequest cannot load URL …", "Cannot load image URL …".
    static func corsURL(_ text: String) -> String? {
        first(#"(?:cannot|Cannot) load (?:image |font |script |stylesheet )?(\S+) due to access control checks"#, in: text).map(trimmedURL)
    }

    private static func corsIssue(_ code: DeveloperIssueCode, reason: String?, url: String?,
                                  message: DeveloperIssueMessage) -> DeveloperIssue {
        var resources: [DeveloperAffectedResource] = []
        if let url {
            resources.append(DeveloperAffectedResource(kind: .request, label: url, detail: reason, url: url))
        } else if let reason {
            resources.append(DeveloperAffectedResource(kind: .request, label: reason))
        }
        if let source = source(message) { resources.append(source) }
        let key = ["cors", code.rawValue, url ?? "", reason ?? "", message.url ?? "", message.line.map(String.init) ?? ""]
            .joined(separator: "|")
        return DeveloperIssue(code: code, key: key, resources: resources)
    }

    // MARK: Deprecations

    /// A warning that names something deprecated: each different message
    /// is its own row, as Chrome lists each deprecated feature apart.
    static func deprecation(_ message: DeveloperIssueMessage) -> DeveloperIssue? {
        guard message.level == "warning" || message.level == "error",
              message.text.range(of: "deprecated", options: .caseInsensitive) != nil else { return nil }
        let text = String(message.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        let resources = source(message).map { [$0] } ?? []
        let key = ["deprecation", text, message.url ?? "", message.line.map(String.init) ?? ""].joined(separator: "|")
        return DeveloperIssue(code: .deprecation, key: key, subtitle: text, resources: resources)
    }

    // MARK: Cookies

    /// What's wrong with the cookies one response's Set-Cookie headers
    /// set: rejected for size, an invalid Domain, SameSite=None without
    /// Secure, or (on a cross-site response) third-party and blocked.
    static func cookies(setCookie: String, responseURL: String, pageURL: String?, requestID: String?) -> [DeveloperIssue] {
        let host = URL(string: responseURL)?.host()?.lowercased() ?? ""
        let thirdParty: Bool = {
            guard let pageURL, let pageHost = URL(string: pageURL)?.host()?.lowercased(), !host.isEmpty else { return false }
            return site(of: host) != site(of: pageHost)
        }()
        var issues: [DeveloperIssue] = []
        for line in DeveloperRequestCookie.setCookieLines(setCookie) {
            let parts = line.split(separator: ";", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let pair = parts.first, !pair.isEmpty else { continue }
            let name = pair.firstIndex(of: "=").map { String(pair[..<$0]).trimmingCharacters(in: .whitespaces) } ?? pair
            var attributes: [(name: String, value: String)] = []
            for part in parts.dropFirst() where !part.isEmpty {
                if let equals = part.firstIndex(of: "=") {
                    attributes.append((String(part[..<equals]).trimmingCharacters(in: .whitespaces).lowercased(),
                                       String(part[part.index(after: equals)...]).trimmingCharacters(in: .whitespaces)))
                } else {
                    attributes.append((part.lowercased(), ""))
                }
            }
            let value = { (attribute: String) in attributes.last { $0.name == attribute }?.value }
            let domain = value("domain") ?? ""
            let path = value("path") ?? ""
            let secure = attributes.contains { $0.name == "secure" }
            let sameSite = value("samesite")?.lowercased()
            let place = (domain.isEmpty ? host : domain) + (path.isEmpty ? "/" : path)
            func issue(_ code: DeveloperIssueCode, _ detail: String, third: Bool = false) -> DeveloperIssue {
                var resources = [DeveloperAffectedResource(kind: .cookie, label: name, detail: place, url: responseURL,
                                                           requestID: requestID)]
                resources.append(DeveloperAffectedResource(kind: .request, label: responseURL, detail: detail, url: responseURL,
                                                           requestID: requestID))
                let key = ["cookie", code.rawValue, name, place, requestID ?? responseURL].joined(separator: "|")
                return DeveloperIssue(code: code, key: key, resources: resources, thirdParty: third)
            }
            if pair.utf8.count > 4096 {
                issues.append(issue(.cookieTooLarge, "\(pair.utf8.count) characters"))
                continue
            }
            if let long = attributes.first(where: { $0.value.utf8.count > 1024 }) {
                issues.append(issue(.cookieAttributeTooLarge, long.name + ": \(long.value.utf8.count) characters"))
            }
            if !domain.isEmpty, !host.isEmpty, !domainMatches(host: host, domain: domain) {
                issues.append(issue(.cookieInvalidDomain, "Domain=" + domain + " on " + host))
                continue
            }
            if sameSite == "none" && !secure {
                issues.append(issue(.cookieSameSiteNoneInsecure, "SameSite=None without Secure", third: thirdParty))
            }
            if thirdParty {
                issues.append(issue(.cookieThirdPartyBlocked, "Blocked: third-party", third: true))
            }
        }
        return issues
    }

    /// Whether a host may set a cookie for a Domain attribute: the host
    /// itself, or a domain it is under (RFC 6265 domain-match).
    static func domainMatches(host: String, domain: String) -> Bool {
        var domain = domain.lowercased()
        while domain.hasPrefix(".") { domain.removeFirst() }
        let host = host.lowercased()
        guard !domain.isEmpty else { return false }
        if host == domain { return true }
        if isIPAddress(host) { return false }
        return host.hasSuffix("." + domain) && domain.contains(".")
    }

    private static func isIPAddress(_ host: String) -> Bool {
        host.contains(":") || host.split(separator: ".").allSatisfy { Int($0) != nil }
    }

    /// Second-level public suffixes common enough that site(of:) keeps one
    /// more label for them. Not the full Public Suffix List.
    private static let twoLabelSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "com.au", "net.au", "org.au", "co.nz", "co.jp", "ne.jp", "or.jp",
        "com.br", "com.cn", "com.mx", "co.in", "co.kr", "com.tr", "co.za", "com.sg", "com.hk", "com.tw",
        "github.io", "gitlab.io", "herokuapp.com", "vercel.app", "netlify.app", "pages.dev", "web.app",
        "firebaseapp.com", "appspot.com", "blogspot.com", "cloudfront.net", "azurewebsites.net",
    ]

    /// A host's site (its registrable domain, roughly): "a.b.example.com"
    /// is example.com, "x.github.io" is itself.
    static func site(of host: String) -> String {
        let host = host.lowercased()
        if isIPAddress(host) { return host }
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count > 2 else { return host }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        return twoLabelSuffixes.contains(lastTwo) ? labels.suffix(3).joined(separator: ".") : lastTwo
    }

    // MARK: Forms

    /// Field types that carry their own label (a button's text) or none.
    private static let unlabelled: Set<String> = ["hidden", "submit", "button", "reset", "image"]
    /// Types that take no text, so no autocomplete either.
    private static let noAutocomplete: Set<String> = ["checkbox", "radio", "file", "range", "color", "submit", "button",
                                                      "reset", "image", "hidden"]
    /// Autocomplete tokens an id or name may spell (HTML's autofill field
    /// names), and the input types that always want autocomplete.
    static let autocompleteTokens: Set<String> = [
        "name", "honorific-prefix", "given-name", "additional-name", "family-name", "honorific-suffix", "nickname",
        "email", "username", "new-password", "current-password", "one-time-code", "organization-title", "organization",
        "street-address", "address-line1", "address-line2", "address-line3", "address-level1", "address-level2",
        "country", "country-name", "postal-code", "cc-name", "cc-given-name", "cc-family-name", "cc-number", "cc-exp",
        "cc-exp-month", "cc-exp-year", "cc-csc", "cc-type", "bday", "sex", "tel", "tel-national", "url", "photo",
    ]

    /// Chrome's Generic form issues, judged on the page scan's snapshot.
    static func forms(_ snapshot: DeveloperFormSnapshot, scan: String) -> [DeveloperIssue] {
        var issues: [DeveloperIssue] = []
        func element(_ index: Int, _ label: String, _ detail: String? = nil) -> DeveloperAffectedResource {
            DeveloperAffectedResource(kind: .element, label: label.isEmpty ? "element" : label, detail: detail,
                                      element: index >= 0 ? DeveloperIssueElement(scan: scan, index: index) : nil)
        }
        func key(_ code: DeveloperIssueCode, _ index: Int, _ label: String) -> String {
            ["form", code.rawValue, String(index), label].joined(separator: "|")
        }
        // Duplicate ids within one form.
        var byID: [String: [DeveloperFormSnapshot.Field]] = [:]
        var order: [String] = []
        for field in snapshot.fields where !field.id.isEmpty && field.form >= 0 {
            let id = "\(field.form)#" + field.id
            if byID[id] == nil { order.append(id) }
            byID[id, default: []].append(field)
        }
        for id in order {
            guard let fields = byID[id], fields.count > 1 else { continue }
            issues.append(DeveloperIssue(code: .formDuplicateId, key: "form|duplicate|" + id,
                                         resources: fields.map { element($0.index, $0.label, "id=" + $0.id) }))
        }
        for field in snapshot.fields {
            let labelable = !unlabelled.contains(field.type)
            if labelable, field.id.isEmpty, field.name.isEmpty {
                issues.append(DeveloperIssue(code: .formEmptyIdAndName, key: key(.formEmptyIdAndName, field.index, field.label),
                                             resources: [element(field.index, field.label)]))
            }
            let ariaIDs = field.ariaLabelledBy.split(whereSeparator: \.isWhitespace).map(String.init)
            let missing = ariaIDs.filter { !snapshot.ids.contains($0) }
            if !missing.isEmpty {
                issues.append(DeveloperIssue(code: .formAriaLabelledByNonExistingId,
                                             key: key(.formAriaLabelledByNonExistingId, field.index, field.label),
                                             resources: [element(field.index, field.label, "aria-labelledby=" + missing.joined(separator: " "))]))
            }
            if labelable, field.labels == 0, field.ariaLabel.trimmingCharacters(in: .whitespaces).isEmpty,
               ariaIDs.allSatisfy({ !snapshot.ids.contains($0) }), field.title.isEmpty {
                issues.append(DeveloperIssue(code: .formInputWithNoLabel, key: key(.formInputWithNoLabel, field.index, field.label),
                                             resources: [element(field.index, field.label)]))
            }
            guard !noAutocomplete.contains(field.type) else { continue }
            if let autocomplete = field.autocomplete {
                if autocomplete.trimmingCharacters(in: .whitespaces).isEmpty {
                    issues.append(DeveloperIssue(code: .formAutocompleteEmpty, key: key(.formAutocompleteEmpty, field.index, field.label),
                                                 resources: [element(field.index, field.label, "autocomplete=\"\"")]))
                }
            } else if field.tag == "input" && (field.type == "password" || field.type == "email")
                        || autocompleteTokens.contains(field.id.lowercased()) || autocompleteTokens.contains(field.name.lowercased()) {
                let hint = field.type == "password" ? "type=password" : field.type == "email" ? "type=email"
                    : autocompleteTokens.contains(field.id.lowercased()) ? "id=" + field.id : "name=" + field.name
                issues.append(DeveloperIssue(code: .formAutocompleteMissing, key: key(.formAutocompleteMissing, field.index, field.label),
                                             resources: [element(field.index, field.label, hint)]))
            }
        }
        let names = Set(snapshot.fields.map(\.name).filter { !$0.isEmpty })
        for label in snapshot.labels {
            if let forID = label.forID {
                guard !snapshot.ids.contains(forID) else { continue }
                let code: DeveloperIssueCode = names.contains(forID) ? .formLabelForName : .formLabelForNonExistingId
                issues.append(DeveloperIssue(code: code, key: key(code, label.index, label.label),
                                             resources: [element(label.index, label.label, "for=" + forID)]))
            } else if !label.hasField {
                issues.append(DeveloperIssue(code: .formLabelHasNoField, key: key(.formLabelHasNoField, label.index, label.label),
                                             resources: [element(label.index, label.label)]))
            }
        }
        if snapshot.quirks {
            issues.append(DeveloperIssue(code: .quirksMode, key: "quirks|" + scan,
                                         resources: [DeveloperAffectedResource(kind: .element, label: "document", detail: "Quirks Mode")]))
        }
        return issues
    }

    // MARK: Contrast

    /// The CSS overview's contrast problems, one issue per element, as
    /// Chrome's LowTextContrastIssue is.
    static func contrast(_ problems: [DeveloperCSSOverview.ContrastIssue], label: (Int) -> String,
                         scan: String) -> [DeveloperIssue] {
        problems.flatMap { problem in
            problem.elements.map { index in
                let detail = "Contrast ratio " + DeveloperCSSOverview.ratioLabel(problem.ratio) + ", minimum AA ratio "
                    + (problem.threshold == 3 ? "3" : "4.5") + " (" + problem.text.hex + " on " + problem.background.hex + ")"
                return DeveloperIssue(code: .lowTextContrast, key: "contrast|\(index)|" + problem.id,
                                      resources: [DeveloperAffectedResource(kind: .element, label: label(index), detail: detail,
                                                                            element: DeveloperIssueElement(scan: scan, index: index))])
            }
        }
    }

    // MARK: Requests

    /// Ties each request resource to the Network panel's request with the
    /// same address, when it doesn't name one already: the latest one.
    static func link(_ issues: [DeveloperIssue], requests: [(id: String, url: String)]) -> [DeveloperIssue] {
        guard !requests.isEmpty else { return issues }
        var byURL: [String: String] = [:]
        for request in requests { byURL[request.url] = request.id }
        return issues.map { issue in
            var issue = issue
            issue.resources = issue.resources.map { resource in
                var resource = resource
                if resource.kind == .request || resource.kind == .cookie, resource.requestID == nil, let url = resource.url {
                    resource.requestID = byURL[url]
                }
                return resource
            }
            return issue
        }
    }

    // MARK: Grouping

    /// The rows of the pane: repeats dropped, issues of a type together in
    /// the order first seen, their resources merged. Third-party cookie
    /// issues are left out unless asked for.
    static func aggregate(_ issues: [DeveloperIssue], includeThirdParty: Bool) -> [DeveloperIssueGroup] {
        var seen = Set<String>()
        var order: [String] = []
        var groups: [String: DeveloperIssueGroup] = [:]
        var resources: [String: Set<DeveloperAffectedResource>] = [:]
        for issue in issues where includeThirdParty || !issue.thirdParty {
            guard seen.insert(issue.key).inserted else { continue }
            let id = issue.groupID
            if groups[id] == nil {
                order.append(id)
                groups[id] = DeveloperIssueGroup(id: id, code: issue.code, kind: issue.kind, subtitle: issue.subtitle,
                                                 count: 0, resources: [])
            }
            groups[id]?.count += 1
            for resource in issue.resources {
                if resources[id, default: []].insert(resource).inserted { groups[id]?.resources.append(resource) }
            }
        }
        return order.compactMap { groups[$0] }
    }

    /// Third-party cookie issues the pane is hiding.
    static func hiddenCount(_ issues: [DeveloperIssue], includeThirdParty: Bool) -> Int {
        guard !includeThirdParty else { return 0 }
        return Set(issues.filter(\.thirdParty).map(\.key)).count
    }

    /// Issues of each kind, as the counters show them.
    static func counts(_ groups: [DeveloperIssueGroup]) -> [DeveloperIssueKind: Int] {
        var counts: [DeveloperIssueKind: Int] = [:]
        for group in groups { counts[group.kind, default: 0] += group.count }
        return counts
    }

    /// The pane's headings: by kind, by category, by kind then category,
    /// or none (one untitled section, rows by kind then as found).
    static func sections(_ groups: [DeveloperIssueGroup], byKind: Bool, byCategory: Bool) -> [DeveloperIssueSection] {
        func categories(_ groups: [DeveloperIssueGroup], prefix: String) -> [DeveloperIssueSection] {
            DeveloperIssueCategory.allCases.compactMap { category in
                let rows = groups.filter { $0.category == category }.sorted { $0.kind < $1.kind }
                return rows.isEmpty ? nil : DeveloperIssueSection(id: prefix + category.rawValue, title: category.rawValue, groups: rows)
            }
        }
        if byKind {
            return DeveloperIssueKind.allCases.compactMap { kind in
                let rows = groups.filter { $0.kind == kind }
                guard !rows.isEmpty else { return nil }
                return byCategory
                    ? DeveloperIssueSection(id: kind.rawValue, title: kind.rawValue, kind: kind,
                                            children: categories(rows, prefix: kind.rawValue + "/"))
                    : DeveloperIssueSection(id: kind.rawValue, title: kind.rawValue, kind: kind, groups: rows)
            }
        }
        if byCategory { return categories(groups, prefix: "") }
        guard !groups.isEmpty else { return [] }
        return [DeveloperIssueSection(id: "all", title: "", groups: groups.enumerated().sorted {
            $0.element.kind != $1.element.kind ? $0.element.kind < $1.element.kind : $0.offset < $1.offset
        }.map(\.element))]
    }

    // MARK: Text

    private static var expressions: [String: NSRegularExpression] = [:]
    private static let expressionsLock = NSLock()

    private static func expression(_ pattern: String) -> NSRegularExpression? {
        expressionsLock.lock()
        defer { expressionsLock.unlock() }
        if let found = expressions[pattern] { return found }
        let made = try? NSRegularExpression(pattern: pattern)
        expressions[pattern] = made
        return made
    }

    /// The capture groups of a pattern's first match.
    static func groups(_ pattern: String, in text: String) -> [String]? {
        guard let regex = expression(pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<max(1, match.numberOfRanges)).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }

    static func first(_ pattern: String, in text: String) -> String? {
        groups(pattern, in: text)?.first
    }

    /// A URL as a message quotes it, without the sentence's full stop or quotes.
    static func trimmedURL(_ url: String) -> String {
        var url = url.trimmingCharacters(in: CharacterSet(charactersIn: "'\"“”‘’ "))
        while let last = url.last, ".,;)".contains(last) { url.removeLast() }
        return url
    }
}
