#!/bin/bash
# Regenerate branding/AppIcon.icns + doc PNGs from the SVG master.
#
# Dev-time tool only — the resulting AppIcon.icns is committed, so the app build
# (build_app.sh) does NOT depend on a rasterizer. Re-run this whenever
# branding/trace-appicon.svg changes. Uses only stock macOS tools
# (qlmanage QuickLook renderer + sips + iconutil); no ImageMagick/Inkscape needed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
B="$ROOT/branding"
SVG="$B/trace-appicon.svg"
TMP="$B/.render"

command -v qlmanage >/dev/null || { echo "qlmanage not found (needs macOS)"; exit 1; }

echo "==> Rendering 1024px master from $SVG"
rm -rf "$TMP"; mkdir -p "$TMP"
qlmanage -t -s 1024 -o "$TMP" "$SVG" >/dev/null 2>&1
MASTER="$TMP/$(basename "$SVG").png"
[ -f "$MASTER" ] || { echo "QuickLook render failed"; exit 1; }

echo "==> Exporting doc PNGs"
cp "$MASTER" "$B/trace-appicon-1024.png"
sips -z 512 512 "$MASTER" --out "$B/trace-appicon-512.png" >/dev/null

echo "==> Building AppIcon.icns"
ISET="$B/Trace.iconset"; rm -rf "$ISET"; mkdir "$ISET"
for e in 16:icon_16x16 32:icon_16x16@2x 32:icon_32x32 64:icon_32x32@2x \
         128:icon_128x128 256:icon_128x128@2x 256:icon_256x256 512:icon_256x256@2x \
         512:icon_512x512 1024:icon_512x512@2x; do
  px="${e%%:*}"; name="${e##*:}"
  sips -z "$px" "$px" "$MASTER" --out "$ISET/${name}.png" >/dev/null
done
iconutil -c icns "$ISET" -o "$B/AppIcon.icns"

rm -rf "$ISET" "$TMP"
echo "==> Done: $B/AppIcon.icns"
