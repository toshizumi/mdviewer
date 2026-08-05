import Foundation

enum TextFileError: LocalizedError {
    case tooLarge(bytes: Int)
    case undecodable

    var errorDescription: String? {
        switch self {
        case .tooLarge(let bytes):
            let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            return "ファイルが大きすぎます（\(size)）。MDViewer は \(TextFile.sizeLimitDescription) までを表示します。"
        case .undecodable:
            return "テキストとして読み取れませんでした。文字コードが未対応か、バイナリファイルの可能性があります。"
        }
    }
}

enum TextFile {
    /// これ以上は表示しない上限。ビューアとして現実的な範囲に切る。
    static let sizeLimit = 32 * 1024 * 1024
    static let sizeLimitDescription = "32 MB"

    /// UTF-8 を基本に、日本語環境でありがちな文字コードへ順に手を伸ばす。
    /// 最後に macOSRoman のような「何でも通る」エンコーディングを置くと
    /// バイナリでも文字化けした状態で表示されてしまうので、あえて入れない。
    private static let fallbackEncodings: [String.Encoding] = [
        .utf8, .shiftJIS, .japaneseEUC, .iso2022JP, .utf16
    ]

    static func read(at url: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attributes[.size] as? Int, size > sizeLimit {
            throw TextFileError.tooLarge(bytes: size)
        }

        let data = try Data(contentsOf: url)

        // BOM 付きは BOM を信じる
        if let decoded = decodeWithBOM(data) { return decoded }

        // NUL バイトが混ざっていればテキストではないと判断する（UTF-16 は BOM で判別済み）
        if data.prefix(8192).contains(0) { throw TextFileError.undecodable }

        for encoding in fallbackEncodings {
            if let text = String(data: data, encoding: encoding) {
                return text
            }
        }
        throw TextFileError.undecodable
    }

    private static func decodeWithBOM(_ data: Data) -> String? {
        let bom: [(prefix: [UInt8], encoding: String.Encoding)] = [
            ([0xEF, 0xBB, 0xBF], .utf8),
            ([0xFF, 0xFE], .utf16LittleEndian),
            ([0xFE, 0xFF], .utf16BigEndian),
        ]
        for entry in bom where data.starts(with: entry.prefix) {
            let body = data.dropFirst(entry.prefix.count)
            return String(data: body, encoding: entry.encoding)
        }
        return nil
    }
}
