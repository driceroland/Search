import SwiftUI
import WebKit

/// A browsing profile, Safari-style.
///
/// Each profile owns its own isolated WebKit website data store — cookies,
/// local storage, caches, and logins — and its own row of tabs.
struct Profile: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var name: String
    var symbol: String
    var colorName: String
    var isDefault: Bool

    static let defaultPersonalID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    static let defaultWorkID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!

    static let defaultPersonal = Profile(
        id: defaultPersonalID,
        name: "Personal",
        symbol: "person.fill",
        colorName: "blue",
        isDefault: true
    )

    static let defaultWork = Profile(
        id: defaultWorkID,
        name: "Trabajo",
        symbol: "briefcase.fill",
        colorName: "orange",
        isDefault: false
    )

    var color: Color {
        ProfileColor.color(for: colorName)
    }

    /// The isolated data store for this profile.
    /// The default profile keeps the app's main store so existing logins and
    /// cookies are completely preserved. Other profiles receive their own
    /// persistent WebKit data store by UUID.
    var dataStore: WKWebsiteDataStore {
        if isDefault {
            return Store.websites
        }
        return WKWebsiteDataStore(forIdentifier: id)
    }
}

enum ProfileColor {
    static let all: [(name: String, title: String, color: Color)] = [
        ("blue", "Azul", .blue),
        ("orange", "Naranja", .orange),
        ("purple", "Morado", .purple),
        ("green", "Verde", .green),
        ("red", "Rojo", .red),
        ("pink", "Rosa", .pink),
        ("teal", "Verde azulado", .teal),
        ("indigo", "Índigo", .indigo),
        ("mint", "Menta", .mint),
        ("yellow", "Amarillo", .yellow),
    ]

    static func color(for name: String) -> Color {
        all.first { $0.name == name }?.color ?? .blue
    }
}

enum ProfileSymbols {
    static let all: [String] = [
        "person.fill",
        "briefcase.fill",
        "book.closed.fill",
        "graduationcap.fill",
        "star.fill",
        "cart.fill",
        "house.fill",
        "globe",
        "folder.fill",
        "terminal.fill",
        "flame.fill",
        "heart.fill",
    ]
}

@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var profiles: [Profile] = []

    private var file: URL { Store.file("profiles.json") }

    init() {
        load()
    }

    func profile(for id: UUID) -> Profile? {
        profiles.first { $0.id == id }
    }

    private func load() {
        if let data = try? Data(contentsOf: file),
           let list = try? JSONDecoder().decode([Profile].self, from: data),
           !list.isEmpty {
            profiles = list
            return
        }

        // Fresh start: provide Personal and Trabajo so switching is ready out of the box.
        profiles = [Profile.defaultPersonal, Profile.defaultWork]
        save()
    }

    func save() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: file, options: .atomic)
    }

    @discardableResult
    func create(name: String, symbol: String, colorName: String) -> Profile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "Nuevo perfil" : trimmed
        let profile = Profile(
            id: UUID(),
            name: finalName,
            symbol: symbol,
            colorName: colorName,
            isDefault: false
        )
        profiles.append(profile)
        save()
        return profile
    }

    func update(_ profile: Profile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
        save()
    }

    func delete(id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        guard !profiles[index].isDefault, profiles.count > 1 else { return }
        let removed = profiles.remove(at: index)
        save()

        // Clean up the WebKit data store for the removed profile.
        WKWebsiteDataStore.remove(forIdentifier: removed.id) { _ in }
    }
}
