import AppKit

/// ウインドウにファイルをドロップして開けるようにするための入れ物。
/// WKWebView 側は `unregisterDraggedTypes()` してあるので、ドロップはここに届く。
final class DropContainerView: NSView {
    var onDropFiles: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) は使わない") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFiles(sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = droppedFiles(sender)
        guard !files.isEmpty else { return false }
        onDropFiles?(files)
        return true
    }

    private func droppedFiles(_ sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: options) as? [URL] ?? []
        return urls.filter { !$0.hasDirectoryPath }
    }
}

// MARK: -

final class DocumentWindowController: NSWindowController {
    private(set) var fileURL: URL

    private let markdownView = MarkdownView(frame: .zero)
    private let container = DropContainerView(frame: .zero)
    private var watcher: FileWatcher?

    // NSSearchToolbarItem は挿入時に検索フィールドを組み直して delegate を握ってしまうため、
    // 逐次検索が拾えない。素の NSSearchField を自前でツールバーに載せる。
    private let searchField = NSSearchField()
    private let matchCountLabel = NSTextField(labelWithString: "")
    private var lastQuery = ""

    // MARK: - 生成

    init(fileURL: URL) {
        self.fileURL = fileURL

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 1000),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.minSize = NSSize(width: 420, height: 320)
        window.toolbarStyle = .unified
        super.init(window: window)

        window.delegate = self
        shouldCascadeWindows = false
        setUpContent()
        setUpToolbar()
        placeWindow()

