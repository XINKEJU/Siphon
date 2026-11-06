#!/bin/bash
# Regenerate the Siphon macOS icon set from the vector source.
#   ./scripts/make-icon.sh
# Outputs (all under Resources/):
#   AppIcon.icns                     shipped in the .app bundle
#   AppIcon-1024.png                 master artwork
#   AppIcon-Preview.png              Finder-style squircle preview
#   AppIcon.iconset/                 10 native-resolution PNGs
#   Assets.xcassets/AppIcon.appiconset/  ready for Xcode
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RES="$ROOT/Resources"
TMP="$(mktemp -d /tmp/siphon-icon.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# swiftc only permits top-level code in a file literally named main.swift.
cp "$ROOT/scripts/MakeIcon.swift" "$TMP/main.swift"
echo "==> Compiling vector icon renderer"
swiftc -O -o "$TMP/makeicon" "$TMP/main.swift"

echo "==> Rendering native-resolution PNGs"
"$TMP/makeicon" "$ROOT"

echo "==> Building .icns"
rm -rf "$RES/AppIcon.icns"
iconutil -c icns -o "$RES/AppIcon.icns" "$RES/AppIcon.iconset"

echo "==> Verifying"
sips -g pixelWidth -g pixelHeight "$RES/AppIcon-1024.png" | tail -2
for f in "$RES/AppIcon.icns" "$RES/AppIcon-1024.png" "$RES/AppIcon-Preview.png"; do
    test -s "$f" || { echo "!! missing $f"; exit 1; }
done
echo "    icns: $(du -h "$RES/AppIcon.icns" | awk '{print $1}')"
echo "    sizes: $(ls -1 "$RES/AppIcon.iconset" | wc -l | tr -d ' ') PNGs"
echo "==> Done"
