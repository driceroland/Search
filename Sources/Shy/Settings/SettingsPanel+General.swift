import SwiftUI

// Settings › General.
extension SettingsPanel {
    var general: some View {
        VStack(alignment: .leading, spacing: 18) {
            group("Shy on this Mac") {
                Line(
                    "Default browser",
                    isDefault ? "Links from other apps open in Shy" : "Links from other apps open in another browser"
                ) {
                    if isDefault {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Palette.ink)
                            .frame(width: 24)
                    } else {
                        Pill("Make default", filled: true) {
                            Links.becomeDefault { worked in
                                isDefault = Links.isDefault
                                browser.announce(worked && isDefault ? "Links now open here" : "macOS didn't change it")
                            }
                        }
                    }
                }
                Rule()
                Line("Open links from other apps in a mini window", "Read and close it, or move it into a tab with ⌘O") {
                    Switch(on: $prefs.littleLinks)
                }
                Rule()
                // What another browser exported, now or any time later: the same
                // sheet as File › Bring In a File….
                Line("Import from a file", "Bookmarks (HTML), passwords (CSV) or a Safari export (ZIP)") {
                    Pill("Import…") { browser.importFile() }
                }
                Rule()
                Line("Confirm before quitting with ⌘Q") {
                    Switch(on: $prefs.confirmsQuit)
                }
            }
            group("Search and the address field") {
                // What ⌘T opens to, and the way back after an extension took
                // it. Only there while an extension offers a page; it brings
                // its own hairline.
                HomePageLine()
                Line("Search engine", searchDetail) {
                    Picker("", selection: $prefs.engine) {
                        ForEach(Engine.allCases) { engine in
                            Text(engine.title).tag(engine)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                if prefs.engine == .custom {
                    ZStack(alignment: .leading) {
                        if prefs.customEngine.isEmpty {
                            Text("https://example.com/search?q=%s")
                                .foregroundStyle(Palette.muted.opacity(0.8))
                        }
                        TextField("", text: $prefs.customEngine)
                            .textFieldStyle(.plain)
                            .foregroundStyle(Palette.ink)
                    }
                    .font(.system(size: 12.5))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .padding(.horizontal, 14)
                    .padding(.bottom, 11)
                }
                Rule()
                Line("Search suggestions", suggestDetail) {
                    Switch(on: $prefs.engineSuggests)
                }
                Rule()
                Line("Open new tabs in a floating field", "⌘T shows the address field over the current page, as in Arc") {
                    Switch(on: $prefs.floatingNewTab)
                }
                Rule()
                Line("Site shortcuts", keywordDetail) {
                    if draft == nil {
                        Pill("Add") { draft = Keyword() }
                    } else {
                        HStack(spacing: 6) {
                            Pill("Cancel") { draft = nil }
                            Pill("Save", filled: true) { saveDraft() }
                                .disabled(draftProblem != nil)
                                .opacity(draftProblem == nil ? 1 : 0.4)
                        }
                    }
                }
                if let current = draft {
                    HStack(spacing: 8) {
                        TextField("yt", text: Binding(
                            get: { current.keyword },
                            set: { draft?.keyword = $0 }
                        ))
                        .textFieldStyle(.plain)
                        .frame(width: 50)
                        Text("→").foregroundStyle(Palette.muted)
                        TextField("https://www.youtube.com/results?search_query=%s", text: Binding(
                            get: { current.template },
                            set: { draft?.template = $0 }
                        ))
                        .textFieldStyle(.plain)
                        .onSubmit(saveDraft)
                    }
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
                }
                ForEach(prefs.keywords) { entry in
                    HStack(spacing: 8) {
                        Text(entry.keyword)
                            .frame(width: 50, alignment: .leading)
                        Text("→").foregroundStyle(Palette.muted)
                        Text(entry.template)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            prefs.keywords.removeAll { $0.id == entry.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Palette.faint)
                        }
                        .buttonStyle(.plain)
                    }
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
                }
            }
            group("Appearance") {
                Line("Appearance") {
                    Segmented(options: Look.allCases.map { ($0, $0.title) }, selection: $prefs.look)
                }
                Rule()
                Line("Default page zoom", "⌘+ and ⌘− still set each site's own") {
                    // The number itself takes it back to 100%.
                    Steps(stops: Preferences.zooms, value: $prefs.pageZoom, home: 1) { "\(Int(($0 * 100).rounded()))%" }
                }
            }
            group("Typing and scrolling") {
                Line("Autocorrect spelling in pages") {
                    Switch(on: $prefs.autocorrect)
                }
                Rule()
                Line("Autoscroll with the middle mouse button", "Click the wheel, then move the mouse to scroll") {
                    Switch(on: $prefs.autoScroll)
                }
            }
            group("Reading") {
                Line("Reading mode follows dark mode") {
                    Switch(on: $prefs.readerFollowsLook)
                }
                if PageTranslator.available {
                    Rule()
                    Line("Translate pages", "On this Mac, by macOS. Right-click › Translate Page") {
                        Switch(on: $prefs.translatesPages)
                    }
                    if prefs.translatesPages { TranslateLanguageList(prefs: prefs) }
                }
            }
            group("Video") {
                Line("Picture in picture automatically", prefs.floatWhen.detail) {
                    Picker("", selection: $prefs.floatWhen) {
                        ForEach(FloatWhen.allCases) { when in
                            Text(when.title).tag(when)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                Rule()
                Line("Block autoplay", "Muted videos too. Open tabs follow once reloaded") {
                    Switch(on: $prefs.waitsForPlay)
                }
                Rule()
                Line("Press Esc twice to exit full screen", "The first press only shows a reminder") {
                    Switch(on: $prefs.escapeTwice)
                }
            }
            group("Performance") {
                Line("Pages at 120 Hz", "Smoother scrolling, more battery. On power: only while plugged in") {
                    Segmented(options: FastPages.allCases.map { ($0, $0.title) }, selection: $prefs.fastPages)
                }
                Rule()
                Line("Reduce motion in Low Power Mode") {
                    Switch(on: $prefs.lightMotion)
                }
            }
        }
    }

    /// A named card, so a long page reads as a few things.
    func group<Content: View>(_ title: String, @ViewBuilder _ content: @escaping () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Caption(title)
            Card(content: content)
        }
    }
}
