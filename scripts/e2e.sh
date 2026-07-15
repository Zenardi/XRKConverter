#!/bin/bash
# End-to-end test: convert every available .xrk through the SHIPPING pipeline and
# validate the CSV is RaceChrono-importable. Prefers the built app's embedded
# Python (the real artifact); falls back to the dev venv.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

APP_PY="$ROOT/dist/XRKConverter.app/Contents/Resources/python/bin/python3"
APP_SC="$ROOT/dist/XRKConverter.app/Contents/Resources/xrk2csv.py"
VENV_PY="$ROOT/.venv/bin/python3"

if [ -x "$APP_PY" ] && [ -f "$APP_SC" ]; then
  PY="$APP_PY"; SC="$APP_SC"; echo "==> Using built app runtime"
elif [ -x "$VENV_PY" ]; then
  PY="$VENV_PY"; SC="$ROOT/core/xrk2csv.py"; echo "==> Using dev venv"
else
  echo "No converter runtime found (build the app or create the venv)." >&2
  exit 1
fi

VALIDATE="$ROOT/scripts/validate_csv.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

shopt -s nullglob
files=("$ROOT"/samples/*.xrk "$ROOT"/test-file/*.xrk)
if [ ${#files[@]} -eq 0 ]; then
  echo "No .xrk files found (run scripts/fetch_samples.sh)." >&2
  exit 1
fi

n=0
for f in "${files[@]}"; do
  base="$(basename "$f" .xrk)"
  out="$TMP/$base.csv"
  echo "==> Converting $base.xrk"
  "$PY" "$SC" "$f" -o "$out" --json >/dev/null 2>"$TMP/$base.err" \
    || { echo "  FAIL: converter errored"; cat "$TMP/$base.err"; exit 1; }
  "$PY" "$VALIDATE" "$out"
  n=$((n + 1))
done

echo "E2E OK — $n file(s) converted and validated."
