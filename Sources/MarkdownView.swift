import AppKit
import WebKit

/// ファイルのドロップを受ける WKWebView。
///
/// ドロップ先は「カーソル下のいちばん手前のビュー」から決まり、AppKit は
/// そこで見つからなくても親ビューまで遡ってはくれない。WKWebView が全面を覆っている以上、
/// 親に `registerForDraggedTypes` しても届かないので、このビュー自身で受ける必要がある。
final class DropTargetWebView: WKWebView {
    /// 受け付けられるファイルを返す。空なら拒否する。
    var acceptableFiles: ((NSDraggingInfo) -> [URL])?
    var onDragEnter: (() -> Void)?
    var onDragLeave: (() -> Void)?
    var onDrop: (([URL]) -> Void)?

    func enableFileDrops() {
        // WKWebView が自前で登録している型（画像や URL の受け入れ）は使わないので外す
        unregisterDraggedTypes()
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let files = acceptableFiles?(sender), !files.isEmpty else { return [] }
        onDragEnter?()
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        (acceptableFiles?(sender).isEmpty == false) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragLeave?()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onDragLeave?()
    }

    override func wantsPeriodicDraggingUpdates() -> Bool { false }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        acceptableFiles?(sender).isEmpty == false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDragLeave?()
        guard let files = acceptableFiles?(sender), !files.isEmpty else { return false }
        onDrop?(files)
        return true
    }
}

/// ドラッグ中に「ここに落とせる」ことを示す枠。
/// ドロップすると表示中の文書が置き換わるので、受け付ける状態が見えたほうがいい。
private final class DropHighlightView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // 操作は素通しする

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 6),
                                xRadius: 10, yRadius: 10)
        NSColor.controlAccentColor.withAlphaComponent(0.08).setFill()
        path.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.85).setStroke()
        path.lineWidth = 3
        path.stroke()
    }
}

/// Markdown を表示する WKWebView のラッパ。
///
/// シェル HTML は起動時に一度だけ読み込み、以降は本文だけ JavaScript で差し替える。
/// 再読み込みが軽く、スクロール位置も保てる。
final class MarkdownView: NSView {
    /// Markdown 内のリンクからローカルファイルを開こうとしたとき
    var onOpenFile: ((URL) -> Void)?
    /// ウインドウにファイルがドロップされたとき
    var onDropFiles: (([URL]) -> Void)?

    let webView: DropTargetWebView
    private let schemeHandler: ResourceSchemeHandler
    private let dropHighlight = DropHighlightView()

    private var isShellReady = false
    private var pendingWork: [() -> Void] = []
    /// プロセスが落ちた際に復帰させるため、最後に表示した内容を持っておく
    private var lastContent: (text: String, directory: URL)?

    private static let shellURL = URL(string: "mdv://app/shell.html")!

    // MARK: - 生成

    override init(frame frameRect: NSRect) {
        let handler = ResourceSchemeHandler()

        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(handler, forURLScheme: ResourceSchemeHandler.scheme)
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.suppressesIncrementalRendering = false

        let webView = DropTargetWebView(frame: frameRect, configuration: configuration)

        self.schemeHandler = handler
        self.webView = webView
        super.init(frame: frameRect)

        if #available(macOS 13.3, *),
           ProcessInfo.processInfo.environment["MDVIEWER_DEBUG"] != nil {
            webView.isInspectable = true
        }

        webView.navigationDelegate = self
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        // 読み込み前や慣性スクロールのはみ出しで白が覗かないようにする
        webView.underPageBackgroundColor = .textBackgroundColor

        webView.autoresizingMask = [.width, .height]
        webView.frame = bounds
        addSubview(webView)
        setUpFileDrops()

        webView.load(URLRequest(url: MarkdownView.shellURL))
    }

    // MARK: - ドロップ

