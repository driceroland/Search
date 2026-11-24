import AppKit
import SwiftUI

/// What the Application sidebar lists beneath Storage and Frames.
struct DeveloperApplicationTree: Equatable {
    struct ObjectStore: Equatable {
        let name: String
        let indexes: [String]
    }

    struct Database: Equatable {
        let name: String
        let stores: [ObjectStore]
    }

    /// The page's origin, as Chrome lists it under Local storage, Session
    /// storage and Cookies.
    var origin: String?
    /// Every origin among the page's frames, the page's own first, as
    /// Chrome lists them under Local storage, Session storage and Cookies.
    var origins: [String] = []
    var databases: [Database] = []
    var caches: [String] = []
    var frame: DeveloperFrameNode?

    /// The distinct HTTP and HTTPS origins of `main` and the frames beneath
    /// `frame`, in the order the frame tree lists them. Opaque origins
    /// ("null", data: and sandboxed frames) have no storage to show.
    static func storageOrigins(main: String?, frame: DeveloperFrameNode?) -> [String] {
        var found: [String] = []
        func add(_ origin: String) {
            let trimmed = origin.hasSuffix("/") ? String(origin.dropLast()) : origin
            guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https", url.host()?.isEmpty == false,
                  !found.contains(trimmed) else { return }
            found.append(trimmed)
        }
        func walk(_ node: DeveloperFrameNode) {
            add(node.origin)
            for child in node.children { walk(child) }
        }
        if let main { add(main) }
        if let frame { walk(frame) }
        return found
    }

    /// The address of the first frame from `origin`, whose cookies stand for the origin's.
    static func address(of origin: String, in frame: DeveloperFrameNode?) -> URL? {
        func find(_ node: DeveloperFrameNode) -> DeveloperFrameNode? {
            let own = node.origin.hasSuffix("/") ? String(node.origin.dropLast()) : node.origin
            if own == origin, let url = URL(string: node.url), url.scheme?.hasPrefix("http") == true { return node }
            for child in node.children { if let found = find(child) { return found } }
            return nil
        }
        return frame.flatMap(find).flatMap { URL(string: $0.url) }
    }
}

/// A frame from WebKit's resource tree (`Page.getResourceTree`), with its
/// subframes and the resources it loaded.
struct DeveloperFrameNode: Equatable, Identifiable {
    struct Resource: Hashable {
        let url: String
        let type: String
        let mimeType: String

        var name: String {
            guard let address = URL(string: url) else { return url }
            return address.lastPathComponent.isEmpty || address.lastPathComponent == "/"
                ? address.host() ?? url : address.lastPathComponent
        }
    }

    let id: String
    let url: String
    let origin: String
    let name: String?
    let mimeType: String
    /// A secure context: its origin and every ancestor's are potentially trustworthy.
    let secure: Bool
    let depth: Int
    var resources: [Resource]
    var children: [DeveloperFrameNode]

    var title: String { depth == 0 ? "top" : (name ?? URL(string: url)?.host() ?? "iframe") }

