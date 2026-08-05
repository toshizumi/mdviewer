import AppKit
import WebKit
import PDFKit
import CoreText

/// `NSPrintOperation` を走らせて、終わったら知らせる。
///
/// 印刷が終わるまで自分自身を保持しておく必要があるので、小さな中間役を挟んでいる。
private final class PrintJob: NSObject {
    private static var active: [PrintJob] = []

    private let completion: (Bool) -> Void

    private init(completion: @escaping (Bool) -> Void) {
        self.completion = completion
    }

    static func run(_ operation: NSPrintOperation, in window: NSWindow?,
                    completion: @escaping (Bool) -> Void) {
        let job = PrintJob(completion: completion)
        active.append(job)

        // WebKit の印刷は、対象のビューが画面に出ているウインドウに載っていないと
        // ページ数を確定できない。ウインドウがあるなら必ずそちら経由で走らせる。
        if let window {
            operation.runModal(for: window,
                               delegate: job,
                               didRun: #selector(didRun(_:success:contextInfo:)),
                               contextInfo: nil)
        } else {
            let success = operation.run()
            job.didRun(operation, success: success, contextInfo: nil)
        }
    }

    @objc private func didRun(_ operation: NSPrintOperation, success: Bool,
                              contextInfo: UnsafeMutableRawPointer?) {
        // NSPrintOperation は印刷を別スレッドで走らせ、この didRun もそのスレッドから呼ぶ。
        // このあと WKWebView や UI に触るので、必ずメインスレッドに戻してから通知する。
        DispatchQueue.main.async {
            Self.active.removeAll { $0 === self }
            self.completion(success)
        }
    }
}

/// WKWebView の内容を A4 の PDF に書き出す。
///
/// `WKWebView.createPDF` はページ分割されない長尺 PDF しか作れないため、
/// 組版は `NSPrintOperation` に任せる。ページ番号はそのあとで PDFKit / CoreGraphics で描き足す。
final class PDFExporter: NSObject {
    /// 印刷が終わるまで自身を保持しておくための置き場
    private static var runningJobs: [PDFExporter] = []

    private let webView: WKWebView
    private let destination: URL
    private let title: String
    private let completion: (Error?) -> Void
    private let temporaryURL: URL

    private init(webView: WKWebView, destination: URL, title: String,
                 completion: @escaping (Error?) -> Void) {
        self.webView = webView
        self.destination = destination
        self.title = title
        self.completion = completion
        self.temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdviewer-\(UUID().uuidString).pdf")
    }

    // MARK: - 公開

    static func export(webView: WKWebView, to destination: URL, title: String,
                       in window: NSWindow?, completion: @escaping (Error?) -> Void) {
        let job = PDFExporter(webView: webView, destination: destination,
                              title: title, completion: completion)
        runningJobs.append(job)
        job.start(in: window)
    }

    /// ⌘P のプリントダイアログ。組版は PDF 書き出しとまったく同じ。
    static func presentPrintPanel(webView: WKWebView, title: String, in window: NSWindow?,
                                  completion: @escaping () -> Void) {
        let info = makePrintInfo()
        let operation = webView.printOperation(with: info)
        operation.jobTitle = title
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        PrintJob.run(operation, in: window) { _ in completion() }
    }

    // MARK: - 印刷設定

    private static let mm = 72.0 / 25.4
    private static let a4 = NSSize(width: 595.276, height: 841.89)

    private static func makePrintInfo() -> NSPrintInfo {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo(dictionary: [:])
        info.paperSize = a4
        info.orientation = .portrait
        info.leftMargin = 15 * mm
        info.rightMargin = 15 * mm
        info.topMargin = 18 * mm
        info.bottomMargin = 20 * mm   // ページ番号を入れるぶん下だけ広げる
        info.horizontalPagination = .automatic
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        return info
    }

    // MARK: - 実行

