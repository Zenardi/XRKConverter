#!/bin/bash
# Assemble XRKConverter.app: build the Swift binary, then lay out a macOS
# application bundle with the embedded Python runtime + converter script.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_SRC="$ROOT/app"
RES="$APP_SRC/Resources"
DIST="$ROOT/dist"
APP="$DIST/XRKConverter.app"
CONTENTS="$APP/Contents"

VERSION="0.1.0"
BUNDLE_ID="com.xrkconverter.app"

# 0. Ensure the embedded Python is present.
if [ ! -x "$RES/python/bin/python3" ] || [ ! -f "$RES/xrk2csv.py" ]; then
  echo "Embedded runtime missing — running bundle_python.sh first."
  bash "$ROOT/scripts/bundle_python.sh"
fi

# 1. Build the Swift executable.
echo "==> Building Swift app (release)"
( cd "$APP_SRC" && swift build -c release )
BIN="$APP_SRC/.build/release/XRKConverter"

# 2. Lay out the bundle.
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN" "$CONTENTS/MacOS/XRKConverter"
printf 'APPL????' > "$CONTENTS/PkgInfo"

# 3. Copy the embedded runtime + converter into Resources.
echo "==> Copying embedded Python + converter"
cp -R "$RES/python" "$CONTENTS/Resources/python"
cp "$RES/xrk2csv.py" "$CONTENTS/Resources/xrk2csv.py"

# 4. Info.plist
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>XRKConverter</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleName</key><string>XRK to CSV</string>
    <key>CFBundleDisplayName</key><string>XRK → CSV</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>CFBundleDocumentTypes</key>
    <array>
      <dict>
        <key>CFBundleTypeName</key><string>AiM Data Log</string>
        <key>CFBundleTypeRole</key><string>Viewer</string>
        <key>LSHandlerRank</key><string>Alternate</string>
        <key>CFBundleTypeExtensions</key>
        <array><string>xrk</string><string>xrz</string></array>
      </dict>
    </array>
</dict>
</plist>
PLIST

# 5. Ad-hoc code sign so it runs locally on Apple Silicon.
echo "==> Ad-hoc code signing"
codesign --force --sign - --timestamp=none \
  "$CONTENTS/MacOS/XRKConverter" >/dev/null 2>&1 || true
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "==> Done: $APP"
du -sh "$APP"
echo "Launch with:  open \"$APP\""
