#!/bin/bash
# Assemble Trace.app: build the Swift binary, then lay out a macOS
# application bundle with the embedded Python runtime + converter script.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_SRC="$ROOT/app"
RES="$APP_SRC/Resources"
DIST="$ROOT/dist"
APP="$DIST/Trace.app"
CONTENTS="$APP/Contents"

# CI passes VERSION from the release tag (see release.yml); defaults for local builds.
VERSION="${VERSION:-0.2.0}"
BUNDLE_ID="com.zenardi.trace"

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
cp "$BIN" "$CONTENTS/MacOS/Trace"
printf 'APPL????' > "$CONTENTS/PkgInfo"

# 3. Copy the embedded runtime + converter into Resources.
echo "==> Copying embedded Python + converter"
cp -R "$RES/python" "$CONTENTS/Resources/python"
cp "$RES/xrk2csv.py" "$CONTENTS/Resources/xrk2csv.py"

# 3b. App icon (Trace mark). Committed .icns so the build needs no rasterizer.
if [ -f "$ROOT/branding/AppIcon.icns" ]; then
  cp "$ROOT/branding/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
fi

# 4. Info.plist
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Trace</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleName</key><string>Trace</string>
    <key>CFBundleDisplayName</key><string>Trace</string>
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

# 5. Code sign.
#    With SIGN_IDENTITY (a "Developer ID Application: ..." identity) we deep-sign
#    every embedded Mach-O with the hardened runtime + entitlements so the app
#    can be notarized. Otherwise we ad-hoc sign for local use.
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
ENTITLEMENTS="${ENTITLEMENTS:-$APP_SRC/XRKConverter.entitlements}"

if [ -n "$SIGN_IDENTITY" ]; then
  echo "==> Signing with Developer ID (hardened runtime): $SIGN_IDENTITY"
  # Inner Mach-O first (interpreter, dylibs, extension modules), then the main
  # executable, then the bundle. codesign must sign nested code before its host.
  while IFS= read -r f; do
    if file -b "$f" | grep -q 'Mach-O'; then
      codesign --force --options runtime --timestamp -s "$SIGN_IDENTITY" "$f"
    fi
  done < <(find "$CONTENTS/Resources" -type f)

  # The interpreter loads compiled extensions, so give it the entitlements.
  for pybin in "$CONTENTS/Resources/python/bin/"python3.*; do
    [ -f "$pybin" ] && file -b "$pybin" | grep -q 'Mach-O' || continue
    codesign --force --options runtime --timestamp \
      --entitlements "$ENTITLEMENTS" -s "$SIGN_IDENTITY" "$pybin"
  done

  codesign --force --options runtime --timestamp -s "$SIGN_IDENTITY" "$CONTENTS/MacOS/Trace"
  codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" -s "$SIGN_IDENTITY" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
  echo "==> Signed and verified."
else
  echo "==> Ad-hoc code signing (local use; not notarizable)"
  codesign --force --sign - "$CONTENTS/MacOS/Trace" >/dev/null 2>&1 || true
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
fi

echo "==> Done: $APP"
du -sh "$APP"
echo "Launch with:  open \"$APP\""
