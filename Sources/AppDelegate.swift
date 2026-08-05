import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let recentMenuDelegate = RecentDocumentsMenuDelegate()
    private let mode: LaunchMode
    private var headlessExporter: HeadlessExporter?

    init(mode: LaunchMode = .normal(files: [])) {
        self.mode = mode
        super.init()
    }

    // MARK: - ライフサイクル

    func applicationDidFinishLaunching(_ notification: Notification) {
        if case .headless(let input, let output, let task) = mode {
            let exporter = HeadlessExporter(input: input, output: output, task: task)
            headlessExporter = exporter
            exporter.run()
            return
        }

        Preferences.applyStoredAppearance()
        installMainMenu()
        NSApp.activate(ignoringOtherApps: false)

        // コマンドラインで渡されたファイル（`MDViewer note.md`）
        if case .normal(let files) = mode {
            files.forEach { DocumentCoordinator.shared.open($0) }
        }

        // Finder からのファイル起動は application(_:open:) が先に走る。
        // 一巡させてから、それでも何も開いていなければ選択ダイアログを出す。
        DispatchQueue.main.async {
            guard DocumentCoordinator.shared.isEmpty else { return }
            DocumentCoordinator.shared.presentOpenPanel()
            if DocumentCoordinator.shared.isEmpty { NSApp.terminate(nil) }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { DocumentCoordinator.shared.open($0) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    // MARK: - アプリ全体のアクション

    @objc func openDocument(_ sender: Any?) {
        DocumentCoordinator.shared.presentOpenPanel()
    }

    @objc func openRecentDocument(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        DocumentCoordinator.shared.open(url)
    }

    @objc func clearRecentDocuments(_ sender: Any?) {
        NSDocumentController.shared.clearRecentDocuments(sender)
    }

    @objc func increaseTextSize(_ sender: Any?) { changeTextSize(by: Preferences.fontSizeStep) }
    @objc func decreaseTextSize(_ sender: Any?) { changeTextSize(by: -Preferences.fontSizeStep) }

    @objc func resetTextSize(_ sender: Any?) {
        Preferences.fontSize = Preferences.defaultFontSize
        DocumentCoordinator.shared.applyPreferencesToAll()
    }

    private func changeTextSize(by delta: CGFloat) {
        Preferences.fontSize += delta
        DocumentCoordinator.shared.applyPreferencesToAll()
    }

    @objc func changeAppearance(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String,
              let appearance = AppearanceMode(rawValue: mode) else { return }
        Preferences.appearance = appearance
        DocumentCoordinator.shared.applyPreferencesToAll()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(changeAppearance(_:)) {
            let mode = menuItem.representedObject as? String
            menuItem.state = (mode == Preferences.appearance.rawValue) ? .on : .off
        }
        if menuItem.action == #selector(increaseTextSize(_:)) {
            return Preferences.fontSize < Preferences.fontSizeRange.upperBound
        }
        if menuItem.action == #selector(decreaseTextSize(_:)) {
            return Preferences.fontSize > Preferences.fontSizeRange.lowerBound
        }
        return true
    }
}

// MARK: - メニュー

private extension AppDelegate {
    func installMainMenu() {
        let mainMenu = NSMenu()
        mainMenu.addItem(makeAppMenuItem())
        mainMenu.addItem(makeFileMenuItem())
        mainMenu.addItem(makeEditMenuItem())
        mainMenu.addItem(makeViewMenuItem())

        let windowItem = makeWindowMenuItem()
        mainMenu.addItem(windowItem)
        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowItem.submenu
    }

