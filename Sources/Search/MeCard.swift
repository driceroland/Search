import AppKit
import Contacts

// Your own details under a form's boxes: name, email, phone, address, from
// your card in Contacts (the one marked Make This My Card), as Safari does.
// Off unless turned on in Settings › Passwords, which is when macOS asks
// whether Search may read Contacts.
//
// Only your card is read, never anyone else's, and nothing of it is
// written anywhere: it is held in memory while Search runs, and read again
// when Contacts says it changed. Nothing goes into a
// page until you pick a row under a box; then the boxes of that box's form
// that you can see, and that are still empty, get what goes in them.

@MainActor
final class MeCard {
    static let shared = MeCard()

    /// One row under a box: one of your addresses, emails or phone numbers,
    /// with the rest of the card beside it.
    struct Offer: Identifiable, Equatable {
        let id: String
        /// What goes into the box the caret is in.
        let title: String
        /// What else comes with it.
        let detail: String
        /// Everything for the form, by kind as autocomplete names it.
        let fields: [String: String]
    }

    private let store = CNContactStore()
    /// Your card as last read, read off the main thread: Contacts answers
    /// from another process, and a list under a box can't wait on it.
    private var card: CNContact?
    private var read = false
    private var reading: Task<Bool, Never>?
    private var watch: NSObjectProtocol?

