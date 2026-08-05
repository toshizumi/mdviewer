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

    /// ドロップされたファイルを開く。
    /// 1 つ目は落とされたウインドウの表示を差し替え、2 つ目以降は新しいウインドウで開く。
    /// ただし、すでに別のウインドウで開いているファイルはそちらを前に出すだけにして、
    /// 同じファイルが 2 枚並ばないようにする。
    func open(_ urls: [URL], startingIn controller: DocumentWindowController) {
        var reuseTarget: DocumentWindowController? = controller

        for url in urls {
            let target = url.standardizedFileURL

            guard FileManager.default.fileExists(atPath: target.path) else {
                presentMissingFileAlert(for: target)
                continue
            }

            if let existing = controllers.first(where: { $0.fileURL == target }) {
                existing.window?.makeKeyAndOrderFront(nil)
                // 落とされたウインドウ自身が既にそのファイルなら、再読み込みだけしておく
                if existing === controller { existing.show(fileURL: target) }
                continue
            }

            if let reuse = reuseTarget {
                reuse.show(fileURL: target)
                reuse.window?.makeKeyAndOrderFront(nil)
                reuseTarget = nil
            } else {
                open(target)
            }
        }
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

    /// MDViewer で表示できそうなファイルか。ドロップを受け付けるかの判定に使う。
    /// 拡張子のないファイル（README など）も通す。
    static func canOpen(_ url: URL) -> Bool {
        let ext = url.pathExtension
        if ext.isEmpty || isMarkdown(url) { return true }
        return UTType(filenameExtension: ext)?.conforms(to: .text) ?? false
    }
}
