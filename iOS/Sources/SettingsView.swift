import GlassineCore
import SwiftUI

/// The Mac's View ▸ Appearance, as a sheet. Everything writes through `Prefs`,
/// which posts `.glassinePrefsChanged`, which is what makes the reader, the
/// thumbnails and the chrome in every scene re-apply at once.
@MainActor
struct SettingsView: View {

    @Environment(\.dismiss) private var dismiss
    private let prefs = PrefsModel.shared

    /// Re-scanned every time the sheet opens, so a `.css` file dropped into
    /// Files a moment ago is in the list without a relaunch -- the same promise
    /// the Mac's Style menu makes by rebuilding itself on open.
    @State private var styles: [MarkdownStyle] = MarkdownStyle.builtIns

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Appearance", selection: appearance) {
                        Text("System").tag(AppearanceMode.system)
                        Text("Light").tag(AppearanceMode.light)
                        Text("Dark").tag(AppearanceMode.dark)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("appearancePicker")
                    // A segmented picker in a Form hides its title, so the
                    // spoken label has to be put back by hand; without it
                    // VoiceOver announces only "Dark, selected".
                    .accessibilityLabel("Appearance")
                    .accessibilityHint("Whether Glassine follows the system, or stays light or dark")

                    Toggle("Invert Page Colors", isOn: invert)
                        .accessibilityIdentifier("invertToggle")
                        .accessibilityHint("In dark mode, turns the page black and the ink white")

                    Picker("Dark Paper", selection: darkPaper) {
                        Text("Black").tag(DarkPaper.black)
                        Text("Charcoal").tag(DarkPaper.charcoal)
                        Text("Gray").tag(DarkPaper.gray)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("darkPaperPicker")
                    .accessibilityLabel("Dark Paper")
                    .accessibilityHint("How dark the page reads when Glassine inverts it")
                    // Meaningless with the inversion off, exactly as the three
                    // radio items grey out in the Mac's menu.
                    .disabled(!prefs.invertInDarkMode)
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("How dark the page reads when Glassine inverts it.")
                }

                Section {
                    Picker("Style", selection: style) {
                        ForEach(styles, id: \.id) { style in
                            Text(style.title).tag(style.id)
                        }
                    }
                    .accessibilityIdentifier("markdownStylePicker")
                    .accessibilityLabel("Markdown style")
                    .accessibilityHint("The typeface and colours a Markdown file is typeset in")

                    Picker("Size", selection: fontSize) {
                        ForEach(Prefs.markdownFontSizes, id: \.self) { size in
                            Text("\(size) pt").tag(size)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("markdownSizePicker")
                    .accessibilityLabel("Markdown size")
                    .accessibilityHint("Body text size in points")

                    Picker("Layout", selection: layout) {
                        Text(MarkdownLayout.pages.title).tag(MarkdownLayout.pages)
                        Text(MarkdownLayout.continuous.title).tag(MarkdownLayout.continuous)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("markdownLayoutPicker")
                    .accessibilityLabel("Markdown layout")
                    .accessibilityHint("Letter pages, or one continuously scrolling page")
                } header: {
                    Text("Markdown")
                } footer: {
                    Text("Drop a .css file into Files ▸ On My iPad ▸ Glassine ▸ Styles "
                         + "and it appears here as a style.")
                }
            }
            .onAppear { styles = MarkdownStyle.builtIns + MarkdownStyle.customStyles() }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("settingsDone")
                        .accessibilityLabel("Done")
                        .accessibilityHint("Closes Settings")
                }
            }
        }
    }

    private var appearance: Binding<AppearanceMode> {
        Binding(get: { prefs.appearance }, set: { prefs.setAppearance($0) })
    }

    private var invert: Binding<Bool> {
        Binding(get: { prefs.invertInDarkMode }, set: { prefs.setInvertInDarkMode($0) })
    }

    private var darkPaper: Binding<DarkPaper> {
        Binding(get: { prefs.darkPaper }, set: { prefs.setDarkPaper($0) })
    }

    /// A custom style whose file has been deleted since it was chosen would have
    /// no row to select, and SwiftUI would show an empty picker; fall back to
    /// the default the way `MarkdownStyle.css(forID:)` does.
    private var style: Binding<String> {
        Binding(get: {
            styles.contains { $0.id == prefs.markdownStyle }
                ? prefs.markdownStyle : MarkdownStyle.defaultID
        }, set: { prefs.setMarkdownStyle($0) })
    }

    private var fontSize: Binding<Int> {
        Binding(get: { prefs.markdownFontSize }, set: { prefs.setMarkdownFontSize($0) })
    }

    private var layout: Binding<MarkdownLayout> {
        Binding(get: { prefs.markdownLayout }, set: { prefs.setMarkdownLayout($0) })
    }
}