    /// `tree` is a `FrameResourceTree`. `topSecure` is what the top
    /// document says of itself, when it was asked.
    static func parse(_ tree: [String: Any], depth: Int = 0, parentSecure: Bool = true,
                      topSecure: Bool? = nil) -> DeveloperFrameNode? {
        guard let frame = tree["frame"] as? [String: Any], let id = frame["id"] as? String, depth < 32 else { return nil }
        let url = frame["url"] as? String ?? ""
        let origin = frame["securityOrigin"] as? String ?? ""
        let own = DeveloperApplication.potentiallyTrustworthy(origin)
        let secure = depth == 0 ? (topSecure ?? own) : parentSecure && own
        let resources = (tree["resources"] as? [[String: Any]] ?? []).prefix(500).compactMap { item -> Resource? in
            guard let url = item["url"] as? String else { return nil }
            return Resource(url: url, type: item["type"] as? String ?? "Other", mimeType: item["mimeType"] as? String ?? "")
        }
        let children = (tree["childFrames"] as? [[String: Any]] ?? []).prefix(100).compactMap {
            parse($0, depth: depth + 1, parentSecure: secure)
        }
        return DeveloperFrameNode(id: id, url: url, origin: origin,
                                  name: (frame["name"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                  mimeType: frame["mimeType"] as? String ?? "", secure: secure, depth: depth,
                                  resources: Array(resources), children: Array(children))
    }

    func find(_ id: String) -> DeveloperFrameNode? {
        if self.id == id { return self }
        for child in children { if let found = child.find(id) { return found } }
        return nil
    }

    struct ResourceGroup: Equatable {
        let title: String
        let resources: [Resource]
    }

    /// Chrome's folders beneath a frame: its resources by kind, in alphabetical order.
    var groups: [ResourceGroup] {
        let grouped = Dictionary(grouping: resources) { Self.folder(for: $0.type) }
        return grouped.keys.sorted().map { title in
            ResourceGroup(title: title, resources: grouped[title, default: []].sorted { $0.name < $1.name })
        }
    }

    static func folder(for type: String) -> String {
        switch type {
        case "Document": "Documents"
        case "StyleSheet": "Stylesheets"
        case "Script": "Scripts"
        case "Image": "Images"
        case "Font": "Fonts"
        case "XHR", "Fetch": "Fetch and XHR"
        default: "Other"
        }
    }

    /// The frame view's Document and Security sections, as label and value rows.
    func properties(crossOriginIsolated: Bool) -> [[String]] {
        var rows = [["URL", String(url.prefix(4096))], ["Origin", origin]]
        if let name { rows.append(["Name", name]) }
        rows.append(["MIME type", mimeType.isEmpty ? "—" : mimeType])
        rows.append(["Secure context", secure ? "Yes" : "No"])
        if depth == 0 { rows.append(["Cross-origin isolated", crossOriginIsolated ? "Yes" : "No"]) }
        rows.append(["Child frames", String(children.count)])
        rows.append(["Resources", String(resources.count)])
        return rows
    }
}

/// Chrome's Application sidebar: Application, Storage and Frames, each
/// entry that holds more opening with a disclosure triangle.
struct DeveloperApplicationSidebar: View {
    @Binding var query: DeveloperApplicationQuery
    let tree: DeveloperApplicationTree
    /// Frames › Web workers: the page's dedicated workers.
    var workers: [DeveloperWorker] = []
    var revealWorker: (DeveloperWorker) -> Void = { _ in }
    let choose: (DeveloperApplicationQuery) -> Void
    @State private var expanded: Set<String> = ["frame:top"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                title("Application")
                plain(.manifest)
                plain(.workers)
                plain(.storage)
                title("Storage").padding(.top, DeveloperToolsStyle.controlSpacing)
                originGroup(.local)
                Group {
                    originGroup(.session)
                    plain(.extensionStorage)
                    indexedDB
                    originGroup(.cookies)
                    caches
                    plain(.fileSystem)
                }
                Group {
                    title("Background services").padding(.top, DeveloperToolsStyle.controlSpacing)
                    plain(.backForwardCache)
                    plain(.reporting)
                    plain(.notifications)
                }
                title("Frames").padding(.top, DeveloperToolsStyle.controlSpacing)
                if let frame = tree.frame {
                    frameRows(frame)
                } else {
                    row(key: "frames", depth: 0, label: "top", icon: DeveloperApplicationSection.frames.icon,
                        target: .init(section: .frames))
                }
                if !workers.isEmpty { workerRows }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DeveloperToolsStyle.controlSpacing)
        }
        .background(DeveloperToolsStyle.chrome)
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .fontWeight(.semibold).foregroundStyle(.secondary)
            .padding(.horizontal, DeveloperToolsStyle.gutter)
            .frame(height: DeveloperToolsStyle.rowHeight)
            .accessibilityAddTraits(.isHeader)
    }

    /// An entry with nothing beneath it.
    private func plain(_ section: DeveloperApplicationSection) -> some View {
        row(key: section.rawValue, depth: 0, label: section.rawValue, icon: section.icon, target: .init(section: section))
    }

