import Foundation
import UniformTypeIdentifiers

/// A text file the user wants read aloud, already loaded into memory so the
/// security scope of wherever it came from can be released immediately.
struct TextDocument: Identifiable {
    let id = UUID()
    let name: String
    let text: String

    var suggestedTitle: String {
        (name as NSString).deletingPathExtension
    }
}

/// Where files arrive from outside the app: the share sheet, "Open in",
/// and the Files picker on the Transfer tab. Audio goes straight to the
/// queue; text is held here until the speech sheet has taken it.
@MainActor
final class Inbox: ObservableObject {
    /// The document the speech sheet is showing. Setting it to nil (the
    /// sheet dismissing) pulls the next one from `waiting`.
    @Published var pendingText: TextDocument? {
        didSet { if pendingText == nil, !waiting.isEmpty { pendingText = waiting.removeFirst() } }
    }
    @Published var problem: String?
    private var waiting: [TextDocument] = []

    static let textTypes: [UTType] = [
        .plainText, .text, .utf8PlainText, UTType("net.daringfireball.markdown")
    ].compactMap { $0 }

    static let textExtensions: Set<String> = ["txt", "text", "md", "markdown"]

    static func isText(_ url: URL) -> Bool {
        if textExtensions.contains(url.pathExtension.lowercased()) { return true }
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .text) && !type.conforms(to: .audio)
    }

    /// Routes one incoming URL. Text is read now and queued for the speech
    /// sheet, a video goes to the extractor, and anything else is assumed
    /// to be audio and handed to the queue.
    func receive(_ url: URL, into library: MobileLibrary, videos: VideoExtractor) {
        if Self.isText(url) {
            do {
                enqueue(try Self.readText(url))
            } catch {
                problem = "Couldn't read \(url.lastPathComponent) — \(error.localizedDescription)"
            }
        } else if VideoExtractor.isVideo(url) {
            videos.extract(url)
        } else {
            library.add([url])
        }
    }

    /// Shows the document now, or after the one already on screen.
    func enqueue(_ document: TextDocument) {
        if pendingText == nil { pendingText = document } else { waiting.append(document) }
    }

    static func readText(_ url: URL) throws -> TextDocument {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)
        // UTF-8 first; a Windows text file falls through to Latin-1 rather
        // than failing, since the most common failure is a stray smart quote.
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        return TextDocument(name: url.lastPathComponent, text: text)
    }
}
