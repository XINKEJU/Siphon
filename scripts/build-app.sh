#!/usr/bin/env bash
# Build a real, codesigned-by-adhoc macOS .app bundle with aria2c embedded.
# Usage:
#   ./scripts/build-app.sh                 # release .app in ./build/
#   ARIA2C=/path/to/aria2c ./scripts/build-app.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="$ROOT/build/Siphon.app"
CONTENTS="$APP/Contents"
BIN_DIR="$(swift build -c release --show-bin-path 2>/dev/null)"

echo "==> Building release binary"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
BIN="$BIN_DIR/Siphon"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN" "$CONTENTS/MacOS/Siphon"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"

# Lift LC_BUILD_VERSION.sdk to the SDK actually used for this build. Package.swift
# pins 26.0 so plain `swift run` also gets the modern chrome; here we use the real
# SDK (e.g. 27.2) so the shipped bundle adopts the newest window metrics. macOS
# 26+ falls back to the opaque pre-Tahoe title bar when this field says 14.0.
APP_BIN="$CONTENTS/MacOS/Siphon"
SDK_VERSION="$(xcrun --show-sdk-version)"
MIN_VERSION="$(vtool -show-build "$APP_BIN" | awk '/minos/{print $2; exit}')"
LD_VERSION="$(vtool -show-build "$APP_BIN" | awk '/version/{print $2; exit}')"
VTOOL_TMP="$(mktemp)"
if vtool -set-build-version macos "${MIN_VERSION:-14.0}" "$SDK_VERSION" \
        -tool ld "${LD_VERSION:-1}" -replace -output "$VTOOL_TMP" "$APP_BIN" >/dev/null 2>&1; then
    cp "$VTOOL_TMP" "$APP_BIN"
    chmod +x "$APP_BIN"
    echo "==> Linked SDK $SDK_VERSION (modern window chrome enabled)"
else
    echo "!!  vtool could not update LC_BUILD_VERSION; window chrome may fall back" >&2
fi
rm -f "$VTOOL_TMP"

# App icon. Generate from the vector source if this is a fresh clone.
if [[ ! -f "$ROOT/Resources/AppIcon.icns" ]]; then
    echo "==> Generating app icon from vector source"
    "$ROOT/scripts/make-icon.sh"
fi
cp "$ROOT/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"

# Locate aria2c: explicit env var, Homebrew (Apple Silicon / Intel), or PATH.
ARIA2C="${ARIA2C:-}"
if [[ -z "$ARIA2C" ]]; then
    for c in /opt/homebrew/bin/aria2c /usr/local/bin/aria2c; do
        [[ -x "$c" ]] && ARIA2C="$c" && break
    done
fi
if [[ -z "$ARIA2C" ]] && command -v aria2c >/dev/null 2>&1; then
    ARIA2C="$(command -v aria2c)"
fi

FRAMEWORKS="$CONTENTS/Frameworks"
mkdir -p "$FRAMEWORKS"
SEEN_DIR="$(mktemp -d)"
trap 'rm -rf "$SEEN_DIR"' EXIT
RELINK_COUNT=0

# A Homebrew aria2c links against /opt/homebrew/opt/*/lib/*.dylib. Copy those
# into the bundle and rewrite load commands to @executable_path so the app runs
# on machines without Homebrew. Handle transitive deps (e.g. libssl -> libcrypto).
# Uses marker files instead of associative arrays: /bin/bash on macOS is 3.2.
relink() {
    local target="$1"
    local key
    key="$(printf '%s' "$target" | shasum | awk '{print $1}')"
    [[ -f "$SEEN_DIR/$key" ]] && return
    : > "$SEEN_DIR/$key"
    RELINK_COUNT=$((RELINK_COUNT + 1))
    chmod u+w "$target" 2>/dev/null || true
    while read -r lib; do
        case "$lib" in
            /opt/homebrew/*|/usr/local/*)
                local name dest
                name="$(basename "$lib")"
                dest="$FRAMEWORKS/$name"
                if [[ ! -f "$dest" ]]; then
                    cp -L "$lib" "$dest" 2>/dev/null || continue
                    chmod u+w "$dest"
                    install_name_tool -id "@executable_path/../Frameworks/$name" "$dest" 2>/dev/null || true
                fi
                install_name_tool -change "$lib" \
                    "@executable_path/../Frameworks/$name" "$target" 2>/dev/null || true
                relink "$dest"
                ;;
        esac
    done < <(otool -L "$target" 2>/dev/null | awk 'NR>1 {print $1}')
}

if [[ -n "$ARIA2C" && -x "$ARIA2C" ]]; then
    cp "$ARIA2C" "$CONTENTS/Resources/aria2c"
    chmod +x "$CONTENTS/Resources/aria2c"
    relink "$CONTENTS/Resources/aria2c"
    echo "==> Bundled aria2c from $ARIA2C ($RELINK_COUNT image(s) relinked)"
    echo "    Frameworks: $(ls -1 "$FRAMEWORKS" | tr '\n' ' ')"
else
    echo "!!  aria2c not found. HTTP/FTP/BT downloads will be unavailable until you"
    echo "    place a universal aria2c binary at $CONTENTS/Resources/aria2c"
    echo "    (e.g. 'brew install aria2' then re-run, or pass ARIA2C=/path/to/aria2c)."
fi

# Optional ffmpeg for fMP4 / DASH remux.
if command -v ffmpeg >/dev/null 2>&1; then
    cp "$(command -v ffmpeg)" "$CONTENTS/Resources/ffmpeg"
    chmod +x "$CONTENTS/Resources/ffmpeg"
    relink "$CONTENTS/Resources/ffmpeg"
    echo "==> Bundled ffmpeg (dylibs relinked)"
fi

# Re-sign every nested Mach-O explicitly. `--deep` alone does NOT reliably
# re-sign helper executables in Resources/ or dylibs in Frameworks/, and an
# install_name_tool-modified binary with a stale signature is SIGKILLed (137)
# by the kernel at launch.
echo "==> Signing nested binaries"
for img in "$CONTENTS/Resources/aria2c" "$CONTENTS/Resources/ffmpeg" \
           "$FRAMEWORKS"/*.dylib; do
    [[ -f "$img" ]] && codesign --force --sign - "$img" 2>/dev/null || true
done
codesign --force --sign - "$APP" 2>/dev/null || \
    echo "!!  codesign unavailable; app will still run locally"

if codesign --verify --deep --strict --verbose=1 "$APP" 2>/dev/null; then
    echo "==> Signature verified"
else
    echo "!!  Signature verification failed"
fi

echo "==> Done: $APP"
echo "    open \"$APP\""
