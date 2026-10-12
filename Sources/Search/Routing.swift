import SwiftUI

enum InternalRoutingPolicy: String, Codable, CaseIterable {
    case current, ask, destination
    var label: String {
        switch self {
        case .current: "Current Space"
        case .ask: "Ask where to open"
        case .destination: "Route to rule destination"
        }
    }
}

enum InternalRoutingOverride: String, Codable, CaseIterable {
    case inherit, current, ask, destination
    var label: String {
        self == .inherit ? "Inherit global" : InternalRoutingPolicy(rawValue: rawValue)?.label ?? "Inherit global"
    }
}

struct RoutingRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var domain: String
    var port: Int?
    var spaceID: UUID
    var spaceName: String
    var enabled = true
    var internalPolicy: InternalRoutingOverride = .inherit

    enum CodingKeys: String, CodingKey { case id, domain, port, spaceID, spaceName, enabled, internalPolicy }
    init(id: UUID = UUID(), domain: String, port: Int? = nil, spaceID: UUID, spaceName: String,
         enabled: Bool = true, internalPolicy: InternalRoutingOverride = .inherit) {
        self.id = id; self.domain = domain; self.port = port; self.spaceID = spaceID; self.spaceName = spaceName
        self.enabled = enabled; self.internalPolicy = internalPolicy
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        domain = try values.decode(String.self, forKey: .domain)
        port = try values.decodeIfPresent(Int.self, forKey: .port)
        spaceID = try values.decode(UUID.self, forKey: .spaceID)
        spaceName = try values.decode(String.self, forKey: .spaceName)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        internalPolicy = try values.decodeIfPresent(InternalRoutingOverride.self, forKey: .internalPolicy) ?? .inherit
    }
    var hostLabel: String {
        guard let port else { return domain }
        return "\(domain.contains(":") ? "[" + domain + "]" : domain):\(port)"
    }
}

struct RoutingConfig: Codable, Equatable {
    var enabled = false
    var rules: [RoutingRule] = []
    var internalPolicy: InternalRoutingPolicy = .current

    enum CodingKeys: String, CodingKey { case enabled, rules, internalPolicy }
    init(enabled: Bool = false, rules: [RoutingRule] = [], internalPolicy: InternalRoutingPolicy = .current) {
        self.enabled = enabled; self.rules = rules; self.internalPolicy = internalPolicy
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        rules = try values.decodeIfPresent([RoutingRule].self, forKey: .rules) ?? []
        internalPolicy = try values.decodeIfPresent(InternalRoutingPolicy.self, forKey: .internalPolicy) ?? .current
    }
    func policy(for rule: RoutingRule) -> InternalRoutingPolicy {
        InternalRoutingPolicy(rawValue: rule.internalPolicy.rawValue) ?? internalPolicy
    }

    static func domain(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasSuffix(".") { text.removeLast() }
        if text == "[::1]" { text = "::1" }
        if isLocalHost(text) { return text }
        guard text.count <= 253, text.contains("."), text.allSatisfy({
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".")
        }) else { return nil }
        let labels = text.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ label in
            !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
        }), labels.last?.contains(where: { $0.isLetter }) == true else { return nil }
        return text
    }

    static func isLocalHost(_ host: String) -> Bool { ["localhost", "127.0.0.1", "::1"].contains(host) }

    static func port(_ text: String) -> Int? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(text), (1...65535).contains(value) else { return nil }
        return value
    }

    func match(_ url: URL) -> RoutingRule? {
        guard enabled, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host.flatMap(Self.domain) else { return nil }
        let port = url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
        return rules.filter { rule in
            rule.enabled && Self.domain(rule.domain) == rule.domain &&
                (rule.port.map { (1...65535).contains($0) } ?? true) &&
                (rule.port == nil || rule.port == port) &&
                (host == rule.domain || (!Self.isLocalHost(rule.domain) && host.hasSuffix("." + rule.domain)))
        }.max {
            if $0.domain.count != $1.domain.count { return $0.domain.count < $1.domain.count }
            return $0.port == nil && $1.port != nil
        }
    }
}

@MainActor
final class Routing: ObservableObject {
    static let shared = Routing()
    static let key = "external.routing"
    @Published private(set) var config: RoutingConfig

