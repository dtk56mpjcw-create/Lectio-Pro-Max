import SwiftUI
import QuickLook
import UIKit

/// QuickLook, so a hand-in opens inside the app instead of bouncing to Safari —
/// which wouldn't have the Lectio session anyway. Its share button is what
/// gives "Save to Files", AirDrop and the rest, so we don't need our own.
struct DocumentPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UINavigationController {
        let preview = QLPreviewController()
        preview.dataSource = context.coordinator
        return UINavigationController(rootViewController: preview)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) { }

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController,
                               previewItemAt index: Int) -> QLPreviewItem {
            return url as NSURL
        }
    }
}

/// A downloaded file waiting to be shown.
struct PreviewDocument: Identifiable {
    let id = UUID()
    let url: URL
}
