#!/bin/bash
# markdown-it と highlight.js を Resources/vendor/ に取得する。
# 初回のみ実行すればよい（取得後はリポジトリに同梱され、実行時はオフラインで完結する）。
set -euo pipefail

cd "$(dirname "$0")"
VENDOR="Resources/vendor"
mkdir -p "$VENDOR"

MDIT_VER="14.1.0"
MDIT_FOOTNOTE_VER="4.0.0"
HLJS_VER="11.11.1"

fetch() {
  local url="$1" out="$2"
  if [ -s "$out" ]; then
    echo "  skip  $out (既に存在)"
    return
  fi
  echo "  get   $out"
  curl -fsSL --retry 3 "$url" -o "$out"
}

echo "ベンダーアセットを取得します..."

fetch "https://cdn.jsdelivr.net/npm/markdown-it@${MDIT_VER}/dist/markdown-it.min.js" \
      "$VENDOR/markdown-it.min.js"

# 脚注（[^1]）は markdown-it 本体に入っていないが実用上よく使うので入れる。
fetch "https://cdn.jsdelivr.net/npm/markdown-it-footnote@${MDIT_FOOTNOTE_VER}/dist/markdown-it-footnote.min.js" \
      "$VENDOR/markdown-it-footnote.min.js"

# highlight.js は common ビルド（主要 ~40 言語）を使う。full は 1MB 超で無駄が大きい。
fetch "https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@${HLJS_VER}/build/highlight.min.js" \
      "$VENDOR/highlight.min.js"
fetch "https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@${HLJS_VER}/build/styles/github.min.css" \
      "$VENDOR/hljs-light.css"
fetch "https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@${HLJS_VER}/build/styles/github-dark.min.css" \
      "$VENDOR/hljs-dark.css"

cat > "$VENDOR/LICENSE.md" <<EOF
本ディレクトリのファイルは以下のサードパーティ製ライブラリです。

- markdown-it ${MDIT_VER} — MIT License — https://github.com/markdown-it/markdown-it
- markdown-it-footnote ${MDIT_FOOTNOTE_VER} — MIT License — https://github.com/markdown-it/markdown-it-footnote
- highlight.js ${HLJS_VER} — BSD 3-Clause License — https://github.com/highlightjs/highlight.js
  （github / github-dark テーマを含む）
EOF

echo "完了:"
ls -lh "$VENDOR"
