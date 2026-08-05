import AppKit
import WebKit

/// ウインドウを表に出さずに 1 ファイルを処理して終了する経路。
/// GUI とまったく同じレンダリングを通すので、結果は画面表示と一致する。
final class HeadlessExporter {
    enum Task {
        /// A4 の PDF に書き出す
        case pdf
        /// 画面表示そのままの PNG を撮る（開発用）
        case snapshot(appearance: AppearanceMode)
    }

    private let input: URL
    private let output: URL
    private let task: Task

    private var window: NSWindow?
    private var markdownView: MarkdownView?
    private var finished = false

    /// 何かの拍子に固まっても永久に居座らないようにする
    private static let timeout: TimeInterval = 60
    private static let renderWidth: CGFloat = 900

    init(input: URL, output: URL, task: Task) {
        self.input = input
        self.output = output
        self.task = task
    }

    func run() {
        guard FileManager.default.fileExists(atPath: input.path) else {
            finish(message: "ファイルが見つかりません: \(input.path)", code: 1)
            return
        }

        let text: String
        do {
            text = try TextFile.read(at: input)
        } catch {
            finish(message: error.localizedDescription, code: 1)
            return
        }

        // WebKit の印刷は、対象のビューが「画面に出ているウインドウ」に載っていないと
        // ページ数を確定できず、際限なくページを吐き続ける。
        // そのため実体のあるウインドウを 1 枚だけ用意し、画面の外に置いて使う。
        let size = NSSize(width: Self.renderWidth, height: 1200)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000),
                                                  size: size),
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false

        let view = MarkdownView(frame: NSRect(origin: .zero, size: size))
        window.contentView = view
        self.window = window
        self.markdownView = view
        window.orderFrontRegardless()

        if case .snapshot(let appearance) = task {
            view.overrideAppearance(appearance)
            window.appearance = appearance.nsAppearance
        }
        view.render(text: text, directory: input.deletingLastPathComponent(),
                    preservingScroll: false)

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) { [weak self] in
            self?.finish(message: "タイムアウトしました。", code: 1)
        }

        switch task {
        case .pdf:      exportPDF(view: view, window: window)
        case .snapshot: takeSnapshot(view: view, window: window)
        }
    }

    // MARK: - PDF

    private func exportPDF(view: MarkdownView, window: NSWindow) {
        view.prepareForPrinting { [weak self] in
            guard let self, !self.finished else { return }
            PDFExporter.export(webView: view.webView,
                               to: self.output,
                               title: self.input.deletingPathExtension().lastPathComponent,
                               in: window) { error in
                if let error {
                    self.finish(message: error.localizedDescription, code: 1)
                } else {
                    self.finish(message: self.output.path, code: 0)
                }
            }
        }
    }

    // MARK: - スナップショット

    private func takeSnapshot(view: MarkdownView, window: NSWindow) {
        view.measureContentHeight { [weak self] height in
            guard let self, !self.finished else { return }

            // 縦に全部入るところまでウインドウを広げてから撮る
            let full = NSSize(width: Self.renderWidth, height: max(height, 400))
            window.setContentSize(full)
            view.frame = NSRect(origin: .zero, size: full)

            // レイアウトが反映された次のターンで撮影する
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let configuration = WKSnapshotConfiguration()
                configuration.rect = NSRect(origin: .zero, size: full)
                configuration.afterScreenUpdates = true

                view.webView.takeSnapshot(with: configuration) { image, error in
                    guard let image,
                          let tiff = image.tiffRepresentation,
                          let rep = NSBitmapImageRep(data: tiff),
                          let png = rep.representation(using: .png, properties: [:]) else {
                        self.finish(message: error?.localizedDescription
                                    ?? "スナップショットを取得できませんでした。", code: 1)
                        return
                    }
                    do {
                        try png.write(to: self.output)
                        self.finish(message: self.output.path, code: 0)
                    } catch {
                        self.finish(message: error.localizedDescription, code: 1)
                    }
                }
            }
        }
    }

    // MARK: -

    private func finish(message: String, code: Int32) {
        guard !finished else { return }
        finished = true
        if code == 0 {
            print(message)
        } else {
            FileHandle.standardError.write(Data(("MDViewer: " + message + "\n").utf8))
        }
        exit(code)
    }
}

// MARK: - コマンドライン引数

enum LaunchMode {
    /// 通常起動。コマンドラインでファイルを渡されていればそれを開く。
    case normal(files: [URL])
    case headless(input: URL, output: URL, task: HeadlessExporter.Task)
    case usage

    var isHeadless: Bool {
        if case .headless = self { return true }
        return false
    }

    static func parse(_ arguments: [String]) -> LaunchMode {
        var input: URL?
        var output: URL?
        var files: [URL] = []
        var wantsSnapshot = false
        var appearance = AppearanceMode.auto
        var iterator = arguments.makeIterator()

        while let argument = iterator.next() {
            switch argument {
            case "--pdf":
                guard let path = iterator.next() else { return .usage }
                input = URL(fileURLWithPath: path).standardizedFileURL
            case "--snapshot":
                guard let path = iterator.next() else { return .usage }
                input = URL(fileURLWithPath: path).standardizedFileURL
                wantsSnapshot = true
            case "-o", "--out":
                guard let path = iterator.next() else { return .usage }
                output = URL(fileURLWithPath: path).standardizedFileURL
            case "--appearance":
                guard let value = iterator.next(),
                      let mode = AppearanceMode(rawValue: value) else { return .usage }
                appearance = mode
            case "-h", "--help":
                return .usage
            default:
                // Finder からの起動時に渡される -psn_… などは無視し、
                // それ以外の裸の引数は「開くファイル」として扱う。
                guard !argument.hasPrefix("-") else { continue }
                files.append(URL(fileURLWithPath: argument).standardizedFileURL)
            }
        }

        guard let input else { return .normal(files: files) }
        let task: HeadlessExporter.Task = wantsSnapshot ? .snapshot(appearance: appearance) : .pdf
        let defaultExtension = wantsSnapshot ? "png" : "pdf"
        return .headless(input: input,
                         output: output ?? input.deletingPathExtension()
                                                .appendingPathExtension(defaultExtension),
                         task: task)
    }

    static let usageText = """
    MDViewer — macOS 用の軽量 Markdown ビューア

    使い方:
      MDViewer <file.md>                     ファイルを開く
      MDViewer --pdf <file.md> [-o out.pdf]  画面に出さずに A4 の PDF へ書き出す
      MDViewer --help                        このヘルプ

    書き出し先を省略すると、入力ファイルと同じ場所に同名の .pdf を作ります。

    開発用:
      MDViewer --snapshot <file.md> [-o out.png] [--appearance auto|light|dark]
        表示画面をそのまま PNG で撮る。見た目の確認用。
    """
}
