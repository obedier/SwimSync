import Foundation

/// Sweeps what the share extension left in the app-group inbox.
///
/// Runs on every return to the foreground: the extension cannot wake the
/// app, so "share, then open SwimSync" is the contract, and this is the
/// half the app keeps.
@MainActor
enum SharedInbox {
    static func drain(into inbox: Inbox, library: MobileLibrary, videos: VideoExtractor) async {
        guard let folder = AppGroup.inbox else { return }
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        )) ?? []).sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }

        for file in files {
            let ext = file.pathExtension.lowercased()
            if ext == AppGroup.webLinkExtension {
                await readLink(file, into: inbox)
            } else if Inbox.isText(file) {
                if let document = try? Inbox.readText(file) { inbox.enqueue(document) }
                try? FileManager.default.removeItem(at: file)
            } else if VideoExtractor.isVideo(file) {
                if let moved = move(file, to: videos.importFolder) { videos.extract(moved) }
            } else if Track.audioFormats.contains(ext) {
                if let moved = move(file, to: sharedAudioFolder) { library.add([moved]) }
            } else {
                inbox.problem = "“\(file.lastPathComponent)” isn't something SwimSync can use."
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    /// `Documents/Shared`: audio that arrived through the share sheet.
    private static var sharedAudioFolder: URL {
        let folder = URL.documentsDirectory.appendingPathComponent("Shared", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func move(_ file: URL, to folder: URL) -> URL? {
        let destination = AppGroup.uniqueURL(
            in: folder, stem: file.deletingPathExtension().lastPathComponent, ext: file.pathExtension
        )
        do {
            try FileManager.default.moveItem(at: file, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    /// A page shared from a browser other than Safari arrives as a bare
    /// link; fetch it and strip the markup down to readable text.
    private static func readLink(_ file: URL, into inbox: Inbox) async {
        defer { try? FileManager.default.removeItem(at: file) }
        guard let raw = try? String(contentsOf: file, encoding: .utf8),
              let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        let name = file.deletingPathExtension().lastPathComponent

        if let host = url.host, host.contains("youtube.com") || host.contains("youtu.be") {
            inbox.problem = "That's a YouTube link. SwimSync can't download videos; save the video with a downloader app or the browser, then share the file."
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                inbox.problem = "Couldn't load \(url.host ?? "that page")."
                return
            }
            let html = String(decoding: data, as: UTF8.self)
            let text = HTMLText.plainText(from: html)
            guard text.count > 40 else {
                inbox.problem = "\(name) had no readable text."
                return
            }
            let title = HTMLText.title(from: html) ?? name
            inbox.enqueue(TextDocument(name: "\(title).txt", text: text))
        } catch {
            inbox.problem = "Couldn't load \(url.host ?? "that page") — \(error.localizedDescription)"
        }
    }
}

/// Just enough HTML handling to read an article aloud. Not a parser: script
/// and style blocks go, block tags become line breaks, everything else is
/// stripped, and the common entities are decoded.
enum HTMLText {
    static func title(from html: String) -> String? {
        guard let match = html.range(of: "<title[^>]*>([^<]*)</title>", options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        let inner = html[match].replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let title = decode(inner).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    static func plainText(from html: String) -> String {
        var s = html
        for block in ["script", "style", "noscript", "svg", "nav", "header", "footer"] {
            s = s.replacingOccurrences(
                of: "<\(block)\\b[^>]*>[\\s\\S]*?</\(block)>", with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        s = s.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(
            of: "</?(p|div|br|h[1-6]|li|tr|section|article|blockquote)\\b[^>]*>", with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        s = decode(s)
        // Collapse runs of spaces, then runs of blank lines.
        s = s.replacingOccurrences(of: "[ \\t\\u{00A0}]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: " *\\n *", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decode(_ s: String) -> String {
        var out = s
        for (entity, char) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
                               ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&rsquo;", "’"),
                               ("&lsquo;", "‘"), ("&ldquo;", "“"), ("&rdquo;", "”"), ("&mdash;", "—"),
                               ("&ndash;", "–"), ("&hellip;", "…")] {
            out = out.replacingOccurrences(of: entity, with: char)
        }
        // Numeric entities.
        if let regex = try? NSRegularExpression(pattern: "&#(\\d+);") {
            let matches = regex.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed()
            for m in matches {
                guard let r = Range(m.range, in: out), let nr = Range(m.range(at: 1), in: out),
                      let code = UInt32(out[nr]), let scalar = Unicode.Scalar(code) else { continue }
                out.replaceSubrange(r, with: String(Character(scalar)))
            }
        }
        return out
    }
}
