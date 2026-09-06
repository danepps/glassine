import SwiftUI
import UIKit

/// A file the reader has just written and wants to hand to the system: Export as
/// PDF's paginated re-render, sitting in the temporary directory until the
/// picker moves or copies it.
///
/// `Identifiable` because `.sheet(item:)` is what presents it: the URL is not
/// known until the re-render finishes, and a boolean flag would present the
/// sheet with nothing in it.
struct ExportFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// `UIDocumentPickerViewController(forExporting:)` -- "where should this go?",
/// the iOS answer to the Mac's `NSSavePanel`. The file is written first and the
/// picker moves it, which is why `exportPDF` writes into the temporary directory
/// rather than asking for a destination up front.
struct ExportPicker: UIViewControllerRepresentable {

    let file: ExportFile
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [file.url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController,
                                context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            onFinish()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onFinish()
        }
    }
}
