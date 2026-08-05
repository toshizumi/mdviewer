import WebKit
import UniformTypeIdentifiers

/// `mdv://` スキームを処理する。
///
/// `file://` のままだと WKWebView のサブリソース読み込み制限に当たり、
/// Markdown 内の相対パス画像が表示できない。すべてこのハンドラ経由に一本化する。
///
///   mdv://app/…   アプリバンドル内のリソース（shell.html, style.css, vendor/…）
///   mdv://doc/…   Markdown ファイルのあるディレクトリからの相対パス
///   mdv://abs/…   ファイルシステムの絶対パス
final class ResourceSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "mdv"

    /// 現在表示している Markdown のあるディレクトリ。`mdv://doc/` の基準になる。
    var documentDirectory: URL?

    private let ioQueue = DispatchQueue(label: "jp.garage-standard.mdviewer.resource",
                                        qos: .userInitiated)
    /// 中断済みタスクに応答するとクラッシュするため、生存中のものを覚えておく。
    private var liveTasks = Set<ObjectIdentifier>()
    private let lock = NSLock()

    // MARK: - WKURLSchemeHandler

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let token = ObjectIdentifier(task)
        lock.lock(); liveTasks.insert(token); lock.unlock()

        guard let url = task.request.url, let fileURL = resolve(url) else {
            fail(task, token: token, url: task.request.url)
            return
        }

        ioQueue.async { [weak self] in
            guard let self else { return }
            let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe)
            DispatchQueue.main.async {
                guard let data else {
                    self.fail(task, token: token, url: url)
                    return
                }
                guard self.claim(token) else { return }
                let response = URLResponse(url: url,
                                           mimeType: Self.mimeType(for: fileURL),
                                           expectedContentLength: data.count,
                                           textEncodingName: nil)
                task.didReceive(response)
                task.didReceive(data)
                task.didFinish()
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        lock.lock(); liveTasks.remove(ObjectIdentifier(task)); lock.unlock()
    }

    // MARK: - 内部

    /// 応答してよければ true を返し、そのタスクを生存リストから外す。
    private func claim(_ token: ObjectIdentifier) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return liveTasks.remove(token) != nil
    }

    private func fail(_ task: WKURLSchemeTask, token: ObjectIdentifier, url: URL?) {
        guard claim(token) else { return }
        task.didFailWithError(NSError(domain: NSURLErrorDomain,
                                      code: NSURLErrorFileDoesNotExist,
                                      userInfo: [NSURLErrorFailingURLStringErrorKey:
                                                    url?.absoluteString ?? ""]))
    }

    private func resolve(_ url: URL) -> URL? {
        // url.path はパーセントデコード済み
        let path = url.path
        switch url.host {
        case "app":
            guard let base = Bundle.main.resourceURL?.standardizedFileURL else { return nil }
            let target = base.appendingPathComponent(path).standardizedFileURL
            // バンドルの外へ出る参照は拒否する
            guard target.path.hasPrefix(base.path + "/") else { return nil }
            return target

        case "doc":
            guard let base = documentDirectory else { return nil }
            return base.appendingPathComponent(path).standardizedFileURL

        case "abs":
            guard !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path).standardizedFileURL

        default:
            return nil
        }
    }

    private static func mimeType(for url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
    }
}
