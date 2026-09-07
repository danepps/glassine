import GlassineCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The recent-documents picker: the files the reader has been in, most recent
/// first, with a filter, each one's reading position, and the way to any other
/// file. Rows, the filename filter and the two secondary labels are
/// `RecentsModel`'s, exactly as on the Mac; this file is only the `List`.
///
/// It knows nothing about where it is shown -- the launch screen and the sidebar
/// pane both host one and decide for themselves what opening means.
@MainActor
struct RecentsList: View {

    let onOpen: (URL) -> Void
    let onOpenInNewWindow: (URL) -> Void
    let onOpenOther: () -> Void

    @State private var rows: [RecentRow] = []
    @State private var query = ""

    private var filtered: [RecentRow] { RecentsModel.filter(rows, query: query) }

    /// One scene is all an iPhone has, so there is nothing to swipe towards.
    private var supportsMultipleScenes: Bool {
        UIApplication.shared.supportsMultipleScenes
    }

    var body: some View {
        List {
            if filtered.isEmpty {
                Text(rows.isEmpty ? "No recent documents" : "No matches")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
            }
            ForEach(filtered, id: \.key) { row in
                RecentRowView(row: row)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // A missing file opens nothing, as on the Mac.
                        guard !row.isMissing else { return }
                        onOpen(row.url)
                    }
                    .accessibilityIdentifier("recents.\(row.url.lastPathComponent)")
                    .contextMenu {
                        if !row.isMissing {
                            Button("Open") { onOpen(row.url) }
                            Button("Open in New Window") { onOpenInNewWindow(row.url) }
                        }
                        Button("Remove from List", role: .destructive) { remove(row) }
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Remove", role: .destructive) { remove(row) }
                    }
                    // The context menu keeps the same item, but a long press is
                    // not something anyone finds; a swipe is the visible route
                    // to a second window. A file that is gone opens nothing, so
                    // it gets no leading action -- the trailing Remove, which is
                    // the one thing a missing row is still for, stays.
                    .swipeActions(edge: .leading) {
                        if supportsMultipleScenes && !row.isMissing {
                            Button("New Window",
                                   systemImage: "plus.rectangle.on.rectangle") {
                                onOpenInNewWindow(row.url)
                            }
                            .tint(.blue)
                        }
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Filter")
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Open Other…") { onOpenOther() }
                    .accessibilityIdentifier("openOther")
                    .accessibilityHint("Choose a document from Files")
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
        // An iPad drag out of the Files app.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: DocumentTypes.canOpen) else { return false }
            onOpen(url)
            return true
        }
        .onAppear { reload() }
        // Reading a document rewrites the list; coming back to it should show that.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            reload()
        }
    }

    private func reload() {
        rows = RecentsModel.rows()
    }

    private func remove(_ row: RecentRow) {
        Prefs.removeRecentDocument(path: row.key)
        reload()
    }
}

/// Name, folder + "p. N of M", and a relative date -- the Mac's three labels.
private struct RecentRowView: View {
    let row: RecentRow

    private var symbol: String {
        row.url.pathExtension.lowercased() == "pdf" ? "doc.richtext" : "doc.plaintext"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 26))
                .foregroundStyle(.tint)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.url.lastPathComponent)
                    .font(.body)
                    .lineLimit(1)
                Text(row.isMissing ? "Not found" : RecentsModel.detailText(row))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            // Two flexible Texts in one HStack split the leftover width evenly,
            // whatever they actually need: on the iPhone 17e that cut
            // "report.pdf" off at 77 pt for a date that wanted 70 — the
            // accessibility audit's "Text clipped", twice per row. The name is
            // what someone is reading, so it takes its width first and the date
            // gets what is left.
            .layoutPriority(1)
            Spacer(minLength: 8)
            Text(RecentsModel.dateText(row.lastOpened))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
        // A file that is gone is dimmed and does nothing, rather than
        // disappearing behind the reader's back.
        .opacity(row.isMissing ? 0.5 : 1)
        // Four separate labels is four VoiceOver stops for one row, and the
        // third of them ("p. 12 of 211") means nothing without the first. One
        // element, one sentence. `.ignore` rather than `.combine` because
        // combine keeps the icon, whose only content is the file's kind, which
        // the sentence already says.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
        .accessibilityHint(row.isMissing ? "" : "Opens this document")
        .accessibilityAddTraits(row.isMissing ? [] : .isButton)
    }

    /// "report.pdf, PDF, in Downloads, page 12 of 211, 2 hours ago" -- name
    /// first because that is what someone is scanning for, then the detail line
    /// and the date the two small labels carry.
    private var spokenLabel: String {
        let kind = row.url.pathExtension.lowercased() == "pdf" ? "PDF" : "Markdown"
        var parts = [row.url.lastPathComponent, kind]
        if row.isMissing {
            parts.append("not found")
        } else {
            let detail = RecentsModel.detailText(row)
            if !detail.isEmpty { parts.append(detail) }
        }
        let date = RecentsModel.dateText(row.lastOpened)
        if !date.isEmpty { parts.append(date) }
        return parts.joined(separator: ", ")
    }
}

/// "Open Other…". `asCopy: false` so the reader opens the file where it lives
/// and the bookmark it stores keeps finding it; the URL that comes back is
/// security-scoped, which `DocumentSession` starts accessing and holds.
struct DocumentPicker: UIViewControllerRepresentable {

    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types: [UTType] = [.pdf, DocumentTypes.markdown]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types,
                                                    asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController,
                                context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}