        // 1 文字ごとの検索。delegate（controlTextDidChange）は NSSearchField の
        // 内部事情で呼ばれないことがあるため、通知を直接受ける。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(searchTextDidChange(_:)),
            name: NSControl.textDidChangeNotification,
            object: searchField)

        markdownView.onOpenFile = { [weak self] url in self?.handleLinkedFile(url) }
        container.onDropFiles = { urls in
            urls.forEach { DocumentCoordinator.shared.open($0) }
        }

        loadDocument()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) は使わない") }

    private func setUpContent() {
        container.autoresizingMask = [.width, .height]
        markdownView.frame = container.bounds
        markdownView.autoresizingMask = [.width, .height]
        container.addSubview(markdownView)
        window?.contentView = container
    }

    /// 1 枚目は前回のサイズを復元し、2 枚目以降は少しずらして重ねる。
    private func placeWindow() {
        guard let window else { return }
        let autosaveName = "MDViewerDocumentWindow"

        if let previous = DocumentCoordinator.shared.frontmostDocumentWindow {
            window.setFrame(previous.frame, display: false)
            window.setFrameOrigin(NSPoint(x: previous.frame.minX + 24,
                                          y: previous.frame.minY - 24))
            window.setFrameAutosaveName(autosaveName)
        } else {
            window.setFrameAutosaveName(autosaveName)
            if !window.setFrameUsingName(autosaveName) { window.center() }
        }
    }

    // MARK: - 読み込み

    private func loadDocument() {
        window?.title = fileURL.lastPathComponent
        window?.representedURL = fileURL
        window?.subtitle = (fileURL.deletingLastPathComponent().path as NSString)
            .abbreviatingWithTildeInPath

        do {
            let text = try TextFile.read(at: fileURL)
            markdownView.render(text: text, directory: fileURL.deletingLastPathComponent())
        } catch {
            markdownView.showMessage(error.localizedDescription)
        }

        watcher = FileWatcher(url: fileURL) { [weak self] in self?.reloadFromDisk() }
        NSDocumentController.shared.noteNewRecentDocumentURL(fileURL)
    }

    private func reloadFromDisk() {
        guard let text = try? TextFile.read(at: fileURL) else { return }
        markdownView.render(text: text, directory: fileURL.deletingLastPathComponent())
    }

    func show(fileURL url: URL) {
        watcher?.stop()
        watcher = nil
        fileURL = url
        lastQuery = ""
        searchField.stringValue = ""
        matchCountLabel.stringValue = ""
        loadDocument()
    }

    func applyPreferences() {
        markdownView.applyPreferences()
    }

    /// Markdown 内のリンクを踏んだとき。.md なら MDViewer で、それ以外は既定のアプリで開く。
    private func handleLinkedFile(_ url: URL) {
        if DocumentCoordinator.isMarkdown(url), FileManager.default.fileExists(atPath: url.path) {
            DocumentCoordinator.shared.open(url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - ツールバー

    private func setUpToolbar() {
        let toolbar = NSToolbar(identifier: "MDViewerToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
    }
}

// MARK: - アクション

extension DocumentWindowController {
    @objc func exportAsPDF(_ sender: Any?) {
        guard let window else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.directoryURL = fileURL.deletingLastPathComponent()
        panel.nameFieldStringValue = fileURL.deletingPathExtension().lastPathComponent + ".pdf"
        panel.message = "PDF の書き出し先を選んでください"

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = panel.url, let self else { return }
            // 画像の読み込み完了と検索ハイライトの解除を待ってから組版する
            self.markdownView.prepareForPrinting {
                PDFExporter.export(webView: self.markdownView.webView,
                                   to: destination,
                                   title: self.fileURL.deletingPathExtension().lastPathComponent,
                                   in: window) { error in
                    self.markdownView.finishPrinting()
                    if let error {
                        self.showErrorSheet(error)
                    } else {
                        NSWorkspace.shared.activateFileViewerSelecting([destination])
                    }
                }
            }
        }
    }

    @objc func printDocument(_ sender: Any?) {
        markdownView.prepareForPrinting { [weak self] in
            guard let self else { return }
            PDFExporter.presentPrintPanel(
                webView: self.markdownView.webView,
                title: self.fileURL.deletingPathExtension().lastPathComponent,
                in: self.window) { [weak self] in
                    self?.markdownView.finishPrinting()
                }
        }
    }

    @objc func reloadDocument(_ sender: Any?) {
        reloadFromDisk()
    }

    @objc func revealInFinder(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    // MARK: 検索

    @objc func showFindBar(_ sender: Any?) {
        window?.makeFirstResponder(searchField)
    }

    @objc func findNextMatch(_ sender: Any?) {
        markdownView.findNext { [weak self] in self?.updateMatchCount($0) }
    }

    @objc func findPreviousMatch(_ sender: Any?) {
        markdownView.findPrevious { [weak self] in self?.updateMatchCount($0) }
    }

    @objc private func searchTextDidChange(_ notification: Notification) {
        runSearch(searchField.stringValue)
    }

    /// 検索フィールドのアクション。
    /// Return で送られてきたときだけ次のヒットへ進める。入力中の逐次検索は
    /// controlTextDidChange 側の担当なので、ここで進めてしまうと 2 件目に飛んでしまう。
    @objc private func searchFieldAction(_ sender: NSSearchField) {
        let returnKeyCodes: Set<UInt16> = [36, 76]   // Return / テンキーの Enter
        let event = NSApp.currentEvent
        let isReturn = event?.type == .keyDown && returnKeyCodes.contains(event?.keyCode ?? 0)

        if isReturn, sender.stringValue == lastQuery, !lastQuery.isEmpty {
            findNextMatch(sender)
        } else {
            runSearch(sender.stringValue)
        }
    }

    private func runSearch(_ query: String) {
        lastQuery = query
        markdownView.find(query) { [weak self] result in
            self?.updateMatchCount(result, query: query)
        }
    }

    private func updateMatchCount(_ result: MarkdownView.SearchResult, query: String? = nil) {
        let text = query ?? lastQuery
        if text.isEmpty {
            matchCountLabel.stringValue = ""
        } else if result.total == 0 {
            matchCountLabel.stringValue = "見つかりません"
            matchCountLabel.textColor = .systemRed
            return
        } else {
            matchCountLabel.stringValue = "\(result.index) / \(result.total)"
        }
        matchCountLabel.textColor = .secondaryLabelColor
    }

    private func showErrorSheet(_ error: Error) {
        guard let window else { return }
        let alert = NSAlert(error: error)
        alert.beginSheetModal(for: window)
    }
}

// MARK: - NSWindowDelegate

extension DocumentWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        watcher?.stop()
        watcher = nil
        DocumentCoordinator.shared.forget(self)
    }
}

// MARK: - NSToolbarDelegate

private extension NSToolbarItem.Identifier {
    static let exportPDF = NSToolbarItem.Identifier("jp.garage-standard.mdviewer.exportPDF")
    static let textSize  = NSToolbarItem.Identifier("jp.garage-standard.mdviewer.textSize")
    static let matches   = NSToolbarItem.Identifier("jp.garage-standard.mdviewer.matches")
    static let search    = NSToolbarItem.Identifier("jp.garage-standard.mdviewer.search")
}

extension DocumentWindowController: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.exportPDF, .flexibleSpace, .textSize, .matches, .search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case .exportPDF:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "PDF"
            item.paletteLabel = "PDF として書き出す"
            item.toolTip = "PDF として書き出す (⇧⌘E)"
            item.image = NSImage(systemSymbolName: "arrow.down.doc",
                                 accessibilityDescription: "PDF として書き出す")
            item.isBordered = true
            item.target = self
            item.action = #selector(exportAsPDF(_:))
            return item

        case .textSize:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "文字サイズ"
            item.toolTip = "文字サイズを変える (⌘- / ⌘+)"
            item.view = makeTextSizeControl()
            return item

        case .matches:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "検索結果"
            matchCountLabel.font = .systemFont(ofSize: 11)
            matchCountLabel.textColor = .secondaryLabelColor
            matchCountLabel.alignment = .right
            matchCountLabel.lineBreakMode = .byClipping
            matchCountLabel.translatesAutoresizingMaskIntoConstraints = false
            matchCountLabel.widthAnchor.constraint(equalToConstant: 84).isActive = true
            item.view = matchCountLabel
            return item

        case .search:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "検索"
            item.toolTip = "文書内を検索 (⌘F)"
            searchField.placeholderString = "文書内を検索"
            searchField.target = self
            searchField.action = #selector(searchFieldAction(_:))
            searchField.sendsSearchStringImmediately = true
            searchField.translatesAutoresizingMaskIntoConstraints = false
            searchField.widthAnchor.constraint(equalToConstant: 210).isActive = true
            item.view = searchField
            return item

        default:
            return nil
        }
    }

    private func makeTextSizeControl() -> NSSegmentedControl {
        let smaller = NSImage(systemSymbolName: "textformat.size.smaller",
                              accessibilityDescription: "文字を小さく")
        let larger = NSImage(systemSymbolName: "textformat.size.larger",
                             accessibilityDescription: "文字を大きく")

        let control: NSSegmentedControl
        if let smaller, let larger {
            control = NSSegmentedControl(images: [smaller, larger],
                                         trackingMode: .momentary,
                                         target: self,
                                         action: #selector(textSizeSegmentChanged(_:)))
        } else {
            control = NSSegmentedControl(labels: ["A-", "A+"],
                                         trackingMode: .momentary,
                                         target: self,
                                         action: #selector(textSizeSegmentChanged(_:)))
        }
        control.segmentStyle = .separated
        control.setToolTip("文字を小さく (⌘-)", forSegment: 0)
        control.setToolTip("文字を大きく (⌘+)", forSegment: 1)
        return control
    }

    @objc private func textSizeSegmentChanged(_ sender: NSSegmentedControl) {
        let delta = sender.selectedSegment == 0 ? -Preferences.fontSizeStep : Preferences.fontSizeStep
        Preferences.fontSize += delta
        DocumentCoordinator.shared.applyPreferencesToAll()
    }
}
