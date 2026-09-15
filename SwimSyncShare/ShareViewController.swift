import UIKit
import UniformTypeIdentifiers

/// The "SwimSync" row in the share sheet.
///
/// Takes whatever was shared — text, a web page, audio or video files — and
/// writes it into the app-group inbox, then tells the user to open the app.
/// Nothing heavy happens here: extensions get little memory and are killed
/// quickly, so conversion waits for the app.
final class ShareViewController: UIViewController {
    private let label = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var saved = 0
    private var failures: [String] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.086, green: 0.092, blue: 0.110, alpha: 1)
        overrideUserInterfaceStyle = .dark

        label.textColor = .white
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textAlignment = .center
        label.numberOfLines = 0
        label.text = "Adding to SwimSync…"

        spinner.color = .white
        spinner.startAnimating()

        let stack = UIStackView(arrangedSubviews: [spinner, label])
        stack.axis = .vertical
        stack.spacing = 14
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24)
        ])
        preferredContentSize = CGSize(width: 320, height: 180)

        process()
    }

    // MARK: - Intake

    private func process() {
        guard let inbox = AppGroup.inbox else {
            finish(message: "SwimSync isn't set up for sharing on this build.")
            return
        }
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        guard !providers.isEmpty else {
            finish(message: "Nothing to add.")
            return
        }

        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            handle(provider, into: inbox) { group.leave() }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            if saved == 0 {
                finish(message: failures.first ?? "That can't be added to SwimSync. Share text, a web page, or an audio or video file.")
            } else {
                let what = saved == 1 ? "1 item" : "\(saved) items"
                finish(message: "Added \(what). Open SwimSync to convert and send it.")
            }
        }
    }

    /// Order matters: a Safari share offers the JavaScript result, a URL and
    /// text all at once, and the page text is the one worth keeping.
    private func handle(_ provider: NSItemProvider, into inbox: URL, done: @escaping () -> Void) {
        if provider.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.propertyList.identifier) { [weak self] item, _ in
                let results = (item as? NSDictionary)?[NSExtensionJavaScriptPreprocessingResultsKey] as? NSDictionary
                self?.savePage(results, into: inbox)
                done()
            }
            return
        }
        for type in [UTType.movie, .video, .audio] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { [weak self] url, error in
                // The file is gone the moment this returns, so it is copied here.
                if let url { self?.saveFile(url, into: inbox) } else { self?.fail(error) }
                done()
            }
            return
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { [weak self] item, error in
                if let url = item as? URL { self?.saveFile(url, into: inbox) } else { self?.fail(error) }
                done()
            }
            return
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.url.identifier) { [weak self] item, error in
                if let url = item as? URL {
                    url.isFileURL ? self?.saveFile(url, into: inbox) : self?.saveLink(url, title: nil, into: inbox)
                } else {
                    self?.fail(error)
                }
                done()
            }
            return
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { [weak self] item, error in
                switch item {
                case let text as String: self?.saveText(text, title: nil, into: inbox)
                case let data as Data: self?.saveText(String(decoding: data, as: UTF8.self), title: nil, into: inbox)
                case let url as URL: self?.saveFile(url, into: inbox)
                default: self?.fail(error)
                }
                done()
            }
            return
        }
        failures.append("One item wasn't a kind SwimSync can use.")
        done()
    }

    // MARK: - Saving

    private func savePage(_ results: NSDictionary?, into inbox: URL) {
        let title = (results?["title"] as? String) ?? ""
        let text = (results?["text"] as? String) ?? ""
        let link = (results?["url"] as? String).flatMap(URL.init(string:))
        if text.trimmingCharacters(in: .whitespacesAndNewlines).count > 40 {
            saveText(text, title: title, into: inbox)
        } else if let link {
            saveLink(link, title: title, into: inbox)
        } else {
            failures.append("The page had no readable text.")
        }
    }

    private func saveText(_ text: String, title: String?, into inbox: URL) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { failures.append("The shared text was empty."); return }
        // Notes shares the note body only; its first line is the title.
        let firstLine = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Shared text"
        let stem = FileNaming.sanitize(String((title?.isEmpty == false ? title! : firstLine).prefix(80)))
        let url = AppGroup.uniqueURL(in: inbox, stem: stem.isEmpty ? "Shared text" : stem, ext: "txt")
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            saved += 1
        } catch {
            failures.append(error.localizedDescription)
        }
    }

    private func saveLink(_ link: URL, title: String?, into inbox: URL) {
        let stem = FileNaming.sanitize(String((title?.isEmpty == false ? title! : (link.host ?? "Web page")).prefix(80)))
        let url = AppGroup.uniqueURL(in: inbox, stem: stem, ext: AppGroup.webLinkExtension)
        do {
            try link.absoluteString.write(to: url, atomically: true, encoding: .utf8)
            saved += 1
        } catch {
            failures.append(error.localizedDescription)
        }
    }

    private func saveFile(_ source: URL, into inbox: URL) {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let ext = source.pathExtension.isEmpty ? "bin" : source.pathExtension
        let stem = FileNaming.sanitize(source.deletingPathExtension().lastPathComponent)
        let destination = AppGroup.uniqueURL(in: inbox, stem: stem.isEmpty ? "Shared file" : stem, ext: ext)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            saved += 1
        } catch {
            failures.append("Couldn't copy \(source.lastPathComponent) — \(error.localizedDescription)")
        }
    }

    private func fail(_ error: Error?) {
        failures.append(error?.localizedDescription ?? "One item couldn't be read.")
    }

    // MARK: - Finish

    private func finish(message: String) {
        spinner.stopAnimating()
        spinner.isHidden = true
        label.text = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
    }
}
