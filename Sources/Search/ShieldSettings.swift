import SwiftUI

struct ShieldSettings: View {
    @ObservedObject private var shield = Shield.shared
    @ObservedObject private var custom = CustomFilters.shared
    @State private var site = ""
    @State private var listURL = ""
    @State private var draft = ""

    private var newSite: String? {
        Shield.normalizedHost(site).flatMap { shield.paused.contains($0) ? nil : $0 }
    }

    private var newList: URL? {
        CustomFilters.subscriptionURL(listURL).flatMap { custom.lists.contains($0.absoluteString) ? nil : $0 }
    }

    var body: some View {
        Rule()
        Line("Sites it's off for", "Includes subdomains. Open pages change when reloaded.") {
            HStack(spacing: 8) {
                TextField("Site", text: $site, prompt: Text(verbatim: "example.com"))
                    .frame(maxWidth: 145)
                    .onSubmit(addSite)
                Pill("Add", action: addSite)
                    .fixedSize(horizontal: true, vertical: false)
                    .disabled(newSite == nil)
            }
        }
        ForEach(shield.paused.sorted(), id: \.self) { host in
            Rule()
            Line(host) {
                Pill("Remove") { shield.pause(host, false) }
                    .accessibilityLabel("Remove \(host) from sites Shield is off for")
            }
        }
        Rule()
        Line("Use my own filters", "Add rules and filter lists in uBlock Origin or Adblock Plus syntax.") {
            Switch(on: Binding(get: { custom.enabled }, set: custom.setEnabled))
                .accessibilityLabel("Use my own filters")
        }
        if custom.enabled {
            customSettings
        }
    }

    private var customSettings: some View {
        Group {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("My filters").font(.system(size: 13)).foregroundStyle(Palette.ink)
                    Spacer()
                    Pill("Save") { custom.save(draft) }.disabled(draft == custom.myFilters)
                }
                TextEditor(text: $draft)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 100)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.hairline))
                    .accessibilityLabel("My filters")
                Text("Enter one filter per line. Exceptions apply to custom filters only. Use Sites it's off for to turn off all Shield blocking for a site.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .onAppear { draft = custom.myFilters }
            .onChange(of: custom.myFilters) { old, new in
                if draft == old { draft = new }
            }
            Rule()
            Line("Filter subscriptions", "Add an HTTPS filter list URL.") {
                HStack(spacing: 8) {
                    TextField("Filter list URL", text: $listURL, prompt: Text(verbatim: "https://example.com/filters.txt"))
                        .frame(maxWidth: 160)
                        .onSubmit(addList)
                    Pill("Add", action: addList)
                        .fixedSize(horizontal: true, vertical: false)
                        .disabled(newList == nil)
                }
            }
            ForEach(custom.lists, id: \.self) { list in
                Rule()
                Line(list, listStatus(list)) {
                    Pill("Remove") { custom.remove(list) }
                        .accessibilityLabel("Remove subscription \(list)")
                }
            }
            Rule()
            Line("\(custom.ruleCount) rules, \(custom.skippedCount) skipped",
                 custom.trouble ?? (custom.refreshing ? "Updating subscriptions…" : nil)) {
                Pill("Update now") { custom.updateNow() }
                    .disabled(custom.lists.isEmpty || custom.refreshing)
            }
        }
    }

    private func addSite() {
        guard let host = newSite else { return }
        shield.pause(host, true)
        site = ""
    }

    private func addList() {
        guard let url = newList else { return }
        custom.add(url)
        listURL = ""
    }

    private func listStatus(_ list: String) -> String? {
        let date = custom.lastUpdated[list]?.formatted(date: .abbreviated, time: .shortened)
        if let trouble = custom.listTrouble[list] {
            if let date { return "\(trouble). Last updated \(date)" }
            return trouble
        }
        return date.map { "Last updated \($0)" }
    }
}
