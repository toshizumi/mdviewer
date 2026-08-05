# MDViewer 実装タスク

## 目標
macOS向けの超軽量Markdownビューア。編集機能なし。A4 PDF出力あり。Finderの右クリックから開ける。

## チェックリスト

### 1. 土台
- [x] `fetch-vendor.sh` — markdown-it / markdown-it-footnote / highlight.js を取得
- [x] `Info.plist` — CFBundleDocumentTypes で .md を関連付け
- [x] `build.sh` — swiftc → .app 組み立て → ad-hoc署名
- [x] `install.sh` — /Applications へ配置 + lsregister
- [x] `make-icon.sh` — AppIcon.icns 生成

### 2. Web層（Resources/）
- [x] `shell.html` — 空のシェル + CSP
- [x] `style.css` — 画面用（light/dark、日本語フォント）
- [x] `print.css` — A4印刷用（改ページ制御）
- [x] `app.js` — markdown-it 呼び出し・タスクリスト・フロントマター・検索・印刷モード

### 3. Swift層（Sources/）
- [x] `main.swift` / `Preferences.swift` / `SchemeHandler.swift` / `FileWatcher.swift`
- [x] `MarkdownView.swift` / `PDFExporter.swift` / `DocumentWindow.swift` / `AppDelegate.swift`
- [x] `TextFile.swift` — 文字コード判定
- [x] `DocumentCoordinator.swift` — 1ファイル1ウインドウ
- [x] `HeadlessExporter.swift` — `--pdf` / `--snapshot`

### 4. 検証
- [x] `sample/test.md` を用意（GFM全部入り・日本語・コード・表・画像・脚注）
- [x] ビルドが警告なく通る（900 KB）
- [x] 表示のレイアウト目視確認（ライト / ダーク）
- [x] 起動速度 — プロセス開始から初回描画まで 354 / 442 / 457 ms
- [x] PDF出力（A4・ページ番号・改ページ・コード折り返し・表の収まり）
- [x] 自動リロード（インプレース書き込み / アトミック保存 / 連続保存）
- [x] Finder右クリックから開ける（.md .markdown .mdx .qmd .mkd .mdown すべてOK）
- [x] 異常系（92MBファイル / バイナリ / Shift_JIS / 存在しないパス）
- [x] GUIからのPDF書き出し・⌘Pの印刷ダイアログ
- [x] ⌘Fの逐次検索・次を検索・Escapeでの解除
- [x] 複数ウインドウ / 同一ファイルの再オープン / 最近使った項目
- [x] 文字サイズ・外観の永続化とメニューのチェック表示
- [x] ドラッグ&ドロップ（自作のドラッグ元アプリ＋CGEvent で実ドラッグを再現して検証）

---

## レビュー

### やったこと
`swiftc` + シェルスクリプトで `.app` を組み立てる、Xcodeプロジェクトを持たない構成にした。
純AppKit + WKWebView。Markdownのレンダリングは同梱の markdown-it に任せ、その結果を
そのまま印刷組版に流している。約900KB、初回描画まで350〜450ms。

### 設計判断
- **WKWebViewに寄せた**: 自前レンダラよりGFM互換性・日本語の折り返し・表組みで勝り、
  PDF化がそのまま乗る。起動コストはWebKitのプロセス起動が支配的で、同梱JS（246KB）を
  外しても起動時間は変わらなかった（実測）ので、機能を削る意味はなかった。
- **`mdv://` カスタムスキーム1本**: `file://` のサブリソース制限を根本回避。
  App Sandbox無効・ローカル配布前提なので、これで画像もCSSも安全に配れる。
- **PDFは `NSPrintOperation`**: `createPDF` はページ分割されない長尺PDFしか作れない。
  ページ番号はPDFKit+CoreGraphicsで焼き込み（注釈ではないのでどのビューアでも同じ）。

### 詰まった点（次に同じことをやるなら）
1. **WebKitの印刷は、対象ビューが画面に出ているウインドウに載っていないとページ数を確定できない。**
   `knowsPageRange` が `{1, Int.max}` を返し続け、PDFが数百MBまで肥大する。
   ヘッドレス出力では画面外にウインドウを1枚置いて回避した。
2. **`NSPrintOperation` の `didRun` は別スレッドから呼ばれる。** そこからWKWebViewに触って
   `EXC_BREAKPOINT` でクラッシュした。完了通知は必ずメインスレッドに戻す。
3. **`NSSearchToolbarItem` は挿入時に検索フィールドを組み直し、delegateを奪う。**
   素の `NSSearchField` に置き換え、`NSControl.textDidChangeNotification` を直接購読した。
4. **`validateMenuItem` は `NSMenuItemValidation` に準拠しないと呼ばれない。**
   準拠宣言を書き忘れてメニューのチェックマークが出なかった。
5. **既存UTIに拡張子を追加することはできない。** `UTImportedTypeDeclarations` で
   `net.daringfireball.markdown` に `.mdx` を足そうとしても無視される。自前の型を
   `UTExportedTypeDeclarations` で宣言する必要がある。
6. **`border-collapse` の外枠は罫線の半分がボックス外に出る。** 紙の右端ぴったりだと切れる。

---

## 追加機能：開いているウインドウにDnDで開く

落としたウインドウの表示を差し替える。新しいウインドウを増やさない。

- 複数ファイル → 1つ目は落としたウインドウ、残りは新規ウインドウ
- すでに別ウインドウで開いているファイル → そのウインドウを前面に出すだけ（重複させない）
- 別ファイルに切り替わったらスクロールを先頭へ（自動リロード時は現在位置を維持）
- テキストとして読めないものはドロップを受け付けない（`DocumentCoordinator.canOpen`）
- ドラッグ中は枠をハイライトする（内容が置き換わるので、受け付ける状態を見せる）

### 詰まった点
7. **ドロップ先の探索は、親ビューまで遡ってくれない。** AppKit は hitTest で当たったビュー
   （＝最前面の WKWebView）を見るだけで、そこが未登録でも上位ビューは探さない。
   親コンテナに `registerForDraggedTypes` する初版の実装は一度も動いていなかった。
   WKWebView を継承して、そのビュー自身でドロップを受けるように変更。
   `draggingUpdated` も必ずオーバーライドすること（WKWebView 側の実装が残ると拒否される）。
8. **`addSubview(_:)` をオーバーライドしてはいけない。** ハイライトを常に最前面へ置こうとして
   `super.addSubview(_:positioned:relativeTo:)` を呼んだら、これが内部で `addSubview(_:)` を
   呼び返して無限再帰し、スタックオーバーフローで落ちた。
   ドラッグ中だけ `addSubview` する方式に変更（最後に足せば最前面になる）。
9. **Finder を使った実ドラッグの自動化は諦めてよい。** Finder のウインドウが別 Space にいると
   AX から見えず、アイコン座標が取れない。代わりに「NSDraggingSession を開始するだけの
   小さなドラッグ元アプリ」を自作し、CGEvent でマウスを動かす方式にしたら安定して再現できた。
   位置が自分で決められるぶん、こちらのほうが確実。

### 残っていること
- Mermaid図・数式（KaTeX）は「標準セット」の選択に従って入れていない。必要なら追加可能
