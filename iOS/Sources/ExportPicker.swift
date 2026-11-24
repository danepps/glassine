import GlassineCore
import SwiftUI
import UIKit

/// `UIDocumentPickerViewController(forExporting:)` -- "where should this go?",
/// the iOS answer to the Mac's `NSSavePanel`. The file is written first and the
/// picker copies it, which is why `exportPDF` writes into the temporary directory
/// rather than asking for a destination up front.
struct ExportPicker: UIViewControllerRepresentable {

    let file: TemporaryExport
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [file.url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController,
                                context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(file: file, onFinish: onFinish) }

    static func dismantleUIViewController(_ controller: UIDocumentPickerViewController,
                                         coordinator: Coordinator) {
        // Interactive sheet dismissal need not call the picker delegate.
        coordinator.file.remove()
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let file: TemporaryExport
        private let onFinish: () -> Void
        init(file: TemporaryExport, onFinish: @escaping () -> Void) {
            self.file = file
            self.onFinish = onFinish
        }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            finish()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            finish()
        }

        private func finish() {
            file.remove()
            onFinish()
        }
    }
}