    private func start(in window: NSWindow?) {
        let info = Self.makePrintInfo()
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = temporaryURL

        let operation = webView.printOperation(with: info)
        operation.jobTitle = title
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false

        PrintJob.run(operation, in: window) { [weak self] success in
            self?.printOperationDidRun(success: success)
        }
    }

    private func printOperationDidRun(success: Bool) {
        defer { Self.runningJobs.removeAll { $0 === self } }

        guard success, FileManager.default.fileExists(atPath: temporaryURL.path) else {
            try? FileManager.default.removeItem(at: temporaryURL)
            completion(ExportError.printFailed)
            return
        }

        do {
            try Self.writeWithPageNumbers(from: temporaryURL, to: destination, title: title)
            try? FileManager.default.removeItem(at: temporaryURL)
            completion(nil)
        } catch {
            // ページ番号を付けられなくても、組版済みの PDF 自体は保存しておく
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.moveItem(at: temporaryURL, to: destination)
            completion(nil)
        }
    }

    enum ExportError: LocalizedError {
        case printFailed
        case pdfUnreadable

        var errorDescription: String? {
            switch self {
            case .printFailed:   return "PDF の組版に失敗しました。"
            case .pdfUnreadable: return "生成した PDF を読み込めませんでした。"
            }
        }
    }

    // MARK: - ページ番号

    /// 各ページを描き直しながらフッタを重ねる。
    /// 注釈ではなくページの内容として焼き込むので、どのビューアでも同じに見える。
    private static func writeWithPageNumbers(from source: URL, to destination: URL,
                                             title: String) throws {
        guard let document = PDFDocument(url: source), document.pageCount > 0 else {
            throw ExportError.pdfUnreadable
        }

        let info: [CFString: Any] = [
            kCGPDFContextTitle: title,
            kCGPDFContextCreator: "MDViewer",
        ]
        var mediaBox = CGRect(origin: .zero, size: a4)
        guard let context = CGContext(destination as CFURL, mediaBox: &mediaBox,
                                      info as CFDictionary) else {
            throw ExportError.pdfUnreadable
        }

        let total = document.pageCount
        let font = CTFontCreateWithName("HiraginoSans-W3" as CFString, 8.5, nil)
        let color = NSColor(white: 0.45, alpha: 1).cgColor

        for index in 0..<total {
            guard let page = document.page(at: index) else { continue }
            var box = page.bounds(for: .mediaBox)
            context.beginPage(mediaBox: &box)

            context.saveGState()
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()

            context.saveGState()
            context.textMatrix = .identity
            let baseline = box.minY + 11 * mm
            let left = box.minX + 15 * mm
            let right = box.maxX - 15 * mm
            draw(text: truncate(title, font: font, maxWidth: (right - left) * 0.62),
                 at: CGPoint(x: left, y: baseline), alignment: .left,
                 font: font, color: color, in: context)
            draw(text: "\(index + 1) / \(total)",
                 at: CGPoint(x: right, y: baseline), alignment: .right,
                 font: font, color: color, in: context)
            context.restoreGState()

            context.endPage()
        }

        context.closePDF()
    }

    private enum TextAlignment { case left, right }

    private static func draw(text: String, at point: CGPoint, alignment: TextAlignment,
                             font: CTFont, color: CGColor, in context: CGContext) {
        guard !text.isEmpty else { return }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor(cgColor: color) ?? .gray,
        ]))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        context.textPosition = CGPoint(x: alignment == .left ? point.x : point.x - width,
                                       y: point.y)
        CTLineDraw(line, context)
    }

    private static func truncate(_ text: String, font: CTFont, maxWidth: CGFloat) -> String {
        func width(_ s: String) -> CGFloat {
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: s, attributes: [.font: font]))
            return CTLineGetTypographicBounds(line, nil, nil, nil)
        }
        guard width(text) > maxWidth else { return text }
        var truncated = text
        while !truncated.isEmpty, width(truncated + "…") > maxWidth {
            truncated.removeLast()
        }
        return truncated + "…"
    }
}
