import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct VideoDocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // Some providers expose MKV and WebM as generic data. The reader checks
        // the actual extension and header; a movie-only filter would hide them.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: (URL?) -> Void

        init(onPick: @escaping (URL?) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls.first)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onPick(nil)
        }
    }
}
