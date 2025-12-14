#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

/// iOS document picker for selecting video files from Files app
struct DocumentPickerView: UIViewControllerRepresentable {
    @Binding var selectedURL: URL?
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let supportedTypes: [UTType] = [
            .movie,
            .video,
            .mpeg4Movie,
            .quickTimeMovie,
            .avi,
            UTType(filenameExtension: "mkv") ?? .movie,
            UTType(filenameExtension: "wmv") ?? .movie,
            UTType(filenameExtension: "flv") ?? .movie,
            UTType(filenameExtension: "webm") ?? .movie
        ]

        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: supportedTypes,
            asCopy: false
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPickerView

        init(_ parent: DocumentPickerView) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }

            // Start accessing security-scoped resource
            if url.startAccessingSecurityScopedResource() {
                parent.selectedURL = url
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.dismiss()
        }
    }
}

/// Wrapper view for presenting the document picker as a sheet
struct FileBrowserSheet: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedURL: URL?

    var body: some View {
        DocumentPickerView(selectedURL: $selectedURL)
            .onChange(of: selectedURL) { newURL in
                if let url = newURL {
                    appState.loadMedia(from: url)
                    appState.showingFilePicker = false
                }
            }
            .ignoresSafeArea()
    }
}
#endif