    init(settings: UserDefaults = Store.settings) {
        self.settings = settings
        config = settings.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(RoutingConfig.self, from: $0) }
            ?? RoutingConfig()
    }

    private let settings: UserDefaults

    private func persist() {
        if let data = try? JSONEncoder().encode(config) { settings.set(data, forKey: Self.key) }
    }

    func setInternalPolicy(_ policy: InternalRoutingPolicy) { config.internalPolicy = policy; persist() }
    func setEnabled(_ enabled: Bool) { config.enabled = enabled; persist() }
    func setRuleEnabled(_ id: UUID, _ enabled: Bool) {
        guard let index = config.rules.firstIndex(where: { $0.id == id }) else { return }
        config.rules[index].enabled = enabled
        persist()
    }
    func remove(_ id: UUID) { config.rules.removeAll { $0.id == id }; persist() }
    @discardableResult
    func save(id: UUID?, domain input: String, port: Int? = nil, space: Space, internalPolicy: InternalRoutingOverride = .inherit) -> Bool {
        guard let domain = RoutingConfig.domain(input), port.map({ (1...65535).contains($0) }) ?? true,
              !config.rules.contains(where: { $0.domain == domain && $0.port == port && $0.id != id }) else { return false }
        if let id, let index = config.rules.firstIndex(where: { $0.id == id }) {
            config.rules[index].domain = domain
            config.rules[index].port = port
            config.rules[index].spaceID = space.id
            config.rules[index].spaceName = space.name
            config.rules[index].internalPolicy = internalPolicy
        } else {
            config.rules.append(RoutingRule(domain: domain, port: port, spaceID: space.id, spaceName: space.name, internalPolicy: internalPolicy))
        }
        persist()
        return true
    }
}