    private func setUpFileDrops() {
        dropHighlight.autoresizingMask = [.width, .height]
        webView.enableFileDrops()

        webView.acceptableFiles = { sender in
            let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
            let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                             options: options) as? [URL] ?? []
            // フォルダと、テキストとして開けないもの（画像など）は受け付けない
            return urls.filter { !$0.hasDirectoryPath && DocumentCoordinator.canOpen($0) }
        }
        webView.onDragEnter = { [weak self] in self?.showDropHighlight() }
        webView.onDragLeave = { [weak self] in self?.dropHighlight.removeFromSuperview() }
        webView.onDrop = { [weak self] urls in self?.onDropFiles?(urls) }
    }

    /// ドラッグ中だけ枠を載せる。最後に addSubview するので WebView の上に来る。
    private func showDropHighlight() {
        guard dropHighlight.superview !== self else { return }
        dropHighlight.frame = bounds
        addSubview(dropHighlight)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) は使わない") }

    // MARK: - 表示

    /// - Parameter preservingScroll: 同じファイルの再読み込みなら true。
    ///   別のファイルに切り替えるときは false にして先頭から見せる。
    func render(text: String, directory: URL, preservingScroll: Bool) {
        lastContent = (text, directory)
        schemeHandler.documentDirectory = directory
        run { [weak self] in
            self?.webView.callAsyncJavaScript("MDV.render(text, keepScroll)",
                                              arguments: ["text": text,
                                                          "keepScroll": preservingScroll],
                                              in: nil, in: .page) { _ in }
        }
    }

    func showMessage(_ message: String) {
        lastContent = nil
        run { [weak self] in
            self?.webView.callAsyncJavaScript("MDV.showEmptyState(message)",
                                              arguments: ["message": message],
                                              in: nil, in: .page) { _ in }
        }
    }

    // MARK: - 表示設定

    func applyPreferences() {
        run { [weak self] in
            guard let self else { return }
            self.webView.callAsyncJavaScript(
                "MDV.setFontSize(size); MDV.setAppearance(mode)",
                arguments: ["size": Double(Preferences.fontSize),
                            "mode": Preferences.appearance.rawValue],
                in: nil, in: .page) { _ in }
        }
    }

    /// 設定を保存せずに外観だけ切り替える（スナップショット用）。
    func overrideAppearance(_ mode: AppearanceMode) {
        run { [weak self] in
            self?.webView.callAsyncJavaScript("MDV.setAppearance(mode)",
                                              arguments: ["mode": mode.rawValue],
                                              in: nil, in: .page) { _ in }
        }
    }

    /// 表示中の内容の高さ（px）。スナップショットの縦幅を決めるのに使う。
    func measureContentHeight(completion: @escaping (CGFloat) -> Void) {
        run { [weak self] in
            self?.webView.callAsyncJavaScript(
                "await MDV.whenReady(); return document.documentElement.scrollHeight",
                arguments: [:], in: nil, in: .page) { result in
                let height = (try? result.get()) as? Double ?? 0
                completion(CGFloat(height))
            }
        }
    }

    // MARK: - 検索

    struct SearchResult {
        var index: Int
        var total: Int
    }

    func find(_ query: String, completion: @escaping (SearchResult) -> Void) {
        evaluateSearch("return MDV.find(query)", arguments: ["query": query], completion: completion)
    }

    func findNext(completion: @escaping (SearchResult) -> Void) {
        evaluateSearch("return MDV.findNext()", arguments: [:], completion: completion)
    }

    func findPrevious(completion: @escaping (SearchResult) -> Void) {
        evaluateSearch("return MDV.findPrevious()", arguments: [:], completion: completion)
    }

    func clearFind(completion: (() -> Void)? = nil) {
        run { [weak self] in
            self?.webView.callAsyncJavaScript("MDV.clearFind()", arguments: [:],
                                              in: nil, in: .page) { _ in completion?() }
        }
    }

    private func evaluateSearch(_ body: String, arguments: [String: Any],
                                completion: @escaping (SearchResult) -> Void) {
        run { [weak self] in
            self?.webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in
                let dict = (try? result.get()) as? [String: Any]
                completion(SearchResult(index: dict?["index"] as? Int ?? 0,
                                        total: dict?["total"] as? Int ?? 0))
            }
        }
    }

    // MARK: - 印刷前の準備

    /// 検索ハイライトの解除・折りたたみの展開・画像の読み込み完了を待ってから呼び出し元に戻る。
    func prepareForPrinting(completion: @escaping () -> Void) {
        run { [weak self] in
            guard let self else { return }
            self.webView.callAsyncJavaScript("""
                MDV.clearFind();
                MDV.beginPrintMode();
                await MDV.whenReady();
                return true
                """, arguments: [:], in: nil, in: .page) { _ in
                completion()
            }
        }
    }

    /// 印刷が終わったら画面表示の状態に戻す。
    func finishPrinting() {
        run { [weak self] in
            self?.webView.callAsyncJavaScript("MDV.endPrintMode()", arguments: [:],
                                              in: nil, in: .page) { _ in }
        }
    }

    // MARK: - 内部

    /// シェルの読み込みが終わるまで処理を保留する。
    private func run(_ work: @escaping () -> Void) {
        if isShellReady { work() } else { pendingWork.append(work) }
    }
}

// MARK: - WKNavigationDelegate

extension MarkdownView: WKNavigationDelegate {
    /// シェルの読み込みに失敗するとウインドウが白いままになる。原因を追えるように記録する。
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("MDViewer: シェルの読み込みに失敗しました: %@", error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        NSLog("MDViewer: シェルの読み込みに失敗しました: %@", error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isShellReady = true
        applyPreferences()
        let work = pendingWork
        pendingWork = []
        work.forEach { $0() }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // レンダラが落ちたら白紙のまま固まるので、黙って復帰させる
        isShellReady = false
        let saved = lastContent
        webView.load(URLRequest(url: MarkdownView.shellURL))
        if let saved { render(text: saved.text, directory: saved.directory, preservingScroll: false) }
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        // シェル自身の読み込みと、文書内アンカーへの移動だけ許可する
        if url.scheme == ResourceSchemeHandler.scheme, url.host == "app" {
            decisionHandler(.allow)
            return
        }

        decisionHandler(.cancel)

        switch url.scheme {
        case ResourceSchemeHandler.scheme:
            // mdv://doc/… と mdv://abs/… はローカルファイルへのリンク
            if let fileURL = localFileURL(for: url) {
                onOpenFile?(fileURL)
            }
        case "http", "https", "mailto":
            NSWorkspace.shared.open(url)
        default:
            break
        }
    }

    private func localFileURL(for url: URL) -> URL? {
        let path = url.path
        switch url.host {
        case "doc":
            guard let base = schemeHandler.documentDirectory else { return nil }
            return base.appendingPathComponent(path).standardizedFileURL
        case "abs":
            guard !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path).standardizedFileURL
        default:
            return nil
        }
    }
}
