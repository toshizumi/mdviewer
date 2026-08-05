import Foundation

/// ファイルの変更を監視して通知する。
///
/// 多くのエディタは「別名で書いてから rename で差し替える」保存の仕方をするため、
/// 監視対象の inode がいきなり消える。その場合は同じパスを開き直して監視を張り直す。
final class FileWatcher {
    private let url: URL
    private let onChange: () -> Void

    private var source: DispatchSourceFileSystemObject?
    private var descriptor: Int32 = -1
    private var coalescer: DispatchWorkItem?
    private var reopenAttempts = 0

    private static let coalesceInterval: DispatchTimeInterval = .milliseconds(80)
    private static let reopenInterval: DispatchTimeInterval = .milliseconds(60)
    private static let maxReopenAttempts = 25

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        beginWatching()
    }

    deinit { stop() }

    func stop() {
        coalescer?.cancel()
        coalescer = nil
        source?.cancel()   // キャンセルハンドラでディスクリプタを閉じる
        source = nil
        descriptor = -1
    }

    // MARK: - 内部

    private func beginWatching() {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            scheduleReopen()
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .revoke],
            queue: .main)

        source.setEventHandler { [weak self] in
            guard let self, let current = self.source else { return }
            let flags = current.data
            if flags.contains(.delete) || flags.contains(.rename) || flags.contains(.revoke) {
                // 別ファイルに差し替えられた。開き直す。
                self.stop()
                self.reopenAttempts = 0
                self.scheduleReopen()
            } else {
                self.scheduleNotify()
            }
        }
        source.setCancelHandler { close(fd) }

        self.descriptor = fd
        self.source = source
        self.reopenAttempts = 0
        source.resume()
    }

    /// 保存中の一瞬だけファイルが存在しないことがあるので、少し待って開き直す。
    private func scheduleReopen() {
        guard reopenAttempts < Self.maxReopenAttempts else { return }
        reopenAttempts += 1

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.reopenInterval) { [weak self] in
            guard let self, self.source == nil else { return }
            // 開けなければ beginWatching が再び scheduleReopen を呼ぶので、ここでは再試行しない
            self.beginWatching()
            if self.source != nil { self.scheduleNotify() }
        }
    }

    /// 連続する書き込みイベントを 1 回にまとめる。
    private func scheduleNotify() {
        coalescer?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        coalescer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.coalesceInterval, execute: work)
    }
}
