#!/usr/bin/env bash
# Create a drag-to-install DMG from the packaged .app.
#   ./scripts/build-app.sh && ./scripts/make-dmg.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Siphon.app"

if [[ ! -d "$APP" ]]; then
    echo "!! $APP not found -- run ./scripts/build-app.sh first" >&2
    exit 1
fi

VERSION="$(plutil -extract CFBundleShortVersionString raw "$ROOT/Resources/Info.plist")"
DMG="$ROOT/build/Siphon-$VERSION.dmg"
STAGE="$(mktemp -d /tmp/siphon-dmg.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT

# ditto (not cp -R) preserves the code signature, extended attributes and ACLs.
ditto "$APP" "$STAGE/Siphon.app"
ln -s /Applications "$STAGE/Applications"

echo "==> Creating $DMG"
hdiutil create -volname "Siphon" -srcfolder "$STAGE" -ov -format UDZO -o "$DMG"

echo "==> Verifying image"
MP="$(mktemp -d /tmp/siphon-mnt.XXXXXX)"
trap 'hdiutil detach "$MP" >/dev/null 2>&1 || true; rm -rf "$STAGE" "$MP"' EXIT
hdiutil attach -nobrowse -readonly -mountpoint "$MP" "$DMG" >/dev/null 2>&1
codesign --verify --deep --strict "$MP/Siphon.app"
test -L "$MP/Applications"
hdiutil detach "$MP" >/dev/null 2>&1
echo "==> Done: $DMG ($(du -h "$DMG" | awk '{print $1}'))"
