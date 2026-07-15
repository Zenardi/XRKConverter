#!/bin/bash
# Notarize an artifact with Apple and staple the ticket onto the given targets.
#
# Requires (App Store Connect API key auth):
#   NOTARY_KEY_ID     - key ID
#   NOTARY_ISSUER_ID  - issuer ID
#   NOTARY_KEY_PATH   - path to the AuthKey_XXXX.p8 file
#
# Usage: notarize.sh SUBMIT_ARTIFACT [STAPLE_TARGET ...]
#   SUBMIT_ARTIFACT is uploaded to Apple (a .dmg/.zip/.pkg). Each STAPLE_TARGET
#   (plus the submit artifact) then gets the ticket stapled.
set -euo pipefail

: "${NOTARY_KEY_ID:?set NOTARY_KEY_ID}"
: "${NOTARY_ISSUER_ID:?set NOTARY_ISSUER_ID}"
: "${NOTARY_KEY_PATH:?set NOTARY_KEY_PATH}"

SUBMIT="${1:?usage: notarize.sh SUBMIT_ARTIFACT [STAPLE_TARGET ...]}"
shift || true

echo "==> Submitting $SUBMIT to Apple notary service (waiting for result)…"
xcrun notarytool submit "$SUBMIT" \
  --key "$NOTARY_KEY_PATH" \
  --key-id "$NOTARY_KEY_ID" \
  --issuer "$NOTARY_ISSUER_ID" \
  --wait

echo "==> Stapling notarization tickets"
for target in "$SUBMIT" "$@"; do
  [ -e "$target" ] || continue
  echo "  staple $target"
  xcrun stapler staple "$target"
  xcrun stapler validate "$target"
done
echo "==> Notarization complete."