    func makeAppMenuItem() -> NSMenuItem {
        let menu = NSMenu()
        menu.addItem(withTitle: "MDViewer について",
                     action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "MDViewer を隠す",
                     action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = menu.addItem(withTitle: "ほかを隠す",
                                      action: #selector(NSApplication.hideOtherApplications(_:)),
                                      keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "すべてを表示",
                     action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "MDViewer を終了",
                     action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    func makeFileMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "ファイル")
        menu.addItem(withTitle: "開く…", action: #selector(openDocument(_:)), keyEquivalent: "o")

        let recentItem = menu.addItem(withTitle: "最近使った項目", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "最近使った項目")
        recentMenu.delegate = recentMenuDelegate
        recentItem.submenu = recentMenu

        menu.addItem(.separator())
        menu.addItem(withTitle: "閉じる", action: #selector(NSWindow.performClose(_:)),
                     keyEquivalent: "w")
        menu.addItem(.separator())

        let export = menu.addItem(withTitle: "PDF として書き出す…",
                                  action: #selector(DocumentWindowController.exportAsPDF(_:)),
                                  keyEquivalent: "e")
        export.keyEquivalentModifierMask = [.command, .shift]

        menu.addItem(withTitle: "プリント…",
                     action: #selector(DocumentWindowController.printDocument(_:)),
                     keyEquivalent: "p")
        menu.addItem(.separator())

        let reveal = menu.addItem(withTitle: "Finder で表示",
                                  action: #selector(DocumentWindowController.revealInFinder(_:)),
                                  keyEquivalent: "r")
        reveal.keyEquivalentModifierMask = [.command, .option]

        let item = NSMenuItem(title: "ファイル", action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    func makeEditMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "編集")
        menu.addItem(withTitle: "コピー", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "すべてを選択", action: #selector(NSText.selectAll(_:)),
                     keyEquivalent: "a")
        menu.addItem(.separator())
        menu.addItem(withTitle: "検索…",
                     action: #selector(DocumentWindowController.showFindBar(_:)),
                     keyEquivalent: "f")
        menu.addItem(withTitle: "次を検索",
                     action: #selector(DocumentWindowController.findNextMatch(_:)),
                     keyEquivalent: "g")
        let previous = menu.addItem(withTitle: "前を検索",
                                    action: #selector(DocumentWindowController.findPreviousMatch(_:)),
                                    keyEquivalent: "g")
        previous.keyEquivalentModifierMask = [.command, .shift]

        let item = NSMenuItem(title: "編集", action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    func makeViewMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "表示")
        menu.addItem(withTitle: "再読み込み",
                     action: #selector(DocumentWindowController.reloadDocument(_:)),
                     keyEquivalent: "r")
        menu.addItem(.separator())
        menu.addItem(withTitle: "文字を大きく", action: #selector(increaseTextSize(_:)),
                     keyEquivalent: "+")
        menu.addItem(withTitle: "文字を小さく", action: #selector(decreaseTextSize(_:)),
                     keyEquivalent: "-")
        menu.addItem(withTitle: "標準の文字サイズ", action: #selector(resetTextSize(_:)),
                     keyEquivalent: "0")
        menu.addItem(.separator())

        let appearanceItem = menu.addItem(withTitle: "外観", action: nil, keyEquivalent: "")
        let appearanceMenu = NSMenu(title: "外観")
        for mode in AppearanceMode.allCases {
            let entry = appearanceMenu.addItem(withTitle: mode.localizedName,
                                               action: #selector(changeAppearance(_:)),
                                               keyEquivalent: "")
            entry.representedObject = mode.rawValue
            entry.target = self
        }
        appearanceItem.submenu = appearanceMenu

        let item = NSMenuItem(title: "表示", action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    func makeWindowMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "ウインドウ")
        menu.addItem(withTitle: "しまう", action: #selector(NSWindow.performMiniaturize(_:)),
                     keyEquivalent: "m")
        menu.addItem(withTitle: "拡大/縮小", action: #selector(NSWindow.performZoom(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "すべてを手前に移動",
                     action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")

        let item = NSMenuItem(title: "ウインドウ", action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}

// MARK: - 最近使った項目

private final class RecentDocumentsMenuDelegate: NSObject, NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let urls = NSDocumentController.shared.recentDocumentURLs
        guard !urls.isEmpty else {
            let empty = menu.addItem(withTitle: "なし", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            return
        }

        for url in urls.prefix(12) {
            let item = menu.addItem(withTitle: url.lastPathComponent,
                                    action: #selector(AppDelegate.openRecentDocument(_:)),
                                    keyEquivalent: "")
            item.representedObject = url
            item.toolTip = url.path
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "メニューを消去",
                     action: #selector(AppDelegate.clearRecentDocuments(_:)), keyEquivalent: "")
    }
}
