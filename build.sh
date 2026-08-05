#!/bin/bash
# MDViewer.app をビルドする。Xcode プロジェクトは使わず swiftc で直接コンパイルし、
# .app バンドルを手で組み立てる。数秒で終わる。
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="MDViewer"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
DEPLOY_TARGET="13.0"

# --- 事前チェック -----------------------------------------------------------
if [ ! -s "Resources/vendor/markdown-it.min.js" ]; then
  echo "ベンダーアセットが未取得です。./fetch-vendor.sh を先に実行してください。" >&2
  exit 1
fi

# --- 前回の成果物を掃除 -----------------------------------------------------
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# --- コンパイル -------------------------------------------------------------
# ネイティブ arm64 のみ。Intel も要るなら x86_64 でもう一度ビルドして lipo する。
ARCH="$(uname -m)"
echo "コンパイル中 ($ARCH, macOS $DEPLOY_TARGET 以上)..."
xcrun swiftc \
  -O -wmo \
  -target "${ARCH}-apple-macos${DEPLOY_TARGET}" \
  -framework AppKit -framework WebKit -framework PDFKit \
  -o "$APP/Contents/MacOS/$APP_NAME" \
  Sources/*.swift

# --- バンドルを組み立て -----------------------------------------------------
cp Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Resources/ 配下をそのままコピー（shell.html, style.css, print.css, app.js, vendor/, AppIcon.icns）
cp -R Resources/ "$APP/Contents/Resources/"

# --- 署名 -------------------------------------------------------------------
# ローカル配布なので ad-hoc 署名。これがないと Gatekeeper や TCC の挙動が不安定になる。
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1

SIZE="$(du -sh "$APP" | cut -f1)"
echo "完成: $APP  ($SIZE)"
echo "起動: open '$APP'      インストール: ./install.sh"
