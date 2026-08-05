---
title: MDViewer 表示テスト
tags: [markdown, test, 日本語]
date: 2026-08-05
---

# MDViewer 表示テスト

このファイルは MDViewer の描画・印刷を確認するための見本です。見出し・表・コード・
リスト・引用・画像・脚注を一通り含んでいます。日本語の長い段落がどのような行間と
字送りで組まれるか、折り返しが不自然になっていないか、コードブロックが横にはみ出して
いないかを確認してください。英数字と日本語が混在した文（macOS 15.6.1 / Swift 6.2）の
アキも見るポイントです。

## 段落と強調

**太字**、*斜体*、***太字斜体***、~~打ち消し線~~、`インラインコード`、
そして [外部リンク](https://www.markdownguide.org) と
[文書内リンク](#表) を並べています。外部リンクはクリックすると既定のブラウザで開き、
文書内リンクはその場でスクロールするはずです。

自動リンク化の確認: https://developer.apple.com/documentation/webkit

> 引用ブロックです。引用の中に**強調**や `code` を入れても崩れないこと。
>
> > 入れ子の引用。
>
> — 出典表記

---

## リスト

### 箇条書き

- 第一階層
  - 第二階層
    - 第三階層まで
- 長い項目の折り返し確認。ここに十分な長さの日本語を書いて、二行目以降がぶら下がり
  インデントで揃うかどうかを見る。
- `コード` を含む項目

### 番号付き

1. 手順その一
2. 手順その二
   1. 入れ子の手順
   2. もうひとつ
3. 手順その三

### タスクリスト

- [x] 完了したタスク
- [x] これも完了
- [ ] 未着手のタスク
- [ ] 長めの未着手タスク。チェックボックスの位置がテキストの一行目に揃っているか確認する。

## 表

| 項目 | 既定値 | 説明 |
|---|---:|---|
| 文字サイズ | 16 px | ⌘+ / ⌘- で 11〜30 px の範囲で変更できる |
| 外観 | 自動 | システム設定に追従。メニューから固定も可能 |
| PDF 用紙 | A4 | 余白は上 18 mm・左右 15 mm・下 20 mm |
| 自動リロード | 有効 | ファイルの保存を検知して再描画する |

### 横に長い表

| 列1 | 列2 | 列3 | 列4 | 列5 | 列6 | 列7 | 列8 |
|---|---|---|---|---|---|---|---|
| データ | データ | データ | データ | データ | データ | データ | データ |
| 長めの内容が入る列 | 長めの内容が入る列 | 長めの内容が入る列 | 長めの内容が入る列 | 長めの内容が入る列 | 長めの内容が入る列 | 長めの内容が入る列 | 長めの内容が入る列 |

## コード

Swift:

```swift
import AppKit

func greet(_ name: String) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "こんにちは" : "こんにちは、\(trimmed)さん"
}

print(greet("世界"))
```

JavaScript:

```javascript
const md = window.markdownit({ html: true, linkify: true, breaks: false });
document.getElementById('content').innerHTML = md.render(source);
```

Python:

```python
def fib(n: int) -> list[int]:
    a, b, out = 0, 1, []
    while a < n:
        out.append(a)
        a, b = b, a + b
    return out
```

シェル:

```bash
./build.sh && ./install.sh
open -a MDViewer sample/test.md
```

JSON:

```json
{ "name": "MDViewer", "version": "1.0", "features": ["view", "pdf", "watch"] }
```

言語指定なし（ハイライトなし・かつ非常に長い行の折り返し確認）:

```
xcrun swiftc -O -wmo -target arm64-apple-macos13.0 -framework AppKit -framework WebKit -framework PDFKit -o build/MDViewer.app/Contents/MacOS/MDViewer Sources/*.swift
```

## 画像

相対パスのローカル画像:

![MDViewer のアイコン](images/logo.png)

存在しないパスの画像（枠だけ出る想定）:

![読み込めない画像](images/does-not-exist.png)

## 脚注

脚注つきの文章です[^1]。もうひとつ[^note]。

[^1]: これが一つ目の脚注。
[^note]: 名前付きの脚注も使えます。

## 生 HTML

<details>
<summary>折りたたみ（クリックで開く）</summary>

生 HTML の `<details>` が機能すること。中に **Markdown** は展開されないが、
HTML はそのまま出る。

</details>

<p align="center"><b>中央寄せの生 HTML 段落</b></p>

## 長文（改ページ確認用）

MDViewer は Markdown を読むためだけのアプリです。編集はしません。起動して、読んで、
必要なら PDF にする。それ以上のことはしません。機能を絞ったぶん、起動は速く、
メモリの消費も小さく保っています。

レンダリングは WebKit に任せています。自前で Markdown をレイアウトするより、
表組みや日本語の折り返しの品質で確実に勝りますし、そのまま印刷組版に乗せられます。
PDF 出力で `WKWebView.createPDF` を使わないのは、あれがページ分割されない長尺 PDF しか
作れないためです。A4 に組むには `NSPrintOperation` を通す必要があります。

ページ番号は WebKit の印刷機能では入れられないため、組版が終わった PDF を
CoreGraphics で描き直し、各ページの下端にファイル名とページ番号を焼き込んでいます。
注釈ではなくページの内容として描いているので、どのビューアで開いても同じに見えます。

ファイルの監視には `DispatchSource` の vnode 監視を使っています。多くのエディタは
「一時ファイルに書いてから rename で差し替える」保存の仕方をするので、監視対象の
inode がいきなり消えます。その場合は同じパスを開き直して監視を張り直しています。

### さらに続く見出し

改ページの直前に見出しが来たとき、見出しだけが前のページに取り残されないことを
確認します。`break-after: avoid-page` を効かせているので、見出しは必ず次の本文と
同じページに乗るはずです。

この段落は、その確認のために置かれています。前の見出しとこの段落が別のページに
分かれていたら、印刷用 CSS の改ページ制御が効いていません。
