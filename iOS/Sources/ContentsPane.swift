import GlassineCore
import PDFKit
import SwiftUI

/// The table of contents: the document's outline flattened pre-order, indented
/// by depth, with the entry the reader is inside highlighted.
///
/// Native text, deliberately **not** filtered -- the inversion is for page
/// content, and running chrome through it would make the labels grey-on-grey.
@MainActor
struct ContentsPane: View {

    let session: DocumentSession
    let onNavigate: () -> Void

    var body: some View {
        Group {
            if session.outlineEntries.isEmpty {
                ContentUnavailableView("No Contents", systemImage: "list.bullet",
                                       description: Text("This document has no outline."))
            } else {
                list
            }
        }
        .accessibilityIdentifier("contentsPane")
    }

    private var list: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(Array(session.outlineEntries.enumerated()), id: \.offset) { index, entry in
                    Button {
                        guard let destination = OutlineSync.destination(of: entry.node) else { return }
                        session.go(to: destination)
                        onNavigate()
                    } label: {
                        Text(entry.node.label ?? "")
                            .font(.callout)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, CGFloat(entry.depth) * 14)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(index == session.outlineSelection ? Color.accentColor : .primary)
                    .listRowBackground(index == session.outlineSelection
                                       ? Color.accentColor.opacity(0.15) : Color.clear)
                    .id(index)
                    .accessibilityIdentifier("contents.row.\(index)")
                    .accessibilityHint("Goes to this section")
                    // The entry the reader is inside, said out loud: VoiceOver
                    // announces "selected", and it is also how a test can see
                    // that a re-typesetting kept the reader's place.
                    .accessibilityAddTraits(index == session.outlineSelection
                                            ? [.isSelected] : [])
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // Follow the reading position, the way the Mac's outline view
            // scrolls itself to the chapter that has started.
            .onChange(of: session.outlineSelection) { _, new in
                guard new >= 0 else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(new, anchor: .center) }
            }
            // And on the way in, because on iPhone the pane is a sheet that
            // appears long after the selection last changed: without this it
            // opens at the top of a 120-entry outline whatever the reader is
            // looking at.
            .onAppear {
                guard session.outlineSelection >= 0 else { return }
                proxy.scrollTo(session.outlineSelection, anchor: .center)
            }
        }
    }
}
