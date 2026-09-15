import SwiftUI
import PhotosUI
import CoreTransferable

/// A video from the Photos library, copied into the app before anything
/// long-running touches it: the picker's file is temporary.
struct PickedVideo: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { picked in
            SentTransferredFile(picked.url)
        } importing: { received in
            let folder = URL.documentsDirectory
                .appendingPathComponent("Videos/Imports", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent(received.file.lastPathComponent)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return PickedVideo(url: destination)
        }
    }
}

/// Wraps `PhotosPicker` so the Transfer tab can offer "from Photos" next to
/// "from Files" without carrying PhotosUI state itself.
struct PhotosVideoPicker: View {
    @Binding var isPresented: Bool
    let onPicked: ([URL]) -> Void
    let onProblem: (String) -> Void

    @State private var selection: [PhotosPickerItem] = []

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .photosPicker(
                isPresented: $isPresented,
                selection: $selection,
                maxSelectionCount: 10,
                matching: .videos
            )
            .onChange(of: selection) { _, items in
                guard !items.isEmpty else { return }
                selection = []
                Task {
                    var urls: [URL] = []
                    for item in items {
                        do {
                            if let video = try await item.loadTransferable(type: PickedVideo.self) {
                                urls.append(video.url)
                            }
                        } catch {
                            onProblem("Couldn't load that video from Photos — \(error.localizedDescription)")
                        }
                    }
                    onPicked(urls)
                }
            }
    }
}