struct RoutingPage: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var routing = Routing.shared
    @State private var draft: RoutingDraft?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Enable link routing", isOn: Binding(
                get: { routing.config.enabled }, set: { routing.setEnabled($0) }))
            Text("Domains include their subdomains; localhost and loopback hosts match exactly. Blank ports match all ports. The most specific enabled rule wins. External links always use the rule destination.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
            Picker("Links opened inside Search", selection: Binding(
                get: { routing.config.internalPolicy }, set: { routing.setInternalPolicy($0) })) {
                ForEach(InternalRoutingPolicy.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            if !browser.prefs.usesSpaces {
                Text("Enable Spaces in Tabs to open routed links. Until then, matching links are blocked.")
                    .font(.system(size: 12)).foregroundStyle(.orange)
            }
            Button("Add rule") { draft = RoutingDraft() }
            Divider()
            ForEach(routing.config.rules) { rule in
                HStack(spacing: 10) {
                    Toggle("Enable \(rule.hostLabel)", isOn: Binding(
                        get: { routing.config.rules.first { $0.id == rule.id }?.enabled ?? false },
                        set: { routing.setRuleEnabled(rule.id, $0) }))
                        .labelsHidden().accessibilityLabel("Enable \(rule.hostLabel)")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(rule.hostLabel).font(.system(size: 13, weight: .medium))
                        if let space = browser.spaces.first(where: { $0.id == rule.spaceID }) {
                            Text(space.name).font(.system(size: 12)).foregroundStyle(Palette.muted)
                        } else {
                            Text("Missing space: \(rule.spaceName)").font(.system(size: 12)).foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    Button("Edit") { draft = RoutingDraft(ruleID: rule.id, domain: rule.domain, port: rule.port.map(String.init) ?? "", destination: rule.spaceID, internalPolicy: rule.internalPolicy) }
                        .accessibilityLabel("Edit \(rule.hostLabel)")
                    Button { routing.remove(rule.id) } label: {
                        Image(systemName: "trash")
                    }.help("Remove \(rule.hostLabel)").accessibilityLabel("Remove \(rule.hostLabel)")
                }
            }
            if routing.config.rules.isEmpty {
                Text("No routing rules. External links open in the current space.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
        }
        .foregroundStyle(Palette.ink)
        .sheet(item: $draft) { draft in
            RoutingEditor(browser: browser, draft: draft)
        }
    }
}

private struct RoutingDraft: Identifiable {
    let id = UUID()
    var ruleID: UUID?
    var domain = ""
    var port = ""
    var destination: UUID?
    var internalPolicy: InternalRoutingOverride = .inherit
}

private struct RoutingEditor: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var routing = Routing.shared
    @Environment(\.dismiss) private var dismiss
    private let editing: UUID?
    @State private var domain: String
    @State private var port: String
    @State private var destination: UUID?
    @State private var internalPolicy: InternalRoutingOverride

    init(browser: Browser, draft: RoutingDraft) {
        self.browser = browser
        editing = draft.ruleID
        _domain = State(initialValue: draft.domain)
        _port = State(initialValue: draft.port)
        _destination = State(initialValue: draft.destination)
        _internalPolicy = State(initialValue: draft.internalPolicy)
    }

    private var selectedSpace: Space? { browser.spaces.first { $0.id == destination } }
    private var valid: Bool {
        guard let normalized = RoutingConfig.domain(domain), selectedSpace != nil, port.isEmpty || RoutingConfig.port(port) != nil else { return false }
        return !routing.config.rules.contains { $0.domain == normalized && $0.port == RoutingConfig.port(port) && $0.id != editing }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(editing == nil ? "Add rule" : "Edit rule").font(.system(size: 13, weight: .semibold))
            Text("Host/domain").font(.system(size: 12, weight: .medium))
            TextField("Host/domain, for example github.com or localhost", text: $domain)
                .textFieldStyle(.roundedBorder).accessibilityLabel("Routing host/domain")
            Text("Port").font(.system(size: 12, weight: .medium))
            TextField("Blank for all ports", text: $port)
                .textFieldStyle(.roundedBorder).accessibilityLabel("Routing port")
            Picker("Space", selection: $destination) {
                Text("Choose a space").tag(nil as UUID?)
                ForEach(browser.spaces) { space in Text(space.name).tag(Optional(space.id)) }
                if let destination, selectedSpace == nil {
                    Text("Missing space — choose another").tag(Optional(destination))
                }
            }
            Picker("Internal links", selection: $internalPolicy) {
                ForEach(InternalRoutingOverride.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            if !domain.isEmpty && !valid {
                Text("Enter a host without a URL, path, port or wildcard, and choose a space. Port must be blank or 1–65535. Each host and port combination can appear once.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            HStack {
                Button(editing == nil ? "Add rule" : "Save rule") {
                    if let space = selectedSpace, routing.save(id: editing, domain: domain, port: RoutingConfig.port(port), space: space, internalPolicy: internalPolicy) { dismiss() }
                }.disabled(!valid)
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 390)
        .foregroundStyle(Palette.ink)
    }
}

extension Browser {
    /// Returns true when the original operation is held or cancelled. Only
    /// callers that represent a user's navigation ask this question.
    func routeInternal(_ url: URL, from source: Tab?, foreground: Bool,
                       current: @escaping () -> Void) -> Bool {
        guard source?.shy != true,
              let rule = Routing.shared.config.match(url) else { return false }
        let policy = Routing.shared.config.policy(for: rule)
        guard policy != .current else { return false }
        guard prefs.usesSpaces else {
            announce("Link not opened: enable Spaces in Settings → Tabs")
            return true
        }
        let originalSpace = spaceID
        let sourceID = source?.id
        let destination = spaces.first { $0.id == rule.spaceID }
        if policy == .destination, destination?.id == originalSpace { return false }
        let open: (UUID?) -> Void = { [weak self] chosen in
            guard let self, let chosen else { return }
            guard self.spaceID == originalSpace,
                  sourceID == nil || self.tabs.contains(where: { $0.id == sourceID }) else {
                self.announce("Link not opened: the original tab or Space changed")
                return
            }
            if chosen == originalSpace { current(); return }
            guard self.spaces.contains(where: { $0.id == chosen }) else {
                self.announce("Link not opened: choose an existing destination in Settings → Routing")
                return
            }
            self.switchSpace(to: chosen)
            guard self.spaceID == chosen else { return }
            self.open(url, foreground: foreground, mayWait: true)
            if !foreground { self.switchSpace(to: originalSpace) }
        }
        if policy == .destination {
            guard let destination else {
                announce("Link not opened: choose an existing destination in Settings → Routing")
                return true
            }
            open(destination.id)
            return true
        }
        guard !routingQuestionOpen else {
            announce("Link not opened: answer the open-link question first")
            return true
        }
        routingQuestionOpen = true
        let alert = NSAlert()
        alert.messageText = "Where should this link open?"
        alert.informativeText = url.absoluteString
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
        picker.addItem(withTitle: "Current Space (\(space.name))")
        let choices = [originalSpace] + spaces.map(\.id)
        for space in spaces { picker.addItem(withTitle: space.name) }
        if let destination, let index = spaces.firstIndex(where: { $0.id == destination.id }) {
            picker.selectItem(at: index + 1)
        }
        alert.accessoryView = picker
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] answer in
            self?.routingQuestionOpen = false
            guard answer == .alertFirstButtonReturn, choices.indices.contains(picker.indexOfSelectedItem) else { return }
            open(choices[picker.indexOfSelectedItem])
        }
        if let source { Dialogs.show(alert, over: source.web, then: finish) }
        else if Store.testing { finish(.cancel) }
        else if let window = NSApp.mainWindow { alert.beginSheetModal(for: window, completionHandler: finish) }
        else { finish(alert.runModal()) }
        return true
    }

    func navigateInternal(_ url: URL, in source: Tab?) {
        guard let source else { return }
        if !routeInternal(url, from: source, foreground: true, current: { [weak source] in source?.go(to: url) }) {
            source.go(to: url)
        }
    }

    func openInternal(_ url: URL, foreground: Bool, from source: Tab?, mayWait: Bool = false) {
        let current = { [weak self, weak source] in
            self?.open(url, foreground: foreground, from: source, mayWait: mayWait)
            return ()
        }
        if !routeInternal(url, from: source, foreground: foreground, current: current) { current() }
    }
}
