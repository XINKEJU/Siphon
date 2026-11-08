#!/usr/bin/env bash
# Notarize and staple a Developer ID build of Siphon.
#
# Prerequisites (one-time, requires an Apple Developer Program membership):
#   xcrun notarytool store-credentials "AC_PASSWORD" \
#       --apple-id "you@example.com" --team-id "TEAMID" \
#       --password "<app-specific-password>"
#
# Build first with a real identity, then package, then notarize:
#   SIPHON_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
#       SIPHON_SANDBOX=1 ./scripts/build-app.sh
#   ./scripts/make-dmg.sh
#   NOTARY_PROFILE=AC_PASSWORD ./scripts/notarize.sh build/Siphon.app
#
# Without a Developer ID this script exits with a clear error. An adhoc-signed
# bundle cannot be notarized and will be blocked by Gatekeeper once quarantined.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="${1:-$ROOT/build/Siphon.app}"
PROFILE="${NOTARY_PROFILE:-}"

if [[ ! -d "$APP" ]]; then
    echo "!!  not an .app bundle: $APP" >&2
    exit 1
fi
if [[ -z "$PROFILE" ]]; then
    echo "!!  NOTARY_PROFILE is required (see the header of this script)." >&2
    exit 1
fi

INFO="$(codesign -dv --verbose=4 "$APP" 2>&1 || true)"
if [[ "$INFO" != *"Developer ID Application"* ]]; then
    echo "!!  $APP is not signed with a Developer ID Application identity." >&2
    echo "    Rebuild with SIPHON_SIGN_IDENTITY=... ./scripts/build-app.sh" >&2
    exit 1
fi
if [[ "$INFO" != *"flags=0x10000(runtime)"* && "$INFO" != *"runtime"* ]]; then
    echo "!!  Hardened Runtime not detected in the signature." >&2
    exit 1
fi

ZIP="$(mktemp -d)/Siphon-notarize.zip"
trap 'rm -rf "$(dirname "$ZIP")"' EXIT
echo "==> Zipping $APP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Submitting to Apple notary service (profile: $PROFILE)"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "==> Stapling ticket"
xcrun stapler staple "$APP"

echo "==> Gatekeeper assessment"
spctl -a -vvv -t execute "$APP"

echo "==> Notarization complete: $APP"
echo "    Rebuild the DMG now: ./scripts/make-dmg.sh"
