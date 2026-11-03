#!/bin/sh
# Regenerates app/AppIcon.icns from docs/soundrouter.png (a squircle on a black glow background):
# crops the squircle, masks it, and centres it on a 1024 canvas with the standard macOS margin.
set -e
cd "$(dirname "$0")/.."
T=$(mktemp -d); I="$T/AppIcon.iconset"; mkdir "$I"
cat > "$T/m.swift" <<'SW'
import AppKit
let a = CommandLine.arguments
let src = NSImage(contentsOfFile: a[1])!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
// squircle bounds measured in the 1536x1024 source, inset a few px to drop the glow
let crop = src.cropping(to: CGRect(x: 402, y: 160, width: 718, height: 718))!
let S = 1024, art = 824, m = (S - art) / 2
let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.interpolationQuality = .high
let r = CGRect(x: m, y: m, width: art, height: art)
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.35))
ctx.addPath(CGPath(roundedRect: r, cornerWidth: 184, cornerHeight: 184, transform: nil)); ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fillPath()
ctx.setShadow(offset: .zero, blur: 0)
ctx.addPath(CGPath(roundedRect: r, cornerWidth: 184, cornerHeight: 184, transform: nil)); ctx.clip()
ctx.draw(crop, in: r)
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
SW
swiftc -O "$T/m.swift" -o "$T/m" 2>&1 | grep error || true
"$T/m" docs/soundrouter.png "$T/1024.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$T/1024.png" --out "$I/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$T/1024.png" --out "$I/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$I" -o app/AppIcon.icns
cp "$T/1024.png" /tmp/sr-icon-preview.png
echo "wrote app/AppIcon.icns"
