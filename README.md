# MDViewer

macOS 用の軽量な Markdown ビューア。開いて、読んで、必要なら A4 の PDF にする。それだけ。
**編集機能はありません。**

- Finder で `.md` を右クリック →「このアプリケーションで開く」で起動できる
- A4 レイアウトの PDF 書き出し（余白・改ページ制御・ページ番号つき）
- GFM（表・チェックリスト・打ち消し線）、シンタックスハイライト、脚注、YAML フロントマター
- ダークモード追従、⌘F の文書内検索、ファイルの保存を検知して自動リロード
- アプリ本体 約 900 KB / 起動からの初回描画 350〜450 ms

---

## インストール

```bash
./fetch-vendor.sh   # 初回のみ。markdown-it と highlight.js を取得する
./build.sh          # MDViewer.app をビルド（数秒）
./install.sh        # /Applications へ配置して Finder に登録
```

Xcode プロジェクトは使いません。`swiftc` で直接コンパイルして `.app` を手で組み立てています。

### Finder から開く

インストール後、`.md` ファイルを右クリック →「このアプリケーションで開く」→ MDViewer。

常に MDViewer で開きたい場合は、ファイルを選んで ⌘I（情報を見る）→「このアプリケーションで開く」で
MDViewer を選び「すべてを変更...」。

既定のアプリを勝手に奪わないよう `LSHandlerRank` は `Alternate` にしてあります。
対応拡張子は `.md .markdown .mdown .mkd .mkdn .mdwn .mdtext .mdx .qmd`。

---

## 使い方

| 操作 | ショートカット |
|---|---|
| 開く | ⌘O |
| PDF として書き出す | ⇧⌘E |
| プリント | ⌘P |
| 文書内を検索 | ⌘F |
| 次を検索 / 前を検索 | ⌘G / ⇧⌘G |
| 文字を大きく / 小さく / 標準 | ⌘+ / ⌘- / ⌘0 |
| 再読み込み | ⌘R |
| Finder で表示 | ⌥⌘R |
| 閉じる | ⌘W |

外観（システムに合わせる / ライト / ダーク）は「表示 > 外観」。文字サイズと外観は次回も引き継がれます。

ウインドウにファイルをドラッグ&ドロップしても開けます。
Markdown 内の相対リンク先が Markdown なら MDViewer で、それ以外は既定のアプリで開きます。

### コマンドラインから

```bash
# 開く
open -a MDViewer note.md

# 画面に出さずに PDF へ変換（出力先を省略すると同じ場所に同名の .pdf）
/Applications/MDViewer.app/Contents/MacOS/MDViewer --pdf note.md
/Applications/MDViewer.app/Contents/MacOS/MDViewer --pdf note.md -o /tmp/out.pdf
```

まとめて変換するなら:

```bash
MDV=/Applications/MDViewer.app/Contents/MacOS/MDViewer
find docs -name '*.md' -exec "$MDV" --pdf {} \;
```

---

## 設計メモ

**レンダリングは WebKit に任せている。** 自前で Markdown を組版するより、表組みや日本語の折り返しの
品質で確実に勝るうえ、そのまま印刷組版に乗せられる。Markdown → HTML の変換はバンドル同梱の
markdown-it（オフラインで完結）。

**シェル HTML は起動時に一度だけ読み込み、以降は本文だけ JavaScript で差し替える。**
再読み込みが軽く、スクロール位置も保てる。

**ローカル画像は `mdv://` カスタムスキームで配信する。** `file://` のままだと WKWebView の
サブリソース制限に当たって相対パス画像が出ない。`mdv://app`（バンドル内）、`mdv://doc`（Markdown
からの相対パス）、`mdv://abs`（絶対パス）の 3 つに分けている。

**PDF は `NSPrintOperation` を通す。** `WKWebView.createPDF` はページ分割されない長尺 PDF しか
作れないため。ページ番号は WebKit の印刷機能では入れられないので、組版済みの PDF を CoreGraphics
で描き直して各ページの下端に焼き込んでいる（注釈ではないのでどのビューアでも同じに見える）。

**生 HTML は許可、スクリプトは CSP で封じている。** `<details>` や `<br>` は使えるが、Markdown 内に
`<script>` や `onclick=` が書かれていても実行されない。

### 実装で踏んだ罠

- WebKit の印刷は、対象のビューが**画面に出ているウインドウ**に載っていないとページ数を確定できず、
  際限なくページを吐き続ける（数百 MB の PDF ができる）。`--pdf` モードでは画面外にウインドウを
  1 枚置いて回避している。
- `NSPrintOperation` は印刷を別スレッドで走らせ、完了コールバックもそのスレッドから呼ぶ。
  そのまま WKWebView に触るとクラッシュするので、必ずメインスレッドに戻す。
- `NSSearchToolbarItem` はツールバー挿入時に検索フィールドを組み直し、こちらが設定した delegate を
  握ってしまう。素の `NSSearchField` を自前で載せ、変更通知を直接購読している。
- `border-collapse` の外枠は罫線の半分がボックスの外に出るため、紙の右端ぴったりだと切れる。

---

## 開発

```
Sources/
  main.swift              起動とコマンドライン引数
  AppDelegate.swift       メニュー、ファイルを開く、最近使った項目
  DocumentCoordinator.swift  1 ファイル 1 ウインドウの管理
  DocumentWindow.swift    ウインドウ、ツールバー、検索、ドロップ
  MarkdownView.swift      WKWebView のラッパ
  SchemeHandler.swift     mdv:// スキーム
  FileWatcher.swift       ファイル監視（アトミック保存に追随）
  PDFExporter.swift       A4 組版とページ番号
  TextFile.swift          文字コード判定つきの読み込み
  HeadlessExporter.swift  --pdf / --snapshot
Resources/
  shell.html style.css print.css app.js vendor/
```

デバッグ用:

```bash
# Web インスペクタを有効にして起動
MDVIEWER_DEBUG=1 ./build/MDViewer.app/Contents/MacOS/MDViewer note.md

# 表示画面をそのまま PNG で撮る（見た目の確認用）
./build/MDViewer.app/Contents/MacOS/MDViewer --snapshot note.md -o out.png --appearance dark

# アイコンを作り直す
./make-icon.sh
```

`sample/test.md` に GFM・日本語・コード・表・画像・脚注を一通り詰めた確認用ファイルがあります。

## 同梱しているもの

- [markdown-it](https://github.com/markdown-it/markdown-it) 14.1.0 — MIT
- [markdown-it-footnote](https://github.com/markdown-it/markdown-it-footnote) 4.0.0 — MIT
- [highlight.js](https://github.com/highlightjs/highlight.js) 11.11.1 — BSD 3-Clause
