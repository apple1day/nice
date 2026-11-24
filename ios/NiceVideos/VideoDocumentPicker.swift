import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct VideoDocumentPicker: UIViewControllerRepresentable {
    let onPick: (PickedVideoFile.Selection?) -> Void

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
        private let onPick: (PickedVideoFile.Selection?) -> Void

        init(onPick: @escaping (PickedVideoFile.Selection?) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls.first.map { PickedVideoFile.Selection($0) })
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onPick(nil)
        }
    }
}