    init() {
        // Any change to Contacts, anyone's card: yours is read again now,
        // not when the caret next lands in a box.
        watch = NotificationCenter.default.addObserver(forName: .CNContactStoreDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.read else { return }
                Task { await self.reload() }
            }
        }
    }

    static var allowed: Bool { CNContactStore.authorizationStatus(for: .contacts) == .authorized }

    /// The colour the boxes it fills flash: the Mac's accent colour (System
    /// Settings › Appearance), as CSS, faint enough to read the text through.
    static var tint: String {
        let color = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        func byte(_ part: CGFloat) -> Int { Int((part * 255).rounded()) }
        return "rgba(\(byte(color.redComponent)), \(byte(color.greenComponent)), \(byte(color.blueComponent)), 0.32)"
    }

    /// macOS's question, the first time; the answer it gave, after.
    func ask() async -> Bool {
        if Self.allowed { return true }
        return (try? await store.requestAccess(for: .contacts)) ?? false
    }

    /// Reads your card again; whether there is one to fill in from.
    @discardableResult
    func reload() async -> Bool {
        if let reading { return await reading.value }
        let task = Task<Bool, Never> {
            defer { reading = nil }
            guard Self.allowed else { card = nil; read = true; return false }
            card = await Task.detached(priority: .userInitiated) {
                try? CNContactStore().unifiedMeContactWithKeys(toFetch: MeCard.keys())
            }.value
            read = true
            return card != nil
        }
        reading = task
        return await task.value
    }

    nonisolated private static func keys() -> [CNKeyDescriptor] {
        [CNContactGivenNameKey, CNContactMiddleNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey,
         CNContactEmailAddressesKey, CNContactPhoneNumbersKey, CNContactPostalAddressesKey] as [CNKeyDescriptor]
            + [CNContactFormatter.descriptorForRequiredKeys(for: .fullName)]
    }

    /// The rows under a box of `kind`, from the card as last read. Not read
    /// yet: nothing this once, and it is read for the next box.
    func offers(for kind: String) -> [Offer] {
        guard Self.allowed else { return [] }
        if !read { Task { await reload() } }
        return card.map { Self.offers(from: $0, for: kind) } ?? []
    }


    /// The rows for a box of `kind`: one per address under an address's
    /// box, per email under an email's, per number under a phone's; under
    /// a name's, one per address. Four at most.
    nonisolated static func offers(from card: CNContact, for kind: String) -> [Offer] {
        let name = CNContactFormatter.string(from: card, style: .fullName)
            ?? [card.givenName, card.familyName].filter { !$0.isEmpty }.joined(separator: " ")
        let emails = card.emailAddresses.map { (label: $0.label, value: $0.value as String) }
        let phones = card.phoneNumbers.map { (label: $0.label, value: $0.value.stringValue) }
        let places = card.postalAddresses.map { (label: $0.label, value: $0.value) }

        func fields(email: String?, phone: String?, place: CNPostalAddress?) -> [String: String] {
            var out: [String: String] = [
                "name": name, "given-name": card.givenName, "additional-name": card.middleName,
                "family-name": card.familyName, "organization": card.organizationName,
                "email": email ?? "", "tel": phone ?? "", "tel-national": national(phone),
            ]
            if let place {
                let lines = place.street.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                out["street-address"] = lines.joined(separator: "\n")
                out["address-line1"] = lines.first ?? ""
                out["address-line2"] = lines.dropFirst().joined(separator: ", ")
                out["address-level2"] = place.city
                out["address-level1"] = place.state
                out["postal-code"] = place.postalCode
                out["country"] = place.isoCountryCode.uppercased()
                out["country-name"] = place.country
            }
            return out.filter { !$0.value.isEmpty }
        }
        // The number without its country's code, for a box that asks for
        // it so (tel-national): "+1 555 0100" is "555 0100". A number
        // written with no space after the code is left whole.
        func national(_ phone: String?) -> String {
            guard let phone else { return "" }
            return phone.replacingOccurrences(of: #"^\s*\+\d{1,3}[\s.\-]+"#, with: "", options: .regularExpression)
        }
        // "home" as Contacts hands it over; "Home" as it shows it.
        func label(_ raw: String?) -> String? {
            guard let raw, !raw.isEmpty else { return nil }
            let word = CNLabeledValue<NSString>.localizedString(forLabel: raw)
            return word.prefix(1).uppercased() + word.dropFirst()
        }
        func oneLine(_ place: CNPostalAddress) -> String {
            [place.street.components(separatedBy: .newlines).first ?? "", place.city]
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: ", ")
        }
        func offer(_ id: String, _ all: [String: String], detail: [String?]) -> Offer? {
            // What the box itself takes; a country's box shows its name.
            let shown = kind == "country" ? all["country-name"] : kind == "street-address"
                ? all["street-address"]?.replacingOccurrences(of: "\n", with: ", ") : all[kind]
            guard let title = shown, !title.isEmpty else { return nil }
            let rest = detail.compactMap { $0 }.filter { !$0.isEmpty && $0 != title }
            return Offer(id: id, title: title, detail: rest.isEmpty ? "Your card" : rest.joined(separator: " · "), fields: all)
        }

        let email = emails.first?.value
        let phone = phones.first?.value
        let place = places.first?.value
        var out: [Offer?] = []
        switch kind {
        case "email":
            for (i, e) in emails.enumerated() {
                out.append(offer("email\(i)", fields(email: e.value, phone: phone, place: place), detail: [name, label(e.label)]))
            }
        case "tel", "tel-national":
            for (i, p) in phones.enumerated() {
                out.append(offer("tel\(i)", fields(email: email, phone: p.value, place: place), detail: [name, label(p.label)]))
            }
        case let k where k.hasPrefix("address-") || ["street-address", "postal-code", "country", "country-name"].contains(k):
            for (i, p) in places.enumerated() {
                out.append(offer("place\(i)", fields(email: email, phone: phone, place: p.value),
                                 detail: [label(p.label), k == "address-line1" || k == "street-address" ? name : oneLine(p.value)]))
            }
        default:
            // A name or a company: with each address, or with none.
            if places.isEmpty {
                out.append(offer("card", fields(email: email, phone: phone, place: nil), detail: [email, phone]))
            }
            for (i, p) in places.enumerated() {
                out.append(offer("place\(i)", fields(email: email, phone: phone, place: p.value),
                                 detail: [oneLine(p.value), label(p.label)]))
            }
        }
        return Array(out.compactMap { $0 }.prefix(4))
    }
}
