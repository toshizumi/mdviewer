#!/bin/bash
# AppIcon.icns を生成する。生成物はリポジトリに同梱されるので、
# デザインを変えたいとき以外は実行不要。
set -euo pipefail

cd "$(dirname "$0")"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"

cat > "$WORK/icon.swift" <<'SWIFT'
import AppKit

// 公式 Markdown マーク（viewBox 0 0 208 128）を CGPath で再現する。
private func markdownMark(in box: CGRect) -> (frame: CGPath, glyph: CGPath) {
    // SVG 座標（y 下向き）→ 描画座標（y 上向き）へ変換する行列
    let sx = box.width / 208.0, sy = box.height / 128.0
    var t = CGAffineTransform(translationX: box.minX, y: box.maxY)
        .scaledBy(x: sx, y: -sy)

    let frame = CGPath(roundedRect: CGRect(x: 5, y: 5, width: 198, height: 118),
                       cornerWidth: 12, cornerHeight: 12, transform: &t)

    let g = CGMutablePath()
    // 左側の "M"
    g.move(to: CGPoint(x: 30, y: 98))
    for p in [(30.0, 30.0), (50.0, 30.0), (70.0, 55.0), (90.0, 30.0), (110.0, 30.0),
              (110.0, 98.0), (90.0, 98.0), (90.0, 59.0), (70.0, 84.0), (50.0, 59.0),
              (50.0, 98.0)] {
        g.addLine(to: CGPoint(x: p.0, y: p.1))
    }
    g.closeSubpath()
    // 右側の下向き矢印
    g.move(to: CGPoint(x: 155, y: 98))
    for p in [(125.0, 65.0), (145.0, 65.0), (145.0, 30.0), (165.0, 30.0),
              (165.0, 65.0), (185.0, 65.0)] {
        g.addLine(to: CGPoint(x: p.0, y: p.1))
    }
    g.closeSubpath()

    return (frame, g.copy(using: &t)!)
}

func renderIcon(size: Int) -> Data {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setShouldAntialias(true)

    // 角丸スクエア（macOS のアイコングリッドに合わせて少し内側に寄せる）
    let inset = s * 0.055
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = body.width * 0.2237
    let squircle = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius,
                          transform: nil)

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let colors = [NSColor(srgbRed: 0.24, green: 0.27, blue: 0.42, alpha: 1).cgColor,
                  NSColor(srgbRed: 0.13, green: 0.14, blue: 0.22, alpha: 1).cgColor]
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: colors as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: body.maxY),
                           end: CGPoint(x: 0, y: body.minY),
                           options: [])
    ctx.restoreGState()

    // 上端のわずかなハイライト（のっぺりさせないため）。
    // 継ぎ目が出ないよう、べた塗りではなく透明へ抜けるグラデーションにする。
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [NSColor(white: 1, alpha: 0.10).cgColor,
                                    NSColor(white: 1, alpha: 0).cgColor] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(sheen,
                           start: CGPoint(x: 0, y: body.maxY),
                           end: CGPoint(x: 0, y: body.midY),
                           options: [])
    ctx.restoreGState()

    // Markdown マーク
    let markWidth = body.width * 0.62
    let markBox = CGRect(x: body.midX - markWidth / 2,
                         y: body.midY - markWidth * 128 / 208 / 2,
                         width: markWidth, height: markWidth * 128 / 208)
    let (frame, glyph) = markdownMark(in: markBox)
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineWidth(max(1, markBox.height / 128 * 10))
    ctx.setLineJoin(.round)
    ctx.addPath(frame)
    ctx.strokePath()
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.addPath(glyph)
    ctx.fillPath()

    image.unlockFocus()

    let rep = NSBitmapImageRep(cgImage: image.cgImage(forProposedRect: nil,
                                                      context: nil, hints: nil)!)
    rep.size = NSSize(width: s, height: s)
    return rep.representation(using: .png, properties: [:])!
}

let outDir = CommandLine.arguments[1]
for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32),
                   ("icon_32x32", 32), ("icon_32x32@2x", 64),
                   ("icon_128x128", 128), ("icon_128x128@2x", 256),
                   ("icon_256x256", 256), ("icon_256x256@2x", 512),
                   ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    try! renderIcon(size: px).write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}
SWIFT

echo "アイコンを描画中..."
xcrun swift "$WORK/icon.swift" "$ICONSET"

mkdir -p Resources
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
echo "完成: Resources/AppIcon.icns ($(du -h Resources/AppIcon.icns | cut -f1))"
