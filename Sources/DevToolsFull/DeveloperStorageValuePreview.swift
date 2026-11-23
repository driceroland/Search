import SwiftUI

/// Application › a storage row's value, as Chrome previews it under the
/// table: a value that parses as a JSON object or array opens as an
/// object tree, and cookies and Web Storage values can be shown
/// URL-decoded ("Show URL-decoded").
enum DeveloperStorageValuePreview {
    /// Which sections offer "Show URL-decoded", as Chrome's cookie and
    /// storage views do.
    static func decodes(_ section: DeveloperApplicationSection) -> Bool {
        switch section {
        case .cookies, .local, .session: true
        default: false
        }
    }

    /// The column holding the value, Chrome's "Value"; nil when there is none.
    static func valueColumn(_ columns: [String]) -> Int? {
        if let index = columns.firstIndex(where: { $0.caseInsensitiveCompare("Value") == .orderedSame }) { return index }
        return nil
    }

    /// decodeURIComponent, which Chrome's checkbox runs: `+` stays, and a
    /// malformed escape leaves the value as it was.
    static func urlDecoded(_ text: String) -> String {
        guard text.contains("%") else { return text }
        return text.removingPercentEncoding ?? text
    }

    /// The value as a tree when it is a JSON object or array; a bare
    /// string, number or boolean stays text, as in Chrome.
    static func json(_ text: String) -> DeveloperJSONValue? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "{" || first == "[" else { return nil }
        guard let value = DeveloperJSONValue.parse(trimmed), value.isContainer else { return nil }
        return value
    }
}

/// The fields of the selected row with its value previewed, beneath the
/// table.
struct DeveloperStorageValueDetails: View {
    let section: DeveloperApplicationSection
    let fields: [(String, String)]
    let valueIndex: Int?
    @AppStorage("DeveloperStorageShowURLDecoded", store: DevDefaults.store) private var urlDecoded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let value {
                HStack(spacing: DeveloperToolsStyle.gutter) {
                    Text(section == .cookies ? "Cookie value" : "Value").fontWeight(.semibold)
                    Spacer(minLength: 0)
                    if DeveloperStorageValuePreview.decodes(section) {
                        Toggle("Show URL-decoded", isOn: $urlDecoded)
                            .toggleStyle(.developerCheckbox)
                            .controlSize(.small)
                    }
                }
                .padding(.horizontal, DeveloperToolsStyle.gutter)
                .frame(height: DeveloperToolsStyle.controlHeight + 4)
                if let tree = DeveloperStorageValuePreview.json(value) {
                    ScrollView { DeveloperJSONTree(root: tree).id(value) }
                        .frame(minHeight: 60, maxHeight: 220)
                } else {
                    ScrollView {
                        Text(value).font(DeveloperToolsStyle.code).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, DeveloperToolsStyle.gutter)
                    }
                    .frame(maxHeight: 96)
                }
                Divider()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: DeveloperToolsStyle.controlSpacing) {
                    ForEach(Array(fields.enumerated()), id: \.offset) { index, field in
                        HStack(alignment: .top, spacing: DeveloperToolsStyle.gutter) {
                            Text(field.0).foregroundStyle(.secondary).frame(width: 93, alignment: .leading)
                            Text(index == valueIndex ? shown(field.1) : field.1)
                                .font(DeveloperToolsStyle.code).textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DeveloperToolsStyle.gutter)
            }
            .frame(maxHeight: 128)
        }
    }

    private var value: String? {
        guard let valueIndex, fields.indices.contains(valueIndex) else { return nil }
        return shown(fields[valueIndex].1)
    }

    private func shown(_ text: String) -> String {
        urlDecoded && DeveloperStorageValuePreview.decodes(section) ? DeveloperStorageValuePreview.urlDecoded(text) : text
    }
}
