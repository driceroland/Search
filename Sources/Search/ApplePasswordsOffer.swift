import Foundation

/// "Use your Apple passwords?": one quiet row under a sign-in box, for
/// someone who keeps their accounts in the Passwords app and hasn't found the
/// switch (Drice, 25 Oct). Apple Passwords stays off until it is clicked.
///
/// Offered sparingly, and remembered so it stays that way:
/// - only where Search keeps no account of its own for the site, so it never
///   pushes in front of an account you already have;
/// - at most once per site (its registrable domain), whatever happens then;
/// - never again once it has gone unanswered twice in all, or once its ✕
///   said "don't offer again";
/// - only on an https page of an ordinary tab, from the page itself or a
///   frame of its own site — never a private tab, never http, never a frame
///   of another site;
/// - only where Apple's helper can be reached at all (macOS 15.4 or later,
///   the helper on the system volume, signed by Apple);
/// - never in a test run, unless the bench asks for it (`appleoffer`).
struct ApplePasswordsOffer {
    /// Where the answers are kept: the settings, or a test's own suite.
    let store: UserDefaults

    static let offeredKey = "passwords.apple.offered"
    static let unansweredKey = "passwords.apple.offer.unanswered"
    static let neverKey = "passwords.apple.offer.never"
    /// Gone unanswered this many times, and it isn't offered again.
    static let patience = 2

    /// The bench's word, in a test run only: offer as a person would see it.
    /// The helper is then a stand-in (see Bench's `appleoffer`); Apple's own
    /// is never run from a test.
    @MainActor static var benchAsks = false
    /// The bench's stand-in for "this Mac has the helper", for the rule that
    /// takes it away.
    @MainActor static var benchHelper: Bool?

    /// Whether this Mac can reach Apple's helper: worked out once, since it
    /// reads a signature from disk.
    static let helperHere: Bool = {
        guard #available(macOS 15.4, *) else { return false }
        return AppleHelper.program() != nil
    }()

    /// What the decision is made from, gathered by the browser for the box
    /// the caret is in.
    struct Field: Equatable {
        /// The page's address, as committed.
        var page: URL?
        var privateTab: Bool
        /// The host of the frame the box is in, when it isn't the page
        /// itself.
        var frameHost: String? = nil
        /// A box that goes with a password, not one for passkeys alone.
        var passwords = true
        /// How many accounts Search keeps for the site.
        var kept = 0
    }

    struct Settings: Equatable {
        /// Apple Passwords already on: nothing to offer.
        var appleOn = false
        /// Filling turned off: the list of accounts doesn't come up at all.
        var fills = true
        var helper = true
        var testRun = false
        var benchAsks = false
    }

    /// The site the offer is counted against, if it may be offered under
    /// this box. Nil: not here, not now.
    func site(for field: Field, _ settings: Settings) -> String? {
        guard !settings.appleOn, settings.fills, settings.helper,
              !settings.testRun || settings.benchAsks,
              field.passwords, field.kept == 0,
              let host = ApplePasswords.offers(on: field.page, privateTab: field.privateTab)
        else { return nil }
        let site = Vault.registrable(host)
        if let frame = field.frameHost?.lowercased(), Vault.registrable(frame) != site { return nil }
        guard !store.bool(forKey: Self.neverKey),
              store.integer(forKey: Self.unansweredKey) < Self.patience,
              !offered.contains(site)
        else { return nil }
        return site
    }

    var offered: Set<String> { Set(store.stringArray(forKey: Self.offeredKey) ?? []) }

    /// It came up under a box on this site: not again here.
    func shown(on site: String) {
        var sites = offered
        guard sites.insert(site).inserted else { return }
        store.set(sites.sorted(), forKey: Self.offeredKey)
    }

    /// It went without an answer: the caret left, or another list came up.
    func unanswered() {
        store.set(store.integer(forKey: Self.unansweredKey) + 1, forKey: Self.unansweredKey)
    }

    /// Its ✕: never again, anywhere.
    func dismissed() {
        store.set(true, forKey: Self.neverKey)
    }

    /// Whether it will ever come up again, for Settings and the bench.
    var retired: Bool {
        store.bool(forKey: Self.neverKey) || store.integer(forKey: Self.unansweredKey) >= Self.patience
    }

    /// Back to never offered, for a test.
    func forget() {
        for key in [Self.offeredKey, Self.unansweredKey, Self.neverKey] { store.removeObject(forKey: key) }
    }
}
