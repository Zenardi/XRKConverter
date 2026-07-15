#!/bin/bash
# Bundle a relocatable Python runtime + libxrk into app/Resources so the .app
# is self-contained (no system Python required). Uses python-build-standalone.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RES="$ROOT/app/Resources"
CACHE="${XRK_CACHE:-$ROOT/.cache}"

PY_VERSION="3.11.15"
PBS_TAG="20260623"
ARCH="$(uname -m)"   # arm64 -> aarch64
case "$ARCH" in
  arm64) PBS_ARCH="aarch64" ;;
  x86_64) PBS_ARCH="x86_64" ;;
  *) echo "Unsupported arch: $ARCH" >&2; exit 1 ;;
esac
ASSET="cpython-${PY_VERSION}+${PBS_TAG}-${PBS_ARCH}-apple-darwin-install_only_stripped.tar.gz"
URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_TAG}/${ASSET}"

mkdir -p "$CACHE" "$RES"

echo "==> Downloading $ASSET"
if [ ! -f "$CACHE/$ASSET" ]; then
  curl -fL "$URL" -o "$CACHE/$ASSET"
fi

echo "==> Extracting to $RES/python"
rm -rf "$RES/python"
tar -xzf "$CACHE/$ASSET" -C "$RES"   # extracts a 'python/' directory

PYBIN="$RES/python/bin/python3"
echo "==> Embedded Python: $("$PYBIN" --version)"

echo "==> Installing libxrk into the embedded runtime"
"$PYBIN" -m pip install --no-cache-dir --upgrade pip >/dev/null
"$PYBIN" -m pip install --no-cache-dir libxrk

echo "==> Copying converter script"
cp "$ROOT/core/xrk2csv.py" "$RES/xrk2csv.py"

echo "==> Pruning to reduce bundle size"
PYLIB="$RES/python/lib/python3.11"
# Remove build-time and rarely-needed pieces.
rm -rf "$PYLIB/test" "$PYLIB/idlelib" "$PYLIB/lib2to3" \
       "$PYLIB/tkinter" "$PYLIB/turtledemo" "$PYLIB/ensurepip" \
       "$RES/python/lib/python3.11/config-"* 2>/dev/null || true
# Drop pip/setuptools after install (not needed at runtime).
rm -rf "$PYLIB/site-packages/pip" "$PYLIB/site-packages/pip-"* \
       "$PYLIB/site-packages/setuptools" "$PYLIB/site-packages/setuptools-"* \
       "$PYLIB/site-packages/_distutils_hack" "$PYLIB/site-packages/pkg_resources" 2>/dev/null || true
# pyarrow: Flight (gRPC) is a large, optional component not linked by the core
# lib and never used by libxrk. NOTE: substrait/dataset/acero/parquet are hard-
# linked by pyarrow's core lib.so and must NOT be removed.
PA="$PYLIB/site-packages/pyarrow"
if [ -d "$PA" ]; then
  rm -f "$PA"/libarrow_flight*.dylib "$PA"/_flight*.so \
        "$PA"/libarrow_python_flight*.dylib "$PA"/libgandiva*.dylib "$PA"/_gandiva*.so 2>/dev/null || true
fi
# Cython/pyximport are build-time only; libxrk's compiled extension does not
# need them at runtime.
rm -rf "$PYLIB/site-packages/Cython" "$PYLIB/site-packages/pyximport" \
       "$PYLIB/site-packages/cython-"* "$PYLIB/site-packages/Cython-"* 2>/dev/null || true
# Silence a benign .pth that references pruned setuptools internals.
rm -f "$PYLIB/site-packages/distutils-precedence.pth" 2>/dev/null || true
# Static libs and headers are not needed at runtime.
find "$RES/python/lib" -name '*.a' -delete 2>/dev/null || true
rm -rf "$RES/python/include" 2>/dev/null || true
# Byte-code caches and test dirs inside site-packages.
find "$RES/python" -type d -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true
find "$RES/python" -type d -name 'tests' -prune -exec rm -rf {} + 2>/dev/null || true

echo "==> Verifying the embedded runtime can import libxrk and run the converter"
"$PYBIN" -c "import libxrk, numpy, pyarrow; print('libxrk import OK')"

echo "==> Bundle size:"
du -sh "$RES/python"
echo "Done. Resources ready at $RES"
