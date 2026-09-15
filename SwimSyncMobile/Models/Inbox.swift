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
    @Published var pendingText: TextDocument?
    @Published var problem: String?

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
    /// sheet; anything else is assumed to be audio and handed to the queue.
    func receive(_ url: URL, into library: MobileLibrary) {
        if Self.isText(url) {
            do {
                pendingText = try Self.readText(url)
            } catch {
                problem = "Couldn't read \(url.lastPathComponent) — \(error.localizedDescription)"
            }
        } else {
            library.add([url])
        }
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
