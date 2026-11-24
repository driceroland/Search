import SwiftUI

/// The request list's header menu, as Chrome lays it out: a checkbox for
/// each column, Response Headers and Request headers to add a header's
/// value as a column, Waterfall to choose what that column sorts by, and Reset Columns. The
/// row menu's Header Options shows the same.
struct DeveloperNetworkColumnMenu: View {
    @Binding var options: DeveloperNetworkView.Options
    /// The request header names recorded, offered after Chrome's own.
    var seen: [String] = []
    let manageHeaders: () -> Void

    var body: some View {
        ForEach(DeveloperNetworkColumn.allCases.filter { $0 != .name }) { column in
            Toggle(column.rawValue, isOn: Binding(get: { options.columns.contains(column) }, set: { on in
                if on { options.columns.insert(column) } else { options.columns.remove(column) }
                if !on && options.sort == .standard(column) { options.sort = nil }
            }))
        }
        Divider()
        Menu("Response Headers") {
            ForEach(options.headerChoices, id: \.self) { name in
                Toggle(DeveloperNetworkListColumn.title(forHeader: name), isOn: Binding(get: {
                    options.headerColumns.contains(name)
                }, set: { on in options.showHeaderColumn(name, on) }))
            }
            Divider()
            Button("Manage Header Columns…", action: manageHeaders)
        }
        Menu("Request headers") {
            ForEach(options.requestHeaderChoices(seen: seen), id: \.self) { name in
                Toggle(DeveloperNetworkListColumn.title(forHeader: name), isOn: Binding(get: {
                    options.requestHeaderColumns.contains(name)
                }, set: { on in options.showRequestHeaderColumn(name, on) }))
            }
        }
        Menu("Waterfall") {
            ForEach(DeveloperNetworkWaterfallSort.allCases) { sort in
                Button {
                    options.columns.insert(.waterfall)
                    options.waterfallSort = sort
                    options.sort = .standard(.waterfall)
                    options.ascending = true
                } label: {
                    if options.sort == .standard(.waterfall) && options.waterfallSort == sort {
                        Label(sort.rawValue, systemImage: "checkmark")
                    } else {
                        Text(sort.rawValue)
                    }
                }
            }
        }
        Divider()
        Button("Reset Columns") { options.resetColumns() }
    }
}

/// Manage Header Columns…: Chrome's dialog of response header columns,
/// each switchable, with custom headers added by name.
struct DeveloperNetworkHeaderColumnsSheet: View {
    @Binding var options: DeveloperNetworkView.Options
    @Environment(\.developerDismiss) private var dismiss
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Manage Header Columns").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: DeveloperToolsStyle.stackSpacing) {
                    ForEach(options.headerChoices, id: \.self) { name in
                        HStack {
                            Toggle(DeveloperNetworkListColumn.title(forHeader: name), isOn: Binding(get: {
                                options.headerColumns.contains(name)
                            }, set: { on in options.showHeaderColumn(name, on) }))
                            .toggleStyle(.developerCheckbox)
                            Spacer(minLength: 0)
                            if options.customHeaders.contains(name) {
                                Button {
                                    options.showHeaderColumn(name, false)
                                    options.customHeaders.removeAll { $0 == name }
                                } label: { Image(systemName: "xmark.circle") }
                                    .buttonStyle(.borderless)
                                    .help("Remove " + DeveloperNetworkListColumn.title(forHeader: name))
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 220)
            HStack {
                TextField("Custom header name", text: $draft)
                    .focused($focused)
                    .onSubmit(add)
                Button("Add custom header", action: add)
                    .disabled(Self.headerName(draft) == nil)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func add() {
        guard let name = Self.headerName(draft) else { return }
        if !options.headerChoices.contains(name) { options.customHeaders.append(name) }
        options.showHeaderColumn(name, true)
        draft = ""
        focused = true
    }

    /// A header name as a column is kept: lowercased, without spaces or
    /// a colon; nil when nothing usable is left.
    static func headerName(_ text: String) -> String? {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty, !name.contains(where: { $0.isWhitespace || $0 == ":" }) else { return nil }
        return name
    }
}
