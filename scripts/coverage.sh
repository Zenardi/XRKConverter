#!/bin/bash
# Coverage gate: runs the Python + Swift-Core suites and fails if either drops
# below the line-coverage threshold. Used locally and in CI.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
THRESHOLD="${COVERAGE_THRESHOLD:-95}"
VENV="$ROOT/.venv"
PYBIN="$VENV/bin"

echo "############################################################"
echo "# Coverage gate — threshold ${THRESHOLD}% (line coverage)"
echo "############################################################"

# --- ensure test fixtures + python deps ---
bash "$ROOT/scripts/fetch_samples.sh"
if [ ! -x "$PYBIN/python3" ]; then
  echo "==> Creating venv"; python3 -m venv "$VENV"
fi
"$PYBIN/python3" -m pip install --quiet --upgrade pip
"$PYBIN/python3" -m pip install --quiet libxrk coverage

# ---------------------------------------------------------------------------
# Python
# ---------------------------------------------------------------------------
echo; echo "==> Python coverage (core/xrk2csv.py)"
( cd "$ROOT/core"
  "$PYBIN/coverage" run --source=. -m unittest discover -s tests -p 'test_*.py'
  "$PYBIN/coverage" report -m --include='*xrk2csv.py' --fail-under="$THRESHOLD"
)

# ---------------------------------------------------------------------------
# Swift (Core library only)
# ---------------------------------------------------------------------------
echo; echo "==> Swift coverage (XRKConverterCore)"
( cd "$ROOT/app"
  # Point the Swift integration tests at the dev venv + a sample.
  export XRK_TEST_PYTHON="$PYBIN/python3"
  export XRK_TEST_SCRIPT="$ROOT/core/xrk2csv.py"
  export XRK_TEST_SAMPLE="$ROOT/samples/aim_official_test.xrk"
  bash "$ROOT/scripts/swift_test.sh" --enable-code-coverage

  BIN="$(find .build -name XRKConverterPackageTests -type f -path '*/Contents/MacOS/*' ! -path '*.dSYM*' | head -1)"
  PROF="$(find .build -name 'default.profdata' | head -1)"
  xcrun llvm-cov export -summary-only "$BIN" -instr-profile "$PROF" \
    Sources/XRKConverterCore > "$ROOT/.cache-swift-cov.json"
  "$PYBIN/python3" - "$ROOT/.cache-swift-cov.json" "$THRESHOLD" <<'PY'
import json, sys
data = json.load(open(sys.argv[1])); thr = float(sys.argv[2])
pct = data["data"][0]["totals"]["lines"]["percent"]
print(f"  XRKConverterCore line coverage: {pct:.2f}%")
if pct < thr:
    print(f"  FAIL: below {thr}%"); sys.exit(1)
print(f"  PASS: >= {thr}%")
PY
  rm -f "$ROOT/.cache-swift-cov.json"
)

echo; echo "############################################################"
echo "# Coverage gate PASSED (both suites >= ${THRESHOLD}%)"
echo "############################################################"