    /// Local storage, Session storage and Cookies, each with one entry per
    /// origin among the page's frames beneath, the page's own first.
    private func originGroup(_ section: DeveloperApplicationSection) -> some View {
        let key = section.rawValue
        let main = tree.origin
        let origins = tree.origins.isEmpty ? (main.map { [$0] } ?? []) : tree.origins
        return VStack(alignment: .leading, spacing: 0) {
            // An origin beneath is what's shown, so it is the one selected;
            // the group stands in for it only while closed over it.
            row(key: key, depth: 0, label: section.rawValue, icon: section.icon, target: .init(section: section),
                expandable: !origins.isEmpty,
                selectedWhen: { [open = expanded.contains(key) && !origins.isEmpty] in $0.section == section && !open })
            if expanded.contains(key) {
                ForEach(origins, id: \.self) { origin in
                    // The page's own origin is the query without one.
                    let target = DeveloperApplicationQuery(section: section, origin: origin == main ? nil : origin)
                    row(key: key + ":" + origin, depth: 1, label: origin, icon: "globe", target: target,
                        selectedWhen: { $0.section == section && ($0.origin ?? main) == origin })
                }
            }
        }
    }

    private var indexedDB: some View {
        let key = "indexedDB"
        return VStack(alignment: .leading, spacing: 0) {
            row(key: key, depth: 0, label: "IndexedDB", icon: DeveloperApplicationSection.indexedDB.icon,
                target: .init(section: .indexedDB), expandable: !tree.databases.isEmpty,
                selectedWhen: { $0.section == .indexedDB && $0.database == nil })
            if expanded.contains(key) {
                ForEach(tree.databases, id: \.name) { database in
                    let databaseKey = key + "/" + database.name
                    row(key: databaseKey, depth: 1, label: database.name, icon: "cylinder",
                        target: .init(section: .indexedDB, database: database.name),
                        expandable: !database.stores.isEmpty,
                        selectedWhen: { $0.section == .indexedDB && $0.database == database.name && $0.store == nil })
                    if expanded.contains(databaseKey) {
                        ForEach(database.stores, id: \.name) { store in
                            let storeKey = databaseKey + "/" + store.name
                            row(key: storeKey, depth: 2, label: store.name, icon: "tablecells",
                                target: .init(section: .indexedDB, database: database.name, store: store.name),
                                expandable: !store.indexes.isEmpty,
                                selectedWhen: { $0.section == .indexedDB && $0.database == database.name
                                    && $0.store == store.name && $0.index == nil })
                            if expanded.contains(storeKey) {
                                ForEach(store.indexes, id: \.self) { index in
                                    row(key: storeKey + "/" + index, depth: 3, label: index, icon: "list.bullet.indent",
                                        target: .init(section: .indexedDB, database: database.name, store: store.name,
                                                      index: index),
                                        selectedWhen: { $0.section == .indexedDB && $0.database == database.name
                                            && $0.store == store.name && $0.index == index })
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var caches: some View {
        let key = "caches"
        return VStack(alignment: .leading, spacing: 0) {
            row(key: key, depth: 0, label: "Cache storage", icon: DeveloperApplicationSection.caches.icon,
                target: .init(section: .caches), expandable: !tree.caches.isEmpty,
                selectedWhen: { $0.section == .caches && $0.cache == nil })
            if expanded.contains(key) {
                ForEach(tree.caches, id: \.self) { cache in
                    row(key: key + "/" + cache, depth: 1, label: cache, icon: "archivebox",
                        target: .init(section: .caches, cache: cache),
                        selectedWhen: { $0.section == .caches && $0.cache == cache })
                }
            }
        }
    }

    /// Chrome's "Web workers" under the frames: each dedicated worker by its
    /// script's address, with a way to its source.
    private var workerRows: some View {
        let key = "frame:workers"
        return VStack(alignment: .leading, spacing: 0) {
            row(key: key, depth: 1, label: "Web workers", icon: "folder", target: nil, expandable: true)
            if expanded.contains(key) {
                ForEach(workers) { worker in
                    row(key: key + "/" + worker.id, depth: 2, label: worker.url.isEmpty ? worker.title : worker.url,
                        icon: "gearshape", target: nil)
                        .help(worker.name.isEmpty ? worker.url : worker.name + "\n" + worker.url)
                        .contextMenu {
                            Button("Reveal in Sources panel") { revealWorker(worker) }
                            Button("Copy link address") { DeveloperToolsSession.copyToPasteboard(worker.url) }
                            .disabled(worker.url.isEmpty)
                        }
                }
            }
        }
    }

    private func frameRows(_ frame: DeveloperFrameNode) -> AnyView {
        let key = frame.depth == 0 ? "frame:top" : "frame:" + frame.id
        return AnyView(VStack(alignment: .leading, spacing: 0) {
            row(key: key, depth: frame.depth, label: frame.title, icon: DeveloperApplicationSection.frames.icon,
                target: .init(section: .frames, frame: frame.id),
                expandable: !frame.children.isEmpty || !frame.resources.isEmpty,
                selectedWhen: { $0.section == .frames && $0.frame == frame.id && $0.resource == nil })
            if expanded.contains(key) {
                ForEach(frame.children) { child in frameRows(child) }
                ForEach(frame.groups, id: \.title) { group in
                    let groupKey = key + "/" + group.title
                    row(key: groupKey, depth: frame.depth + 1, label: group.title, icon: "folder",
                        target: nil, expandable: true)
                    if expanded.contains(groupKey) {
                        ForEach(group.resources, id: \.self) { resource in
                            row(key: groupKey + "/" + resource.url, depth: frame.depth + 2, label: resource.name,
                                icon: "doc", target: .init(section: .frames, frame: frame.id, resource: resource.url),
                                selectedWhen: { $0.section == .frames && $0.frame == frame.id
                                    && $0.resource == resource.url })
                                .help(resource.url)
                        }
                    }
                }
            }
        })
    }

    /// One entry. `target` is what it shows when chosen; a folder, with
    /// none, only opens and closes.
    private func row(key: String, depth: Int, label: String, icon: String, target: DeveloperApplicationQuery?,
                     expandable: Bool = false,
                     selectedWhen: ((DeveloperApplicationQuery) -> Bool)? = nil) -> some View {
        let selected: Bool = target.map { target in selectedWhen?(query) ?? (query.section == target.section) } ?? false
        let open: Bool = expanded.contains(key)
        let content = HStack(spacing: DeveloperToolsStyle.controlSpacing) {
            disclosure(key: key, expandable: expandable, open: open)
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(label).lineLimit(1).truncationMode(.middle)
        }
        .padding(.leading, CGFloat(depth) * 12 + 2)
        .padding(.trailing, DeveloperToolsStyle.gutter)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: DeveloperToolsStyle.rowHeight)
        // Inset a point top and bottom, so two lit rows (the one selected
        // and one hovered or focused) read as two, not one block.
        .background {
            if selected {
                RoundedRectangle(cornerRadius: DeveloperToolsStyle.controlRadius)
                    .fill(Color.primary.opacity(0.08)).padding(.vertical, 1)
            }
        }
        .contentShape(Rectangle())
        // A click chooses at once; a double-click also opens or closes it.
        .simultaneousGesture(TapGesture().onEnded {
            if let target { choose(target) } else { toggle(key) }
        })
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if expandable, target != nil { toggle(key) }
        })
        return rowAccessibility(content, key: key, label: label, target: target, expandable: expandable,
                                selected: selected, open: open)
    }

    private func disclosure(key: String, expandable: Bool, open: Bool) -> some View {
        Group {
            if expandable {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .foregroundStyle(.secondary)
                    .frame(width: 10, height: DeveloperToolsStyle.rowHeight)
                    .contentShape(Rectangle())
                    .onTapGesture { toggle(key) }
            } else {
                Color.clear.frame(width: 10)
            }
        }
        .accessibilityHidden(true)
    }

    private func rowAccessibility(_ content: some View, key: String, label: String,
                                  target: DeveloperApplicationQuery?, expandable: Bool,
                                  selected: Bool, open: Bool) -> some View {
        let traits: AccessibilityTraits = selected ? [.isButton, .isSelected] : .isButton
        let state: String = expandable ? (open ? "Expanded" : "Collapsed") : ""
        let action: String = open ? "Collapse" : "Expand"
        return content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityAddTraits(traits)
            .accessibilityValue(state)
            // A press chooses the entry; pressed again once chosen, a group
            // opens or closes, as a second click would. VoiceOver also gets
            // Expand / Collapse by name.
            .accessibilityAction {
                if let target, !(selected && expandable) { choose(target) } else { toggle(key) }
            }
            .accessibilityAction(named: action) { if expandable { toggle(key) } }
    }

    private func toggle(_ key: String) {
        if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
    }
}
