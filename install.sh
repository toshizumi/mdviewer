#!/bin/bash
# ビルド済みの MDViewer.app を /Applications に配置し、LaunchServices に登録する。
# 登録することで Finder の右クリック →「このアプリケーションで開く」に即座に現れる。
set -euo pipefail

cd "$(dirname "$0")"

SRC="build/MDViewer.app"
DEST="/Applications/MDViewer.app"

if [ ! -d "$SRC" ]; then
  echo "$SRC がありません。先に ./build.sh を実行してください。" >&2
  exit 1
fi

# 起動中なら一度終了させる（コピー中の差し替えでクラッシュさせないため）
if pgrep -x MDViewer >/dev/null 2>&1; then
  echo "起動中の MDViewer を終了します..."
  osascript -e 'quit app "MDViewer"' >/dev/null 2>&1 || true
  sleep 1
fi

echo "$DEST へインストール中..."
rm -rf "$DEST"
cp -R "$SRC" "$DEST"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
# 開発中にビルド版を起動していると「このアプリケーションで開く」に二重で並ぶので登録を外す
"$LSREGISTER" -u "$PWD/$SRC" >/dev/null 2>&1 || true
"$LSREGISTER" -f "$DEST"

echo "完了。"
echo
echo "使い方:"
echo "  Finder で .md ファイルを右クリック →「このアプリケーションで開く」→ MDViewer"
echo "  常に MDViewer で開きたい場合は、⌘I（情報を見る）→「このアプリケーションで開く」"
echo "  で MDViewer を選び「すべてを変更...」を押してください。"
