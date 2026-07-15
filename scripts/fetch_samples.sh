#!/bin/bash
# Download test fixtures (real .xrk files + a RaceStudio reference CSV) from the
# libxrk repo. Idempotent + cached. Needed by the test/coverage/e2e suites.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/samples"
mkdir -p "$S"
base="https://raw.githubusercontent.com/m3rlin45/libxrk/master"

dl() {  # remote-path  local-name
  if [ -s "$S/$2" ]; then echo "  cached  $2"; return; fi
  echo "  fetch   $2"
  curl -sfL "$base/$1" -o "$S/$2"
}

echo "==> Fetching samples into $S"
dl "tests/test_data/aim_official/test.xrk" "aim_official_test.xrk"
dl "tests/test_data/SFJ/CMD_SFJ_Fuji%20GP%20Sh_Generic%20testing_a_0033.xrk" "fuji_0033.xrk"
dl "tests/test_data/SFJ/CMD_SFJ_Fuji%20GP%20Sh_Generic%20testing_a_0033.csv" "fuji_0033_reference.csv"
echo "Done."
