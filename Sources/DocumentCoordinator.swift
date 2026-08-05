import AppKit
import UniformTypeIdentifiers

/// 開いているウインドウの管理役。1 ファイル 1 ウインドウを守り、
/// 既に開いているファイルをもう一度開こうとしたら、そのウインドウを前に出す。
final class DocumentCoordinator {
    static let shared = DocumentCoordinator()

    private var controllers: [DocumentWindowController] = []

    private init() {}

    var isEmpty: Bool { controllers.isEmpty }

    var frontmostDocumentWindow: NSWindow? {
        controllers.last(where: { $0.window?.isVisible == true })?.window
    }

    // MARK: - 開く

    func open(_ url: URL) {
        let target = url.standardizedFileURL

        guard FileManager.default.fileExists(atPath: target.path) else {
            presentMissingFileAlert(for: target)
            return
        }

        if let existing = controllers.first(where: { $0.fileURL == target }) {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        let controller = DocumentWindowController(fileURL: target)
        controllers.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    func forget(_ controller: DocumentWindowController) {
        controllers.removeAll { $0 === controller }
    }

    func applyPreferencesToAll() {
        controllers.forEach { $0.applyPreferences() }
    }

    // MARK: - ファイル選択

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = Self.openableContentTypes
        panel.allowsOtherFileTypes = true
        panel.message = "表示する Markdown ファイルを選んでください"

        guard panel.runModal() == .OK else { return }
        panel.urls.forEach { open($0) }
    }

    private func presentMissingFileAlert(for url: URL) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "ファイルが見つかりません"
        alert.informativeText = url.path
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - 判定

    private static let markdownExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "mdtext", "mdx", "qmd", "text", "txt"
    ]

    private static var openableContentTypes: [UTType] {
        var types: [UTType] = [.plainText]
        if let markdown = UTType("net.daringfireball.markdown") { types.insert(markdown, at: 0) }
        return types
    }

    static func isMarkdown(_ url: URL) -> Bool {
        markdownExtensions.contains(url.pathExtension.lowercased())
    }
}
