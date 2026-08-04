import UIKit
import UniformTypeIdentifiers

/// "Add to Brain Buddy" from any app's share sheet.
///
/// This extension is deliberately dumb: it copies the shared payload into the
/// App Group inbox folder and exits. All the expensive, failure-prone work —
/// OCR, PDF text extraction, transcription, embeddings — happens in the app,
/// where there is no extension memory cap and no risk of being killed halfway
/// through writing a CloudKit-mirrored store.
///
/// The only contract with the app is "a real file with a real filename".
/// See `BrainBuddy/Services/SharedInbox.swift`.
final class ShareViewController: UIViewController {
    /// Must match `SharedInbox.appGroupIdentifier` and both entitlements files.
    private let appGroupIdentifier = "group.com.brainbuddy.app"
    private let inboxFolderName = "Inbox"

    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    override func viewDidLoad() {
        super.viewDidLoad()
        configureUI()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { await processSharedItems() }
    }

    // MARK: - UI

    private func configureUI() {
        view.backgroundColor = .systemBackground

        let card = UIStackView(arrangedSubviews: [spinner, statusLabel])
        card.axis = .vertical
        card.alignment = .center
        card.spacing = 14
        card.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.text = "Saving to Brain Buddy…"
        statusLabel.font = .preferredFont(forTextStyle: .headline)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        spinner.startAnimating()

        view.addSubview(card)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            card.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32)
        ])
    }

    private func finish(message: String, isError: Bool) {
        spinner.stopAnimating()
        spinner.isHidden = true
        statusLabel.text = message
        statusLabel.textColor = isError ? .systemOrange : .label

        // Leave the confirmation on screen just long enough to be read.
        DispatchQueue.main.asyncAfter(deadline: .now() + (isError ? 1.6 : 0.7)) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
    }

    // MARK: - Import

    private func processSharedItems() async {
        guard let inbox = prepareInboxDirectory() else {
            finish(message: "Brain Buddy's shared storage isn't set up.", isError: true)
            return
        }

        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }

        var saved = 0
        for provider in providers {
            if await write(provider, to: inbox) { saved += 1 }
        }

        guard saved > 0 else {
            finish(message: "Nothing here could be saved.", isError: true)
            return
        }
        finish(message: saved == 1 ? "Saved to Brain Buddy" : "Saved \(saved) items", isError: false)
    }

    /// Writes one attachment into the inbox. Order matters: files and images are
    /// tried before text, because a shared PDF also advertises a text
    /// representation and we want the actual document.
    private func write(_ provider: NSItemProvider, to inbox: URL) async -> Bool {
        if let url = await loadFileURL(from: provider), copy(url, to: inbox) { return true }
        if let image = await loadImageData(from: provider), store(image.data, named: image.name, in: inbox) { return true }
        if let text = await loadText(from: provider) {
            return store(Data(text.utf8), named: "shared-\(UUID().uuidString).txt", in: inbox)
        }
        return false
    }

    // MARK: - Loading

    /// A URL attachment can be either a web link or an on-disk file; only the
    /// latter should be copied as a document.
    private func loadFileURL(from provider: NSItemProvider) async -> URL? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return nil }
        let url = await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                switch item {
                case let url as URL: continuation.resume(returning: url)
                case let data as Data: continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil))
                default: continuation.resume(returning: nil)
                }
            }
        }
        return url?.isFileURL == true ? url : nil
    }

    private func loadImageData(from provider: NSItemProvider) async -> (data: Data, name: String)? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<(Data, String)?, Never>) in
            provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { item, _ in
                let base = "shared-\(UUID().uuidString)"
                switch item {
                case let image as UIImage:
                    if let data = image.jpegData(compressionQuality: 0.9) {
                        continuation.resume(returning: (data, base + ".jpg"))
                    } else {
                        continuation.resume(returning: nil)
                    }
                case let data as Data:
                    continuation.resume(returning: (data, base + ".jpg"))
                case let url as URL:
                    if let data = try? Data(contentsOf: url) {
                        continuation.resume(returning: (data, base + "." + (url.pathExtension.isEmpty ? "jpg" : url.pathExtension)))
                    } else {
                        continuation.resume(returning: nil)
                    }
                default:
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Plain text and web URLs both arrive as text; the app decides which is
    /// which, so both are written as `.txt`.
    private func loadText(from provider: NSItemProvider) async -> String? {
        for identifier in [UTType.url.identifier, UTType.plainText.identifier, UTType.text.identifier]
        where provider.hasItemConformingToTypeIdentifier(identifier) {
            let text = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, _ in
                    switch item {
                    case let url as URL: continuation.resume(returning: url.absoluteString)
                    case let string as String: continuation.resume(returning: string)
                    case let attributed as NSAttributedString: continuation.resume(returning: attributed.string)
                    case let data as Data: continuation.resume(returning: String(data: data, encoding: .utf8))
                    default: continuation.resume(returning: nil)
                    }
                }
            }
            if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        }
        return nil
    }

    // MARK: - Writing

    private func prepareInboxDirectory() -> URL? {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else { return nil }
        let inbox = container.appendingPathComponent(inboxFolderName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            return inbox
        } catch {
            return nil
        }
    }

    private func copy(_ source: URL, to inbox: URL) -> Bool {
        // Keep the original filename — it's the only title hint a shared PDF has
        // — but prefix it so two shares of "scan.pdf" can't collide.
        let name = "\(UUID().uuidString.prefix(8))-\(source.lastPathComponent)"
        let destination = inbox.appendingPathComponent(name)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            return true
        } catch {
            // Sandboxed providers sometimes refuse a direct copy; fall back to
            // reading the bytes ourselves.
            guard let data = try? Data(contentsOf: source) else { return false }
            return store(data, named: name, in: inbox)
        }
    }

    private func store(_ data: Data, named name: String, in inbox: URL) -> Bool {
        guard !data.isEmpty else { return false }
        do {
            try data.write(to: inbox.appendingPathComponent(name), options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
