import SwiftUI
import WebKit
import Combine

// The window's profile, followed as its space changes.
extension Browser {
    /// The History menu lists what the history holds, and the menu and the
    /// bookmarks are drawn from this object's changes — so the history's and
    /// the bookmarks' of the space's profile are passed on, and another
    /// profile's once the space on screen is in another.
    func followProfile() {
        guard followed != profileID else { return }
        followed = profileID
        profileBag = []
        history.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &profileBag)
        bookmarks.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &profileBag)
        if pageTab(.passwords) != nil { relist() }
        objectWillChange.send()
    }

    /// The profile a tab's page is signed in as: read from its store, so a
    /// page in a small window, a peek or the side panel answers for itself
    /// whatever the window shows now; for a private tab, the space it is in.
    func profile(of tab: Tab) -> UUID {
        if let owner = Profiles.owner(of: tab.store) { return owner }
        if tabs.contains(where: { $0 === tab }) { return profileID }
        let space = parked.first { $0.value.tabs.contains { $0 === tab } }?.key
        return space.flatMap { id in spaces.first { $0.id == id } }?.profileID ?? profileID
    }

    /// The space's menu › Profile: the space, and its tabs, into another.
    func setProfile(_ profile: UUID, of id: UUID) {
        guard let at = spaces.firstIndex(where: { $0.id == id }), spaces[at].profileID != profile else { return }
        var list = spaces
        // Sign-ins of its own stay behind with the profile it leaves: erased
        // now, while the store is still the space's to name (Spaces.erase
        // goes by what the space signs in with), and the space signs in as
        // its new profile does.
        if list[at].sharesSignIns != true, !list[at].isFirst {
            Spaces.erase(id)
            list[at].sharesSignIns = true
        }
        list[at].profile = profile == Profile.personalID ? nil : profile
        spaces = list
        Spaces.write(list)
        announce("\(list[at].name) is in \(Profiles.shared.profile(profile).name)")
    }

    /// The same, asked first: the space's tabs start again signed in as the
    /// other profile, and that is worth a yes.
    func askToMove(_ id: UUID, to profile: UUID) {
        guard let space = spaces.first(where: { $0.id == id }), space.profileID != profile else { return }
        let name = Profiles.shared.profile(profile).name
        let own = space.sharesSignIns != true && !space.isFirst
        Ask.sure("Move “\(space.name)” to “\(name)”?",
                 detail: "Its tabs reload signed in as \(name), with nothing of their old session, and what you do there from now on is kept in \(name)'s history, bookmarks and passwords."
                    + (own ? " The sign-ins this space had of its own are erased." : ""),
                 confirm: "Move") { [weak self] in self?.setProfile(profile, of: id) }
    }
}
