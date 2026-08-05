import AppKit
import WebKit

/// Markdown を表示する WKWebView のラッパ。
///
/// シェル HTML は起動時に一度だけ読み込み、以降は本文だけ JavaScript で差し替える。
/// 再読み込みが軽く、スクロール位置も保てる。
final class MarkdownView: NSView {
    /// Markdown 内のリンクからローカルファイルを開こうとしたとき
    var onOpenFile: ((URL) -> Void)?

    let webView: WKWebView
    private let schemeHandler: ResourceSchemeHandler

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

        let webView = WKWebView(frame: frameRect, configuration: configuration)

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
        // ドロップは親ビューで受けたいので、WebView 自身には渡さない
        webView.unregisterDraggedTypes()

        webView.autoresizingMask = [.width, .height]
        webView.frame = bounds
        addSubview(webView)

        webView.load(URLRequest(url: MarkdownView.shellURL))
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
